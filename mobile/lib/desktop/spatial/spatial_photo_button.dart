// Spatial 2.5D of a 3D photo on the computers (release 53, lot P2): "Spatial 2.5D" in the top bar of the viewer, beside
// the view modes of a photo of two eyes (lib/desktop/ai/sbs_view_modes.dart), where the viewer shows one eye of it, and
// in the top bar of the page of a photo of a share or a folder (network_photo.page.dart). It opens the 2.5D page
// (spatial_photo_page.dart) on:
// - a photo of two eyes side by side: in the viewer as it shows it in its modes, ours, made by "2D to 3D" (full width
//   eyes, our XMP), and those of other tools, full or half width, eyes crossed or not (stereo_photo_probe.dart); on the
//   page of a share as the probe of its file told it (its frame, else the size the page decoded it at);
// - a photo of two eyes one above the other by its name (_TB, _OU, _HTB..., stackedPhotoFormatOf), never a 360° one.
// Nothing on any other photo (an Apple spatial pair and a 3D scene included), nor while the Spatial 2.5D switch of the
// settings is off; but an ordinary 2D photo gets it too when this computer makes its 3D photo with AI: pressed, the 3D
// photo made by AI is opened, made first when there is none yet (spatial_conversion.dart).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/share_publisher.dart'
    show shareFolderChangeKey, shareFolderChangesProvider;
import 'package:immich_mobile/desktop/ai/library/versions.provider.dart';
import 'package:immich_mobile/desktop/ai/sbs_view_modes.dart';
import 'package:immich_mobile/desktop/network/share_writer.dart' show sharePathIn;
import 'package:immich_mobile/desktop/spatial/spatial_conversion.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_page.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_render.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/flat_stereo.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/ai_immersive/share_versions.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:path/path.dart' as p;

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
/// probe told; for any file the probe told no two eyes of (meant for those whose frame it could not read: a HEIF, an
/// AVIF, a TIFF), they are told again by the name and [decoded], the size the page decoded the photo at (scaled down,
/// with its aspect ratio), without our XMP. The switch is the caller's.
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

/// The "Spatial 2.5D" button itself, which calls [onOpen]; [tooltip], its words when not "Spatial 2.5D"
class SpatialPhotoIconButton extends StatelessWidget {
  const SpatialPhotoIconButton({super.key, required this.onOpen, this.tooltip});

  final VoidCallback? onOpen;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('desktop_spatial_photo'),
    icon: const Icon(Icons.threed_rotation_rounded),
    tooltip: tooltip ?? context.t.spatial_2_5d,
    onPressed: onOpen,
  );
}

/// "Spatial 2.5D" on a plain photo (spatial_conversion.dart): its tooltip says the 3D photo is made first, and a
/// second press does nothing while [run] is under way
class SpatialConvertPhotoButton extends StatefulWidget {
  const SpatialConvertPhotoButton({super.key, required this.run});

  final Future<void> Function() run;

  @override
  State<SpatialConvertPhotoButton> createState() => _SpatialConvertPhotoButtonState();
}

class _SpatialConvertPhotoButtonState extends State<SpatialConvertPhotoButton> {
  var _running = false;

