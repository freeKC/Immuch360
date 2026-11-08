import 'dart:async';
import 'dart:ui';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/data/data_controller.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/desktop/platform/desktop_apis.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/hash.service.dart';
import 'package:immich_mobile/domain/services/local_sync.service.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/domain/services/sync_stream.service.dart';
// ignore: library_prefixes
import 'package:immich_mobile/entities/store.entity.dart' as dbStore;
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/platform/background_worker_api.g.dart';
import 'package:immich_mobile/platform/background_worker_lock_api.g.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/cancel.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/sync.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/auth.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/localization.service.dart';
import 'package:immich_mobile/utils/bootstrap.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:immich_mobile/wm_executor.dart';
import 'package:logging/logging.dart';

class BackgroundWorkerFgService {
  final BackgroundWorkerFgHostApi _foregroundHostApi;

  const BackgroundWorkerFgService(this._foregroundHostApi);

  // TODO: Move this call to native side once old timeline is removed
  Future<void> enable() => _foregroundHostApi.enable();

  Future<void> saveNotificationMessage(String title, String body) =>
      _foregroundHostApi.saveNotificationMessage(title, body);

  Future<void> configure({int? minimumDelaySeconds, bool? requireCharging}) {
    final backup = SettingsRepository.instance.appConfig.backup;
    return _foregroundHostApi.configure(
      BackgroundWorkerSettings(
        minimumDelaySeconds: minimumDelaySeconds ?? backup.triggerDelay,
        requiresCharging: requireCharging ?? backup.requireCharging,
      ),
    );
  }

  // ignore: unused-code
  Future<void> disable() => _foregroundHostApi.disable();

  Future<bool> wasLaunchedInBackground() => _foregroundHostApi.wasLaunchedInBackground();
}

class BackgroundWorkerBgService extends BackgroundWorkerFlutterApi {
  /// How long cancel() waits for init() and the running upload to stop before it cleans up all the same. The answer
  /// to cancel() means that no database work is left in this engine: the native side destroys the engine on it.
  @visibleForTesting
  static const cancelWaitLimit = Duration(seconds: 20);

  ProviderContainer? _ref;
  final DataController _dataController;
  final BackgroundWorkerBgHostApi _backgroundHostApi;
  final _cancellationToken = Completer<void>();
  final Logger _logger = Logger('BackgroundWorkerBgService');
  late LocalSyncService _localSyncService;
  late SyncStreamService _remoteSyncService;
  late HashService _hashService;

  bool _isCleanedUp = false;

  /// init(), then the upload asked by the native side, for cancel() to wait for
  Future<void>? _initFuture;
  Future<void>? _workFuture;

  /// The one cleanup, shared by the end of an upload and cancel()
  Future<void>? _cleanupFuture;

  BackgroundWorkerBgService({
    required this._dataController,
    required ApiService apiService,
    List<Override> overrides = const [],
  }) : _backgroundHostApi = PlatformApis.backgroundWorkerBg() {
    final ref = ProviderContainer(
      overrides: [
        cancellationProvider.overrideWithValue(_cancellationToken),
        ...Store.overrideWith(dataController: _dataController, apiService: apiService),
        ...overrides,
      ],
    );
    _ref = ref;
    _localSyncService = ref.read(localSyncServiceProvider);
    _remoteSyncService = ref.read(syncStreamServiceProvider);
    _hashService = ref.read(hashServiceProvider);
    BackgroundWorkerFlutterApi.setUp(this);
  }

  bool get _isBackupEnabled => SettingsRepository.instance.appConfig.backup.enabled;

  /// False in a session without a server and before any login: there is no server to sync with or back up to, only
  /// the index of the device to keep fresh
  bool get _hasServerSession => dbStore.Store.tryGet(StoreKey.accessToken) != null;

