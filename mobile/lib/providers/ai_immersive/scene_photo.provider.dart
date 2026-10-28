// Photos of the library that carry a 3D scene (see ScenePhotoService): the Quest offers "Explore the 3D scene" from
// what this finds, the phones, tablets and TVs say "Open it on a Meta Quest to explore it" in the details. The photos
// of the shares get the same answer from NetworkMediaInfo.scene.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/scene_photo_probe.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/services/api.service.dart';

/// Tells the photos of the library that carry a 3D scene. What it found lasts as long as the app.
final scenePhotoServiceProvider = Provider<ScenePhotoService>((ref) {
  final storage = ref.watch(storageRepositoryProvider);
  return ScenePhotoService(
    localFile: storage.getFileForAsset,
    // The head of the original, with the app's shared client and the authentication of the server, as for the flat 3D
    // photos: a server that ignores the range is read from the start and cut after the bytes asked for
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

/// The packet of the 3D scene [asset] carries, null for any other media and while its file was not read. A photo not
/// named like a scene is never read (see ScenePhotoService.isCandidate).
final scenePhotoProvider = FutureProvider.autoDispose.family<SceneXmp?, BaseAsset>((ref, asset) {
  if (!ScenePhotoService.isCandidate(asset)) {
    return null;
  }
  return ref.watch(scenePhotoServiceProvider).detect(asset);
});
