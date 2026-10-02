// Where an asset opens in 360°, shared by the 360° button of the viewer and its "View as 360°" action. Whether an
// asset is 360° at all is another rule, see isEquirectangularProvider.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:logging/logging.dart';

final _log = Logger('View360');

/// Whether this device has a 360° view for [asset], whatever its projection: the panorama viewer for a photo, and
/// for a video the native 360° player where the platform has one. On a Meta Quest, the immersive viewer for both,
/// from the server or from the file on the headset (see [openImmersiveViewer]).
final can360ViewProvider = Provider.autoDispose.family<bool, BaseAsset>((ref, asset) {
  final isHorizonOs = ref.watch(isHorizonOsProvider).valueOrNull ?? false;
  return switch (asset.type) {
    AssetType.image => true,
    AssetType.video => isHorizonOs || ref.watch(panorama360VideoSupportedProvider),
    _ => false,
  };
});

/// Opens [asset] in 360°, as the 360° button of the viewer does: in the immersive viewer on a Meta Quest, else a
/// photo in the panorama viewer and a video in the native 360° player (see [openPanoramaVideo]). Returns once the
/// view is open, or could not open; a photo returns right away.
Future<void> open360View(BuildContext context, WidgetRef ref, BaseAsset asset) async {
  if (ref.read(isHorizonOsProvider).valueOrNull ?? false) {
    return _openImmersive(context, ref, asset);
  }
  switch (asset.type) {
    case AssetType.image:
      unawaited(context.router.push(PanoramaViewerRoute(asset: asset)));
    case AssetType.video when ref.read(panorama360VideoSupportedProvider):
      await openPanoramaVideo(context, ref, asset);
    default:
      _log.warning('No 360° view for ${asset.name} on this device');
  }
}

Future<void> _openImmersive(BuildContext context, WidgetRef ref, BaseAsset asset) async {
  // Read before the first await: the viewer may be gone by then
  final messenger = ScaffoldMessenger.maybeOf(context);
  final errorMessage = context.t.immersive_viewer_open_failed;
  final stereoLabels = sphereViewerLabels(context.t);
  try {
    await openImmersiveViewer(ref, asset, stereoLabels: stereoLabels);
  } catch (error) {
    _log.warning('Could not open the immersive viewer: $error');
    messenger?.showSnackBar(SnackBar(content: Text(errorMessage)));
  }
}
