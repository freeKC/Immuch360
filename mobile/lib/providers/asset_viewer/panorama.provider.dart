import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/spatial_media.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('Panorama');

/// Whether the asset is a 360° photo: an image viewed as 360° (see [isEquirectangularProvider]).
///
/// Raw Insta360 .insp files are the exception: the web opens them as panoramas by file name, but they are unstitched
/// dual fisheye images that no sphere viewer can display correctly, so mobile shows them flat unless the user asks
/// otherwise. Equirectangular videos are ignored, like on the web. False while the exif is loading.
final isPanoramaProvider = Provider.autoDispose.family<bool, BaseAsset>(
  (ref, asset) => asset.isImage && ref.watch(isEquirectangularProvider(asset)),
);

/// Whether the asset, photo or video, is viewed as 360°: its exif carries an equirectangular projection (see
/// [hasEquirectangularExifProvider]), or the user chose to view it as 360° (see [ForcedPanoramaAssets]). False while
/// the exif is loading, unless the user chose so. Videos are only playable in 360° where a native player exists (see
/// panorama360VideoSupportedProvider).
final isEquirectangularProvider = Provider.autoDispose.family<bool, BaseAsset>((ref, asset) {
  // Both watched, so that the exif is at hand when the user stops viewing the asset as 360°
  final isForced = ref.watch(isForcedPanoramaProvider(asset));
  final isFlagged = ref.watch(hasEquirectangularExifProvider(asset));
  return isForced || isFlagged;
});

/// Whether the exif of the asset, photo or video, carries an equirectangular projection: the server flags it as 360°,
/// same rule as the web. False while the exif is loading.
final hasEquirectangularExifProvider = Provider.autoDispose.family<bool, BaseAsset>(
  (ref, asset) =>
      ref.watch(assetExifProvider(asset).select((s) => s.valueOrNull?.projectionType)) ==
      ProjectionType.equirectangular,
);

/// Whether the user chose to view the asset as 360°, see [ForcedPanoramaAssets]
final isForcedPanoramaProvider = Provider.autoDispose.family<bool, BaseAsset>(
  (ref, asset) => ref.watch(forcedPanoramaAssetsProvider.select((keys) => _isForced(keys, asset))),
);

// The asset is found under its id on the device too, so that a choice made before the upload holds after it
bool _isForced(Set<String> keys, BaseAsset asset) =>
    keys.contains(spatialLayoutKey(asset)) || (asset.localId != null && keys.contains(asset.localId));

/// The assets the user chose to view as 360° although the server does not flag them, kept in the Store of the device
/// only. Some cameras and editors write no projection tag into 360° files, 3D ones in particular, so nothing tells the
/// server those files are 360°.
///
/// The state holds the keys of those assets, the same as for the stereo layouts (see [spatialLayoutKey]), the latest
/// choice last.
class ForcedPanoramaAssets extends Notifier<Set<String>> {
  ForcedPanoramaAssets({this.maxEntries = 1000});

  /// Past this many assets, the ones chosen first are forgotten
  final int maxEntries;

  @override
  Set<String> build() {
    try {
      return _decode(ref.watch(storeServiceProvider).tryGet(StoreKey.forcedPanoramaAssets));
    } on UnsupportedError catch (error) {
      // The store is not initialised: nothing was chosen yet, and a thumbnail badge must not fail for that
      _log.fine('No store for the assets viewed as 360°: $error');
      return {};
    }
  }

  /// Whether the user chose to view [asset] as 360°
  bool contains(BaseAsset asset) => _isForced(state, asset);

  /// Views [asset] as 360° from now on
  Future<void> add(BaseAsset asset) async {
    final key = spatialLayoutKey(asset);
    // Removed first, so that the asset moves to the end, as the most recent choice
    final keys = {...state}
      ..remove(key)
      ..add(key);
    while (keys.length > maxEntries) {
      keys.remove(keys.first);
    }
    await _save(keys);
  }

  /// Goes back to what the server says for [asset]
  Future<void> remove(BaseAsset asset) async {
    if (!contains(asset)) {
      return;
    }
    await _save(
      {...state}
        ..remove(spatialLayoutKey(asset))
        ..remove(asset.localId),
    );
  }

  Future<void> _save(Set<String> keys) async {
    final store = ref.read(storeServiceProvider);
    state = keys;
    try {
      await store.put(StoreKey.forcedPanoramaAssets, jsonEncode(keys.toList()));
    } catch (error, stackTrace) {
      // The choice still holds until the app restarts
      _log.warning('Could not remember the assets viewed as 360°', error, stackTrace);
    }
  }

  // A JSON list of asset keys. Anything else in it, and a damaged value, are skipped.
  static Set<String> _decode(String? json) {
    if (json == null || json.isEmpty) {
      return {};
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return {};
    }
    return decoded is List ? decoded.whereType<String>().toSet() : {};
  }
}

final forcedPanoramaAssetsProvider = NotifierProvider<ForcedPanoramaAssets, Set<String>>(ForcedPanoramaAssets.new);
