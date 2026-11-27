// The files a copy to the clipboard fetches first (lib/desktop/clipboard/clipboard_copies.dart): into a folder of their
// own under their real names, "name (1)" for a second of the same name, the bytes told as they come; a fetch that fails
// or is cancelled leaves nothing, a cancel stops even a share that sends nothing more. Then the rule of their clean up:
// kept an hour at least, then while the clipboard holds their write, a week at most; on Linux a write of an earlier run
// is no longer held.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/clipboard/clipboard_copies.dart';
import 'package:path/path.dart' as p;

RemoteClipboardSource _remote(String name, List<int> bytes, {int status = HttpStatus.ok, int? contentLength}) =>
    RemoteClipboardSource(
      name: name,
      isVideo: false,
      fetch: (abort) async => http.StreamedResponse(
        Stream.fromIterable([bytes.sublist(0, bytes.length ~/ 2), bytes.sublist(bytes.length ~/ 2)]),
        status,
        contentLength: contentLength ?? bytes.length,
      ),
    );

void main() {
  late Directory root;

  setUp(() async => root = await Directory.systemTemp.createTemp('clipboard-copies-test'));
  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  group('the fetch', () {
    test('writes each file under its name in a folder of its own, a second of the same name as "name (1)"', () async {
      final progress = <(int, int?)>[];
      final copies = await fetchClipboardCopies(
        [
          _remote('IMG_1.jpg', List.filled(10, 1)),
          _remote('IMG_1.jpg', List.filled(6, 2)),
          _remote('what?.mp4', List.filled(4, 3)),
        ],
        root,
        onProgress: (fetched, total) => progress.add((fetched, total)),
      );
      expect(p.dirname(copies.folder.path), root.path);
      expect([for (final path in copies.paths) p.basename(path)], ['IMG_1.jpg', 'IMG_1 (1).jpg', 'what_.mp4']);
      expect(File(copies.paths[0]).readAsBytesSync(), List.filled(10, 1));
      expect(File(copies.paths[1]).readAsBytesSync(), List.filled(6, 2));
      expect(progress.last.$1, 20, reason: 'every byte told');
      expect(progress.every((step) => step.$2 == null), isTrue, reason: 'no size listed: no total');
    });

    test('a server that refuses or sends half a file fails it, and nothing stays', () async {
      await expectLater(
        fetchClipboardCopies([_remote('a.jpg', List.filled(8, 1), status: HttpStatus.notFound)], root),
        throwsA(isA<ClipboardCopyException>().having((e) => e.failure, 'failure', ClipboardCopyFailure.fetchFailed)),
      );
      await expectLater(
        fetchClipboardCopies([
          _remote('a.jpg', List.filled(4, 1)),
          _remote('b.jpg', List.filled(8, 1), contentLength: 100),
        ], root),
        throwsA(isA<ClipboardCopyException>().having((e) => e.failure, 'failure', ClipboardCopyFailure.fetchFailed)),
      );
      await expectLater(
        fetchClipboardCopies([
          RemoteClipboardSource(
            name: 'c.jpg',
            isVideo: false,
            fetch: (abort) async => throw const SocketException('x'),
          ),
        ], root),
        throwsA(isA<ClipboardCopyException>().having((e) => e.failure, 'failure', ClipboardCopyFailure.fetchFailed)),
      );
      expect(root.listSync(), isEmpty);
    });

    test('a cancel stops a share that sends nothing more, at once, and nothing stays', () async {
      final stalled = StreamController<List<int>>();
      var aborted = false;
      final cancel = Completer<void>();
      final fetching = fetchClipboardCopies(
        [
          RemoteClipboardSource(
            name: 'film.mkv',
            isVideo: true,
            size: 1000,
            fetch: (abort) async {
              unawaited(abort.then((_) => aborted = true));
              stalled.add(List.filled(10, 1));
              return http.StreamedResponse(stalled.stream, HttpStatus.ok, contentLength: 1000);
            },
          ),
        ],
        root,
        cancelled: cancel.future,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      cancel.complete();
      await expectLater(
        fetching.timeout(const Duration(seconds: 2)),
        throwsA(isA<ClipboardCopyException>().having((e) => e.failure, 'failure', ClipboardCopyFailure.cancelled)),
      );
      expect(aborted, isTrue, reason: 'the request is aborted');
      expect(root.listSync(), isEmpty);
      unawaited(stalled.close());
    });

    test('a cancel while a share is still being opened is not waited for', () async {
      final cancel = Completer<void>();
      final fetching = fetchClipboardCopies(
        [
          RemoteClipboardSource(
            name: 'a.jpg',
            isVideo: false,
            fetch: (abort) => Completer<http.StreamedResponse>().future,
          ),
        ],
        root,
        cancelled: cancel.future,
      );
      cancel.complete();
      await expectLater(
        fetching.timeout(const Duration(seconds: 2)),
        throwsA(isA<ClipboardCopyException>().having((e) => e.failure, 'failure', ClipboardCopyFailure.cancelled)),
      );
    });

    test('the total of the sizes listed makes the progress', () async {
      final progress = <(int, int?)>[];
      await fetchClipboardCopies(
        [
          RemoteClipboardSource(
            name: 'a.jpg',
            isVideo: false,
            size: 8,
            fetch: (abort) async => http.StreamedResponse(Stream.value(List.filled(8, 1)), HttpStatus.ok),
          ),
        ],
        root,
        onProgress: (fetched, total) => progress.add((fetched, total)),
      );
      expect(progress.last, (8, 8));
      expect(clipboardFetchFraction(4, 8), 0.5);
      expect(clipboardFetchFraction(4, null), isNull);
    });
  });

  group('the clean up', () {
    final now = DateTime.utc(2026, 11, 27, 20);
    var madeCount = 0;

    /// A copy folder made [age] before now, with a marker of [token] and [run] unless [marked] is false
    Directory folder(Duration age, {int? token, String run = 'this run', bool marked = true}) {
      // A microsecond apart, so that two folders of the same age have names of their own
      final made = now.subtract(age).subtract(Duration(microseconds: ++madeCount));
      final folder = Directory(p.join(root.path, '${made.microsecondsSinceEpoch}'))..createSync();
      File(p.join(folder.path, 'IMG_1.jpg')).writeAsBytesSync([1, 2, 3]);
      if (marked) {
        File(p.join(folder.path, clipboardCopyMarker)).writeAsStringSync(jsonEncode({'token': token, 'run': run}));
      }
      return folder;
    }

    Future<int> clean({required Set<int> held, bool systemTokens = true, Directory? keep}) => cleanClipboardCopies(
      root,
      holds: (token) async => held.contains(token),
      systemTokens: systemTokens,
      keep: keep,
      run: 'this run',
      now: () => now,
    );

    test('a copy stays an hour, then while the clipboard holds it, a week at most', () async {
      final young = folder(const Duration(minutes: 20), token: 1);
      final held = folder(const Duration(hours: 3), token: 2);
      final replaced = folder(const Duration(hours: 3), token: 3);
      final unmarked = folder(const Duration(hours: 2), marked: false);
      final youngUnmarked = folder(const Duration(minutes: 5), marked: false);
      final old = folder(const Duration(days: 8), token: 4);
      final notOurs = Directory(p.join(root.path, 'something else'))..createSync();
      expect(await clean(held: {1, 2, 4}), 3);
      expect(young.existsSync(), isTrue, reason: 'a chat may still read it');
      expect(held.existsSync(), isTrue, reason: 'the clipboard holds it');
      expect(replaced.existsSync(), isFalse, reason: 'something else was copied since');
      expect(unmarked.existsSync(), isFalse, reason: 'never reached the clipboard');
      expect(youngUnmarked.existsSync(), isTrue, reason: 'may still be on its way to the clipboard');
      expect(old.existsSync(), isFalse, reason: 'a week at most');
      expect(notOurs.existsSync(), isTrue, reason: 'a folder the app did not make');
    });

    test('on Linux a write of an earlier run is no longer held, whatever its number', () async {
      final earlier = folder(const Duration(hours: 2), token: 1, run: 'an earlier run');
      final now = folder(const Duration(hours: 2), token: 1);
      expect(await clean(held: {1}, systemTokens: false), 1);
      expect(earlier.existsSync(), isFalse);
      expect(now.existsSync(), isTrue);
    });

    test('the folder of the copy being made is never touched, nor a missing folder of copies', () async {
      final current = folder(const Duration(hours: 2), marked: false);
      expect(await clean(held: {}, keep: current), 0);
      expect(current.existsSync(), isTrue);
      await root.delete(recursive: true);
      expect(await clean(held: {}), 0);
    });

    test('the marker keeps the token and the run of the write', () async {
      final copy = folder(Duration.zero, marked: false);
      await markClipboardCopy(copy, 77, run: 'this run');
      final marker = jsonDecode(File(p.join(copy.path, clipboardCopyMarker)).readAsStringSync());
      expect(marker, {'token': 77, 'run': 'this run'});
    });
  });
}
