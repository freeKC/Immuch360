import 'package:pigeon/pigeon.dart';

// The live view of the Tapo cameras, a platform view ("immuch/camera_live"). On Android and the Quest it plays the RTSP
// stream of a camera with Media3; the credentials of the camera account go through setSource, never through the
// creation parameters of the view. On iPhone and iPad it plays with AVPlayer the live playlist that Dart makes of the
// stream on the local media bridge (isHls, no account: the camera account never leaves Dart).
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/camera_live_api.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/camera/CameraLive.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.camera'),
    swiftOut: 'ios/Runner/Core/CameraLive.g.swift',
    // PigeonError is already declared by Messages.g.swift in the same Runner target
    swiftOptions: SwiftOptions(includeErrorClass: false),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
enum CameraLiveState { idle, connecting, playing, buffering, failed }

class CameraLiveSource {
  const CameraLiveSource({required this.url, this.username, this.password, required this.isHls});

  /// rtsp://host:port/path without credentials (Android), or the bridge URL of a live playlist (iOS)
  final String url;

  /// The camera account of an RTSP address; none with a playlist
  final String? username;
  final String? password;

  /// A live playlist of the bridge rather than RTSP: what iPhone and iPad play, Android plays RTSP only
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
