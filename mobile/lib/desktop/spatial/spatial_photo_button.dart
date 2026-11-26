// Spatial 2.5D of a 3D photo on the computers (release 53, lot P2): "Spatial 2.5D" in the top bar of the viewer, beside
// the view modes of a photo of two eyes (lib/desktop/ai/sbs_view_modes.dart), where the viewer shows one eye of it, and
// in the top bar of the page of a photo of a share or a folder (network_photo.page.dart). It opens the 2.5D page
// (spatial_photo_page.dart) on:
// - a photo of two eyes side by side: in the viewer as it shows it in its modes, ours, made by "2D to 3D" (full width
//   eyes, our XMP), and those of other tools, full or half width, eyes crossed or not (stereo_photo_probe.dart); on the
//   page of a share as the probe of its file told it (its frame, else the size the page decoded it at);
// - a photo of two eyes one above the other by its name (_TB, _OU, _HTB..., stackedPhotoFormatOf), never a 360° one.
// Nothing on any other photo (an Apple spatial pair and a 3D scene included), nor while the Spatial 2.5D switch of the
// settings is off.

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
import 'package:immich_mobile/domain/services/network_media.service.dart';
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

/// What the 2.5D page opens a photo with
typedef SpatialPhoto = ({SpatialPhotoLayout layout, bool estimatedRelief});

/// What the 2.5D page opens the photo named [name] with, from what is known of it: [sideBySide], its two eyes side by
/// side as the probe told them, else two eyes one above the other by its name unless [isSphere] says it is a 360° one
/// (asked only then); null for any other photo and for a file of a newer format. The switch is the caller's.
SpatialPhoto? spatialPhotoFrom({required String name, FlatStereoPhoto? sideBySide, required bool Function() isSphere}) {
  if (sideBySide != null) {
    return sideBySide.canShowIn3d
        ? (layout: spatialLayoutOfSideBySide(sideBySide), estimatedRelief: sideBySide.isEstimatedRelief)
        : null;
  }
  final stacked = stackedPhotoFormatOf(name);
  if (stacked == null || isSphere()) {
    return null;
  }
  final layout = spatialLayoutOfStacked(stacked);
  return layout == null ? null : (layout: layout, estimatedRelief: false);
}

/// Whether the Spatial 2.5D switch of the settings is on
bool _spatialEnabled(WidgetRef ref) => ref.watch(appConfigProvider.select((config) => config.viewer.spatial25d));

/// What the 2.5D page opens [asset] with: its layout and whether its relief was estimated by AI; null for a photo it
/// does not take (see the top of this file)
SpatialPhoto? spatialPhotoOf(WidgetRef ref, BaseAsset asset) {
  if (!asset.isImage || !_spatialEnabled(ref)) {
    return null;
  }
  return spatialPhotoFrom(
    name: asset.name,
    sideBySide: desktopSbsPhotoOf(ref, asset),
    isSphere: () => ref.watch(isEquirectangularProvider(asset)),
  );
}

/// What the 2.5D page opens the photo of a share named [name] with, from [info], what the page read of its file: null
/// until it was read, and for a photo it does not take (see the top of this file). Two eyes side by side are those the
/// probe told; for a file whose frame the probe could not read (a HEIF, an AVIF, a TIFF), they are told by the name and
/// [decoded], the size the page decoded the photo at (scaled down, with its aspect ratio). The switch is the caller's.
SpatialPhoto? spatialPhotoOfShareFile(String name, NetworkMediaInfo? info, {Size? decoded}) {
  // The desktop viewer does not read the second eye of an Apple spatial photo; a 3D scene has its own page
  if (info == null || info.stereoPair != null || info.scene != null) {
    return null;
  }
  var sideBySide = info.stereoPhoto;
  // Our packet of a panorama is no flat 3D photo, whatever its name
  if (sideBySide == null && decoded != null && !info.is360 && info.panorama == null) {
    sideBySide = decideStereoPhoto(name: name, width: decoded.width.round(), height: decoded.height.round());
  }
  return spatialPhotoFrom(name: name, sideBySide: sideBySide, isSphere: () => info.is360);
}

/// [spatialPhotoOfShareFile] while the Spatial 2.5D switch is on, null otherwise; the switch is read only for a photo
/// the page takes, so that the page of any other photo does not depend on it
SpatialPhoto? spatialPhotoOfShare(WidgetRef ref, String name, NetworkMediaInfo? info, {Size? decoded}) {
  final photo = spatialPhotoOfShareFile(name, info, decoded: decoded);
  return photo != null && _spatialEnabled(ref) ? photo : null;
}

/// Opens the 2.5D page over the window on [image], the whole frame of a photo of two eyes packed as [layout]
void openSpatialPhoto(
  BuildContext context, {
  required ImageProvider image,
  required String title,
  required SpatialPhotoLayout layout,
  required bool estimatedRelief,
}) => unawaited(
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(SpatialPhotoPage.route(image: image, layout: layout, title: title, estimatedRelief: estimatedRelief)),
);

/// Opens the 2.5D page over the window on a photo of the library; replaced in the tests
final spatialPhotoOpenerProvider =
    Provider<void Function(BuildContext context, BaseAsset asset, SpatialPhotoLayout, bool)>(
      (ref) =>
          (context, asset, layout, estimatedRelief) => openSpatialPhoto(
            context,
            // Twice the window: the frame holds two eyes, and each is shown as large as the window
            image: getFullImageProvider(asset, size: MediaQuery.sizeOf(context) * 2),
            layout: layout,
            title: asset.name,
            estimatedRelief: estimatedRelief,
          ),
    );

/// Opens the 2.5D page over the window on a photo of a share, its [image] and its name; replaced in the tests
final spatialSharePhotoOpenerProvider =
    Provider<void Function(BuildContext context, ImageProvider image, String name, SpatialPhoto photo)>(
      (ref) =>
          (context, image, name, photo) => openSpatialPhoto(
            context,
            image: image,
            title: name,
            layout: photo.layout,
            estimatedRelief: photo.estimatedRelief,
          ),
    );

/// The "Spatial 2.5D" button itself, which calls [onOpen]
class SpatialPhotoIconButton extends StatelessWidget {
  const SpatialPhotoIconButton({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('desktop_spatial_photo'),
    icon: const Icon(Icons.threed_rotation_rounded),
    tooltip: context.t.spatial_2_5d,
    onPressed: onOpen,
  );
}

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
    return SpatialPhotoIconButton(
      onOpen: () => ref.read(spatialPhotoOpenerProvider)(context, asset, photo.layout, photo.estimatedRelief),
    );
  }
}
