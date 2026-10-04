// 360° panoramas, ported from web. Kept in one file on purpose, apart from the rule deciding
// what is a panorama (isPanoramaProvider), shared with the top bar and the edit action. The
// only new dependency is sensors_plus, for the optional gyroscope mode. The raw dual fisheye
// photos of Insta360 cameras are stitched into equirect images before the sphere shows them
// (see dual_fisheye_stitcher.dart).

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/models/video_audio_track.dart';
import 'package:immich_mobile/domain/models/video_buffering.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_stitcher.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/raw/dual_fisheye.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// 360° videos play in a native player: SphericalVideoActivity on Android, SphericalVideoViewController on iOS
final panorama360VideoSupportedProvider = Provider<bool>((_) => !kIsWeb && (Platform.isAndroid || Platform.isIOS));

final _log = Logger('PanoramaViewer');

/// Plays [asset] full screen in the native 360° player, from the file the viewer plays: the copy on the phone when
/// there is one, else the server's original or its transcoded stream, as the settings and the decoders of the phone
/// say (see [chooseVideoSource]); the player switches to the transcoded stream by itself when it cannot play the
/// original, unless the user chose the original whatever happens. A message tells when the choice went against the
/// original, or when the original plays although the phone cannot decode it. Meanwhile the viewer's player is
/// stopped, see [VideoPlayerNotifier.suspendForExternalPlayer].
///
/// The player shows the left eye of a 3D video, over the whole sphere or its front half (VR180), as the file declares
/// (see [SphericalProbeService]) or else as guessed from the video dimensions and name (see [resolveSphereView]),
/// until the user picks another layout or coverage. The coverage the user picked is remembered for the asset, see
/// [SphericalVideoSession].
///
/// A raw dual fisheye video (an Insta360 .insv whose frame holds both lenses side by side, see [raw360LayoutProvider])
/// goes with the calibration of its file (see [DualFisheyeCalibrationService]), which the player maps on the sphere
/// itself, one picture over the whole sphere. One whose frame holds one lens (a split recording, or one track per lens)
/// does not open: a message says so.
Future<void> openPanoramaVideo(BuildContext context, WidgetRef ref, BaseAsset asset) async {
  final remoteId = asset.remoteId;
  final localId = asset.localId;
  if (remoteId == null && localId == null) {
    return;
  }
  // Read before the first await: the viewer may be gone by then
  final api = ref.read(sphericalVideoApiProvider);
  final session = ref.read(sphericalVideoSessionProvider);
  final coverageOverrides = ref.read(sphereCoverageOverridesProvider.notifier);
  final probeService = ref.read(sphericalProbeServiceProvider);
  final storage = ref.read(storageRepositoryProvider);
  final player = ref.read(videoPlayerProvider(asset.id).notifier);
  final videoSources = ref.read(videoSourceServiceProvider);
  final policy = ref.read(appConfigProvider).viewer.videoSourcePolicy;
  final rawLayout = ref.read(raw360LayoutProvider(asset));
  final calibrations = ref.read(dualFisheyeCalibrationServiceProvider);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final closeLabel = context.t.close;
  final errorMessage = context.t.errors.unable_to_play_video;
  final unsupportedRawMessage = context.t.raw_video_split_unsupported;
  final labels = {
    ...sphereViewerLabels(context.t),
    ...audioTrackLabels(context.t, Localizations.localeOf(context)),
    ...videoBufferingLabels(context.t),
    ...videoSourceLabels(context.t),
  };

  try {
    // The native player reads file:// URIs too, and ignores the headers for them
    final localFile = localId != null ? await storage.getFileForAsset(localId) : null;
    // A video only on the phone, which the user chose to view as 360°, has no server copy
    if (localFile == null && remoteId == null) {
      _log.warning('No file to play in 360° for ${asset.name}');
      return;
    }
    final probe = await probeService.probe(asset, localFile: localFile);
    String? rawProjection;
    if (rawLayout != null) {
      // The frame the file declares settles it when the server did not give its size
      final frame = rawVideoFrameSize(probe: probe, width: asset.width, height: asset.height);
      if (rawLayout == Raw360Layout.separateLenses ||
          rawVideoLayout(frame?.width, frame?.height) == Raw360Layout.separateLenses) {
        _log.info('${asset.name} holds one lens per file or per track: not shown in 360°');
        messenger?.showSnackBar(SnackBar(content: Text(unsupportedRawMessage)));
        return;
      }
      rawProjection = rawVideoProjectionJson(await calibrations.forAsset(asset, localFile: localFile), frame);
    }
    // A file on the phone plays as it is: only the server has a transcoded stream to choose
    final source = localFile != null
        ? ChosenVideoSource(url: localFile.uri.toString())
        : await videoSources.serverSource(videoId: remoteId!, policy: policy, probe: probe);
    final view = rawProjection != null
        ? raw360SphereView
        : resolveSphereView(
            fileName: asset.name,
            width: asset.width,
            height: asset.height,
            probe: probe,
            chosenCoverage: coverageOverrides.get(asset),
          );
    session.start(asset: asset, coverage: view.coverage, coverageGuess: view.coverageGuess);
    // Stopped before the viewer goes to the background: it neither plays nor buffers behind the 360° player.
    // The viewer lifts this when the app resumes, which closing the player brings about on iOS as well: its full
    // screen presentation hides the Flutter view, and the app lifecycle follows.
    await player.suspendForExternalPlayer();
    final notice = source.notice;
    if (notice != null) {
      messenger?.showSnackBar(SnackBar(content: Text(notice.message(StaticTranslations.instance))));
    }
    await api.open(
      source.url,
      ApiService.getRequestHeaders(),
      asset.name,
      closeLabel,
      errorMessage,
      view.layout,
      labels,
      view.coverage,
      source.fallbackUrl,
      rawProjection,
    );
  } catch (error, stackTrace) {
    _log.severe('Cannot open the 360° video player for ${asset.name}', error, stackTrace);
    session.cancel();
    // Nothing else would bring the viewer's player back
    await player.resumeAfterExternalPlayer();
  }
}

