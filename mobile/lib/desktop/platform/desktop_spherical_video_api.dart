// SphericalVideoApi on the computers (design 1.2 and 2.6): open pushes the 360° player route of the app's window and
// returns at once, as the native open starts an activity on Android. The headers are dropped: the player reads the
// server's videos through the media bridge, which carries the session itself (spherical_player_route.dart).

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/spherical_player_route.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart';

class DesktopSphericalVideoApi implements SphericalVideoApi {
  /// [navigator] gives the root navigator of the app (the router's), null when there is none yet
  DesktopSphericalVideoApi({this.navigator});

  final GlobalKey<NavigatorState>? Function()? navigator;

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
  ) async {
    final state = navigator?.call()?.currentState;
    if (state == null || !desktopVideoAvailable) {
      // As a phone without the native player: the caller gives the viewer's video back
      throw PlatformException(code: 'unsupported', message: 'No 360 video player on this computer');
    }
    // Not awaited: the route's future ends when it closes, the native open returns once the player started
    unawaited(
      state.push(
        DesktopSphericalPlayerPage.route(
          SphericalPlayerArgs(
            url: url,
            title: title,
            layout: stereoLayout,
            coverage: coverage,
            fallbackUrl: fallbackUrl,
            rawProjection: rawProjection,
            errorMessage: errorMessage,
          ),
        ),
      ),
    );
  }
}
