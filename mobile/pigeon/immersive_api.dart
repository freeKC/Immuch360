import 'package:pigeon/pigeon.dart';

// Android only: Meta Quest (Horizon OS) immersive viewer for 360 photos and videos.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/immersive_api.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/immersive/Immersive.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.immersive'),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
/// How the two eyes of a stereoscopic (3D) 360° media are laid out in the frame: one above the other (left eye on
/// top) or side by side (left eye on the left). [mono] is a regular 360° media. Same values as the player API.
enum ImmersiveStereoLayout { mono, topBottom, leftRight }

/// How much of the sphere the image covers: all of it (360°), or the front half (180°, VR180 files)
enum ImmersiveSphereCoverage { full, half }

@HostApi()
abstract class ImmersiveApi {
  /// True on a Meta Quest headset (Horizon OS).
  bool isHorizonOs();

  /// Opens the immersive head tracked viewer for an equirectangular photo or video. [stereoLayout] is the layout
  /// Flutter guessed from the media dimensions; the headset shows each eye its own half of a stereoscopic media,
  /// and the user can change the layout in the viewer. [stereoLabels] are the translated labels of the 3D control,
  /// keyed "stereo", "mono", "topBottom", "leftRight".
  void open(
    String url,
    Map<String, String> headers,
    bool isVideo,
    String title,
    ImmersiveStereoLayout stereoLayout,
    Map<String, String> stereoLabels,
    ImmersiveSphereCoverage coverage,
  );
}
