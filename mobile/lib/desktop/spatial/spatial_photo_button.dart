// Spatial 2.5D of a 3D photo on the computers (release 53, lot P2): "Spatial 2.5D" in the top bar of the viewer, beside
// the view modes of a photo of two eyes (lib/desktop/ai/sbs_view_modes.dart), where the viewer shows one eye of it, and
// in the top bar of the page of a photo of a share or a folder (network_photo.page.dart). It opens the 2.5D page
// (spatial_photo_page.dart) on:
// - a photo of two eyes side by side: in the viewer as it shows it in its modes, ours, made by "2D to 3D" (full width
//   eyes, our XMP), and those of other tools, full or half width, eyes crossed or not (stereo_photo_probe.dart); on the
//   page of a share as the probe of its file told it (its frame, else the size the page decoded it at);
// - a photo of two eyes one above the other by its name (_TB, _OU, _HTB..., stackedPhotoFormatOf), never a 360° one;
// - a 360° or VR180 photo of two eyes (lot P3), as the 360° viewers lay its eyes out (resolveSphereView: one above the
//   other in a square frame, side by side in a 4:1 one, the coverage picked in a 360° viewer or guessed, the 3D
//   versions of 360° photos the app makes; from the frame before any edit of the server, and a partial panorama by its
//   GPano crop is one picture), shown as the 360° viewer shows it (spatial_sphere_render.dart); never the raw photo of
//   a 360° camera, nor a splat photo.
// Nothing on any other photo (an Apple spatial pair and a 3D scene included), nor while the Spatial 2.5D switch of the
// settings is off; but an ordinary 2D photo gets it too when this computer makes its 3D photo with AI: pressed, the 3D
// photo made by AI is opened, made first when there is none yet (spatial_conversion.dart); and so does a 360° photo of
// one eye when this computer makes its 3D version.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/library/stereo_badge.dart';
import 'package:immich_mobile/desktop/ai/library/versions.provider.dart';
import 'package:immich_mobile/desktop/ai/sbs_view_modes.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/desktop/network/share_writer.dart' show sharePathIn;
import 'package:immich_mobile/desktop/spatial/spatial_conversion.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_page.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_render.dart';
import 'package:immich_mobile/desktop/spatial/spatial_sphere_render.dart';
import 'package:immich_mobile/domain/models/ai_immersive/generated_panorama.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/flat_stereo.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/models/unedited_frame.dart';
import 'package:immich_mobile/domain/services/ai_immersive/share_versions.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart'
    show fetchGPano, panoramaGPanoClientProvider, panoramaOriginalReaderProvider, readGPanoFile;
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/splat/splat_photo.provider.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart' show AssetMediaSize;
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

/// What the 2.5D page opens a 360° photo with, from [view], how the 360° viewers show it, and the GPano crop of each
/// eye when known ([gpanoCrop]); null for a sphere of one eye
SpatialPhoto? spatialSphereFrom(SphereView view, {Rect? gpanoCrop, bool estimatedRelief = false}) {
  final layout = spatialSphereLayout(view.layout, crop: sphereCrop(view.coverage, gpanoCrop: gpanoCrop));
  return layout == null ? null : (layout: layout, estimatedRelief: estimatedRelief);
}

/// Whether the Spatial 2.5D switch of the settings is on
bool _spatialEnabled(WidgetRef ref) => ref.watch(appConfigProvider.select((config) => config.viewer.spatial25d));

/// What the 2.5D page opens [asset] with: its layout and whether its relief was estimated by AI; null for a photo it
/// does not take (see the top of this file)
SpatialPhoto? spatialPhotoOf(WidgetRef ref, BaseAsset asset) {
  if (!asset.isImage || !_spatialEnabled(ref)) {
    return null;
  }
  if (ref.watch(isEquirectangularProvider(asset))) {
    return _spatialSphereOfAsset(ref, asset);
  }
  // A 360° photo was told above: two eyes of a band of the sphere are no flat 3D photo
  return spatialPhotoFrom(name: asset.name, sideBySide: desktopSbsPhotoOf(ref, asset), isSphere: () => false);
}

