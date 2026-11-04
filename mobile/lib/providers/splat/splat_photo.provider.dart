// The splat photos of the library (plan of 3 November 2026, section 4): a Gaussian splat scene kept on the Immich server
// inside a photo, <stem>_splat.jpg (see SplatPhotoService). Looked for while Gaussian splats are on (experimental, on
// by default): off, no head is read, no badge shows, nothing is offered.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/splat/splat_gate.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_probe.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/splat/splat_viewer.provider.dart';
import 'package:immich_mobile/services/api.service.dart';

/// Whether the splat photos are looked for: Gaussian splats on
final splatPhotosEnabledProvider = Provider<bool>(
  (ref) => ref.watch(appConfigProvider.select((config) => config.viewer.gaussianSplats)),
);

/// Tells the splat photos of the library. What it found lasts as long as the app.
final splatPhotoServiceProvider = Provider<SplatPhotoService>((ref) {
  final storage = ref.watch(storageRepositoryProvider);
  return SplatPhotoService(
    localFile: storage.getFileForAsset,
    // The head of the original, never edited, with the app's shared client and the authentication of the server: a
    // server that ignores the range is read from the start and cut after the bytes asked for
    serverReader: (remoteId) {
      final endpoint = Store.tryGet(StoreKey.serverEndpoint);
      return endpoint == null
          ? null
          : httpRangeReader(
              NetworkRepository.client,
              splatPhotoOriginalUri(endpoint, remoteId),
              headers: ApiService.getRequestHeaders(),
            );
    },
  );
});

/// The photos whose head was read and held no packet of a splat photo, by SplatPhotoService.keyOf: their name badge
/// drops
class SplatPhotosNotOurs extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void add(String key) {
    if (!state.contains(key)) {
      state = {...state, key};
    }
  }
}

final splatPhotosNotOursProvider = NotifierProvider<SplatPhotosNotOurs, Set<String>>(SplatPhotosNotOurs.new);

/// The packet of the splat scene [asset] carries, null for any other media, while its file was not read, and with
/// Gaussian splats off. A photo not named like one is never read (see SplatPhotoService.isCandidate).
final splatPhotoProvider = FutureProvider.autoDispose.family<SplatPhotoXmp?, BaseAsset>((ref, asset) async {
  // The name first: the setting is read for a photo named like one only
  if (!SplatPhotoService.isCandidate(asset) || !ref.watch(splatPhotosEnabledProvider)) {
    return null;
  }
  final probe = await ref.watch(splatPhotoServiceProvider).detect(asset);
  switch (probe) {
    case SplatPhotoFound(:final xmp):
      return xmp;
    case SplatPhotoNone():
      ref.read(splatPhotosNotOursProvider.notifier).add(SplatPhotoService.keyOf(asset));
      return null;
    case SplatPhotoUnread():
      return null;
  }
});

/// Whether [asset] is a splat photo, or may be one while its head is read: the editor, the one key rotation, the 360°
/// viewer, View 3D, the AI relief, View on a big screen and Make 3D stay off for it (plan section 4)
final splatPhotoHoldsProvider = Provider.autoDispose.family<bool, BaseAsset>((ref, asset) {
  if (!SplatPhotoService.isCandidate(asset) || !ref.watch(splatPhotosEnabledProvider)) {
    return false;
  }
  final state = ref.watch(splatPhotoProvider(asset));
  return (state.isLoading && !state.hasValue && !state.hasError) || state.valueOrNull != null;
});

/// Whether the tile of [asset] shows the "3D splat" badge: from its name alone, no read; dropped once a read found it
/// holds no packet of ours
final splatPhotoBadgeProvider = Provider.autoDispose.family<bool, BaseAsset>(
  (ref, asset) =>
      SplatPhotoService.isCandidate(asset) &&
      ref.watch(splatPhotosEnabledProvider) &&
      !ref.watch(splatPhotosNotOursProvider.select((keys) => keys.contains(SplatPhotoService.keyOf(asset)))),
);

/// Where a splat photo's scene can be explored from this device
enum SplatPhotoExplore {
  /// "Explore the splat scene" in the top bar: a computer, an Android phone or tablet, a Meta Quest of a build that
  /// offers the splats (the button greyed on a Quest 2 or Pro, with the reason)
  here,

  /// A details line saying where: a TV, iOS
  elsewhere,

  /// A details line saying where, without the headset: the builds of the Meta Horizon Store
  elsewhereStore,

  /// Not known yet (Android has not said whether this is a headset)
  unknown,
}

/// Where the splat photos are explored from this device (see [SplatPhotoExplore])
final splatPhotoExploreProvider = Provider<SplatPhotoExplore>((ref) {
  final device = ref.watch(splatDeviceClassProvider);
  switch (device) {
    case SplatDeviceClass.phone || SplatDeviceClass.computer:
      return SplatPhotoExplore.here;
    case SplatDeviceClass.quest:
      final inThisBuild = ref.watch(splatsInThisBuildProvider);
      if (!inThisBuild.hasValue) {
        return SplatPhotoExplore.unknown;
      }
      return inThisBuild.value! ? SplatPhotoExplore.here : SplatPhotoExplore.elsewhereStore;
    case null:
      // A TV or iOS; or an Android device that has not said yet whether it is a headset
      return !CurrentPlatform.isAndroid || ref.watch(isHorizonOsProvider).hasValue
          ? SplatPhotoExplore.elsewhere
          : SplatPhotoExplore.unknown;
  }
});
