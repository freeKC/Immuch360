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
@HostApi()
abstract class SphericalVideoApi {
  /// Plays an equirectangular video full screen in a native 360° player. [closeLabel] and [errorMessage] are
  /// translated by Flutter; the player falls back to its English resources without them.
  void open(String url, Map<String, String> headers, String title, String? closeLabel, String? errorMessage);
}
