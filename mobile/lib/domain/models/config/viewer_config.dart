import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:immich_mobile/constants/enums.dart';

part 'viewer_config.freezed.dart';

@freezed
abstract class ViewerConfig with _$ViewerConfig {
  const factory ViewerConfig({
    @Default(true) bool loopVideo,

    /// The Looping setting of a TV (Android TV, Google TV), off by default: a film ends there, and left and right go to
    /// the next item. Its own key, so that the default of the phones stays on (see loopVideoProvider).
    @Default(false) bool loopVideoOnTv,
    @Default(false) bool loadOriginalVideo,
    @Default(true) bool autoPlayVideo,
    @Default(false) bool tapToNavigate,

    /// With the remote control layout (a TV), the date and time of a photo at the bottom left of the viewer, shown with
    /// its controls, rather than over the top centre of the photo; on by default (Settings, Asset Viewer, Photos)
    @Default(true) bool tvShowDateTime,

    /// Experimental Spatial 2.5D player for stereoscopic videos on phones, on by default (Settings, Asset Viewer,
    /// Videos turns it off)
    @Default(true) bool spatial25d,

    /// Meta Quest immersive viewer: the right thumbstick turns 360° photos and videos the other way. Off by default,
    /// the view then turns the way the stick is pushed, as in most headset apps (Settings, Asset Viewer, Videos)
    @Default(false) bool reverseThumbstickTurn,

    /// Which file of a server video the players load, null until the user picks one in the settings: the source then
    /// follows [loadOriginalVideo], which the choice replaces (see videoSourcePolicy)
    VideoSourcePolicy? videoSource,
  }) = _ViewerConfig;
}