/// Plays the video at [url] full screen in the native 360° player, like [openPanoramaVideo] for a video that is no
/// asset: a file of a network share, streamed through the local media bridge for example. [title] names it in the
/// player, [layout] and [coverage] are what the player opens with (see [resolveSphereView]); the user can change them
/// there, and nothing is remembered. [fallbackUrl] is a stream the player switches to when it cannot play [url], null
/// for none. [rawProjection] is the calibration of a raw dual fisheye video (see [rawVideoProjectionJson]), null for
/// an equirectangular one.
///
/// Meanwhile [player], the page's own player when there is one, is stopped (see
/// [VideoPlayerNotifier.suspendForExternalPlayer]): the page lifts this when the app resumes, which closing the 360°
/// player brings about, and a failure to open gives it back right away. Returns whether the 360° player opened.
Future<bool> openSphericalVideoUrl(
  BuildContext context,
  WidgetRef ref, {
  required String url,
  Map<String, String> headers = const {},
  required String title,
  required StereoLayout layout,
  required SphereCoverage coverage,
  VideoPlayerNotifier? player,
  String? fallbackUrl,
  String? rawProjection,
}) async {
  // Read before the first await: the page may be gone by then
  final api = ref.read(sphericalVideoApiProvider);
  // The session takes the events of the player; without an asset, it has nothing to remember when it closes
  ref.read(sphericalVideoSessionProvider).cancel();
  final closeLabel = context.t.close;
  final errorMessage = context.t.errors.unable_to_play_video;
  final labels = {
    ...sphereViewerLabels(context.t),
    ...audioTrackLabels(context.t, Localizations.localeOf(context)),
    ...videoBufferingLabels(context.t),
    ...videoSourceLabels(context.t),
  };

  try {
    await player?.suspendForExternalPlayer();
    await api.open(url, headers, title, closeLabel, errorMessage, layout, labels, coverage, fallbackUrl, rawProjection);
    return true;
  } catch (error, stackTrace) {
    _log.severe('Cannot open the 360° video player for $title', error, stackTrace);
    await player?.resumeAfterExternalPlayer();
    return false;
  }
}

// Value of a GPano tag, written as an attribute (GPano:Name="1.5", as cameras do) or as an element
// (<GPano:Name>1.5</GPano:Name>, as the server's copy into previews does)
double? _gpanoTag(String xmp, String name) {
  final match = RegExp(
    'GPano:$name'
    r'''(?:\s*=\s*["']|>)\s*([-+]?(?:\d+\.?\d*|\.\d+))''',
  ).firstMatch(xmp);
  return match == null ? null : double.tryParse(match.group(1)!);
}

// The GPano crop: which part of the full sphere the image covers, normalised to [0, 1]
@visibleForTesting
Rect? parseGPanoCrop(String xmp) {
  double? tag(String name) => _gpanoTag(xmp, name);
  final fullWidth = tag('FullPanoWidthPixels');
  final fullHeight = tag('FullPanoHeightPixels');
  final left = tag('CroppedAreaLeftPixels');
  final top = tag('CroppedAreaTopPixels');
  final width = tag('CroppedAreaImageWidthPixels');
  final height = tag('CroppedAreaImageHeightPixels');
  if (fullWidth == null || fullHeight == null || left == null || top == null || width == null || height == null) {
    return null;
  }
  return Rect.fromLTWH(left / fullWidth, top / fullHeight, width / fullWidth, height / fullHeight);
}

/// The view a panorama asks to open on, in degrees. Headings are compass headings: the center of the image points
/// to [poseHeading], 0 when the file does not say. Pitch is positive upwards.
typedef GPanoInitialView = ({double heading, double pitch, double poseHeading});

// Like the web viewer (Photo Sphere Viewer), only when both the heading and the pitch are set
@visibleForTesting
GPanoInitialView? parseGPanoInitialView(String xmp) {
  final heading = _gpanoTag(xmp, 'InitialViewHeadingDegrees');
  final pitch = _gpanoTag(xmp, 'InitialViewPitchDegrees');
  if (heading == null || pitch == null) {
    return null;
  }
  return (heading: heading, pitch: pitch, poseHeading: _gpanoTag(xmp, 'PoseHeadingDegrees') ?? 0);
}

// The GPano projection, as written: "equirectangular" for a 360° panorama, the value the server flags 360° assets
// by in their exif (ProjectionType), "cylindrical" for a flat one
@visibleForTesting
String? parseGPanoProjectionType(String xmp) =>
    RegExp(r'''GPano:ProjectionType(?:\s*=\s*["']|>)\s*([A-Za-z_-]+)''').firstMatch(xmp)?.group(1);

/// What the viewer takes from the GPano XMP of a panorama: [crop] is the part of the full sphere the image
/// covers, normalised to [0, 1], null for a full sphere. See [isPartialSphere] for crops covering the whole sphere.
typedef GPano = ({Rect? crop, GPanoInitialView? initialView});

/// The GPano tags of a file: its [projectionType] as written (see [isEquirectangularGPano]), and what the viewer
/// takes from them (see [GPano])
typedef GPanoTags = ({String? projectionType, Rect? crop, GPanoInitialView? initialView});

/// Whether [tags] declare a 360° panorama: an equirectangular projection, in any case, as the server rules on exif
bool isEquirectangularGPano(GPanoTags tags) => tags.projectionType?.toLowerCase() == 'equirectangular';

// Length of the windows at the head and at the tail of a file where the GPano XMP is looked for
const _gpanoWindow = 131072;

GPanoTags? _parseGPanoTags(String xmp) {
  final projectionType = parseGPanoProjectionType(xmp);
  final crop = parseGPanoCrop(xmp);
  final initialView = parseGPanoInitialView(xmp);
  if (projectionType == null && crop == null && initialView == null) {
    return null;
  }
  return (projectionType: projectionType, crop: crop, initialView: initialView);
}

/// Reads the GPano tags of a file [length] bytes long through [read], from the same windows as [fetchGPano] reads
/// on the server: the head of the file, where JPEG files carry their XMP, else its tail. Null when neither holds
/// GPano tags. Errors of [read] are not caught.
Future<GPanoTags?> readGPanoTags(ByteRangeReader read, int length) async {
  for (final offset in {0, if (length > _gpanoWindow) length - _gpanoWindow}) {
    final tags = _parseGPanoTags(String.fromCharCodes(await read(offset, _gpanoWindow)));
    if (tags != null) {
      return tags;
    }
  }
  return null;
}

