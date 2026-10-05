// Where an asset opens in 360°, shared by the 360° button of the viewer and its "View as 360°" action. Whether an
// asset is 360° at all is another rule, see isEquirectangularProvider and rawMediaKindProvider.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_plan.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/raw/raw_video.provider.dart';
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
///
/// A raw video whose layout does not open (the other file of a split pair missing, a layout the players do not play)
/// opens nowhere: a message says why (see [rawVideoUnsupportedMessage]).
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

/// Tells the user why the raw video of [error] does not open in 360° (see [rawVideoUnsupportedMessage])
void showRawVideoUnsupported(ScaffoldMessengerState? messenger, Translations t, RawVideoUnsupportedException error) =>
    messenger?.showSnackBar(SnackBar(content: Text(rawVideoUnsupportedMessage(t, error))));

Future<void> _openImmersive(BuildContext context, WidgetRef ref, BaseAsset asset) async {
  // Read before the first await: the viewer may be gone by then
  final messenger = ScaffoldMessenger.maybeOf(context);
  final t = context.t;
  final errorMessage = t.immersive_viewer_open_failed;
  final stereoLabels = sphereViewerLabels(context.t);
  try {
    await openImmersiveViewer(
      ref,
      asset,
      stereoLabels: stereoLabels,
      // Comes once the file is chosen, after the slow steps: the static translations do not need the viewer then
      onSourceNotice: (notice) =>
          messenger?.showSnackBar(SnackBar(content: Text(notice.message(StaticTranslations.instance)))),
    );
  } on RawVideoUnsupportedException catch (error) {
    // Found out from the tracks the file declares, when the viewer was about to open it
    _log.info('${asset.name} does not open in the immersive viewer: $error');
    showRawVideoUnsupported(messenger, t, error);
  } catch (error) {
    _log.warning('Could not open the immersive viewer: $error');
    messenger?.showSnackBar(SnackBar(content: Text(errorMessage)));
  }
}
