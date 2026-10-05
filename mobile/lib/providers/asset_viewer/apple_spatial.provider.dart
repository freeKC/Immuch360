// Apple spatial media of the library (see AppleSpatialService): the label and the details row of the viewer, the
// "View in 3D" button of the Meta Quest and the 2D notice of the spatial videos read them.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/apple_spatial/apple_spatial.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/services/api.service.dart';

/// Tells the spatial media of the library. What it found lasts as long as the app, and the photos across restarts.
final appleSpatialServiceProvider = Provider<AppleSpatialService>((ref) {
  final storage = ref.watch(storageRepositoryProvider);
  final probes = ref.watch(sphericalProbeServiceProvider);
  final store = ref.watch(storeServiceProvider);
  return AppleSpatialService(
    localFile: storage.getFileForAsset,
    // The head of the original, with the app's shared client and the authentication of the server: a server that
    // ignores the range is read from the start and cut after the bytes asked for
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
    probeVideo: probes.probe,
    readCache: () => store.tryGet(StoreKey.appleSpatialAssets),
    writeCache: (json) => store.put(StoreKey.appleSpatialAssets, json),
  );
});

/// What makes [asset] an Apple spatial media, null for any other media and while its file was not read
final appleSpatialInfoProvider = FutureProvider.autoDispose.family<AppleSpatialInfo?, BaseAsset>((ref, asset) {
  if (!AppleSpatialService.isCandidate(asset)) {
    return null;
  }
  return ref.watch(appleSpatialServiceProvider).detect(asset);
});
