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
@HostApi()
abstract class ImmersiveApi {
  /// True on a Meta Quest headset (Horizon OS).
  bool isHorizonOs();

  /// Opens the immersive head tracked viewer for an equirectangular photo or video.
  void open(String url, Map<String, String> headers, bool isVideo, String title);
}
