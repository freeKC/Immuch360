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

    /// Meta Quest immersive viewer, experimental: a video whose file name says it holds two eyes (_SBS, _HSBS, _LR,
    /// _TB, _OU, Half-SBS...) and a photo of two eyes one above the other (_TB, _OU, _HTB...) open in 3D on a flat
    /// screen with View in 3D. On by default (Settings, Advanced turns it off); the side by side photos keep their View
    /// in 3D whatever it says (see stackedPhotoFormatOf)
    @Default(true) bool flat3dByName,

    /// Meta Quest immersive viewer, experimental: the photos of a flat screen drawn by the compositor of the headset on
    /// a quad layer, and that layer and the flat video screen sampled with its quality super sampling and sharpening.
    /// On by default (Settings, Advanced turns it off: the photos then go on the quad mesh, without filters)
    @Default(true) bool sharpFlatScreens,

    /// Meta Quest, experimental: the Gaussian splat files of other tools (.spz, .ply) of the shares are listed and open
    /// in the immersive viewer of a Quest 3 or 3S (lot S5). On by default (Settings, Advanced turns it off)
    @Default(true) bool gaussianSplats,

    /// Meta Quest, experimental: a splat shows up to 150 000 gaussians, the advice of the Meta Spatial SDK, rather than
    /// the 50 000 of the first measures, with a passing word that it may stutter. Off by default, unlike the other
    /// experimental settings: 50 000 until a measure in the headset says more (decision D7 of the splats, kept by
    /// FreeKC on 30 October 2026); Settings, Advanced turns it on
    @Default(false) bool largeSplats,

    /// Which file of a server video the players load, null until the user picks one in the settings: the source then
    /// follows [loadOriginalVideo], which the choice replaces (see videoSourcePolicy)
    VideoSourcePolicy? videoSource,
  }) = _ViewerConfig;
}
