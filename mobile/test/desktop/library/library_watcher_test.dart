import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/library_watcher.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late Map<String, StreamController<FileSystemEvent>> streams;
  late int changes;
  late int watches;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('library_watcher_test_');
    streams = {};
    changes = 0;
    watches = 0;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  LibraryWatcher watcher() => LibraryWatcher(
    onChange: () => changes++,
    watch: (path) {
      watches++;
      final controller = StreamController<FileSystemEvent>();
      // Not awaited: a stream nobody listens to any more never reports done
      addTearDown(() => unawaited(controller.close()));
      streams[path] = controller;
      return controller.stream;
    },
  );

  String folder(String name) => (Directory(p.join(dir.path, name))..createSync()).path;

  test('a burst of photo events makes one rescan, a few seconds after the last one', () {
    fakeAsync((async) {
      final pictures = folder('Pictures');
      final subject = watcher()..watchFolders([pictures]);
      for (var i = 0; i < 20; i++) {
        streams[pictures]!.add(FileSystemCreateEvent(p.join(pictures, 'IMG_$i.JPG'), false));
        async.elapse(const Duration(milliseconds: 500));
      }
      expect(changes, 0);
      async.elapse(const Duration(seconds: 3));
      expect(changes, 1);
      subject.dispose();
    });
  });

  test('events of files that are no media, and changes of a folder itself, are ignored', () {
    fakeAsync((async) {
      final pictures = folder('Pictures');
      final subject = watcher()..watchFolders([pictures]);
      streams[pictures]!
        ..add(FileSystemModifyEvent(p.join(pictures, 'notes.txt'), false, true))
        ..add(FileSystemCreateEvent(p.join(pictures, 'Thumbs.db'), false))
        ..add(FileSystemModifyEvent(p.join(pictures, '2024'), true, false));
      async.elapse(const Duration(seconds: 10));
      expect(changes, 0);

      // A folder created or renamed may carry photos; a video renamed into a media name counts
      streams[pictures]!.add(FileSystemCreateEvent(p.join(pictures, 'Trips'), true));
      async.elapse(const Duration(seconds: 4));
      expect(changes, 1);
      streams[pictures]!.add(FileSystemMoveEvent(p.join(pictures, 'a.tmp'), false, p.join(pictures, 'VID.mp4')));
      async.elapse(const Duration(seconds: 4));
      expect(changes, 2);
      subject.dispose();
    });
  });

  test('a watch that ends (buffer overflow) rescans and watches again', () {
    fakeAsync((async) {
      final pictures = folder('Pictures');
      final subject = watcher()..watchFolders([pictures]);
      expect(watches, 1);
      unawaited(streams[pictures]!.close());
      async.elapse(const Duration(seconds: 3));
      expect(changes, 1);
      async.elapse(const Duration(seconds: 3));
      expect(watches, 2);
      subject.dispose();
    });
  });

  test('a folder that went away is watched again once it is back, without a rescan in between', () {
    fakeAsync((async) {
      final drive = folder('E');
      final subject = watcher()..watchFolders([drive]);
      Directory(drive).deleteSync();
      streams[drive]!.addError(const FileSystemException('gone'));
      async.elapse(const Duration(seconds: 6));
      expect((changes, watches), (1, 1));
      async.elapse(const Duration(minutes: 3));
      expect((changes, watches), (1, 1));

      Directory(drive).createSync();
      async.elapse(const Duration(minutes: 1, seconds: 10));
      expect(watches, 2);
      expect(changes, 2);
      subject.dispose();
    });
  });

  test('only the folders asked are watched, and nothing after dispose', () {
    fakeAsync((async) {
      final a = folder('A');
      final b = folder('B');
      final subject = watcher()..watchFolders([a, b]);
      expect(subject.folders, {a, b});
      subject.watchFolders([b]);
      expect(subject.folders, {b});
      expect(streams[a]!.hasListener, isFalse);

      subject.dispose();
      expect(streams[b]!.hasListener, isFalse);
      async.elapse(const Duration(minutes: 1));
      expect(changes, 0);
    });
  });
}
