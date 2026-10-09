import 'package:flutter/services.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart';

/// SphericalVideoApi on the computers, before the desktop 360° player exists. Nothing opens it there: the 360° button
/// of videos shows only where panorama360VideoSupportedProvider says so, which is the phones; an unexpected call fails
/// the way a phone without the native player would.
class DesktopSphericalVideoApi implements SphericalVideoApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  @override
  Future<void> open(
    String url,
    Map<String, String> headers,
    String title,
    String? closeLabel,
    String? errorMessage,
    StereoLayout stereoLayout,
    Map<String, String> stereoLabels,
    SphereCoverage coverage,
    String? fallbackUrl,
    String? rawProjection,
  ) => Future.error(PlatformException(code: 'unsupported', message: 'No 360 video player on this computer yet'));
}
