import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/shared_file.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('shared_file_test_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String name, List<int> bytes) => File(p.join(dir.path, name))..writeAsBytesSync(bytes);

  Future<List<int>> collect(Stream<List<int>> stream) async => [for (final chunk in await stream.toList()) ...chunk];

  final bytes = Uint8List.fromList(List.generate(2 * sharedReadChunkLength + 5, (i) => i * 7));

  test('a file being read can be renamed and deleted meanwhile, and is read to its end as it was', () {
    final file = write('busy.insv', bytes);
    final reader = SharedFileReader.open(file.path);
    final buffer = malloc<Uint8>(sharedReadChunkLength);
    final read = <int>[];
    try {
      var length = reader.readInto(buffer, sharedReadChunkLength);
      read.addAll(buffer.asTypedList(length));
      File(file.renameSync(p.join(dir.path, 'renamed.insv')).path).deleteSync();
      while ((length = reader.readInto(buffer, sharedReadChunkLength)) > 0) {
        read.addAll(buffer.asTypedList(length));
      }
      reader.seek(3);
      expect(reader.readInto(buffer, 2), 2);
      expect(buffer.asTypedList(2), bytes.sublist(3, 5));
    } finally {
      reader.close();
      malloc.free(buffer);
    }
    expect(read, bytes);
    expect(() => SharedFileReader.open(file.path), throwsA(isA<FileSystemException>()));
  });

  test('the stream gives the bytes File.openRead gives, for the whole file and for ranges', () async {
    final file = write('video.mp4', bytes);
    expect(await collect(openSharedRead(file.path)), bytes);
    for (final (start, end) in [
      (0, 10),
      (5, null),
      (sharedReadChunkLength - 1, sharedReadChunkLength + 2),
      (bytes.length - 3, bytes.length + 100),
      (bytes.length, null),
      (bytes.length + 10, null),
    ]) {
      expect(
        await collect(openSharedRead(file.path, start, end)),
        await collect(file.openRead(start, end)),
        reason: '$start to $end',
      );
    }
  });

  test('a file renamed and deleted while it is sent is sent to its end', () async {
    final file = write('upload.insv', bytes);
    final received = <int>[];
    var chunks = 0;
    await for (final chunk in openSharedRead(file.path)) {
      received.addAll(chunk);
      if (++chunks == 1) {
        File(file.renameSync(p.join(dir.path, 'moved.insv')).path).deleteSync();
      }
    }
    expect(received, bytes);
    expect(chunks, 3);
  });

  test('a missing file is an error of the stream, not of the call', () async {
    final stream = openSharedRead(p.join(dir.path, 'gone.jpg'));
    await expectLater(stream, emitsError(isA<FileSystemException>()));
  });

  test('a stream cancelled at once, before its first chunk, ends and closes the file', () async {
    final folder = Directory(p.join(dir.path, 'early'))..createSync();
    final file = File(p.join(folder.path, 'shared.jpg'))..writeAsBytesSync(bytes);
    final subscription = openSharedRead(file.path).listen((_) {});
    await subscription.cancel().timeout(const Duration(seconds: 10));
    folder.deleteSync(recursive: true);
    expect(folder.existsSync(), isFalse);
  });

  test('a paused listener gets no more than what was on its way', () async {
    final file = write('paused.insv', bytes);
    final received = <int>[];
    final first = Completer<void>();
    late final StreamSubscription<List<int>> subscription;
    subscription = openSharedRead(file.path).listen((chunk) {
      received.addAll(chunk);
      if (!first.isCompleted) {
        subscription.pause();
        first.complete();
      }
    });
    final done = subscription.asFuture<void>();
    await first.future;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(received.length, lessThanOrEqualTo(2 * sharedReadChunkLength), reason: 'one chunk read ahead at most');
    subscription.resume();
    await done;
    await subscription.cancel();
    expect(received, bytes);
  });

  test('a cancelled stream closes the file: it can be deleted, and the folder with it', () async {
    final folder = Directory(p.join(dir.path, 'folder'))..createSync();
    final file = File(p.join(folder.path, 'shared.jpg'))..writeAsBytesSync(bytes);
    final first = Completer<void>();
    final subscription = openSharedRead(file.path).listen((_) {
      if (!first.isCompleted) {
        first.complete();
      }
    });
    await first.future;
    await subscription.cancel();
    folder.deleteSync(recursive: true);
    expect(folder.existsSync(), isFalse);
  });
}
