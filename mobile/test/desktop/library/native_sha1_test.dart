import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/library_hasher.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/desktop/library/placeholder_check.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('native_sha1_test_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String name, List<int> bytes) => File(p.join(dir.path, name))..writeAsBytesSync(bytes);

  String reference(List<int> bytes) => base64.encode(crypto.sha1.convert(bytes).bytes);

  test('the engine of the operating system is the one in use', () {
    final name = Sha1Engine.system().name;
    if (Platform.isWindows) {
      expect(name, 'cng');
    } else if (Platform.isMacOS) {
      expect(name, 'commoncrypto');
    } else if (Platform.isLinux) {
      var hasLibcrypto = true;
      try {
        LibcryptoSha1Engine.load();
      } on ArgumentError {
        hasLibcrypto = false;
      }
      expect(name, hasLibcrypto ? 'libcrypto' : 'dart');
    }
  });

  test('equal to package:crypto in base64, across chunk boundaries', () {
    final random = Random(20261008);
    final engines = [Sha1Engine.system(), const DartSha1Engine()];
    for (final length in [0, 1, 55, 64, 1000, sha1ChunkLength - 1, sha1ChunkLength, 2 * sha1ChunkLength + 3]) {
      final bytes = Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
      final file = write('f$length.bin', bytes);
      for (final engine in engines) {
        expect(sha1OfFile(file.path, engine: engine), reference(bytes), reason: '${engine.name}, $length bytes');
      }
    }
  });

  test('the known answer of "abc", as the phones give it', () {
    final file = write('abc.txt', ascii.encode('abc'));
    expect(sha1OfFile(file.path), 'qZk+NkcGgWq6PiVxeFDCbJzQ2J0=');
  });

  test('a cancel between chunks stops the read', () {
    final file = write('big.bin', Uint8List(3 * sha1ChunkLength));
    var chunks = 0;
    expect(() => sha1OfFile(file.path, isCancelled: () => ++chunks > 1), throwsA(isA<Sha1Cancelled>()));
    expect(chunks, 2);
  });

  group('one file of a run', () {
    test('a placeholder is refused without being read, a missing file gives an error', () {
      final cloud = write('cloud.jpg', [1, 2, 3]);
      final outcome = hashOneFile(
        (id: 'f1', path: cloud.path, size: 3),
        engine: Sha1Engine.system(),
        attributes: (_) => fileAttributeRecallOnDataAccess,
      );
      expect(outcome.hash, isNull);
      expect(outcome.error, contains('online only'));

      final missing = hashOneFile((id: 'f2', path: p.join(dir.path, 'gone.jpg'), size: 3), engine: Sha1Engine.system());
      expect(missing.hash, isNull);
      expect(missing.error, startsWith('Failed to hash asset'));
    });
  });

  group('the isolate pool', () {
    test('one outcome per file, in the order asked, the largest files spread over the workers', () async {
      final random = Random(7);
      final jobs = <HashJob>[];
      final expected = <String>[];
      for (var i = 0; i < 9; i++) {
        final bytes = Uint8List.fromList(List.generate(1000 * (i + 1) * (i + 1), (_) => random.nextInt(256)));
        jobs.add((id: 'f$i', path: write('f$i', bytes).path, size: bytes.length));
        expected.add(reference(bytes));
      }
      jobs.insert(4, (id: 'missing', path: p.join(dir.path, 'missing'), size: 10));

      final outcomes = await hashFiles(jobs, workers: 3);

      expect(outcomes.map((outcome) => outcome.id), jobs.map((job) => job.id));
      expect([
        for (final outcome in outcomes)
          if (outcome.id != 'missing') outcome.hash,
      ], expected);
      expect(outcomes[4].error, isNotNull);
    });

    test('a cancelled run throws', () async {
      final cancel = NativeCancelFlag()..cancel();
      addTearDown(cancel.free);
      final job = (id: 'f', path: write('f', Uint8List(10)).path, size: 10);
      await expectLater(hashFiles([job, job], workers: 2, cancel: cancel), throwsA(isA<HashRunCancelled>()));
    });

    test('a few readers, fewer on a network folder', () {
      expect(hashWorkerCount(1), 1);
      expect(hashWorkerCount(1000), lessThanOrEqualTo(4));
      expect(hashWorkerCount(1000, network: true), lessThanOrEqualTo(2));
      expect(hashWorkerCount(0), 1);
    });
  });
}