  Future<void> _press() async {
    if (_running) {
      return;
    }
    setState(() => _running = true);
    try {
      await widget.run();
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => SpatialPhotoIconButton(
    tooltip: context.t.spatial_2_5d_convert_first,
    onOpen: _running ? null : () => unawaited(_press()),
  );
}

/// Opens the 2.5D page on a 3D photo made by AI ([SpatialMadePhoto]), through the opener of the photos of a share
void openSpatialMadePhoto(BuildContext context, WidgetRef ref, SpatialMadePhoto photo) => ref.read(
  spatialSharePhotoOpenerProvider,
)(context, photo.image, photo.name, (layout: photo.layout, estimatedRelief: true));

/// The 3D photo made by AI from the library photo [asset] that the details of the viewer list (PhotoVersionsFinder),
/// null when it has none that can be opened now; replaced in the tests
final spatialMadeVersionOfAssetProvider = Provider<Future<SpatialMadePhoto?> Function(BaseAsset asset)>(
  (ref) => (asset) async {
    final localId = asset.localId;
    if (localId == null || !asset.isImage) {
      return null;
    }
    final finder = await ref.read(photoVersionsFinderProvider.future);
    final version = madeStereoVersionOf(await finder.find(localId, checksum: asset.checksum));
    return version == null
        ? null
        : (
            image: spatialCappedImage(FileImage(File(version.path))),
            name: version.name,
            layout: spatialMadePhotoLayout,
          );
  },
);

/// "Spatial 2.5D" on the plain library photo [asset] (spatial_conversion.dart)
Future<void> runLibrarySpatialConversion(BuildContext context, WidgetRef ref, BaseAsset asset) => runSpatialConversion(
  context,
  name: asset.name,
  known: () => ref.read(spatialMadeVersionOfAssetProvider)(asset),
  launch: () => ref.read(spatialConversionLauncherProvider)(context, assets: [asset]),
  existing: (path) async => spatialCappedImage(FileImage(File(path))),
  open: (photo) => openSpatialMadePhoto(context, ref, photo),
);

/// The 3D photo made by AI from the photo of a share at [entry] among the files of its folder ([neighbours], those the
/// browser read, else its folder is listed), as the Versions of its page find them; replaced in the tests. Once a
/// version was put in that folder (shareFolderChangesProvider), the browser's files are out of date: the folder is
/// listed again, so that the 3D photo just made opens at the next press instead of being made a second time.
final spatialMadeVersionOfShareProvider =
    Provider<Future<ShareVersion?> Function(NetworkEntry entry, List<NetworkEntry>? neighbours)>(
      (ref) => (entry, neighbours) async {
        final folder = shareFolderOf(entry.path);
        final changed = ref.read(shareFolderChangesProvider)[shareFolderChangeKey(entry.sourceId, folder)] != null;
        final fileSystem = await ref.read(networkConnectionsProvider).fileSystem(entry.sourceId);
        final listed = (changed ? null : neighbours) ?? await fileSystem.list(folder);
        final versions = await findShareVersions(
          entry,
          listed,
          readerOf: (neighbour) => networkFileReader(fileSystem, neighbour.path),
        );
        return madeShareStereoVersionOf(versions);
      },
    );

/// "Spatial 2.5D" on the plain photo of a share at [entry] (spatial_conversion.dart); [neighbours], the files of its
/// folder the browser read; [imageOf], the picture of a file of the share at its media bridge URL, as its page shows it
Future<void> runShareSpatialConversion(
  BuildContext context,
  WidgetRef ref,
  NetworkEntry entry, {
  List<NetworkEntry>? neighbours,
  required ImageProvider Function(Uri url, NetworkEntry file) imageOf,
}) {
  final connections = ref.read(networkConnectionsProvider);
  return runSpatialConversion(
    context,
    name: entry.name,
    known: () async {
      final version = await ref.read(spatialMadeVersionOfShareProvider)(entry, neighbours);
      final photo = version?.photo;
      if (version == null || photo == null) {
        return null;
      }
      final file = version.entry;
      return (
        image: imageOf(await connections.mediaUrl(file.sourceId, file.path), file),
        name: file.name,
        layout: spatialLayoutOfSideBySide(photo),
      );
    },
    launch: () => ref.read(spatialConversionLauncherProvider)(context, shareFiles: [entry]),
    existing: (path) => spatialShareExistingImage(entry, path, mediaUrl: connections.mediaUrl, imageOf: imageOf),
    open: (photo) => openSpatialMadePhoto(context, ref, photo),
  );
}

/// The picture of the version at [path] a job of the photo of a share at [entry] was skipped for: a file of this
/// computer when the queue found it here (the folder of my choice, the library, where it looks first), else the file of
/// that name in the folder of the photo on its share, through [mediaUrl] and [imageOf]
Future<ImageProvider?> spatialShareExistingImage(
  NetworkEntry entry,
  String path, {
  required Future<Uri> Function(String sourceId, String path) mediaUrl,
  required ImageProvider Function(Uri url, NetworkEntry file) imageOf,
}) async {
  final folder = shareFolderOf(entry.path);
  if (!p.equals(p.dirname(path), folder) && File(path).existsSync()) {
    return spatialCappedImage(FileImage(File(path)));
  }
  final file = NetworkEntry(sourceId: entry.sourceId, path: sharePathIn(folder, p.basename(path)), isDirectory: false);
  return imageOf(await mediaUrl(file.sourceId, file.path), file);
}

/// "Spatial 2.5D" in the top bar of the viewer of a computer, on a 3D photo, and on a plain photo whose 3D photo this
/// computer makes; nothing on any other photo
class DesktopSpatialPhotoButton extends ConsumerWidget {
  const DesktopSpatialPhotoButton({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photo = spatialPhotoOf(ref, asset);
    if (photo == null) {
      return spatialConversionOffered(ref, asset)
          ? SpatialConvertPhotoButton(run: () => runLibrarySpatialConversion(context, ref, asset))
          : const SizedBox.shrink();
    }
    return SpatialPhotoIconButton(
      onOpen: () => ref.read(spatialPhotoOpenerProvider)(context, asset, photo.layout, photo.estimatedRelief),
    );
  }
}
