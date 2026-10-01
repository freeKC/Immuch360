import 'package:pigeon/pigeon.dart';

// Experimental Spatial 2.5D player for stereoscopic videos on phones: SpatialVideoActivity on Android,
// SpatialVideoViewController on iOS. Not available on Meta Quest headsets.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/spatial_video_api.g.dart',
    swiftOut: 'ios/Runner/Spatial/SpatialVideo.g.swift',
    swiftOptions: SwiftOptions(includeErrorClass: false),
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/spatial/SpatialVideo.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.spatial'),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
/// How the two eyes of a stereoscopic video are laid out in the frame. [auto] lets the player use what the file
/// declares, then the frame shape. The swapped variants are for files that put the right eye first.
enum SpatialStereoLayout { auto, sideBySide, topBottom, sideBySideSwapped, topBottomSwapped, none }

/// [flat] is a regular video; [equirectangular] is a 360° video, which the player shows through a viewport that the
/// user turns by touch or with the sensors.
enum SpatialProjection { flat, equirectangular }

/// What the device can do. [reason] is a short English diagnostic for the logs when [supported] is false.
class SpatialCapabilities {
  SpatialCapabilities({required this.supported, required this.frontCamera, required this.cameraPermissionGranted, this.reason});
  bool supported;
  bool frontCamera;
  bool cameraPermissionGranted;
  String? reason;
}

class SpatialOpenRequest {
  SpatialOpenRequest({
    required this.url,
    required this.headers,
    required this.title,
    required this.layout,
    required this.projection,
    required this.startPositionMs,
    required this.autoplay,
    required this.debugOverlay,
    required this.labels,
  });

  String url;
  Map<String, String> headers;
  String title;
  SpatialStereoLayout layout;
  SpatialProjection projection;
  int startPositionMs;
  bool autoplay;

  /// Shows the diagnostics overlay (frame rates, head position, viewpoint, disparity size) and the manual viewpoint
  /// slider.
  bool debugOverlay;

  /// Translated labels of the player UI, keyed spatial, normal, layout, layoutAuto, layoutSideBySide, layoutTopBottom,
  /// layoutSideBySideSwapped, layoutTopBottomSwapped, layoutNone, recenter, trackingLost, cameraDenied, unavailable,
  /// sensitivity, close, error. English fallbacks live in the native code.
  Map<String, String> labels;
}

@HostApi()
abstract class SpatialVideoApi {
  /// Whether the Spatial 2.5D player can run here (GPU features, front camera). Cheap, no permission prompt.
  SpatialCapabilities capabilities();

  /// Opens the full screen Spatial 2.5D player. The camera permission is asked inside the player, on first use.
  void open(SpatialOpenRequest request);
}

@FlutterApi()
abstract class SpatialVideoEvents {
  /// The player closed: where playback was, whether it was playing, and the stereo layout in use, so that the
  /// normal player resumes at the same place and the choice can be remembered for the asset.
  void closed(int positionMs, bool wasPlaying, SpatialStereoLayout layout);
}
