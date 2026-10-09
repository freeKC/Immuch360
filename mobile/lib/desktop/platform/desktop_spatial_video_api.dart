import 'package:flutter/services.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';

/// SpatialVideoApi on the computers, before the desktop Spatial player exists: unsupported, so the viewers keep their
/// own player and show the spatial_unavailable message, as on a phone without the GPU path
class DesktopSpatialVideoApi implements SpatialVideoApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  @override
  Future<SpatialCapabilities> capabilities() async =>
      SpatialCapabilities(supported: false, frontCamera: false, cameraPermissionGranted: false, reason: 'desktop');

  @override
  Future<void> open(SpatialOpenRequest request) =>
      Future.error(PlatformException(code: 'unsupported', message: 'No Spatial player on this computer yet'));
}