/// Reads the GPano tags of a photo on the device, see [readGPanoTags]. Errors are not caught.
Future<GPanoTags?> readGPanoFile(File file) async {
  final handle = await file.open();
  try {
    return await readGPanoTags((offset, length) async {
      await handle.setPosition(offset);
      return handle.read(length);
    }, await handle.length());
  } finally {
    await handle.close();
  }
}

/// Where the viewer looks first for a GPano initial view, as its longitude and latitude in degrees.
///
/// The viewer's longitude is 0 at the center column of the full panorama and grows to the right, and the center
/// of the image points to the pose heading: the longitude is how far clockwise the initial heading is from it.
/// Photo Sphere Viewer, on the web, does the same by turning the sphere by the pose heading.
@visibleForTesting
({double longitude, double latitude}) initialViewDirection(GPanoInitialView view) =>
    (longitude: (view.heading - view.poseHeading + 180) % 360 - 180, latitude: view.pitch.clamp(-90.0, 90.0));

/// Reads the GPano tags from the XMP of a preview image with byte range requests: JPEG previews carry
/// the XMP at the head of the file, WebP previews at the tail. Returns null when there is neither a crop
/// nor an initial view.
Future<GPano?> fetchGPano(http.Client client, Uri url, {Duration timeout = const Duration(seconds: 5)}) async {
  const window = 131072;
  for (final range in const ['bytes=0-${window - 1}', 'bytes=-$window']) {
    final http.Response response;
    try {
      response = await client.get(url, headers: {'range': range}).timeout(timeout);
    } catch (_) {
      return null; // keep the full sphere
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      return null;
    }
    final xmp = String.fromCharCodes(response.bodyBytes);
    final crop = parseGPanoCrop(xmp);
    final initialView = parseGPanoInitialView(xmp);
    final found = crop != null || initialView != null;
    // A server ignoring the range header, or a file shorter than the window, already sent everything
    if (found || response.statusCode == 200 || response.bodyBytes.length < window) {
      return found ? (crop: crop, initialView: initialView) : null;
    }
  }
  return null;
}

// Slower rotations, in rad/s, are sensor noise: ignoring them keeps the view from drifting
const _gyroNoiseThreshold = 0.005;

/// Turns the view, in degrees, by the rotation the gyroscope measured over [dt] seconds.
///
/// Rates are in rad/s around the device axes, as sensors_plus reports them on Android and iOS alike: x towards
/// the right edge of the screen, y towards its top, z out of it, all taken in portrait, and a positive rate turns
/// counterclockwise as seen from the tip of the axis. [orientation] is how the screen content is rotated.
@visibleForTesting
({double longitude, double latitude}) applyGyroRotation({
  required double longitude,
  required double latitude,
  required double rateX,
  required double rateY,
  required double rateZ,
  required double dt,
  required DeviceOrientation orientation,
}) {
  // Rotation around the axes of the screen as the user sees it
  final (aroundScreenRight, aroundScreenUp) = switch (orientation) {
    DeviceOrientation.portraitUp => (rateX, rateY),
    // Top of the phone on the left
    DeviceOrientation.landscapeLeft => (-rateY, rateX),
    DeviceOrientation.portraitDown => (-rateX, -rateY),
    // Top of the phone on the right
    DeviceOrientation.landscapeRight => (rateY, -rateX),
  };
  double degrees(double rate) => rate.abs() < _gyroNoiseThreshold ? 0 : rate * dt * 180 / math.pi;

  // Turning the phone to the right is clockwise around the screen's up axis: look further right, like dragging
  // to the left. Tilting its top towards the user is counterclockwise around the screen's right axis: the back
  // of the phone points higher, look up. Rolling around z is ignored: the view has no roll.
  return (
    longitude: longitude - degrees(aroundScreenUp),
    latitude: (latitude + degrees(aroundScreenRight)).clamp(-90.0, 90.0),
  );
}

// After a drag, the view keeps turning and slows down with this time constant, in seconds
const _inertiaTimeConstant = 0.3;
// Slower than 0.05° per frame at 60 fps, the rotation stops
const _inertiaStopSpeed = 0.05 * 60;

/// One frame of the rotation that goes on after a drag, over [dt] seconds.
///
/// [velocity] is in degrees per second, of longitude along x and of latitude along y. It decays exponentially,
/// with a time constant of 0.3 s, and the step integrates that decay over the frame, so the view travels the same
/// way whatever the frame rate. Returns null once the rotation is too slow to go on.
@visibleForTesting
({double longitude, double latitude, Offset velocity})? applyInertia({
  required double longitude,
  required double latitude,
  required Offset velocity,
  required double dt,
}) {
  if (velocity.distance < _inertiaStopSpeed) {
    return null;
  }
  final decay = math.exp(-dt / _inertiaTimeConstant);
  final travel = velocity * (_inertiaTimeConstant * (1 - decay));
  final unclamped = latitude + travel.dy;
  final clamped = unclamped.clamp(-90.0, 90.0);
  return (
    longitude: longitude + travel.dx,
    latitude: clamped,
    // At a pole, only the longitude keeps turning
    velocity: Offset(velocity.dx * decay, clamped == unclamped ? velocity.dy * decay : 0),
  );
}

// Field of view, in degrees, when opening the viewer and after zooming out with a double tap
const _defaultFov = 90.0;
const _doubleTapZoomedFov = 45.0;

/// The field of view a double tap animates to: zoomed in, or back to the default once zoomed in.
@visibleForTesting
double doubleTapFov(double fov) => fov > _doubleTapZoomedFov + 1 ? _doubleTapZoomedFov : _defaultFov;

// Zoomed in this far, the viewer loads a sharper texture than the preview
const _highResolutionFov = _doubleTapZoomedFov;

// Largest texture the viewer decodes: 8192 pixels is the most common maximum texture size of phone GPUs, and
// 8192 x 4096 pixels already take 128 MB
const _maxTextureSize = Size(8192, 4096);

