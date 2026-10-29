// Flat photos of the library that hold two eyes side by side (see FlatStereoService): ours, made from a 2D photo on a
// computer, and those of other tools. The viewers read it for their 3D buttons and labels; the photos of the shares
// get the same answer from NetworkMediaInfo.stereoPhoto.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/services/api.service.dart';

/// Tells the flat 3D photos of the library. What it found lasts as long as the app.
final flatStereoServiceProvider = Provider<FlatStereoService>((ref) {
  final storage = ref.watch(storageRepositoryProvider);
  return FlatStereoService(
    localFile: storage.getFileForAsset,
    // The head of the original, with the app's shared client and the authentication of the server, as for the Apple
    // spatial photos: a server that ignores the range is read from the start and cut after the bytes asked for
    serverReader: (remoteId) {
      final endpoint = Store.tryGet(StoreKey.serverEndpoint);
      return endpoint == null
          ? null
          : httpRangeReader(
              NetworkRepository.client,
              Uri.parse('$endpoint/assets/$remoteId/original'),
              headers: ApiService.getRequestHeaders(),
            );
    },
  );
});

/// The two eyes side by side of [asset], null for any other media and while its file was not read. An ordinary photo
/// is never read (see FlatStereoService.isCandidate).
final flatStereoProvider = FutureProvider.autoDispose.family<FlatStereoPhoto?, BaseAsset>((ref, asset) {
  if (!FlatStereoService.isCandidate(asset)) {
    return null;
  }
  return ref.watch(flatStereoServiceProvider).detect(asset);
});
