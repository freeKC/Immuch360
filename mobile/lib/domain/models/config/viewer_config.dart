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

    /// "Remember where I stopped": a video longer than [resumeMinMinutes] minutes, a film, starts where it was left, its
    /// tile shows how much of it was watched, and it plays once whatever Looping says; a shorter one always starts from
    /// the beginning (see WatchRule). On by default, the lab rule (Settings, Asset Viewer, Videos turns it off)
    @Default(true) bool resumeVideos,

    /// The threshold of [resumeVideos], in minutes, which a film is longer than: 10 by default, 0 for every video
    @Default(10) int resumeMinMinutes,
    @Default(false) bool loadOriginalVideo,
    @Default(true) bool autoPlayVideo,
    @Default(false) bool tapToNavigate,

    /// With the remote control layout (a TV), the date and time of a photo at the bottom left of the viewer, shown with
    /// its controls, rather than over the top centre of the photo; on by default (Settings, Asset Viewer, Photos)
    @Default(true) bool tvShowDateTime,

    /// Experimental Spatial 2.5D player for stereoscopic videos on phones, on by default (Settings, Asset Viewer,
    /// Videos turns it off)
    @Default(true) bool spatial25d,

    /// Experimental: a raw 360° video whose camera recorded its motion (the gyroscope of an Insta360, CORI and GRAV of a
    /// GoPro, the attitude of a DJI Osmo 360) plays stabilised, the horizon level and the shake gone, the view following
    /// the road (issue 14). On by default, the lab rule (Settings, Asset Viewer, Videos, and the switch of the 360°
    /// player, turn it off); the Android phones, tablets and TVs apply it
    @Default(true) bool stabilizeVideos,

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

    /// Experimental: the Gaussian splat files of other tools (.spz, .ply) of the shares are listed and open in the
    /// immersive viewer of a Quest 3 or 3S (lot S5), and in the splat viewer of the computers, phones and tablets. On
    /// by default (Settings, Advanced turns it off)
    @Default(true) bool gaussianSplats,

    /// Meta Quest, experimental: a splat shows up to 150 000 gaussians, the advice of the Meta Spatial SDK, rather than
    /// the 50 000 of the first measures, with a passing word that it may stutter. Off by default, unlike the other
    /// experimental settings: 50 000 until a measure in the headset says more (decision D7 of the splats, kept by
    /// FreeKC on 30 October 2026); Settings, Advanced turns it on
    @Default(false) bool largeSplats,

    /// Windows computers with two graphics chips, experimental: the splat viewer draws with the dedicated chip
    /// (WebView2's --force_high_performance_gpu), decision D2 of the splat viewer of 2 November 2026. On by default
    /// (Settings, Advanced turns it off: Windows then chooses)
    @Default(true) bool highPerformanceGpu,

    /// Computers, experimental: a splat shows whole up to what the computer's memory holds also on a graphics chip
    /// that shares that memory, which otherwise keeps its 1,000,000 strongest gaussians (lot SVC, 3 November 2026). Off
    /// by default: such a chip draws 2 million gaussians at about 33 frames per second, 4 million at 12 to 20 (an Intel
    /// UHD, measured); a dedicated graphics card shows every gaussian whatever this says
    @Default(false) bool keepAllGaussians,

    /// Experimental: a scene saved to Immich gets a small 3D sign at the bottom right of its photo (decision D1 of the
    /// splat photos, plan of 3 November 2026), so that Immich and other apps tell it apart from a photo. On by default,
    /// the lab rule (Settings, Advanced turns it off: the poster is then left clean)
    @Default(true) bool markSplatPhotos,

    /// Immuch360 Desktop, experimental: the AV2 videos (.ivf, .obu) of the folders, the shares and "Open with" play,
    /// decoded by the processor with the AV2 decoder downloaded at the first one (store/m2/av2-2026-11-02/
    /// plan-2026-11-02.md, section 1.3). On by default, the lab rule (Settings, Asset Viewer, Videos turns it off: an
    /// AV2 video then says so instead of playing)
    @Default(true) bool av2Videos,

    /// Which file of a server video the players load, null until the user picks one in the settings: the source then
    /// follows [loadOriginalVideo], which the choice replaces (see videoSourcePolicy)
    VideoSourcePolicy? videoSource,
  }) = _ViewerConfig;
}