/// The decode size to ask for, for an image of [aspectRatio] (width / height) to fit in 8192 x 4096 pixels.
///
/// The decoders (native on Android and iOS, and the Dart fallback) scale an image down to the smallest size that
/// covers the size asked for, never up. A side of 1 is always covered, so asking for a width and a height of 1 caps
/// the width, and the other way round. One pixel under the cap absorbs the rounding of the scaled sides.
///
/// The aspect ratio comes from the preview or the thumbnail, which may be off by a rounding: around 2:1, the width
/// is capped, so the long side stays under the GPU limit and the height at most goes 1% over 4096.
@visibleForTesting
Size textureDecodeSize(double aspectRatio) => aspectRatio >= _maxTextureSize.aspectRatio * 0.99
    ? Size(_maxTextureSize.width - 1, 1)
    : Size(1, _maxTextureSize.height - 1);

/// URL of the sharp image of the photo [remoteId] on the server that the viewers load, not edited: panoramas cannot be
/// edited, and the calibration of a raw photo places the lenses in the frame as the camera wrote it.
///
/// For most photos, the full size image of the server: the original when browsers read its format, else its full size
/// conversion, or the preview when that conversion is off, as it is by default. A raw dual fisheye photo
/// ([isRawDualFisheye]) loads its original instead: .insp is no format browsers read, so a 72 MP photo would come as
/// its 2880 x 1440 preview, while the original is a plain JPEG followed by the trailer of the camera, which the
/// decoders stop before.
String sharpPanoramaUrl(String remoteId, {required bool isRawDualFisheye}) => isRawDualFisheye
    ? getOriginalUrlForRemoteId(remoteId, edited: false)
    : getThumbnailUrlForRemoteId(remoteId, type: AssetMediaSize.fullsize, edited: false);

// 360° badge on grid thumbnails, same as web:
// https://github.com/immich-app/immich/blob/main/web/src/lib/components/assets/thumbnail/Thumbnail.svelte
class PanoramaBadge extends ConsumerWidget {
  final BaseAsset asset;

  const PanoramaBadge({super.key, required this.asset});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(isPanoramaProvider(asset))) {
      return const SizedBox.shrink();
    }
    return const Padding(
      padding: EdgeInsets.only(right: 10.0, top: 6.0),
      child: Icon(
        Icons.threesixty_rounded,
        color: Colors.white,
        size: 16,
        shadows: [Shadow(blurRadius: 5.0, color: Color.fromRGBO(0, 0, 0, 0.6), offset: Offset.zero)],
      ),
    );
  }
}

/// Image the panorama viewer shows for an asset, at most [size] on screen: the thumbnail, then the preview, then the
/// original when the provider gets there. Tests replace it.
final panoramaImageProvider = Provider<ImageProvider Function(BaseAsset asset, Size size)>(
  (_) =>
      (asset, size) => getFullImageProvider(asset, size: size),
);

/// Client of the request for the GPano tags of a panorama: the app's shared client, with its native SSL setup. Tests
/// replace it.
final panoramaGPanoClientProvider = Provider<http.Client>((_) => NetworkRepository.client);

/// A photo the panorama viewer shows that is no asset: a file of a network share, for example. [image] is the photo,
/// [name] its file name (see [resolveSphereView]), [length] its size in bytes when known, and [read] reads its bytes
/// for its GPano tags (see [readGPanoTags]), null when they cannot be read.
typedef PanoramaSource = ({ImageProvider image, String name, int? length, ByteRangeReader? read});

/// Full-screen viewer for equirectangular (360°) photos: drag or flick to look around, pinch or double tap
/// to zoom, or turn on the gyroscope and move the phone. VR180 photos cover the front half of the sphere only; the
/// coverage control switches between that and the whole sphere.
///
/// A raw dual fisheye photo of an Insta360 camera (.insp, or a photo that ends with the trailer of the camera) is
/// stitched into an equirect image with the calibration of its file before the sphere shows it, each image the
/// provider yields in turn; a label tells where the calibration came from. It is one picture over the whole sphere:
/// no 3D or coverage control then.
@RoutePage()
class PanoramaViewerPage extends ConsumerStatefulWidget {
  /// The asset shown, null for a [source]
  final BaseAsset? asset;

  /// The photo shown when it is no asset, null for an [asset]. The coverage the user picks for it is not remembered.
  final PanoramaSource? source;

  const PanoramaViewerPage({super.key, required BaseAsset this.asset}) : source = null;

  const PanoramaViewerPage.source({super.key, required PanoramaSource this.source}) : asset = null;

  @override
  ConsumerState<PanoramaViewerPage> createState() => _PanoramaViewerPageState();
}

