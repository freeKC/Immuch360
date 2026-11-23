// The recursive watch of Linux (library_watcher.dart, parity lot L08): one watch per folder of a root, the folders the
// scans skip left out, the folders created or moved in watched as they come and those deleted or moved out let go, a
// budget for all the roots together, the deepest folders left out first, and a system out of inotify watches that
// keeps the root's stream open. On fake single folder watches over real folders, then, on Linux, on real inotify
// watches through LibraryWatcher: a photo copied into a folder that existed, and into one made after the start.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/library_watcher.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late Map<String, StreamController<FileSystemEvent>> streams;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('linux_tree_watches_test_');
    streams = {};
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String folder(String relative) => (Directory(p.join(dir.path, relative))..createSync(recursive: true)).path;

  LinuxTreeWatches watches({int budget = 100}) => LinuxTreeWatches(
    budget: budget,
    watchOne: (path) {
      final controller = StreamController<FileSystemEvent>();
      addTearDown(() => unawaited(controller.close()));
      streams[path] = controller;
      return controller.stream;
    },
  );

  /// Lets the listing of the folders run
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

  test('every folder of the root, but the hidden ones and the thumbnail caches', () async {
    final root = folder('Pictures');
    folder('Pictures/2024/Summer');
    folder('Pictures/2025');
    folder('Pictures/.cache/deep');
    folder('Pictures/@eaDir');
    final tree = watches();
    final events = <FileSystemEvent>[];
    final subscription = tree.watch(root).listen(events.add);
    await settle();

    expect(tree.watching[root], {root, p.join(root, '2024'), p.join(root, '2024', 'Summer'), p.join(root, '2025')});
    expect(tree.used, 4);

    // The events of a folder below come on the stream of the root
    streams[p.join(root, '2024', 'Summer')]!.add(FileSystemCreateEvent(p.join(root, '2024', 'Summer', 'a.jpg'), false));
    await settle();
    expect(events.single.path, p.join(root, '2024', 'Summer', 'a.jpg'));

    await subscription.cancel();
    expect(tree.used, 0, reason: 'the watches are given back once the root is no longer watched');
    expect(tree.watching, isEmpty);
  });

  test('a folder created or moved in is watched with what it holds, one deleted or moved out is let go', () async {
    final root = folder('Pictures');
    final tree = watches();
    final subscription = tree.watch(root).listen((_) {});
    await settle();
    expect(tree.watching[root], {root});

    // Created, with a folder already inside (a copy of a whole tree)
    folder('Pictures/Trip/Day 1');
    streams[root]!.add(FileSystemCreateEvent(p.join(root, 'Trip'), true));
    await settle();
    expect(tree.watching[root], {root, p.join(root, 'Trip'), p.join(root, 'Trip', 'Day 1')});

    // Renamed in place: the old paths let go, the new ones watched
    Directory(p.join(root, 'Trip')).renameSync(p.join(root, 'Holiday'));
    streams[root]!.add(FileSystemMoveEvent(p.join(root, 'Trip'), true, p.join(root, 'Holiday')));
    await settle();
    expect(tree.watching[root], {root, p.join(root, 'Holiday'), p.join(root, 'Holiday', 'Day 1')});

    // A hidden folder made later stays out
    folder('Pictures/.Trash');
    streams[root]!.add(FileSystemCreateEvent(p.join(root, '.Trash'), true));
    await settle();
    expect(tree.watching[root], isNot(contains(p.join(root, '.Trash'))));

    // Deleted
    // dart:io makes every delete event a file's: the folder is let go by its path
    streams[root]!.add(FileSystemDeleteEvent(p.join(root, 'Holiday'), false));
    await settle();
    expect(tree.watching[root], {root});
    expect(tree.used, 1);
    await subscription.cancel();
  });

  test('the budget is shared by the roots, and the deepest folders are left out first', () async {
    final pictures = folder('Pictures');
    folder('Pictures/a/b/c');
    folder('Pictures/d');
    final videos = folder('Videos');
    final tree = watches(budget: 4);
    final first = tree.watch(pictures).listen((_) {});
    await settle();
    expect(tree.watching[pictures], {
      pictures,
      p.join(pictures, 'a'),
      p.join(pictures, 'd'),
      p.join(pictures, 'a', 'b'),
    });
    expect(tree.capped, isTrue);

    final second = tree.watch(videos).listen((_) {});
    await settle();
    expect(tree.watching[videos], isEmpty, reason: 'no watch left for it');

    // Watches given back by the first root go to the next start of a root
    await first.cancel();
    await second.cancel();
    final again = tree.watch(videos).listen((_) {});
    await settle();
    expect(tree.watching[videos], {videos});
    await again.cancel();
  });

  test('a system out of inotify watches keeps the stream of the root open, without errors to start again on', () async {
    final root = folder('Pictures');
    folder('Pictures/2024');
    final tree = LinuxTreeWatches(
      budget: 100,
      watchOne: (path) => path == root
          ? (streams[path] = StreamController<FileSystemEvent>()).stream
          : Stream.error(const FileSystemException('Failed to watch path', '', OSError('No space left on device', 28))),
    );
    final errors = <Object>[];
    var done = false;
    final subscription = tree.watch(root).listen((_) {}, onError: errors.add, onDone: () => done = true);
    await settle();
    expect(errors, isEmpty);
    expect(done, isFalse);
    expect(tree.capped, isTrue);
    expect(tree.watching[root], {root});
    await subscription.cancel();
    await streams[root]!.close();
  });

  test('the root gone ends its stream, so that its watcher starts it again later', () async {
    final root = folder('Pictures');
    folder('Pictures/2024');
    final tree = watches();
    var done = false;
    tree.watch(root).listen((_) {}, onDone: () => done = true);
    await settle();
    await streams[root]!.close();
    await settle();
    expect(done, isTrue);
    expect(tree.used, 0);
  });

  test('the budget is half of the user limit, from 256 to 65536', () {
    expect(libraryWatchBudget(8192), 4096);
    expect(libraryWatchBudget(100), 256);
    expect(libraryWatchBudget(1048576), 65536);
    final limit = File(p.join(Directory.systemTemp.createTempSync('limit').path, 'max_user_watches'))
      ..writeAsStringSync('124987\n');
    expect(inotifyWatchLimit(path: limit.path), 124987);
    expect(inotifyWatchLimit(path: p.join(dir.path, 'missing')), 8192);
    limit.parent.deleteSync(recursive: true);
  });

  group('on real inotify watches', () {
    Future<void> changeWithin(Completer<void> changed) => changed.future.timeout(const Duration(seconds: 15));

    test('a photo copied into a folder below the root, and into a folder made after the start, rescans', () async {
      final root = folder('Pictures');
      final nested = folder('Pictures/2024/Summer');
      var changed = Completer<void>();
      final watcher = LibraryWatcher(
        onChange: () {
          if (!changed.isCompleted) {
            changed.complete();
          }
        },
        debounce: const Duration(milliseconds: 200),
        watch: LinuxTreeWatches(budget: 100).watch,
      )..watchFolders([root]);
      addTearDown(watcher.dispose);
      // The watches are taken while the folders are listed
      await Future<void>.delayed(const Duration(milliseconds: 300));

      File(p.join(nested, 'IMG_0001.jpg')).writeAsBytesSync([0xFF, 0xD8, 0xFF]);
      await changeWithin(changed);

      changed = Completer<void>();
      final later = folder('Pictures/Trip');
      // The folder itself is a change; wait for that rescan, then copy into it
      await changeWithin(changed);
      changed = Completer<void>();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      File(p.join(later, 'VID_0001.mp4')).writeAsBytesSync([0, 0, 0, 0]);
      await changeWithin(changed);
    }, skip: Platform.isLinux ? false : 'inotify is Linux only');
  });
}
