// SpatialVideoApi on the computers (release 53, lot S1): open pushes the Spatial 2.5D page of the app's window
// (spatial/spatial_video_page.dart) and returns at once, as the native open starts an activity on Android; its closing
// comes back as the SpatialVideoEvents.closed of the phones, so that SpatialVideoSession (or the page of a network
// share) takes the video back where the page left it and remembers the layout picked. The passes draw in the video
// plugin on Windows (renderer C) and macOS (Metal); Linux has no such renderer yet, so it answers unsupported with
// the reason, and the viewers say that 3D videos in Spatial 2.5D are not on Linux yet.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/desktop/spatial/spatial_video_page.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:logging/logging.dart';

final _log = Logger('DesktopSpatialVideoApi');

class DesktopSpatialVideoApi implements SpatialVideoApi {
  /// [navigator] gives the root navigator of the app (the router's), null when there is none yet. [rendererExists],
  /// [videoAvailable] and [routeFor] are for the tests.
  DesktopSpatialVideoApi({
    this.navigator,
    bool? rendererExists,
    bool Function()? videoAvailable,
    Route<void> Function(SpatialVideoArgs args, SpatialVideoClosed onClosed)? routeFor,
  }) : _rendererExists = rendererExists ?? spatialVideoRendererExists,
       _videoAvailable = videoAvailable ?? (() => desktopVideoAvailable),
       _routeFor = routeFor ?? ((args, onClosed) => SpatialVideoPage.route(args, onClosed: onClosed));

  final GlobalKey<NavigatorState>? Function()? navigator;
  final bool _rendererExists;
  final bool Function() _videoAvailable;
  final Route<void> Function(SpatialVideoArgs args, SpatialVideoClosed onClosed) _routeFor;

  /// The channel of SpatialVideoEvents.closed, on which the native players of the phones report their closing
  static const closedChannel = 'dev.flutter.pigeon.immich_mobile.SpatialVideoEvents.closed';

  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  /// Supported where the plugin draws the passes and libmpv loaded. The webcam is not asked for here: no camera opens
  /// before the page, which shows its card of the first time and its messages itself.
  @override
  Future<SpatialCapabilities> capabilities() async {
    if (!_rendererExists) {
      return SpatialCapabilities(
        supported: false,
        frontCamera: false,
        cameraPermissionGranted: false,
        reason: 'no Spatial renderer for videos on this system',
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
    if (!_rendererExists || state == null || !_videoAvailable()) {
      // As a phone without the player: the caller gives the viewer's video back
      throw PlatformException(code: 'unsupported', message: 'No Spatial player on this computer');
    }
    // Not awaited: the route's future ends when it closes, the native open returns once the player started
    unawaited(state.push(_routeFor(SpatialVideoArgs.of(request), reportClosed)));
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
