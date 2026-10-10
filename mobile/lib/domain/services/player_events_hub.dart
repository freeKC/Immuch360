// The handlers of the Flutter APIs that the full screen players call when they close (SphericalVideoEvents,
// SpatialVideoEvents), in one place for the phones and the computers (desktop design 1.3).
//
// On a phone the player is native: it calls the handler through the channel the generated setUp registers, as before.
// On a computer the player is a route of the app, in Dart, and the generated code keeps the handler to itself: the hub
// keeps it too, so that the desktop player calls the same session when it closes. The generated setUp is still called
// on every platform, so that a phone registers exactly what it registered before the hub existed.

import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart';

abstract final class PlayerEventsHub {
  static SphericalVideoEvents? _spherical;
  static SpatialVideoEvents? _spatial;

  /// The handler of the 360° player's events, null when none is registered
  static SphericalVideoEvents? get spherical => _spherical;

  /// The handler of the Spatial 2.5D player's events, null when none is registered
  static SpatialVideoEvents? get spatial => _spatial;

  /// Registers [handler] for the 360° player's events (null removes it), as SphericalVideoEvents.setUp does
  static void setUpSpherical(SphericalVideoEvents? handler) {
    _spherical = handler;
    SphericalVideoEvents.setUp(handler);
  }

  /// Registers [handler] for the Spatial 2.5D player's events (null removes it), as SpatialVideoEvents.setUp does
  static void setUpSpatial(SpatialVideoEvents? handler) {
    _spatial = handler;
    SpatialVideoEvents.setUp(handler);
  }
}
