import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';

/// Whether the asset is a 360° photo: an image whose exif projection is equirectangular, same rule as the web.
///
/// Raw Insta360 .insp files are the exception: the web opens them as panoramas by file name, but they are unstitched
/// dual fisheye images that no sphere viewer can display correctly, so mobile shows them flat. Equirectangular videos
/// are ignored, like on the web. False while the exif is loading.
final isPanoramaProvider = Provider.autoDispose.family<bool, BaseAsset>(
  (ref, asset) => asset.isImage && ref.watch(isEquirectangularProvider(asset)),
);

/// Whether the asset, photo or video, carries an equirectangular projection in its exif. False while the exif is
/// loading. Videos are only playable in 360° where a native player exists (see panorama360VideoSupportedProvider).
final isEquirectangularProvider = Provider.autoDispose.family<bool, BaseAsset>(
  (ref, asset) =>
      ref.watch(assetExifProvider(asset).select((s) => s.valueOrNull?.projectionType)) ==
      ProjectionType.equirectangular,
);
