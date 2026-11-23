// Keeps the folder library current while the app runs. FileSystemEntity.watch is recursive on Windows and macOS and
// not on Linux, and on Windows the stream ends when the ReadDirectoryChangesW buffer overflows (api.dart.dev). So:
//  - on Windows and macOS, a recursive watch per local root; the events of photos, videos and folders start a rescan
//    a few seconds after the last one, and a watch that ends or fails is started again a little later, with a rescan,
//    since events were lost;
//  - on Linux, the same, the watch of a root made of one inotify watch per folder below it ([LinuxTreeWatches], parity
//    lot L08 of release 51): the folders created or moved in later are watched as they come, those deleted or moved
//    out are let go. The watches of the app stay under half of the user's limit (fs.inotify.max_user_watches), which
//    an editor or a sync client shares; past it the deepest folders are not watched, and the Refresh action and the
//    rescans below cover them, as they cover a computer that has no watch left at all;
//  - network folders are not watched (change notifications over SMB are not reliable): the Refresh action, and the
//    rescan when the window comes back after five minutes or more, cover them;
//  - nor are folders on a drive the user ejects (a memory card, a USB drive): on Windows a watch keeps a handle open on
//    the volume, and Windows then refuses to eject it ("This device is currently in use") for as long as the app runs,
//    which leads people to pull the drive anyway. The same Refresh and rescan cover them.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('LibraryWatcher');

/// Watches one folder and what is below it
typedef FolderWatch = Stream<FileSystemEvent> Function(String path);

/// The folders of [roots] to watch: the local ones whose drive is connected, less those [isRemovable] puts on a drive
/// the user ejects
List<String> watchedRootPaths(Iterable<LibraryRoot> roots, {required bool Function(LibraryRoot root) isRemovable}) => [
  for (final root in roots)
    if (root.available && !root.isNetwork && !isRemovable(root)) root.path,
];

Stream<FileSystemEvent> _systemWatch(String path) => Directory(path).watch(recursive: true);

/// The watch of this computer: recursive on Windows and macOS, a watch per folder on Linux
FolderWatch _thisComputerWatch() => Platform.isLinux ? LinuxTreeWatches().watch : _systemWatch;

class LibraryWatcher {
  LibraryWatcher({
    required this.onChange,
    this.debounce = const Duration(seconds: 3),
    this.restartDelay = const Duration(seconds: 5),
    FolderWatch? watch,
  }) : _watch = watch ?? _thisComputerWatch();

  /// Whether this computer can watch a folder with what is below it: Windows and macOS by themselves, Linux one folder
  /// at a time ([LinuxTreeWatches])
  static bool get supported => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Called once the changes have settled
  final void Function() onChange;
  final Duration debounce;
  final Duration restartDelay;
  final FolderWatch _watch;

  final _subscriptions = <String, StreamSubscription<FileSystemEvent>>{};
  final _restarts = <String, Timer>{};
  var _wanted = <String>{};
  Timer? _pending;
  var _disposed = false;

  /// The folders watched now, or waiting to be watched again
  Set<String> get folders => {..._wanted};

  /// Watches [paths] from now on, and only them
  void watchFolders(Iterable<String> paths) {
    if (_disposed) {
      return;
    }
    _wanted = paths.toSet();
    for (final path in {..._subscriptions.keys, ..._restarts.keys}.difference(_wanted)) {
      _stop(path);
    }
    for (final path in _wanted) {
      if (!_subscriptions.containsKey(path) && !_restarts.containsKey(path)) {
        _start(path);
      }
    }
  }

  void _start(String path) {
    try {
      _subscriptions[path] = _watch(path).listen(
        (event) {
          if (_isRelevant(event)) {
            _changed();
          }
        },
        onError: (Object _) => _lost(path),
        onDone: () => _lost(path),
        cancelOnError: true,
      );
    } on FileSystemException {
      _lost(path);
    }
  }

  void _stop(String path) {
    _restarts.remove(path)?.cancel();
    unawaited(_subscriptions.remove(path)?.cancel());
  }

  // The watch ended (buffer overflow, folder gone, drive removed): events were lost, so a rescan, and a new watch later
  void _lost(String path) {
    _subscriptions.remove(path);
    if (_disposed || !_wanted.contains(path)) {
      return;
    }
    _changed();
    _restartLater(path, restartDelay);
  }

  void _restartLater(String path, Duration delay) {
    _restarts.remove(path)?.cancel();
    _restarts[path] = Timer(delay, () {
      _restarts.remove(path);
      if (_disposed || !_wanted.contains(path)) {
        return;
      }
      if (Directory(path).existsSync()) {
        _start(path);
        // Whatever happened while it was not watched
        _changed();
      } else {
        // Not there now (an unplugged drive): tried again now and then, without a rescan each time
        _restartLater(path, restartDelay * 12);
      }
    });
  }

