// Spatial 2.5D of a 3D photo on the computers (release 53, lot P2): "Spatial 2.5D" in the top bar of the viewer, beside
// the view modes of a photo of two eyes (lib/desktop/ai/sbs_view_modes.dart), where the viewer shows one eye of it. It
// opens the 2.5D page (spatial_photo_page.dart) on:
// - a photo of two eyes side by side as the viewer shows it in its modes: ours, made by "2D to 3D" (full width eyes,
//   our XMP), and those of other tools, full or half width, eyes crossed or not (stereo_photo_probe.dart);
// - a photo of two eyes one above the other by its name (_TB, _OU, _HTB..., stackedPhotoFormatOf), never a 360° one.
// Nothing on any other photo, nor while the Spatial 2.5D switch of the settings is off.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/sbs_view_modes.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_page.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_render.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/flat_stereo.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';

/// The layout of a photo of two eyes side by side as the probe told it
SpatialPhotoLayout spatialLayoutOfSideBySide(FlatStereoPhoto photo) => SpatialPhotoLayout(
  packing: SpatialPhotoPacking.sideBySide,
  swapped: photo.eyeOrder == EyeOrder.rightLeft,
  squeezed: photo.eyes == StereoEyes.half,
);

/// The layout of a photo of two eyes one above the other packed as [format], left eye on top; null for another packing
SpatialPhotoLayout? spatialLayoutOfStacked(FlatStereoFormat format) => switch (format) {
  FlatStereoFormat.tb => const SpatialPhotoLayout(packing: SpatialPhotoPacking.topBottom),
  FlatStereoFormat.halfTb => const SpatialPhotoLayout(packing: SpatialPhotoPacking.topBottom, squeezed: true),
  FlatStereoFormat.sbs || FlatStereoFormat.halfSbs => null,
};

/// What the 2.5D page opens [asset] with: its layout and whether its relief was estimated by AI; null for a photo it
/// does not take (see the top of this file)
({SpatialPhotoLayout layout, bool estimatedRelief})? spatialPhotoOf(WidgetRef ref, BaseAsset asset) {
  if (!asset.isImage || !ref.watch(appConfigProvider.select((config) => config.viewer.spatial25d))) {
    return null;
  }
  final sideBySide = desktopSbsPhotoOf(ref, asset);
  if (sideBySide != null) {
    return (layout: spatialLayoutOfSideBySide(sideBySide), estimatedRelief: sideBySide.isEstimatedRelief);
  }
  final stacked = stackedPhotoFormatOf(asset.name);
  if (stacked == null || ref.watch(isEquirectangularProvider(asset))) {
    return null;
  }
  final layout = spatialLayoutOfStacked(stacked);
  return layout == null ? null : (layout: layout, estimatedRelief: false);
}

/// Opens the 2.5D page over the window; replaced in the tests
final spatialPhotoOpenerProvider =
    Provider<void Function(BuildContext context, BaseAsset asset, SpatialPhotoLayout, bool)>(
      (ref) =>
          (context, asset, layout, estimatedRelief) => unawaited(
            Navigator.of(context, rootNavigator: true).push(
              SpatialPhotoPage.route(
                // Twice the window: the frame holds two eyes, and each is shown as large as the window
                image: getFullImageProvider(asset, size: MediaQuery.sizeOf(context) * 2),
                layout: layout,
                title: asset.name,
                estimatedRelief: estimatedRelief,
              ),
            ),
          ),
    );

/// "Spatial 2.5D" in the top bar of the viewer of a computer, on a 3D photo; nothing on any other photo
class DesktopSpatialPhotoButton extends ConsumerWidget {
  const DesktopSpatialPhotoButton({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photo = spatialPhotoOf(ref, asset);
    if (photo == null) {
      return const SizedBox.shrink();
    }
    return IconButton(
      key: const Key('desktop_spatial_photo'),
      icon: const Icon(Icons.threed_rotation_rounded),
      tooltip: context.t.spatial_2_5d,
      onPressed: () => ref.read(spatialPhotoOpenerProvider)(context, asset, photo.layout, photo.estimatedRelief),
    );
  }
}
