import 'package:flutter/services.dart';
import 'package:immich_mobile/platform/video_thumbnail_api.g.dart';

/// VideoThumbnailApi on the computers, before the desktop player can grab a frame: no frame, which the thumbnail
/// service takes as a failure, so the tile keeps its film icon
class DesktopVideoThumbnailApi implements VideoThumbnailApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  @override
  Future<Uint8List> thumbnailForUrl(String url, Map<String, String> headers, int timeMs, int maxWidth) async =>
      Uint8List(0);
}
