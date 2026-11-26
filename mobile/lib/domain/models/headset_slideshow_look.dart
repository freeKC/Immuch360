// The background and the transition of the photos of a flat screen in the immersive viewer of a Meta Quest (issue 19,
// the choices promised on 19 November 2026): Settings, Advanced, and the two buttons of the panel in the headset,
// which the settings follow (ImmersiveEvents.slideshowLookChanged). The names of the values are those the viewer reads
// (SlideshowLook.kt).

import 'package:immich_mobile/domain/models/config/viewer_config.dart';

/// What surrounds a photo of a flat screen: nothing (black), a blurred, darker copy of the photo filling the box around
/// it (the frosted background of build 49), or the room seen through the cameras of the headset (passthrough)
enum SlideshowBackground { black, blurred, passthrough }

/// How a photo of a flat screen gives way to the next one: at once, a cross fade, or a slide
enum SlideshowTransition { none, crossFade, slide }

/// The background and the transition sent to the viewer when it opens
class HeadsetSlideshowLook {
  const HeadsetSlideshowLook({
    this.background = SlideshowBackground.blurred,
    this.transition = SlideshowTransition.crossFade,
  });

  /// The settings of the app: [background] null (never chosen) follows the switch of build 49, "Frosted background
  /// behind photos" ([frosted]), on by default
  factory HeadsetSlideshowLook.ofSettings({
    required SlideshowBackground? background,
    required bool frosted,
    required SlideshowTransition transition,
  }) => HeadsetSlideshowLook(
    background: background ?? (frosted ? SlideshowBackground.blurred : SlideshowBackground.black),
    transition: transition,
  );

  final SlideshowBackground background;
  final SlideshowTransition transition;

  /// The background named [name] by the viewer, null for a name this build does not know
  static SlideshowBackground? backgroundNamed(String name) =>
      SlideshowBackground.values.where((value) => value.name == name).firstOrNull;

  /// The transition named [name] by the viewer, null for a name this build does not know
  static SlideshowTransition? transitionNamed(String name) =>
      SlideshowTransition.values.where((value) => value.name == name).firstOrNull;

  @override
  bool operator ==(Object other) =>
      other is HeadsetSlideshowLook && other.background == background && other.transition == transition;

  @override
  int get hashCode => Object.hash(background, transition);

  @override
  String toString() => 'HeadsetSlideshowLook(${background.name}, ${transition.name})';
}

/// The background and the transition the settings give the viewer (see [HeadsetSlideshowLook.ofSettings])
extension ViewerHeadsetSlideshowLook on ViewerConfig {
  HeadsetSlideshowLook get headsetLook => HeadsetSlideshowLook.ofSettings(
    background: slideshowBackground,
    frosted: frostedFlatScreens,
    transition: slideshowTransition,
  );
}
