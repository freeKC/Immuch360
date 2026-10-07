import 'package:pigeon/pigeon.dart';

// Android only: the live view of the Tapo cameras, a platform view ("immuch/camera_live") that plays the RTSP stream of
// a camera with Media3. The credentials of the camera account go through setSource, never through the creation
// parameters of the view.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/camera_live_api.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/camera/CameraLive.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.camera'),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
enum CameraLiveState { idle, connecting, playing, buffering, failed }

class CameraLiveSource {
  const CameraLiveSource({required this.url, this.username, this.password, required this.isHls});

  /// rtsp://host:port/path without credentials, or the bridge URL of a live playlist
  final String url;
  final String? username;
  final String? password;

  /// A live playlist of the bridge rather than RTSP; always false until the live view through HLS comes
  final bool isHls;
}

@HostApi()
abstract class CameraLiveApi {
  /// Starts or replaces what the view [viewId] plays (also the HD/SD switch)
  void setSource(int viewId, CameraLiveSource source);

  void setMuted(int viewId, bool muted);

  void stop(int viewId);
}

@FlutterApi()
abstract class CameraLiveEvents {
  /// The state of the view [viewId]; [error] never holds the address of the stream, [hasAudio] whether the device
  /// plays its sound
  void stateChanged(int viewId, CameraLiveState state, String? error, bool hasAudio);
}
