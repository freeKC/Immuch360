import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/spatial_media.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('Panorama');

/// Whether the asset is a 360° photo: an image viewed as 360° (see [isEquirectangularProvider]), or a raw dual fisheye
/// photo of an Insta360 camera (.insp), which the panorama viewer stitches itself (see [rawMediaKindProvider]).
/// Equirectangular videos are ignored, like on the web. False while the exif is loading, unless the photo is raw.
final isPanoramaProvider = Provider.autoDispose.family<bool, BaseAsset>(
  (ref, asset) =>
      asset.isImage &&
      (ref.watch(isEquirectangularProvider(asset)) ||
          ref.watch(rawMediaKindProvider(asset)) == RawMediaKind.insta360Photo),
);

/// What kind of raw file of a 360° camera the asset is, null for any other: an Insta360 .insp photo or .insv video, a
/// GoPro .360 or a DJI .osv video by its name (see [rawMediaKindOfName]); or a photo of the device found raw by
/// reading it, renamed from .insp for example (see [LocalPanoramaRecord.raw360]). How a raw video holds its lenses is
/// settled when it opens (see RawVideoResolver).
///
/// The server sees a JPEG or an MP4 in them and flags no projection: the viewers stitch them, with the calibration the
/// file carries (see dualFisheyeCalibrationProvider). Kept apart from [isEquirectangularProvider], which tells the
/// players to read the frame as equirectangular: false for those, the ones the scan of the device found raw included.
final rawMediaKindProvider = Provider.autoDispose.family<RawMediaKind?, BaseAsset>(
  (ref, asset) => rawMediaKindOfAsset(
    asset,
    isFoundRaw: (localId) =>
        ref.watch(localPanoramaAssetsProvider.select((records) => records[localId]?.raw360 ?? false)),
  ),
);

/// What [rawMediaKindProvider] says of [asset], [isFoundRaw] telling whether the scan of the device found the file of
/// an id on the device raw: by its name; else, for a photo of the device, what the scan found (a .insp renamed .jpg).
/// For those who read the records once, the immersive viewer that moves on to other assets.
RawMediaKind? rawMediaKindOfAsset(BaseAsset asset, {required bool Function(String localId) isFoundRaw}) {
  if (!(asset.isImage || asset.isVideo)) {
    return null;
  }
  final byName = rawMediaKindOfName(asset.name, isVideo: asset.isVideo);
  final localId = asset.localId;
  if (byName != null || localId == null || !asset.isImage) {
    return byName;
  }
  // A raw video is told by its name only: the scan finds no other
  return isFoundRaw(localId) ? RawMediaKind.insta360Photo : null;
}

/// Whether the asset, photo or video, is viewed as 360°: its exif carries an equirectangular projection (see
/// [hasEquirectangularExifProvider]), or the user chose to view it as 360° (see [ForcedPanoramaAssets]), or its file
/// on the device declares a 360° projection (see [localPanoramaIdsProvider]), which is all there is to tell without
/// a server. False while the exif is loading, unless the user chose so or the file was read. Videos are only playable
/// in 360° where a native player exists (see panorama360VideoSupportedProvider).
///
/// A photo whose exif names a 360° camera and whose frame is 2:1 is viewed as 360° too, without GPano tags (see
/// [hasEquirectCameraExifProvider]).
///
/// Never for a raw file of a 360° camera (see [rawMediaKindProvider]), though the scan of the device finds it 360° and
/// lists it among the others: its frames hold the images of the lenses or the faces of a cube, which a player reading
/// them as equirectangular would wrap on the sphere as they are.
final isEquirectangularProvider = Provider.autoDispose.family<bool, BaseAsset>((ref, asset) {
  // All watched, so that the exif is at hand when the user stops viewing the asset as 360°
  final isForced = ref.watch(isForcedPanoramaProvider(asset));
  final isFlagged = ref.watch(hasEquirectangularExifProvider(asset));
  final isCameraPhoto = ref.watch(hasEquirectCameraExifProvider(asset));
  final localId = asset.localId;
  final isFoundOnDevice = localId != null && ref.watch(localPanoramaIdsProvider.select((ids) => ids.contains(localId)));
  final isRaw = ref.watch(rawMediaKindProvider(asset)) != null;
  return !isRaw && (isForced || isFlagged || isFoundOnDevice || isCameraPhoto);
});

/// Whether the exif of the asset, photo or video, carries an equirectangular projection: the server flags it as 360°,
/// same rule as the web. False while the exif is loading.
final hasEquirectangularExifProvider = Provider.autoDispose.family<bool, BaseAsset>(
  (ref, asset) =>
      ref.watch(assetExifProvider(asset).select((s) => s.valueOrNull?.projectionType)) ==
      ProjectionType.equirectangular,
);

/// Whether the asset is a photo a 360° camera stitched into an equirect picture itself, without the GPano tags that
/// make the server flag it: named .36p (GoPro MAX 2), or 2:1 with the make and model of a 360° camera in its exif
/// (see [isEquirectCameraPhoto]). Photos only; false while the exif is loading, unless its name tells.
///
/// Never for an Insta360 photo (make "Arashi Vision"): a raw one renamed .jpg has the same make and the same 2:1
/// frame, and only the trailer at the end of its file tells it from one the camera stitched, which the exif of the
/// server does not hold. Shown as an equirect picture, its two fisheye circles would make a broken sphere. The scan of
/// the device and the shares read that trailer first (see probeLocalPanoramaPhoto and NetworkMediaService.detect).
final hasEquirectCameraExifProvider = Provider.autoDispose.family<bool, BaseAsset>((ref, asset) {
  if (!asset.isImage) {
    return false;
  }
  if (isEquirectCameraPhoto(name: asset.name)) {
    return true;
  }
  final camera = ref.watch(
    assetExifProvider(asset).select((s) {
      final exif = s.valueOrNull;
      return exif == null ? null : (make: exif.make, model: exif.model, width: exif.width, height: exif.height);
    }),
  );
  return camera != null &&
      camera.make?.trim().toLowerCase() != 'arashi vision' &&
      isEquirectCameraPhoto(
        name: asset.name,
        make: camera.make,
        model: camera.model,
        width: camera.width ?? asset.width,
        height: camera.height ?? asset.height,
      );
});

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
