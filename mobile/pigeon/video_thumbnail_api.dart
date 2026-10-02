import 'package:pigeon/pigeon.dart';

// A frame of a video as a JPEG thumbnail, for the videos of the network share browser: MediaMetadataRetriever on
// Android, AVAssetImageGenerator on iOS
// Not Messages.g.swift on iOS: the Sync API already generates the Messages* types there, and PigeonError
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/video_thumbnail_api.g.dart',
    swiftOut: 'ios/Runner/VideoThumbnail/VideoThumbnail.g.swift',
    swiftOptions: SwiftOptions(includeErrorClass: false),
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/videothumbnail/VideoThumbnail.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.videothumbnail'),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
@HostApi()
abstract class VideoThumbnailApi {
  /// The frame of the video at [url] (sent with [headers]) at [timeMs] milliseconds, or at the middle of a shorter
  /// video, as JPEG bytes at most [maxWidth] pixels wide. The video is read over HTTP by ranges, only what the frame
  /// needs. Fails when the video cannot be read or decoded.
  @async
  Uint8List thumbnailForUrl(String url, Map<String, String> headers, int timeMs, int maxWidth);
}
