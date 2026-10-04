// 360° photos and videos of this device, found by reading their files (StoreKey.localPanoramaAssets, see
// LocalPanoramaService). A session without a server has no exif to tell them: the 360° list of the Library and the
// viewers rely on this instead. The results are keyed by the id on the device, so they still hold once a server is
// connected.

import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/local_panorama.service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('LocalPanorama');

/// What reading their files told about the assets of this device that may be 360°, per id on the device (see
/// [LocalPanoramaRecord]), kept in the Store of the device, the latest last. [scan] reads the files not read yet.
class LocalPanoramaAssets extends Notifier<Map<String, LocalPanoramaRecord>> {
  // The scan under way, and whether another one was asked for meanwhile
  Future<void>? _scan;
  bool _scanAgain = false;

  @override
  Map<String, LocalPanoramaRecord> build() {
    try {
      return decodeLocalPanoramaRecords(ref.watch(storeServiceProvider).tryGet(StoreKey.localPanoramaAssets));
    } on UnsupportedError catch (error) {
      // The store is not initialised: nothing was read yet, and a viewer must not fail for that
      _log.fine('No store for the 360° assets of the device: $error');
      return const {};
    }
  }

  /// Reads the files of the assets that may be 360° and were not read yet, or changed since, and remembers what
  /// they declare (see [LocalPanoramaService.scan]). Asked for during a scan, another one follows it, for the
  /// assets a sync added meanwhile. Never fails: errors are logged.
  Future<void> scan() {
    final running = _scan;
    if (running != null) {
      _scanAgain = true;
      return running;
    }
    return _scan = _scanUntilDone().whenComplete(() => _scan = null);
  }

  Future<void> _scanUntilDone() async {
    final service = ref.read(localPanoramaServiceProvider);
    do {
      _scanAgain = false;
      try {
        final records = await service.scan(state, onProgress: _save);
        if (!mapEquals(records, state)) {
          await _save(records);
        }
      } catch (error, stackTrace) {
        _log.warning('Could not look for the 360° photos and videos of the device', error, stackTrace);
        return;
      }
    } while (_scanAgain);
  }

  Future<void> _save(Map<String, LocalPanoramaRecord> records) async {
    state = Map.unmodifiable(records);
    try {
      await ref.read(storeServiceProvider).put(StoreKey.localPanoramaAssets, encodeLocalPanoramaRecords(records));
    } catch (error, stackTrace) {
      // What was found still holds until the app restarts
      _log.warning('Could not remember the 360° assets of the device', error, stackTrace);
    }
  }
}

final localPanoramaAssetsProvider = NotifierProvider<LocalPanoramaAssets, Map<String, LocalPanoramaRecord>>(
  LocalPanoramaAssets.new,
);

/// Ids (on the device) of the local assets whose files declare a 360° projection, or are raw dual fisheye files, see
/// [LocalPanoramaAssets]. The latter are listed with the others, on the 360° page and by the immersive viewer, but
/// their frame is no equirectangular one: see raw360LayoutProvider. Its listeners hear of a change only when the ids
/// change, not at every file a scan reads.
class FoundLocalPanoramaIds extends Notifier<Set<String>> {
  @override
  Set<String> build() => Set.unmodifiable({
    for (final MapEntry(:key, :value) in ref.watch(localPanoramaAssetsProvider).entries)
      if (value.isPanorama) key,
  });

  @override
  bool updateShouldNotify(Set<String> previous, Set<String> next) => !setEquals(previous, next);
}

final foundLocalPanoramaIdsProvider = NotifierProvider<FoundLocalPanoramaIds, Set<String>>(FoundLocalPanoramaIds.new);

/// Whether the file of [asset] on the device declares a 360° projection, see [LocalPanoramaAssets]
final isFoundLocalPanoramaProvider = Provider.autoDispose.family<bool, BaseAsset>((ref, asset) {
  final localId = asset.localId;
  return localId != null && ref.watch(foundLocalPanoramaIdsProvider.select((ids) => ids.contains(localId)));
});

/// Ids (on the device) of the local assets found to be 360°, forced ones included: those whose files declare it
/// (see [foundLocalPanoramaIdsProvider]), and those the user chose to view as 360° (see [ForcedPanoramaAssets]). The
/// latter are keyed by their server id once uploaded, which matches no id on the device.
final localPanoramaIdsProvider = Provider<Set<String>>(
  (ref) => Set.unmodifiable({...ref.watch(foundLocalPanoramaIdsProvider), ...ref.watch(forcedPanoramaAssetsProvider)}),
);

/// Reads the files of the assets of the device, see [LocalPanoramaService]
final localPanoramaServiceProvider = Provider<LocalPanoramaService>((ref) {
  final db = ref.watch(driftProvider);
  final storage = ref.watch(storageRepositoryProvider);
  return LocalPanoramaService(
    assets: (offset, limit) => newestLocalAssets(db, offset: offset, limit: limit),
    file: storage.getFileForAsset,
    isLocallyAvailable: CurrentPlatform.isIOS ? storage.isAssetAvailableLocally : null,
  );
});

/// Up to [limit] assets of the device from the [offset]-th one, the newest first, as the timelines of the device
/// order them
@visibleForTesting
Future<List<LocalAsset>> newestLocalAssets(Drift db, {required int offset, required int limit}) {
  final query = db.localAssetEntity.select()
    ..orderBy([(row) => OrderingTerm.desc(row.createdAt), (row) => OrderingTerm.desc(row.id)])
    ..limit(limit, offset: offset);
  return query.map((row) => row.toDto()).get();
}

/// Scans the local assets that may be 360° and remembers the result; safe to call after every local sync
Future<void> scanLocalPanoramas(Ref ref) => ref.read(localPanoramaAssetsProvider.notifier).scan();