  static bool _isRelevant(FileSystemEvent event) {
    if (event.isDirectory) {
      // A folder created, deleted or moved may carry media; a folder's own modification says nothing new
      return event.type != FileSystemEvent.modify;
    }
    final destination = event is FileSystemMoveEvent ? event.destination : null;
    return mediaKindOfName(p.basename(event.path)) != null ||
        (destination != null && mediaKindOfName(p.basename(destination)) != null);
  }

  void _changed() {
    _pending?.cancel();
    _pending = Timer(debounce, () {
      _pending = null;
      if (!_disposed) {
        onChange();
      }
    });
  }

  void dispose() {
    _disposed = true;
    _pending?.cancel();
    for (final path in {..._subscriptions.keys, ..._restarts.keys}) {
      _stop(path);
    }
    _wanted = {};
  }
}

/// The number of inotify watches the user may hold, from /proc/sys/fs/inotify/max_user_watches; 8192, the old default
/// of the kernel, when it does not read
int inotifyWatchLimit({String path = '/proc/sys/fs/inotify/max_user_watches'}) {
  try {
    return int.tryParse(File(path).readAsStringSync().trim()) ?? 8192;
  } on FileSystemException {
    return 8192;
  }
}

/// The watches the app takes of [limit] (see [inotifyWatchLimit]): half of it, which leaves the rest to the other
/// programs of the user, from 256 to 65536
int libraryWatchBudget(int limit) => (limit ~/ 2).clamp(256, 65536);

/// Watches one folder alone, without what is below it
typedef SingleFolderWatch = Stream<FileSystemEvent> Function(String path);

/// The folders right inside one folder, by their paths; none when it cannot be read
typedef SubfolderLister = Future<List<String>> Function(String path);

Stream<FileSystemEvent> _watchOneFolder(String path) => Directory(path).watch();

Future<List<String>> _listSubfolders(String path) async {
  final found = <String>[];
  try {
    await for (final entity in Directory(path).list(followLinks: false)) {
      if (entity is Directory) {
        found.add(entity.path);
      }
    }
  } on FileSystemException {
    // Unreadable (its permissions) or gone meanwhile: nothing below it is watched
  }
  return found;
}

/// The recursive watch of Linux, where FileSystemEntity.watch watches one folder only: one inotify watch per folder of
/// a root, the folders scans skip left out (isSkippedFolderName), at most [budget] watches for all the roots
/// together. A folder created or moved in is watched with what it holds; one deleted or moved out is let go. The
/// events of every folder come on the stream of the root; the stream ends, or fails, as the watch of the root does,
/// and its watcher then starts it again (LibraryWatcher). The links to folders are not followed, as the scans do not.
class LinuxTreeWatches {
  LinuxTreeWatches({int? budget, SingleFolderWatch? watchOne, SubfolderLister? subfolders})
    : budget = budget ?? libraryWatchBudget(inotifyWatchLimit()),
      _watchOne = watchOne ?? _watchOneFolder,
      _subfolders = subfolders ?? _listSubfolders;

  /// The most watches of all the roots together
  final int budget;
  final SingleFolderWatch _watchOne;
  final SubfolderLister _subfolders;

  var _used = 0;
  var _capped = false;

  /// The watches held now, of every root
  int get used => _used;

  /// Whether a folder was left unwatched for want of watches: the budget reached, or the system's limit
  bool get capped => _capped;

  /// The folders watched now below [root], [root] included (the tests)
  @visibleForTesting
  final watching = <String, Set<String>>{};

  /// The folder [root] and every folder below it, their events on one stream
  Stream<FileSystemEvent> watch(String root) {
    late final _Tree tree;
    // Closed by its tree, when the watch of the root ends
    // ignore: close_sinks
    final controller = StreamController<FileSystemEvent>(onListen: () => tree.start(), onCancel: () => tree.stop());
    tree = _Tree(this, root, controller);
    return controller.stream;
  }

  bool _take() {
    if (_used >= budget) {
      _cap('the budget of $budget watches is reached');
      return false;
    }
    _used++;
    return true;
  }

  void _give() => _used = math.max(0, _used - 1);

  void _cap(String why) {
    if (!_capped) {
      _capped = true;
      _log.warning(
        'Some folders of the library are not watched ($why): Refresh, or the rescan when the window comes '
        'back, finds what changes there',
      );
    }
  }
}

/// The inotify error of a system out of watches (ENOSPC)
bool _outOfWatches(Object error) => error is FileSystemException && error.osError?.errorCode == 28;

