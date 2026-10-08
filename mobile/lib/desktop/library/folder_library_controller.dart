// The controller lives as long as the app (not auto disposed) and Riverpod 2 has no ref.mounted to check, as in the
// other providers of the app that act after an await:
// ignore_for_file: use-ref-and-state-synchronously

// The folder library while the app runs on a computer: the state of the folders page, the actions on the roots, the
// watcher, and what follows a scan that found changes. That last part is what a phone does when it comes back to the
// foreground (app_life_cycle.provider.dart), which a computer never does: its window has no paused state. So after a
// change the library brings the local tables up to date (syncLocal), and with a server it hashes the folders chosen
// for backup and starts the backup, as the phones do on resume, so that backup from folders runs while the app is open.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_scanner.dart';
import 'package:immich_mobile/desktop/library/library_watcher.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('FolderLibrary');

/// The library of the main isolate
final folderLibraryProvider = FutureProvider<FolderLibrary>((ref) => FolderLibrary.shared());

/// The Pictures and Videos folders the page offers
final folderSuggestionsProvider = FutureProvider<List<FolderSuggestion>>((ref) => folderSuggestions());

/// What the folders page shows
class FolderLibraryView {
  const FolderLibraryView({required this.roots, required this.suggestions, this.scanning = false});

  final List<LibraryRoot> roots;
  final List<FolderSuggestion> suggestions;

  /// A scan runs
  final bool scanning;

  FolderLibraryView copyWith({List<LibraryRoot>? roots, bool? scanning}) =>
      FolderLibraryView(roots: roots ?? this.roots, suggestions: suggestions, scanning: scanning ?? this.scanning);
}

/// What follows a scan that changed the library; replaced in tests
final libraryChangesPusherProvider = Provider<Future<void> Function()>(
  (ref) =>
      () => _pushLibraryChanges(ref),
);

Future<void> _pushLibraryChanges(Ref ref) async {
  // The banner of a session without a server asks for folders until there is one
  await ref.read(galleryPermissionNotifier.notifier).getGalleryPermissionStatus();
  if (!ref.read(hasServerProvider)) {
    await ref.read(localSessionRefreshProvider)();
    return;
  }
  if (!ref.read(authProvider).isAuthenticated) {
    // The login page: the library is read once signed in
    return;
  }
  final manager = ref.read(backgroundSyncProvider);
  await manager.syncLocal();
  await manager.hashAssets();
  ref.read(_backupStarterProvider).start();
}

bool _isUploading(BackupState state) => state.uploadItems.values.any((item) => item.isFailed != true);

/// Starts the foreground backup when it is on, as the phones do on resume; never in the middle of an upload, which a
/// restart would begin again from zero (a 360° video runs to gigabytes): it then starts once the uploads are done
final _backupStarterProvider = Provider<_BackupStarter>((ref) {
  final starter = _BackupStarter(ref);
  ref.listen(backupProvider.select(_isUploading), (previous, uploading) {
    if (previous == true && !uploading) {
      starter.startIfWaiting();
    }
  });
  return starter;
});

class _BackupStarter {
  _BackupStarter(this._ref);

  final Ref _ref;
  var _waiting = false;

  void start() {
    if (!_ref.read(appConfigProvider).backup.enabled) {
      return;
    }
    final user = Store.tryGet(StoreKey.currentUser);
    if (user == null) {
      return;
    }
    if (_isUploading(_ref.read(backupProvider))) {
      _waiting = true;
      return;
    }
    _waiting = false;
    unawaited(
      _ref
          .read(backupProvider.notifier)
          .startForegroundBackup(user.id)
          .catchError(
            (Object error, StackTrace stackTrace) => _log.warning('Backup from the folders', error, stackTrace),
          ),
    );
  }

  void startIfWaiting() {
    if (_waiting) {
      start();
    }
  }
}

class FolderLibraryController extends AsyncNotifier<FolderLibraryView> {
  Future<void>? _refreshing;
  var _refreshAgain = false;
  var _everyRootAgain = false;

  // The roots changed: the app hears of it after the next scan even when that scan writes nothing (a removed folder
  // leaves the index before the scan)
  var _pushPending = false;

  @override
  Future<FolderLibraryView> build() async {
    final library = ref.watch(folderLibraryProvider.future);
    final suggestions = ref.watch(folderSuggestionsProvider.future);
    return FolderLibraryView(roots: (await library).roots(), suggestions: await suggestions);
  }

  Future<FolderLibrary> get _library => ref.read(folderLibraryProvider.future);

  /// Adds the folder [path], then scans it. Throws [FolderNotAddedException] when it is not a readable folder.
  Future<void> addFolder(String path) async {
    (await _library).addRoot(path);
    _pushPending = true;
    await _reloadRoots();
    await refresh();
  }

