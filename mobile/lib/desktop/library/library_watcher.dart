// Keeps the folder library current while the app runs. FileSystemEntity.watch is recursive on Windows and macOS and
// not on Linux, and on Windows the stream ends when the ReadDirectoryChangesW buffer overflows (api.dart.dev). So:
//  - on Windows and macOS, a recursive watch per local root; the events of photos, videos and folders start a rescan
//    a few seconds after the last one, and a watch that ends or fails is started again a little later, with a rescan,
//    since events were lost;
//  - network folders are not watched (change notifications over SMB are not reliable), nor anything on Linux: the
//    Refresh action, and the rescan when the window comes back after five minutes or more, cover them;
//  - nor are folders on a drive the user ejects (a memory card, a USB drive): on Windows a watch keeps a handle open on
//    the volume, and Windows then refuses to eject it ("This device is currently in use") for as long as the app runs,
//    which leads people to pull the drive anyway. The same Refresh and rescan cover them.

import 'dart:async';
import 'dart:io';

import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:path/path.dart' as p;

/// Watches one folder and what is below it
typedef FolderWatch = Stream<FileSystemEvent> Function(String path);

/// The folders of [roots] to watch: the local ones whose drive is connected, less those [isRemovable] puts on a drive
/// the user ejects
List<String> watchedRootPaths(Iterable<LibraryRoot> roots, {required bool Function(LibraryRoot root) isRemovable}) => [
  for (final root in roots)
    if (root.available && !root.isNetwork && !isRemovable(root)) root.path,
];

Stream<FileSystemEvent> _systemWatch(String path) => Directory(path).watch(recursive: true);

class LibraryWatcher {
  LibraryWatcher({
    required this.onChange,
    this.debounce = const Duration(seconds: 3),
    this.restartDelay = const Duration(seconds: 5),
    FolderWatch? watch,
  }) : _watch = watch ?? _systemWatch;

  /// Whether this computer can watch a folder with what is below it
  static bool get supported => Platform.isWindows || Platform.isMacOS;

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