/// The 360° photo [asset] of two eyes as the 360° viewer lays them out: from its frame before any edit of the server
/// (uneditedFrameOf, as the viewer reads it), its name, its GPano crop (a partial panorama is one picture, whatever its
/// shape) and the coverage the user picked. The frame decides first, so that a 360° photo of one eye reads nothing
/// more; until its file was read for the crop, nothing. Its relief was estimated by AI when the index of the versions
/// of this computer says so, or our packet in its file. Never a raw photo nor a splat photo.
SpatialPhoto? _spatialSphereOfAsset(WidgetRef ref, BaseAsset asset) {
  final frame = uneditedFrameOf(asset, hasEditedFrame(asset) ? ref.watch(assetExifProvider(asset)).valueOrNull : null);
  if (!isKnownFrame(frame)) {
    return null;
  }
  final chosenCoverage = ref.watch(sphereCoverageOverrideProvider(asset));
  SphereView view({Rect? gpanoCrop}) => resolveSphereView(
    fileName: asset.name,
    width: frame.width,
    height: frame.height,
    gpanoCrop: gpanoCrop,
    chosenCoverage: chosenCoverage,
  );
  if (view().layout == StereoLayout.mono ||
      ref.watch(rawMediaKindProvider(asset)) != null ||
      ref.watch(splatPhotoHoldsProvider(asset))) {
    return null;
  }
  final facts = ref.watch(spatialSphereFileFactsProvider(asset)).valueOrNull;
  if (facts == null) {
    return null;
  }
  final sphere = view(gpanoCrop: facts.gpanoCrop);
  if (sphere.layout == StereoLayout.mono) {
    return null;
  }
  final localId = asset.localId;
  final version = localId == null
      ? null
      : ref.watch(generatedVersionsProvider.select((versions) => versions.valueOrNull?[localId]));
  final indexed = version?.kind == ImmersiveKind.stereoPanorama360 && version?.origin == IndexedOrigin.estimated;
  return spatialSphereFrom(sphere, gpanoCrop: facts.gpanoCrop, estimatedRelief: indexed || facts.estimatedRelief);
}

/// What the file of a 360° library photo of two eyes tells the 2.5D page: its GPano crop, and whether our packet says
/// its relief was estimated by AI (a 3D version made on another computer and uploaded)
typedef SphereFileFacts = ({Rect? gpanoCrop, bool estimatedRelief});

const SphereFileFacts _noSphereFacts = (gpanoCrop: null, estimatedRelief: false);

/// [SphereFileFacts] of [asset], read where the 360° viewer reads them: the GPano crop from the unedited preview of
/// the server (its XMP holds the tags), our packet from the head of its original there; for a photo only on this
/// computer, both from its file. A read that fails or does not come within a few seconds tells nothing, as in the
/// viewer: the full sphere. Replaced in the tests.
final spatialSphereFileFactsProvider = FutureProvider.autoDispose.family<SphereFileFacts, BaseAsset>((
  ref,
  asset,
) async {
  final remoteId = asset.remoteId;
  try {
    if (remoteId != null) {
      final gpano = await fetchGPano(
        ref.read(panoramaGPanoClientProvider),
        Uri.parse(getThumbnailUrlForRemoteId(remoteId, type: AssetMediaSize.preview, edited: false)),
      );
      var estimated = false;
      final read = ref.read(panoramaOriginalReaderProvider)(remoteId);
      if (read != null) {
        try {
          final head = await read(0, generatedPanoramaHeadLength).timeout(_sphereReadTimeout);
          estimated = generatedPanoramaOfHead(head)?.isEstimatedRelief ?? false;
        } catch (error) {
          _log.info('Could not read the head of the original of ${asset.name}: $error');
        }
      }
      return (gpanoCrop: gpano?.crop, estimatedRelief: estimated);
    }
    final localId = asset.localId;
    if (localId == null) {
      return _noSphereFacts;
    }
    final file = await ref.read(storageRepositoryProvider).getFileForAsset(localId).timeout(_sphereReadTimeout);
    if (file == null) {
      return _noSphereFacts;
    }
    final tags = await readGPanoFile(file).timeout(_sphereReadTimeout);
    final head = await _headOf(file).timeout(_sphereReadTimeout);
    return (gpanoCrop: tags?.crop, estimatedRelief: generatedPanoramaOfHead(head)?.isEstimatedRelief ?? false);
  } catch (error) {
    _log.info('Could not read the GPano tags of ${asset.name}: $error');
    return _noSphereFacts;
  }
});

const _sphereReadTimeout = Duration(seconds: 5);

final _log = Logger('SpatialPhotoButton');

