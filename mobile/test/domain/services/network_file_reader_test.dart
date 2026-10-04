import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_reader.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';

/// One file in memory; the reads are recorded, and held until [gate] completes when set
class _OneFile implements NetworkFileSystem {
  _OneFile(this.bytes);

  Uint8List bytes;
  final List<(int, int)> reads = [];
  Completer<void>? gate;

  /// Thrown by the read at this offset, when set
  int? failAt;

  @override
  final source = const NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'NAS', host: 'nas.local');

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    reads.add((offset, length));
    final gate = this.gate;
    if (gate != null) {
      await gate.future;
    }
    if (offset == failAt) {
      throw const NetworkFileSystemException('Connection reset');
    }
    final start = math.min(offset, bytes.length);
    return Uint8List.sublistView(bytes, start, math.min(start + length, bytes.length));
  }

  @override
  Future<List<NetworkEntry>> list(String path) => throw UnimplementedError();

  @override
  Future<NetworkEntry> stat(String path) => throw UnimplementedError();

  @override
  Future<void> close() async {}
}

Uint8List _bytes(int length) => Uint8List.fromList(List.generate(length, (i) => i % 251));

Future<Uint8List> _collect(Stream<Uint8List> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

void main() {
  test('reads the whole file in sequence, chunk after chunk', () async {
    final file = _OneFile(_bytes(25));

    final read = await _collect(readWholeFile(file, '/v.mp4', 25, chunkSize: 10));

    expect(read, file.bytes);
    expect(file.reads, [(0, 10), (10, 10), (20, 5)]);
  });

  test('reads nothing of an empty file', () async {
    final file = _OneFile(Uint8List(0));

    expect(await _collect(readWholeFile(file, '/empty.jpg', 0)), isEmpty);
    expect(file.reads, isEmpty);
  });

  test('reads one chunk ahead of the listener, never more', () async {
    final file = _OneFile(_bytes(40));
    final chunks = <Uint8List>[];
    final subscription = readWholeFile(file, '/v.mp4', 40, chunkSize: 10).listen(chunks.add);
    addTearDown(subscription.cancel);
    await pumpEventQueue();
    subscription.pause();
    final seen = chunks.length;
    final asked = file.reads.length;
    await pumpEventQueue();

    expect(file.reads.length, asked, reason: 'nothing more is read while the listener is paused');
    expect(asked - seen, lessThanOrEqualTo(1), reason: 'one chunk read ahead at most');

    subscription.resume();
    await pumpEventQueue();
    expect(chunks.expand((chunk) => chunk).toList(), file.bytes);
  });

  test('reads the next chunk while the listener handles the current one', () async {
    final file = _OneFile(_bytes(30));
    final iterator = StreamIterator(readWholeFile(file, '/v.mp4', 30, chunkSize: 10));
    addTearDown(iterator.cancel);

    expect(await iterator.moveNext(), isTrue);
    expect(file.reads, [(0, 10), (10, 10)], reason: 'the second chunk asked for before the first is handled');
  });

  test('starts again from the first byte at each listen, for a request sent again', () async {
    final file = _OneFile(_bytes(15));
    Stream<Uint8List> open() => readWholeFile(file, '/v.mp4', 15, chunkSize: 10);

    await _collect(open());
    final again = await _collect(open());

    expect(again, file.bytes);
    expect(file.reads, [(0, 10), (10, 5), (0, 10), (10, 5)]);
  });

  test('fails when the share gives fewer bytes than the file had', () async {
    final file = _OneFile(_bytes(15));

    await expectLater(
      _collect(readWholeFile(file, '/v.mp4', 25, chunkSize: 10)),
      throwsA(isA<NetworkFileSystemException>()),
    );
  });

  test('gives a failed read ahead to the listener at its turn', () async {
    final file = _OneFile(_bytes(30))..failAt = 10;
    final chunks = <int>[];

    await expectLater(
      readWholeFile(file, '/v.mp4', 30, chunkSize: 10).map((chunk) => chunks.add(chunk.length)).drain<void>(),
      throwsA(isA<NetworkFileSystemException>()),
    );
    expect(chunks, [10], reason: 'the first chunk came before the failure');
  });

  test('stops once cancelled, without reading further', () async {
    final file = _OneFile(_bytes(50));
    var cancelled = false;
    final chunks = <int>[];

    await expectLater(
      readWholeFile(file, '/v.mp4', 50, chunkSize: 10, isCancelled: () => cancelled).map((chunk) {
        chunks.add(chunk.length);
        cancelled = true;
      }).drain<void>(),
      throwsA(isA<NetworkReadCancelledException>()),
    );
    expect(chunks, [10]);
    expect(file.reads.length, lessThanOrEqualTo(2), reason: 'the chunk read ahead at most');
  });

  test('stops reading once the listener cancels', () async {
    final file = _OneFile(_bytes(50));
    final first = await readWholeFile(file, '/v.mp4', 50, chunkSize: 10).first;

    await pumpEventQueue();
    expect(first.length, 10);
    expect(file.reads, [(0, 10), (10, 10)]);
  });

  test('reports the bytes read so far', () async {
    final file = _OneFile(_bytes(25));
    final progress = <int>[];

    await _collect(readWholeFile(file, '/v.mp4', 25, chunkSize: 10, onProgress: progress.add));

    expect(progress, [10, 20, 25]);
  });

  test('reads in chunks of 8 MiB by default', () async {
    final file = _OneFile(_bytes(networkUploadChunkSize + 3));

    await _collect(readWholeFile(file, '/v.mp4', networkUploadChunkSize + 3));

    expect(file.reads, [(0, networkUploadChunkSize), (networkUploadChunkSize, 3)]);
    expect(networkUploadChunkSize, 8 * 1024 * 1024);
  });
}
