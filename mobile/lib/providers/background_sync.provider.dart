import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/settings_file/settings_file.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';

final backgroundSyncProvider = Provider<BackgroundSyncManager>((ref) {
  final syncStatusNotifier = ref.read(syncStatusProvider.notifier);

  final manager = BackgroundSyncManager(
    onRemoteSyncStart: () {
      syncStatusNotifier.startRemoteSync();
      // ignore: dispose-provided-instances
      final backupNotifier = ref.read(backupProvider.notifier);
      if (backupNotifier.mounted) {
        backupNotifier.updateError(BackupError.none);
      }
    },
    onRemoteSyncComplete: (isSuccess) {
      syncStatusNotifier.completeRemoteSync();
      // ignore: dispose-provided-instances
      final backupNotifier = ref.read(backupProvider.notifier);
      if (backupNotifier.mounted) {
        backupNotifier.updateError(isSuccess == true ? BackupError.none : BackupError.syncFailed);
      }
    },
    onRemoteSyncError: syncStatusNotifier.errorRemoteSync,
    onLocalSyncStart: syncStatusNotifier.startLocalSync,
    onLocalSyncComplete: () {
      syncStatusNotifier.completeLocalSync();
      // The backup albums a settings file restored before this device's albums were listed (issue 16)
      unawaited(ref.read(settingsFileServiceProvider).applyPendingBackupAlbums());
    },
    onLocalSyncError: syncStatusNotifier.errorLocalSync,
    onHashingStart: syncStatusNotifier.startHashJob,
    onHashingComplete: syncStatusNotifier.completeHashJob,
    onHashingError: syncStatusNotifier.errorHashJob,
    onCloudIdSyncStart: syncStatusNotifier.startCloudIdSync,
    onCloudIdSyncComplete: syncStatusNotifier.completeCloudIdSync,
    onCloudIdSyncError: syncStatusNotifier.errorCloudIdSync,
  );
  ref.onDispose(manager.cancel);
  return manager;
});