Future<Uint8List> _headOf(File file) async {
  final handle = await file.open();
  try {
    return await handle.read(generatedPanoramaHeadLength);
  } finally {
    await handle.close();
  }
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
  // A 360° photo of two eyes as its 360° button lays them out (the size the page decoded it at, else its EXIF frame);
  // never the raw photo of a 360° camera, one picture over the sphere once stitched
  if (info.is360) {
    if (info.rawKind != null) {
      return null;
    }
    final view = info.sphereView(
      name,
      width: decoded?.width.round() ?? info.frameWidth,
      height: decoded?.height.round() ?? info.frameHeight,
    );
    return spatialSphereFrom(
      view,
      gpanoCrop: info.gpano?.crop,
      estimatedRelief: info.panorama?.isEstimatedRelief ?? false,
    );
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
            // Twice the window: the frame holds two eyes, and each is shown as large as the window. A sphere at most
            // 4096 pixels on its long side, as a share decodes it, never edited, as the 360° viewer shows it: the view
            // shows a part (sphereDecodeBox)
            image: layout.sphere != null
                ? getFullImageProvider(
                    asset,
                    size: sphereDecodeBox(
                      width: asset.width,
                      height: asset.height,
                      devicePixelRatio: PlatformDispatcher.instance.views.first.devicePixelRatio,
                    ),
                    edited: false,
                  )
                : getFullImageProvider(asset, size: MediaQuery.sizeOf(context) * 2),
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

/// The longest side a 3D sphere of the library is decoded at for the 2.5D page
const sphereMaxDecodeSide = 4096;

/// The logical box the 2.5D page asks the decoder of a library photo of [width] x [height] pixels for, so that a 3D
/// sphere comes at most [sphereMaxDecodeSide] pixels on its long side: the photo's own shape, divided by
/// [devicePixelRatio], as the decoder covers the box at the pixel ratio of the window (LocalFullImageProvider, then
/// the cover scale of the request); a square box for a photo of unknown size. A server photo shows its preview
/// whatever the box, and "Load original image" decodes the original at its full size after it, as the other viewers.
Size sphereDecodeBox({required int? width, required int? height, required double devicePixelRatio}) {
  final ratio = devicePixelRatio > 0 ? devicePixelRatio : 1.0;
  if (width == null || height == null || width <= 0 || height <= 0) {
    return Size.square(sphereMaxDecodeSide / ratio);
  }
  // Half a pixel under the bound: the decoder rounds the sides up
  final scale = math.min(1.0, (sphereMaxDecodeSide - 0.5) / math.max(width, height));
  return Size(width * scale / ratio, height * scale / ratio);
}

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

/// "Spatial 2.5D" on a plain photo (spatial_conversion.dart): its tooltip says the 3D photo (the 3D version of a 360°
/// photo for a [sphere]) is made first, and a second press does nothing while [run] is under way
class SpatialConvertPhotoButton extends StatefulWidget {
  const SpatialConvertPhotoButton({super.key, required this.run, this.sphere = false});

  final Future<void> Function() run;
  final bool sphere;

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
    tooltip: widget.sphere ? context.t.spatial_2_5d_convert_first_360 : context.t.spatial_2_5d_convert_first,
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

/// The 3D version made by AI of the 360° library photo [asset] that the details of the viewer list, null when it has
/// none that can be opened now; replaced in the tests
final spatialMadeSphereOfAssetProvider = Provider<Future<SpatialMadePhoto?> Function(BaseAsset asset)>(
  (ref) => (asset) async {
    final localId = asset.localId;
    if (localId == null || !asset.isImage) {
      return null;
    }
    final finder = await ref.read(photoVersionsFinderProvider.future);
    final version = madeSphereVersionOf(await finder.find(localId, checksum: asset.checksum));
    return version == null
        ? null
        : (
            image: spatialCappedImage(FileImage(File(version.path))),
            name: version.name,
            layout: spatialMadeSphereLayout,
          );
  },
);

/// "Spatial 2.5D" on the plain library photo [asset] (spatial_conversion.dart): its 3D photo, or for [kind] the 3D
/// version of a 360° photo
Future<void> runLibrarySpatialConversion(
  BuildContext context,
  WidgetRef ref,
  BaseAsset asset, {
  ConversionKind kind = ConversionKind.sbsFromPhoto,
}) {
  final sphere = kind == ConversionKind.stereoPanoramaFromPanorama;
  return runSpatialConversion(
    context,
    name: asset.name,
    known: () => ref.read(sphere ? spatialMadeSphereOfAssetProvider : spatialMadeVersionOfAssetProvider)(asset),
    launch: () => ref.read(sphere ? spatialSphereConversionLauncherProvider : spatialConversionLauncherProvider)(
      context,
      assets: [asset],
    ),
    existing: (path) async => spatialCappedImage(FileImage(File(path))),
    open: (photo) => openSpatialMadePhoto(context, ref, photo),
  );
}

/// The 3D photo made by AI from the photo of a share at [entry] among the files of its folder ([neighbours], those the
/// browser read, else its folder is listed), as the Versions of its page find them; replaced in the tests
final spatialMadeVersionOfShareProvider =
    Provider<Future<ShareVersion?> Function(NetworkEntry entry, List<NetworkEntry>? neighbours)>(
      (ref) =>
          (entry, neighbours) async => madeShareStereoVersionOf(await _shareVersionsOf(ref, entry, neighbours)),
    );

/// The same for the 3D version made by AI of a 360° photo of a share; replaced in the tests
final spatialMadeSphereOfShareProvider =
    Provider<Future<ShareVersion?> Function(NetworkEntry entry, List<NetworkEntry>? neighbours)>(
      (ref) =>
          (entry, neighbours) async => madeShareSphereVersionOf(await _shareVersionsOf(ref, entry, neighbours)),
    );

/// The versions of the photo of a share at [entry] in its folder, as its Versions button finds them
Future<List<ShareVersion>> _shareVersionsOf(Ref ref, NetworkEntry entry, List<NetworkEntry>? neighbours) async {
  final fileSystem = await ref.read(networkConnectionsProvider).fileSystem(entry.sourceId);
  final listed = neighbours ?? await fileSystem.list(shareFolderOf(entry.path));
  return findShareVersions(entry, listed, readerOf: (neighbour) => networkFileReader(fileSystem, neighbour.path));
}

/// "Spatial 2.5D" on the plain photo of a share at [entry] (spatial_conversion.dart), its 3D photo or for [kind] the
/// 3D version of a 360° photo; [neighbours], the files of its folder the browser read; [imageOf], the picture of a file
/// of the share at its media bridge URL, as its page shows it
Future<void> runShareSpatialConversion(
  BuildContext context,
  WidgetRef ref,
  NetworkEntry entry, {
  List<NetworkEntry>? neighbours,
  required ImageProvider Function(Uri url, NetworkEntry file) imageOf,
  ConversionKind kind = ConversionKind.sbsFromPhoto,
}) {
  final connections = ref.read(networkConnectionsProvider);
  final sphere = kind == ConversionKind.stereoPanoramaFromPanorama;
  return runSpatialConversion(
    context,
    name: entry.name,
    known: () async {
      final version = await ref.read(sphere ? spatialMadeSphereOfShareProvider : spatialMadeVersionOfShareProvider)(
        entry,
        neighbours,
      );
      final photo = version?.photo;
      if (version == null || (photo == null && !sphere)) {
        return null;
      }
      final file = version.entry;
      return (
        image: imageOf(await connections.mediaUrl(file.sourceId, file.path), file),
        name: file.name,
        layout: photo == null ? spatialMadeSphereLayout : spatialLayoutOfSideBySide(photo),
      );
    },
    launch: () => ref.read(sphere ? spatialSphereConversionLauncherProvider : spatialConversionLauncherProvider)(
      context,
      shareFiles: [entry],
    ),
    // The version the job found is in the folder of the photo on its share
    existing: (path) async {
      final file = NetworkEntry(
        sourceId: entry.sourceId,
        path: sharePathIn(shareFolderOf(entry.path), p.basename(path)),
        isDirectory: false,
      );
      return imageOf(await connections.mediaUrl(file.sourceId, file.path), file);
    },
    open: (photo) => openSpatialMadePhoto(context, ref, photo),
  );
}

/// "Spatial 2.5D" in the top bar of the viewer of a computer, on a 3D photo or a 3D sphere, and on a plain photo or
/// a 360° photo of one eye whose 3D version this computer makes; nothing on any other photo
class DesktopSpatialPhotoButton extends ConsumerWidget {
  const DesktopSpatialPhotoButton({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photo = spatialPhotoOf(ref, asset);
    if (photo == null) {
      final kind = spatialConversionKindOf(ref, asset);
      return kind == null
          ? const SizedBox.shrink()
          : SpatialConvertPhotoButton(
              sphere: kind == ConversionKind.stereoPanoramaFromPanorama,
              run: () => runLibrarySpatialConversion(context, ref, asset, kind: kind),
            );
    }
    return SpatialPhotoIconButton(
      onOpen: () => ref.read(spatialPhotoOpenerProvider)(context, asset, photo.layout, photo.estimatedRelief),
    );
  }
}