  /// Cancelled or cleaned up: nothing new starts
  bool get _isStopping => _isCleanedUp || _cancellationToken.isCompleted;

  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    try {
      await Future.wait(
        [
          loadTranslations(),
          workerManagerPatch.init(dynamicSpawning: true),
          _ref?.read(authServiceProvider).setOpenApiServiceEndpoint(),
          // Initialize the file downloader
          FileDownloader().configure(
            globalConfig: [
              // maxConcurrent: 6, maxConcurrentByHost(server):6, maxConcurrentByGroup: 3
              (Config.holdingQueue, (6, 6, 3)),
              // On Android, if files are larger than 256MB, run in foreground service
              (Config.runInForegroundIfFileLargerThan, 256),
            ],
          ),
          FileDownloader().trackTasksInGroup(kDownloadGroupLivePhoto, markDownloadedComplete: false),
          FileDownloader().trackTasks(),
        ].nonNulls,
      );

      configureFileDownloaderNotifications();

      // Cancelled while starting: cancel() cleans up once this returns, there is nothing to run
      if (_isStopping) {
        _logger.info("Background worker cancelled while starting, nothing to run");
        return;
      }

      // Notify the host that the background worker service has been initialized and is ready to use
      unawaited(_backgroundHostApi.onInitialized());
    } catch (error, stack) {
      _logger.severe("Failed to initialize background worker", error, stack);
      unawaited(_backgroundHostApi.close());
    }
  }

  @override
  Future<bool> onAndroidUpload(int? maxMinutes) {
    if (_isStopping) {
      _logger.info("Android background upload asked after a cancel, skipped");
      return Future.value(false);
    }
    final work = _androidUpload(maxMinutes);
    _workFuture = work;
    return work;
  }

  Future<bool> _androidUpload(int? maxMinutes) async {
    final hashTimeout = Duration(minutes: _isBackupEnabled ? 3 : 6);
    final backupTimeout = maxMinutes != null ? Duration(minutes: maxMinutes - 1) : null;
    await _optimizeDB();
    return _backgroundLoop(
      hashTimeout: hashTimeout,
      backupTimeout: backupTimeout,
      debugLabel: 'Android background upload',
    );
  }

  @override
  Future<void> onIosUpload(bool isRefresh, int? maxSeconds) {
    if (_isStopping) {
      _logger.info("iOS background upload asked after a cancel, skipped");
      return Future.value();
    }
    final work = _iosUpload(isRefresh, maxSeconds);
    _workFuture = work;
    return work;
  }

  Future<void> _iosUpload(bool isRefresh, int? maxSeconds) async {
    _logger.info('iOS background upload started with maxSeconds: ${maxSeconds}s');
    final sw = Stopwatch()..start();
    try {
      final budget = maxSeconds != null ? Duration(seconds: maxSeconds - 1) : null;

      // Only for Background Processing tasks
      if (maxSeconds == null) {
        await _optimizeDB();
      }

      // Run sync local, sync remote, hash and backup concurrently so the bg
      // refresh task (20s budget) can make progress on all four instead of
      // racing them sequentially. Hash tolerates stale reads, but a new backup
      // batch waits for the remote sync. The single budget caps the
      // whole batch; no phase needs its own timeout.
      // Without a server session there is no remote sync, hashing or backup, only the index of the device
      final remoteSync = _hasServerSession ? _remoteSyncService.sync() : null;
      final all = Future.wait<dynamic>([
        _localSyncService.sync(),
        if (remoteSync != null) ...[
          remoteSync,
          _hashService.hashAssets(),
          _handleBackup(
            remoteSync: remoteSync.then((ok) => ok && !_cancellationToken.isCompleted).catchError((_) => false),
          ),
        ],
      ]);
      if (budget != null) {
        await all.timeout(
          budget,
          onTimeout: () {
            if (!_cancellationToken.isCompleted) {
              _logger.warning("iOS background upload timed out after ${budget.inSeconds}s, cancelling tasks");
              _cancellationToken.complete();
            }
            return <dynamic>[];
          },
        );
      } else {
        await all;
      }
    } catch (error, stack) {
      _logger.severe("Failed to complete iOS background upload", error, stack);
    } finally {
      sw.stop();
      _logger.info("iOS background upload completed in ${sw.elapsed.inSeconds}s");
      await _cleanup();
    }
  }

  Future<bool> _backgroundLoop({
    required Duration hashTimeout,
    required Duration? backupTimeout,
    required String debugLabel,
  }) async {
    _logger.info(
      '$debugLabel started hashTimeout: ${hashTimeout.inSeconds}s, backupTimeout: ${backupTimeout?.inMinutes ?? '~'}m',
    );
    final sw = Stopwatch()..start();
    try {
      if (!_hasServerSession) {
        _logger.info("No server session, only syncing the assets of the device");
        await _localSyncService.sync();
        // Nothing failed that a retry would fix
        return false;
      }

      final synced = await _syncAssets(hashTimeout: hashTimeout);
      if (_isStopping) {
        _logger.info("$debugLabel cancelled before the backup");
        return true;
      }
      if (!synced) {
        _logger.warning("Remote sync did not complete successfully, skipping backup");
        return true;
      }

      final backupFuture = _handleBackup(remoteSync: Future.value(true));
      Timer? cancelTimer;
      if (backupTimeout != null) {
        cancelTimer = Timer(backupTimeout, () {
          if (!_cancellationToken.isCompleted) {
            _logger.warning("$debugLabel timed out after ${backupTimeout.inMinutes}m, cancelling backup");
            _cancellationToken.complete();
          }
        });
      }
      try {
        return await backupFuture;
      } finally {
        cancelTimer?.cancel();
      }
    } catch (error, stack) {
      _logger.severe("Failed to complete $debugLabel", error, stack);
      return true;
    } finally {
      sw.stop();
      _logger.info("$debugLabel completed in ${sw.elapsed.inSeconds}s");
      await _cleanup();
    }
  }

  /// Stops the work, then cleans up: the running upload and init() are waited for (up to [cancelWaitLimit]) before
  /// the databases close, so that its answer means no database work is left in this engine
  @override
  Future<void> cancel() async {
    _logger.warning("Background worker cancelled");
    if (!_cancellationToken.isCompleted) {
      _cancellationToken.complete();
    }
    try {
      await _waitForRunningWork();
      await _cleanup();
    } catch (error, stack) {
      dPrint(() => 'Failed to cleanup background worker: $error with stack: $stack');
    }
  }

  Future<void> _waitForRunningWork() async {
    final running = [_initFuture, _workFuture].nonNulls.map((work) => work.then<void>((_) {}, onError: (Object _) {}));
    if (running.isEmpty) {
      return;
    }
    final sw = Stopwatch()..start();
    await Future.wait(running).timeout(
      cancelWaitLimit,
      onTimeout: () {
        _logger.warning("The background work did not stop within ${cancelWaitLimit.inSeconds}s, cleaning up anyway");
        return const [];
      },
    );
    dPrint(() => 'Background work stopped ${sw.elapsedMilliseconds}ms after the cancel');
  }

  Future<void> _optimizeDB() async {
    try {
      await (_dataController.db.optimize(allTables: true), _dataController.logDb.optimize()).wait;
    } catch (error, stack) {
      dPrint(() => "Error during background worker optimize: $error, $stack");
    }
  }

  /// The cleanup runs once; a second call (cancel() after the end of an upload) waits for the same one
  Future<void> _cleanup() => _cleanupFuture ??= _runCleanup();

  Future<void> _runCleanup() async {
    await runZonedGuarded(_handleCleanup, (error, stack) {
      dPrint(() => "Error during background worker cleanup: $error, $stack");
    });
  }

  Future<void> _handleCleanup() async {
    // If ref is null, it means the service was never initialized properly
    if (_isCleanedUp || _ref == null) {
      return;
    }

    _isCleanedUp = true;
    final sw = Stopwatch()..start();
    _logger.info("Cleaning up background worker");
    if (!_cancellationToken.isCompleted) {
      _cancellationToken.complete();
    }

    // Each step on its own: one that fails must not leave the databases open, since destroying the engine would then
    // close them through the native finalizers, under statements that may still run.
    // Workers share one sqlite connection, so DB teardown must wait until every worker has stopped using it.
    await _cleanupStep('hashing', () async {
      await _ref?.read(nativeSyncApiProvider).cancelHashing();
    });
    await _cleanupStep('worker isolates', () => workerManagerPatch.dispose());
    await _cleanupStep('logs', () => LogService.I.dispose());
    await _cleanupStep('store', () => dbStore.Store.dispose());
    await _cleanupStep('databases', () => _dataController.close());
    await _cleanupStep('providers', () async {
      _ref?.dispose();
    });
    _ref = null;
    dPrint(() => 'Background worker cleaned up in ${sw.elapsedMilliseconds}ms');
  }

  Future<void> _cleanupStep(String name, Future<void> Function() step) async {
    try {
      await step();
    } catch (error, stack) {
      dPrint(() => 'Failed to clean up the $name of the background worker: $error with stack: $stack');
    }
  }

  Future<bool> _handleBackup({required Future<bool> remoteSync}) async {
    final needsRetry = await runZonedGuarded(() async {
      if (_isStopping) {
        return false;
      }

      if (!_isBackupEnabled) {
        _logger.info("Backup is disabled. Skipping backup routine");
        return false;
      }

      final currentUser = _ref?.read(currentUserProvider);
      if (currentUser == null) {
        _logger.warning("No current user found. Skipping backup from background");
        return false;
      }

      if (CurrentPlatform.isIOS) {
        await _ref?.read(backupProvider.notifier).startBackupWithURLSession(currentUser.id, remoteSync);
        return false;
      }

      final uploadService = _ref?.read(foregroundUploadServiceProvider);
      var failed = 0;
      await uploadService?.uploadCandidates(
        currentUser.id,
        _cancellationToken,
        callbacks: UploadCallbacks(onError: (_, _) => failed++),
        useSequentialUpload: true,
      );
      _logger.info("Background backup finished, $failed uploads failed");
      // Retry when at least one upload failed
      return failed > 0;
    }, (error, stack) => dPrint(() => "Error in backup zone $error, $stack"));
    return needsRetry ?? true;
  }

  Future<bool> _syncAssets({Duration? hashTimeout}) async {
    await _localSyncService.sync();
    if (_isStopping) {
      return false;
    }

    final isSuccess = await _remoteSyncService.sync();
    if (_isStopping) {
      return isSuccess;
    }

    var hashFuture = _hashService.hashAssets();
    if (hashTimeout != null) {
      hashFuture = hashFuture.timeout(
        hashTimeout,
        onTimeout: () {
          // Consume cancellation errors as we want to continue processing
        },
      );
    }

    await hashFuture;
    return isSuccess;
  }
}

class BackgroundWorkerLockService {
  final BackgroundWorkerLockApi _hostApi;
  const BackgroundWorkerLockService(this._hostApi);

  Future<void> lock() async {
    if (CurrentPlatform.isAndroid) {
      return _hostApi.lock();
    }
  }

  Future<void> unlock() async {
    if (CurrentPlatform.isAndroid) {
      return _hostApi.unlock();
    }
  }
}

/// Native entry invoked from the background worker. If renaming or moving this to a different
/// library, make sure to update the entry points and URI in native workers as well
@pragma('vm:entry-point')
Future<void> backgroundSyncNativeEntrypoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final (dataController, apiService) = await Bootstrap.initDomain(shouldBufferLogs: false, disableStoreWatching: true);
  await BackgroundWorkerBgService(dataController: dataController, apiService: apiService).init();
}
