import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/video_thumbnail_grabber.dart';
import 'package:immich_mobile/platform/video_thumbnail_api.g.dart';

/// VideoThumbnailApi on the computers: a frame of the video of a share tile, taken by the desktop player's frame
/// grabber from its media bridge URL (design 2.7); NetworkVideoThumbnailService keeps it in the video thumbnail disk
/// cache, as on the phones. No frame (an empty answer, which the service takes as a failure, so that the tile keeps
/// its film icon) without libmpv, for an address that is not the bridge's, or when the video gives none.
class DesktopVideoThumbnailApi implements VideoThumbnailApi {
  /// [grabber] and [available] are replaced by the tests; by default the app's grabber, when libmpv loaded at start
  DesktopVideoThumbnailApi({this._grabber, this._available});

  final VideoThumbnailGrabber? _grabber;
  final bool? _available;

  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  /// [headers] are never used: the tiles hand bridge URLs only, and nothing of a session goes to libmpv
  @override
  Future<Uint8List> thumbnailForUrl(String url, Map<String, String> headers, int timeMs, int maxWidth) async {
    if (!(_available ?? desktopVideoAvailable) || !isBridgeUrl(url) || maxWidth <= 0) {
      return Uint8List(0);
    }
    final frame = await (_grabber ?? VideoThumbnailGrabber.shared).grab(
      url,
      time: Duration(milliseconds: timeMs),
      // As wide as asked, as tall as the frame's shape gives (a portrait video four times taller at most)
      box: (width: maxWidth, height: maxWidth * 4, cover: false),
    );
    return frame ?? Uint8List(0);
  }

  /// Whether [url] is one of the app's media bridge: http on this computer, with no user name
  static bool isBridgeUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.scheme == 'http' &&
        uri.userInfo.isEmpty &&
        (uri.host == '127.0.0.1' || uri.host == 'localhost' || uri.host == '::1');
  }
}
