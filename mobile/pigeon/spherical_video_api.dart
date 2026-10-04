import 'package:pigeon/pigeon.dart';

// Native 360° video player: SphericalVideoActivity on Android, SphericalVideoViewController on iOS
// Not Messages.g.swift on iOS: the Sync API already generates the Messages* types there, and PigeonError
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/spherical_video_api.g.dart',
    swiftOut: 'ios/Runner/Spherical/SphericalVideo.g.swift',
    swiftOptions: SwiftOptions(includeErrorClass: false),
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/spherical/SphericalVideo.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.spherical'),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
/// How the two eyes of a stereoscopic (3D) 360° media are laid out in the frame: one above the other (left eye on
/// top) or side by side (left eye on the left). [mono] is a regular 360° media.
enum StereoLayout { mono, topBottom, leftRight }

/// How much of the sphere the image covers: all of it (360°), or the front half (180°, VR180 files)
enum SphereCoverage { full, half }

@HostApi()
abstract class SphericalVideoApi {
  /// Plays an equirectangular video full screen in a native 360° player. [closeLabel] and [errorMessage] are
  /// translated by Flutter; the player falls back to its English resources without them. [stereoLayout] is the
  /// layout Flutter guessed from the video dimensions (the player prefers the layout the file declares, when it
  /// does); the user can change it in the player. [stereoLabels] are the translated labels of the 3D control,
  /// keyed "stereo", "mono", "topBottom", "leftRight".
  /// [fallbackUrl] is the server's transcoded stream, played instead of the original when the device cannot
  /// decode it (checked when the tracks are known) or when the original fails; null when there is none.
  void open(
    String url,
    Map<String, String> headers,
    String title,
    String? closeLabel,
    String? errorMessage,
    StereoLayout stereoLayout,
    Map<String, String> stereoLabels,
    SphereCoverage coverage,
    String? fallbackUrl,
  );
}

@FlutterApi()
abstract class SphericalVideoEvents {
  /// The player closed; [stereoLayout] and [coverage] are what it showed last, after the user's corrections
  void closed(StereoLayout stereoLayout, SphereCoverage coverage);
}
