// SpatialVideoApi on the computers (study feasibility-windows-spatial.md, section 3.5): on Windows, open pushes the
// Spatial 2.5D route of the app's window (spatial/spatial_player_route.dart) and returns at once, as the native open
// starts an activity on Android; its closing comes back as the SpatialVideoEvents.closed of the phones, so that
// SpatialVideoSession (or the page of a network share) takes the video back where the player left it and remembers the
// layout picked. The passes draw in renderer C of the vendored media_kit_video, on Windows only: Linux and macOS keep
// the message that Spatial 2.5D comes later.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/desktop/spatial/spatial_player_route.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:logging/logging.dart';

final _log = Logger('DesktopSpatialVideoApi');

class DesktopSpatialVideoApi implements SpatialVideoApi {
  /// [navigator] gives the root navigator of the app (the router's), null when there is none yet. [windows],
  /// [videoAvailable] and [routeFor] are for the tests.
  DesktopSpatialVideoApi({
    this.navigator,
    bool? windows,
    bool Function()? videoAvailable,
    Route<void> Function(SpatialPlayerArgs args, SpatialClosedCallback onClosed)? routeFor,
  }) : _windows = windows ?? Platform.isWindows,
       _videoAvailable = videoAvailable ?? (() => desktopVideoAvailable),
       _routeFor = routeFor ?? ((args, onClosed) => DesktopSpatialPlayerPage.route(args, onClosed: onClosed));

  final GlobalKey<NavigatorState>? Function()? navigator;
  final bool _windows;
  final bool Function() _videoAvailable;
  final Route<void> Function(SpatialPlayerArgs args, SpatialClosedCallback onClosed) _routeFor;

  /// The channel of SpatialVideoEvents.closed, on which the native players of the phones report their closing
  static const closedChannel = 'dev.flutter.pigeon.immich_mobile.SpatialVideoEvents.closed';

  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  /// Supported on Windows when libmpv loaded. The webcam is not asked for here: no camera opens before the page,
  /// and Windows has no prompt to ask beforehand (the page shows the privacy message when access is turned off).
  @override
  Future<SpatialCapabilities> capabilities() async {
    if (!_windows) {
      return SpatialCapabilities(
        supported: false,
        frontCamera: false,
        cameraPermissionGranted: false,
        reason: 'desktop',
      );
    }
    if (!_videoAvailable()) {
      return SpatialCapabilities(
        supported: false,
        frontCamera: false,
        cameraPermissionGranted: false,
        reason: 'no libmpv',
      );
    }
    return SpatialCapabilities(supported: true, frontCamera: true, cameraPermissionGranted: true);
  }

  @override
  Future<void> open(SpatialOpenRequest request) async {
    final state = navigator?.call()?.currentState;
    if (!_windows || state == null || !_videoAvailable()) {
      // As a phone without the player: the caller gives the viewer's video back
      throw PlatformException(code: 'unsupported', message: 'No Spatial player on this computer');
    }
    // Not awaited: the route's future ends when it closes, the native open returns once the player started
    unawaited(state.push(_routeFor(SpatialPlayerArgs.of(request), reportClosed)));
  }

  /// Tells the handler of SpatialVideoEvents (SpatialVideoSession, or the page of a network share) that the player
  /// closed, as the native players of the phones do through the pigeon channel
  static void reportClosed(int positionMs, bool wasPlaying, SpatialStereoLayout layout, SpatialProjection projection) {
    final message = SpatialVideoEvents.pigeonChannelCodec.encodeMessage(<Object?>[
      positionMs,
      wasPlaying,
      layout,
      projection,
    ]);
    ServicesBinding.instance.channelBuffers.push(closedChannel, message, (_) {});
    _log.info('Spatial player closed at $positionMs ms, ${wasPlaying ? 'playing' : 'paused'}, ${layout.name}');
  }
}