class _Tree {
  _Tree(this.owner, this.root, this.controller);

  final LinuxTreeWatches owner;
  final String root;
  final StreamController<FileSystemEvent> controller;
  final _folders = <String, StreamSubscription<FileSystemEvent>>{};
  var _stopped = false;

  void start() {
    owner.watching[root] = {};
    if (!_add(root, isRoot: true)) {
      return;
    }
    unawaited(_addBelow([root]));
  }

  Future<void> stop() async {
    _stopped = true;
    owner.watching.remove(root);
    final subscriptions = _folders.values.toList();
    for (var index = 0; index < subscriptions.length; index++) {
      owner._give();
    }
    _folders.clear();
    await Future.wait([for (final subscription in subscriptions) subscription.cancel()]);
  }

  /// Watches [folder] alone; false when it is not watched
  bool _add(String folder, {bool isRoot = false}) {
    if (_stopped || _folders.containsKey(folder) || !owner._take()) {
      return false;
    }
    // Kept in _folders, cancelled when the folder is let go or the tree stops
    // ignore: cancel_subscriptions
    final StreamSubscription<FileSystemEvent> subscription;
    try {
      subscription = owner
          ._watchOne(folder)
          .listen(
            (event) => _onEvent(event),
            onError: (Object error) => _failed(folder, error, isRoot: isRoot),
            onDone: () => _ended(folder, isRoot: isRoot),
            cancelOnError: true,
          );
    } on FileSystemException catch (error) {
      owner._give();
      _failed(folder, error, isRoot: isRoot, held: false);
      return false;
    }
    _folders[folder] = subscription;
    owner.watching[root]?.add(folder);
    return true;
  }

  /// Watches the folders below [starts], breadth first, so that a budget reached leaves out the deepest ones
  Future<void> _addBelow(List<String> starts) async {
    final queue = Queue<String>.of(starts);
    while (queue.isNotEmpty && !_stopped) {
      for (final folder in await owner._subfolders(queue.removeFirst())) {
        if (_stopped || isSkippedFolderName(p.basename(folder))) {
          continue;
        }
        if (!_add(folder)) {
          if (owner.capped) {
            return;
          }
          continue;
        }
        queue.add(folder);
      }
    }
  }

  void _onEvent(FileSystemEvent event) {
    if (_stopped) {
      return;
    }
    if (event is FileSystemDeleteEvent) {
      // A delete event never says whether it was a folder (dart:io): a watched folder of that path is let go
      _drop(event.path);
    } else if (event is FileSystemMoveEvent) {
      _drop(event.path);
      final destination = event.destination;
      if (event.isDirectory && destination != null && _inside(destination)) {
        _addTree(destination);
      }
    } else if (event is FileSystemCreateEvent && event.isDirectory) {
      _addTree(event.path);
    }
    controller.add(event);
  }

  bool _inside(String path) => p.equals(path, root) || p.isWithin(root, path);

  void _addTree(String folder) {
    if (_skippedBelowRoot(folder) || !_add(folder)) {
      return;
    }
    unawaited(_addBelow([folder]));
  }

  bool _skippedBelowRoot(String folder) =>
      p.split(p.relative(folder, from: root)).any((name) => name != '.' && isSkippedFolderName(name));

  /// Lets go of [folder] and the folders below it, deleted or moved out
  void _drop(String folder) {
    for (final watched in _folders.keys.where((path) => p.equals(path, folder) || p.isWithin(folder, path)).toList()) {
      if (p.equals(watched, root)) {
        continue;
      }
      unawaited(_folders.remove(watched)?.cancel());
      owner.watching[root]?.remove(watched);
      owner._give();
    }
  }

  void _failed(String folder, Object error, {required bool isRoot, bool held = true}) {
    if (held && _folders.remove(folder) != null) {
      owner.watching[root]?.remove(folder);
      owner._give();
    }
    if (_outOfWatches(error)) {
      // Out of watches: the folder stays unwatched, the rescans cover it; the root's stream goes on, its watcher would
      // only try again in vain
      owner._cap('the system has no inotify watch left');
      return;
    }
    if (isRoot && !_stopped && !controller.isClosed) {
      controller.addError(error);
    }
  }

  void _ended(String folder, {required bool isRoot}) {
    if (_folders.remove(folder) != null) {
      owner.watching[root]?.remove(folder);
      owner._give();
    }
    if (isRoot && !_stopped && !controller.isClosed) {
      // The root gone or its watch ended: the folders below are let go, and its watcher starts it again later
      unawaited(stop());
      unawaited(controller.close());
    }
  }
}