  /// Takes the folder [rootId] out of the library; its files stay where they are
  Future<void> removeFolder(String rootId) async {
    (await _library).removeRoot(rootId);
    _pushPending = true;
    await _reloadRoots();
    await refresh();
  }

  /// "Download and include" the files of [rootId] kept online only
  Future<void> includeCloudOnly(String rootId) async {
    (await _library).includeCloudOnly(rootId);
    _pushPending = true;
    await _reloadRoots();
    await refresh();
  }

  /// Rescans when the last scan ended [age] ago or more: the window came back after a while
  Future<void> refreshIfOlderThan(Duration age) async {
    final library = await _library;
    final last = library.lastScanEnd;
    if (library.hasRoots && (last == null || DateTime.now().difference(last) >= age)) {
      await refresh();
    }
  }

  /// Scans the folders, then brings the app up to date when something changed. [everyRoot] is the user's Refresh:
  /// the network folders too, which the other rescans read only now and then. A call during a scan runs one more scan
  /// after it, since what it was called for may have come after the running scan passed by.
  Future<void> refresh({bool everyRoot = false}) {
    final running = _refreshing;
    if (running != null) {
      _refreshAgain = true;
      _everyRootAgain = _everyRootAgain || everyRoot;
      return running;
    }
    final run = _refresh(everyRoot: everyRoot).whenComplete(() {
      _refreshing = null;
      if (_refreshAgain) {
        final again = _everyRootAgain;
        _refreshAgain = false;
        _everyRootAgain = false;
        unawaited(refresh(everyRoot: again));
      }
    });
    _refreshing = run;
    return run;
  }

  Future<void> _refresh({required bool everyRoot}) async {
    final library = await _library;
    _setScanning(true);
    ScanSummary summary;
    try {
      summary = await library.scan(everyRoot: everyRoot);
      // Another scan held the index (the sync services scan before they read): this one waits and goes again, as
      // that one may have started before the change it is asked for
      while (summary.busy) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        summary = await library.scan(everyRoot: everyRoot);
      }
    } catch (error, stackTrace) {
      _log.warning('Scan of the folders failed', error, stackTrace);
      return;
    } finally {
      _setScanning(false);
      await _reloadRoots();
    }
    // A drive that is not connected changes nothing in the local tables: its files stay as they were
    final push = summary.hasChanges || summary.moved > 0 || _pushPending;
    _pushPending = false;
    if (push) {
      try {
        await ref.read(libraryChangesPusherProvider)();
      } catch (error, stackTrace) {
        _log.warning('Could not bring the app up to date with the folders', error, stackTrace);
      }
    }
  }

  void _setScanning(bool scanning) {
    final view = state.valueOrNull;
    if (view != null) {
      state = AsyncData(view.copyWith(scanning: scanning));
    }
  }

  Future<void> _reloadRoots() async {
    final view = state.valueOrNull;
    final roots = (await _library).roots();
    if (view != null) {
      state = AsyncData(view.copyWith(roots: roots));
    }
  }
}

final folderLibraryControllerProvider = AsyncNotifierProvider<FolderLibraryController, FolderLibraryView>(
  FolderLibraryController.new,
);

/// The watcher of the roots on a computer that can watch folders (Windows, macOS); null elsewhere. Kept alive by
/// [FolderLibraryHost].
final folderLibraryWatcherProvider = Provider<LibraryWatcher?>((ref) {
  if (!LibraryWatcher.supported) {
    return null;
  }
  final watcher = LibraryWatcher(
    onChange: () => unawaited(ref.read(folderLibraryControllerProvider.notifier).refresh()),
  );
  ref.onDispose(watcher.dispose);
  ref.listen(folderLibraryControllerProvider, (_, next) {
    final roots = next.valueOrNull?.roots ?? const <LibraryRoot>[];
    watcher.watchFolders([
      for (final root in roots)
        if (root.available && !root.isNetwork) root.path,
    ]);
  }, fireImmediately: true);
  return watcher;
});

/// Wraps the app on a computer (desktop_overrides.dart): keeps the folder library current while the app runs, through
/// the watcher, and with a rescan when the window comes back to the front five minutes or more after the last one
class FolderLibraryHost extends ConsumerStatefulWidget {
  const FolderLibraryHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<FolderLibraryHost> createState() => _FolderLibraryHostState();
}

class _FolderLibraryHostState extends ConsumerState<FolderLibraryHost> with WidgetsBindingObserver {
  static const _staleAfter = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        ref
            .read(folderLibraryControllerProvider.notifier)
            .refreshIfOlderThan(_staleAfter)
            .catchError((Object error, StackTrace stackTrace) => _log.warning('Rescan on resume', error, stackTrace)),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(folderLibraryWatcherProvider);
    return widget.child;
  }
}