class _PanoramaViewerPageState extends ConsumerState<PanoramaViewerPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  ImageStream? _imageStream;
  late final ImageStreamListener _imageListener = ImageStreamListener(_onImage, onError: _onImageError);
  ImageInfo? _imageInfo;
  Object? _imageError;
  bool _loadStarted = false;
  // Sharper texture for zoomed in views, requested once
  bool _highResolutionRequested = false;
  RemoteImageRequest? _highResolutionRequest;
  // Part of the full sphere the image covers, normalised to [0, 1], as its GPano tags say: null without them
  Rect? _gpanoCrop;
  // Painting waits for the GPano tags, so the first frame already shows the initial view
  bool _gpanoLoaded = false;
  // Layout of a 3D panorama picked with the 3D button, null until then: see _view
  StereoLayout? _chosenStereoLayout;
  // Coverage picked with the coverage button for a photo that is no asset, null until then. That of an asset is
  // remembered for it, see sphereCoverageOverrideProvider.
  SphereCoverage? _chosenSourceCoverage;
  // Size of the image decoded last: the image of a raw photo is let go once stitched
  Size? _frameSize;

  // Whether the photo is a raw dual fisheye one, whose images are stitched before the sphere shows them, with its
  // calibration (see _startRaw). Null until known: a photo that is no asset is found raw by reading its file, and
  // painting waits for that.
  bool? _isRaw;
  Future<DualFisheyeCalibration>? _calibration;
  // Where the calibration came from, for the label, once known
  DualFisheyeSource? _calibrationSource;
  // The equirect image stitched last, and the stitches started and shown, counted, so that a slower stitch of an
  // earlier image never replaces a later one
  ui.Image? _stitched;
  int _stitchesStarted = 0;
  int _stitchShown = 0;

  // View direction and vertical field of view, in degrees
  double _longitude = 0;
  double _latitude = 0;
  double _fov = _defaultFov;
  double _fovAtScaleStart = _defaultFov;

  // Rotation that goes on after a drag, in degrees per second of longitude (x) and latitude (y)
  late final Ticker _inertia = createTicker(_onInertiaTick);
  Offset _inertiaVelocity = Offset.zero;
  Duration _lastInertiaTick = Duration.zero;
  // Fingers on the screen, and whether they pinched since the first one touched it: no inertia after a pinch
  int _pointers = 0;
  bool _pinched = false;

  // Double tap zoom
  late final AnimationController _zoom = AnimationController(vsync: this, duration: const Duration(milliseconds: 250))
    ..addListener(() {
      setState(() => _fov = _zoomAnimation.value);
      _loadHighResolutionIfZoomedIn();
    });
  Animation<double> _zoomAnimation = const AlwaysStoppedAnimation(_defaultFov);

  // Gyroscope mode: the view follows the phone, drags still add on top
  bool _gyroEnabled = false;
  StreamSubscription<GyroscopeEvent>? _gyroSubscription;
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  DateTime? _lastGyroTimestamp;
  Orientation _orientation = Orientation.portrait;
  // MediaQuery only tells landscape: gravity tells on which side the top of the phone is
  DeviceOrientation _landscapeSide = DeviceOrientation.landscapeLeft;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _orientation = MediaQuery.orientationOf(context);
    if (!_loadStarted) {
      _loadStarted = true;
      final asset = widget.asset;
      final image = asset != null
          ? ref.read(panoramaImageProvider)(asset, MediaQuery.sizeOf(context))
          : widget.source!.image;
      _imageStream = image.resolve(ImageConfiguration.empty)..addListener(_imageListener);
      _startRaw();
      // A raw photo has no GPano tags: a stitch looks ahead at the horizon
      if (_isRaw ?? false) {
        _gpanoLoaded = true;
      } else {
        _loadGPano().whenComplete(() {
          if (mounted) {
            setState(() => _gpanoLoaded = true);
          }
        }).ignore();
      }
    }
  }

  // Whether the photo is raw dual fisheye: an asset as its name or the scan of the device says (see
  // raw360LayoutProvider), a photo that is no asset as its name or the end of its file says (see hasInsta360Trailer)
  void _startRaw() {
    final asset = widget.asset;
    final calibrations = ref.read(dualFisheyeCalibrationServiceProvider);
    if (asset != null) {
      final isRaw = asset.isImage && ref.read(raw360LayoutProvider(asset)) == Raw360Layout.dualFisheye;
      _setRaw(isRaw ? calibrations.forAsset(asset) : null);
      return;
    }
    final source = widget.source!;
    // Read anew at each opening: the name and the size do not tell two files of two shares apart
    Future<DualFisheyeCalibration> calibration() => calibrations.forReader(
      'source:${source.name}:${source.length}:${identityHashCode(source.image)}',
      read: source.read,
      fileSize: source.length,
      isPhoto: true,
    );
    final read = source.read;
    final length = source.length;
    if (isRawPhotoName(source.name) || read == null || length == null) {
      _setRaw(isRawPhotoName(source.name) ? calibration() : null);
      return;
    }
    unawaited(_readSourceTrailer(read, length, calibration));
  }

  Future<void> _readSourceTrailer(
    ByteRangeReader read,
    int length,
    Future<DualFisheyeCalibration> Function() calibration,
  ) async {
    var isRaw = false;
    try {
      isRaw = await hasInsta360Trailer(read, length).timeout(const Duration(seconds: 5));
    } catch (error) {
      _log.info('Could not read the end of $_name: $error');
    }
    if (mounted) {
      setState(() => _setRaw(isRaw ? calibration() : null));
    }
  }

  void _setRaw(Future<DualFisheyeCalibration>? calibration) {
    _isRaw = calibration != null;
    _calibration = calibration;
    if (calibration != null) {
      unawaited(_stitchFrame());
    }
  }

  // Stitches the image decoded last into the equirect image the sphere shows, once the calibration is known. A
  // stitch that fails before any was shown shows the error.
  Future<void> _stitchFrame() async {
    final calibration = _calibration;
    final frame = _imageInfo?.image;
    if (calibration == null || frame == null) {
      return;
    }
    final stitch = ++_stitchesStarted;
    final source = frame.clone();
    try {
      final resolved = await calibration;
      if (!mounted) {
        return;
      }
      if (_calibrationSource != resolved.source) {
        setState(() => _calibrationSource = resolved.source);
      }
      final stitched = await stitchDualFisheye(source, resolved);
      if (!mounted || stitch <= _stitchShown) {
        stitched.dispose();
        return;
      }
      setState(() {
        _stitched?.dispose();
        _stitched = stitched;
        _stitchShown = stitch;
        // Not needed once stitched, unless a later image is on its way: a 8192 pixel wide image takes 128 MB
        if (stitch == _stitchesStarted) {
          _imageInfo?.dispose();
          _imageInfo = null;
        }
      });
    } catch (error, stackTrace) {
      _log.warning('Could not stitch $_name', error, stackTrace);
      if (mounted && _stitched == null && stitch == _stitchesStarted) {
        setState(() => _imageError = error);
      }
    } finally {
      source.dispose();
    }
  }

  /// The file name of the photo
  String get _name => widget.asset?.name ?? widget.source!.name;

  // Partial spheres and initial views: the server copies the GPano tags into the preview's XMP (same source as web);
  // a photo only on the device has them in its file, and so does a photo that is no asset
  Future<void> _loadGPano() async {
    final source = widget.source;
    final remoteId = widget.asset?.remoteId;
    final localId = widget.asset?.localId;
    final gpano = source != null
        ? await _readSourceGPano(source)
        : remoteId != null
        ? await fetchGPano(
            ref.read(panoramaGPanoClientProvider),
            Uri.parse(getThumbnailUrlForRemoteId(remoteId, type: AssetMediaSize.preview)),
          )
        : localId != null
        ? await _readLocalGPano(localId)
        : null;
    if (gpano == null || !mounted) {
      return;
    }
    setState(() {
      final crop = gpano.crop;
      if (crop != null) {
        _gpanoCrop = crop;
        // Without an initial view, start looking at the center of the captured area
        _longitude = 360 * (crop.left + crop.width / 2 - 0.5);
        _latitude = 90 - 180 * (crop.top + crop.height / 2);
      }
      final initialView = gpano.initialView;
      if (initialView != null) {
        final direction = initialViewDirection(initialView);
        _longitude = direction.longitude;
        _latitude = direction.latitude;
      }
    });
  }

  // The GPano tags of the file on the device, from the same windows as on the server. Painting waits for them, so a
  // file that does not come within a few seconds (one still in the cloud, on iOS) keeps the full sphere.
  Future<GPano?> _readLocalGPano(String localId) async {
    final storage = ref.read(storageRepositoryProvider);
    try {
      final file = await storage.getFileForAsset(localId).timeout(const Duration(seconds: 5));
      final tags = file == null ? null : await readGPanoFile(file).timeout(const Duration(seconds: 5));
      if (tags == null || (tags.crop == null && tags.initialView == null)) {
        return null;
      }
      return (crop: tags.crop, initialView: tags.initialView);
    } catch (error) {
      _log.info('Could not read the GPano tags of $_name: $error');
      return null; // keep the full sphere
    }
  }

  // The GPano tags of a photo that is no asset, from the same windows of its file. Painting waits for them, so a file
  // that cannot be read within a few seconds keeps the full sphere.
  Future<GPano?> _readSourceGPano(PanoramaSource source) async {
    final read = source.read;
    if (read == null) {
      return null;
    }
    try {
      final tags = await readGPanoTags(read, source.length ?? 0).timeout(const Duration(seconds: 5));
      if (tags == null || (tags.crop == null && tags.initialView == null)) {
        return null;
      }
      return (crop: tags.crop, initialView: tags.initialView);
    } catch (error) {
      _log.info('Could not read the GPano tags of $_name: $error');
      return null; // keep the full sphere
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inertia.dispose();
    _zoom.dispose();
    _stopSensors();
    if (_gyroEnabled) {
      unawaited(WakelockPlus.disable());
    }
    _highResolutionRequest?.cancel();
    _imageStream?.removeListener(_imageListener);
    _imageInfo?.dispose();
    _stitched?.dispose();
    super.dispose();
  }

  /// How the eyes of a 3D panorama are laid out, and how much of the sphere it covers (see [resolveSphereView]). A
  /// phone shows the left eye only. The layout the user picked, and the coverage the user picked for the asset
  /// ([chosenCoverage]), else guesses from the asset dimensions, or from the image while those are unknown, its name
  /// and its GPano crop. Partial panoramas are mono. A raw photo once stitched is one picture over the whole sphere.
  SphereView _view(SphereCoverage? chosenCoverage) {
    if (_isRaw ?? false) {
      return raw360SphereView;
    }
    final asset = widget.asset;
    final image = _imageInfo?.image;
    final (width, height) = asset != null && (asset.width ?? 0) > 0 && (asset.height ?? 0) > 0
        ? (asset.width, asset.height)
        : (image?.width, image?.height);
    return resolveSphereView(
      fileName: _name,
      width: width,
      height: height,
      gpanoCrop: _gpanoCrop,
      chosenLayout: _chosenStereoLayout,
      chosenCoverage: chosenCoverage,
    );
  }

  // The guess can be wrong both ways: a square panorama that is not 3D, or a 3D one of another size
  void _showNextStereoLayout(StereoLayout current) {
    final layout = current.next;
    setState(() => _chosenStereoLayout = layout);
    _showChoice(layout.label(context.t));
  }

  // The guess can be wrong both ways too: a VR180 file that nothing marks, or a 360° one whose name looks like VR180.
  // The choice is remembered for the asset; for a photo that is no asset, only while the viewer is open.
  void _showNextCoverage(SphereView view) {
    final coverage = view.coverage.next;
    // Back to the front, from behind the half sphere
    if (coverage == SphereCoverage.half && ((_longitude + 180) % 360 - 180).abs() > 90) {
      setState(() => _longitude = 0);
    }
    final asset = widget.asset;
    if (asset == null) {
      setState(() => _chosenSourceCoverage = coverage);
    } else {
      unawaited(
        ref
            .read(sphereCoverageOverridesProvider.notifier)
            .remember(asset, coverage, opened: view.coverage, guess: view.coverageGuess),
      );
    }
    _showChoice(coverage.label(context.t));
  }

  void _showChoice(String label) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(label), duration: const Duration(seconds: 2)));
  }

  // Called for every image the provider yields (thumbnail, preview, original), and for the sharp one loaded once
  // zoomed in
  void _onImage(ImageInfo imageInfo, bool _) {
    _imageInfo?.dispose();
    setState(() {
      _imageInfo = imageInfo;
      _frameSize = Size(imageInfo.image.width.toDouble(), imageInfo.image.height.toDouble());
      _imageError = null;
    });
    if (_isRaw ?? false) {
      unawaited(_stitchFrame());
    }
  }

  void _onImageError(Object error, StackTrace? _) {
    if (_imageInfo == null && _stitched == null && mounted) {
      setState(() => _imageError = error);
    }
  }

  // The preview is blurry once zoomed in: load the sharp image of the server (see sharpPanoramaUrl), the original of a
  // raw photo, which is then stitched like the preview. Straight from the server, with the headers of the session,
  // outside the image cache, where a texture this large would push out the thumbnails of the timeline.
  void _loadHighResolutionIfZoomedIn() {
    final remoteId = widget.asset?.remoteId;
    final frame = _frameSize;
    if (_highResolutionRequested || _fov > _highResolutionFov || remoteId == null || frame == null) {
      return;
    }
    _highResolutionRequested = true;
    final request = _highResolutionRequest = RemoteImageRequest(
      uri: sharpPanoramaUrl(remoteId, isRawDualFisheye: _isRaw ?? false),
      decodeSize: textureDecodeSize(frame.width / frame.height),
    );
    unawaited(_loadHighResolution(request));
  }

  Future<void> _loadHighResolution(RemoteImageRequest request) async {
    final ImageInfo? imageInfo;
    try {
      imageInfo = await request.load(PaintingBinding.instance.instantiateImageCodecWithSize);
    } catch (_) {
      return; // keep the preview
    } finally {
      _highResolutionRequest = null;
    }
    if (imageInfo == null) {
      return;
    }
    if (!mounted) {
      imageInfo.dispose();
      return;
    }
    // The server may send the preview again, and the provider may have loaded the original meanwhile
    final current = _frameSize;
    if (current != null && imageInfo.image.width <= current.width) {
      imageInfo.dispose();
      return;
    }
    // Whatever the provider still had to load would only replace it
    _imageStream?.removeListener(_imageListener);
    _imageStream = null;
    _onImage(imageInfo, false);
  }

  // Sensors stay off while the app is in the background
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_gyroEnabled) {
      return;
    }
    if (state == AppLifecycleState.paused) {
      _stopSensors();
    } else if (state == AppLifecycleState.resumed && _gyroSubscription == null) {
      _startSensors();
    }
  }

  void _setGyroEnabled(bool enabled) {
    setState(() => _gyroEnabled = enabled);
    if (enabled) {
      _inertia.stop();
      _startSensors();
      // Nobody touches the screen while looking around with the phone
      unawaited(WakelockPlus.enable());
    } else {
      _stopSensors();
      unawaited(WakelockPlus.disable());
    }
  }

  void _startSensors() {
    _lastGyroTimestamp = null;
    _gyroSubscription = gyroscopeEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(_onGyroscope, onError: (Object _) => _onGyroscopeError(), cancelOnError: true);
    // Without it, landscape keeps the default side
    _accelerometerSubscription = accelerometerEventStream().listen(
      _onAccelerometer,
      onError: (Object _) {},
      cancelOnError: true,
    );
  }

  void _stopSensors() {
    unawaited(_gyroSubscription?.cancel());
    _gyroSubscription = null;
    unawaited(_accelerometerSubscription?.cancel());
    _accelerometerSubscription = null;
  }

  void _onGyroscope(GyroscopeEvent event) {
    final previous = _lastGyroTimestamp;
    _lastGyroTimestamp = event.timestamp;
    final elapsed = previous == null ? 0.0 : event.timestamp.difference(previous).inMicroseconds / 1e6;
    // First event or unusable timestamps: assume the requested sampling rate
    final dt = elapsed > 0 && elapsed <= 0.2 ? elapsed : 1 / 50;
    final view = applyGyroRotation(
      longitude: _longitude,
      latitude: _latitude,
      rateX: event.x,
      rateY: event.y,
      rateZ: event.z,
      dt: dt,
      orientation: _orientation == Orientation.portrait ? DeviceOrientation.portraitUp : _landscapeSide,
    );
    if (view.longitude != _longitude || view.latitude != _latitude) {
      setState(() {
        _longitude = view.longitude;
        _latitude = view.latitude;
      });
    }
  }

  // At rest the accelerometer points up. Mostly along x, the phone is on its side, with its top on the left when
  // x points up. Held nearly flat, the screen keeps its rotation, and so does this.
  void _onAccelerometer(AccelerometerEvent event) {
    if (event.x.abs() > event.y.abs() && event.x.abs() > 4) {
      _landscapeSide = event.x > 0 ? DeviceOrientation.landscapeLeft : DeviceOrientation.landscapeRight;
    }
  }

  void _onGyroscopeError() {
    if (!mounted) {
      return;
    }
    _setGyroEnabled(false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t.panorama_no_gyroscope)));
  }

  // Any touch stops the view where it is
  void _onPointerDown(PointerDownEvent _) {
    if (_pointers++ == 0) {
      _pinched = false;
    }
    _inertia.stop();
    _zoom.stop();
  }

  void _onPointerUp(PointerEvent _) => _pointers = math.max(0, _pointers - 1);

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount > 1) {
      _pinched = true;
    }
    setState(() {
      _fov = (_fovAtScaleStart / details.scale).clamp(15.0, 115.0);
      // Rotate by the angle the dragged distance covers on screen, so the image follows the finger
      final degreesPerPixel = _fov / context.size!.height;
      _longitude -= details.focalPointDelta.dx * degreesPerPixel;
      _latitude = (_latitude + details.focalPointDelta.dy * degreesPerPixel).clamp(-90.0, 90.0);
    });
    _loadHighResolutionIfZoomedIn();
  }

  // A drag released while the finger still moves keeps turning the view, like a flick. The gyroscope already
  // moves it, and after lifting one finger of a pinch the other one is still on the screen.
  void _onScaleEnd(ScaleEndDetails details) {
    if (details.pointerCount > 0 || _pinched || _gyroEnabled) {
      return;
    }
    final degreesPerPixel = _fov / context.size!.height;
    final velocity = details.velocity.pixelsPerSecond;
    // Same signs as the drag in _onScaleUpdate
    _inertiaVelocity = Offset(-velocity.dx * degreesPerPixel, velocity.dy * degreesPerPixel);
    _lastInertiaTick = Duration.zero;
    _inertia.stop();
    unawaited(_inertia.start());
  }

  void _onInertiaTick(Duration elapsed) {
    final dt = (elapsed - _lastInertiaTick).inMicroseconds / 1e6;
    _lastInertiaTick = elapsed;
    // The first tick comes at 0: nothing to integrate yet
    if (dt <= 0) {
      return;
    }
    final view = applyInertia(longitude: _longitude, latitude: _latitude, velocity: _inertiaVelocity, dt: dt);
    if (view == null) {
      _inertia.stop();
      return;
    }
    _inertiaVelocity = view.velocity;
    setState(() {
      _longitude = view.longitude;
      _latitude = view.latitude;
    });
  }

  void _onDoubleTap() {
    _zoomAnimation = Tween(
      begin: _fov,
      end: doubleTapFov(_fov),
    ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(_zoom);
    unawaited(_zoom.forward(from: 0));
  }

  @override
  Widget build(BuildContext context) {
    final isRaw = _isRaw ?? false;
    final image = isRaw ? _stitched : _imageInfo?.image;
    final showsSphere = image != null && _gpanoLoaded && _isRaw != null;
    final calibrationSource = _calibrationSource;
    // On a Meta Quest the panel is fixed in space: following the head makes no sense there
    final isHorizonOs = ref.watch(isHorizonOsProvider).valueOrNull ?? false;
    final asset = widget.asset;
    final view = _view(asset != null ? ref.watch(sphereCoverageOverrideProvider(asset)) : _chosenSourceCoverage);
    final stereoLayout = view.layout;
    final gpanoCrop = isRaw ? null : _gpanoCrop;
    // A partial panorama covers what its GPano crop says, whatever the coverage
    final hasGPanoCrop = gpanoCrop != null && isPartialSphere(gpanoCrop);

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        leading: const CloseButton(),
        actions: [
          if (showsSphere && !hasGPanoCrop && !isRaw)
            IconButton(
              isSelected: view.coverage == SphereCoverage.half,
              icon: Text(
                view.coverage.shortLabel,
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
              ),
              tooltip: context.t.panorama_coverage,
              onPressed: () => _showNextCoverage(view),
            ),
          if (showsSphere && !isRaw)
            IconButton(
              isSelected: stereoLayout != StereoLayout.mono,
              icon: const Icon(Icons.view_in_ar_outlined),
              selectedIcon: const Icon(Icons.view_in_ar),
              tooltip: stereoLayout.label(context.t),
              onPressed: () => _showNextStereoLayout(stereoLayout),
            ),
          if (showsSphere && !isHorizonOs)
            IconButton(
              isSelected: _gyroEnabled,
              icon: const Icon(Icons.explore_outlined),
              selectedIcon: const Icon(Icons.explore),
              tooltip: context.t.panorama_gyroscope,
              onPressed: () => _setGyroEnabled(!_gyroEnabled),
            ),
        ],
      ),
      body: !showsSphere
          ? Center(
              child: _imageError != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(context.t.error_loading_image, style: const TextStyle(color: Colors.white70)),
                    )
                  : const CircularProgressIndicator(color: Colors.white70),
            )
          : Listener(
              onPointerDown: _onPointerDown,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerUp,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (_) => _fovAtScaleStart = _fov,
                onScaleUpdate: _onScaleUpdate,
                onScaleEnd: _onScaleEnd,
                onDoubleTap: _onDoubleTap,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(
                      painter: _SpherePainter(
                        image: image,
                        crop: sphereCrop(view.coverage, gpanoCrop: gpanoCrop),
                        textureRect: stereoLayout.leftEyeRect,
                        longitude: _longitude,
                        latitude: _latitude,
                        fov: _fov,
                      ),
                      size: Size.infinite,
                    ),
                    if (isRaw && calibrationSource != null)
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 16,
                        child: SafeArea(top: false, child: _RawStitchLabel(source: calibrationSource)),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// Tells that the app stitched a raw photo itself, and where the calibration of its lenses came from: the seams of
/// nominal values may show
class _RawStitchLabel extends StatelessWidget {
  const _RawStitchLabel({required this.source});

  final DualFisheyeSource source;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text(
              context.t.raw_360_stitched_by_app(source: dualFisheyeSourceLabel(context.t, source)),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints a sphere textured with an equirectangular image, as seen from its centre. Only the [textureRect] part of
/// the image textures it, the left eye of a 3D panorama, and only the [crop] part of the sphere: the rest, the back
/// of a VR180 photo for example, stays the black of the background.
class _SpherePainter extends CustomPainter {
  static const _rows = 32;
  static const _columns = 64;
  static const _vertexCount = (_rows + 1) * (_columns + 1);

  // Vertices further than ~80° from the view direction are off screen
  static const _minDepth = 0.15;

  final ui.Image image;
  final Rect crop;
  // Part of the image the sphere shows, normalised to [0, 1]
  final Rect textureRect;
  final double longitude;
  final double latitude;
  final double fov;

  const _SpherePainter({
    required this.image,
    required this.crop,
    required this.textureRect,
    required this.longitude,
    required this.latitude,
    required this.fov,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final yaw = longitude * math.pi / 180;
    final cosPitch = math.cos(latitude * math.pi / 180);
    final sinPitch = math.sin(latitude * math.pi / 180);
    final focalLength = size.height / 2 / math.tan(fov * math.pi / 360);
    final center = size.center(Offset.zero);

    // Project the vertices of a sphere mesh onto the canvas
    final positions = Float32List(_vertexCount * 2);
    final textureCoordinates = Float32List(_vertexCount * 2);
    final depths = Float32List(_vertexCount);
    for (var i = 0; i < _vertexCount; i++) {
      final row = i ~/ (_columns + 1);
      final column = i % (_columns + 1);
      final elevation = math.pi / 2 - math.pi * (crop.top + crop.height * row / _rows);
      final azimuth = 2 * math.pi * (crop.left + crop.width * column / _columns - 0.5) - yaw;
      final x = math.cos(elevation) * math.sin(azimuth);
      final y = math.sin(elevation) * cosPitch - math.cos(elevation) * math.cos(azimuth) * sinPitch;
      final depth = math.sin(elevation) * sinPitch + math.cos(elevation) * math.cos(azimuth) * cosPitch;

      depths[i] = depth;
      positions[i * 2] = center.dx + focalLength * x / depth;
      positions[i * 2 + 1] = center.dy - focalLength * y / depth;
      textureCoordinates[i * 2] = image.width * (textureRect.left + textureRect.width * column / _columns);
      textureCoordinates[i * 2 + 1] = image.height * (textureRect.top + textureRect.height * row / _rows);
    }

    // Keep only the triangles in front of the viewer
    final indices = Uint16List(_rows * _columns * 6);
    var indexCount = 0;
    for (var row = 0; row < _rows; row++) {
      for (var column = 0; column < _columns; column++) {
        final topLeft = row * (_columns + 1) + column;
        final corners = [topLeft, topLeft + 1, topLeft + _columns + 1, topLeft + _columns + 2];
        if (corners.any((corner) => depths[corner] < _minDepth)) {
          continue;
        }
        indices.setAll(indexCount, [corners[0], corners[1], corners[2], corners[1], corners[3], corners[2]]);
        indexCount += 6;
      }
    }

    final paint = Paint()
      ..shader = ImageShader(
        image,
        TileMode.clamp,
        TileMode.clamp,
        Matrix4.identity().storage,
        filterQuality: FilterQuality.medium,
      );
    canvas.drawVertices(
      ui.Vertices.raw(
        ui.VertexMode.triangles,
        positions,
        textureCoordinates: textureCoordinates,
        indices: Uint16List.sublistView(indices, 0, indexCount),
      ),
      BlendMode.srcOver,
      paint,
    );
  }

  @override
  bool shouldRepaint(_SpherePainter oldDelegate) => true;
}
