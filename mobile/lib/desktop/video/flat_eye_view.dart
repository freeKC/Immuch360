// One eye of a 3D video shown flat (parity lot L02 of release 51): where the 360° player plays a video flat (Linux and
// macOS, which have no renderer C yet; a Windows computer whose graphics card cannot keep up, or whose user chose
// flat), a 3D video, side by side or over-under, shows the eye the 360° view would show (the left one) rather than
// both eyes next to each other. The crop is made by Flutter, never by mpv: the "video-crop" property came with mpv
// 0.37, and Ubuntu 22.04 (0.34) and Debian 12 (0.35) have older ones; a "vf=crop" filter would copy every frame of a
// hardware decoder back to memory. Here the texture of the whole frame is laid out at its size, cut to the eye by a
// clip, and the eye fitted to the window: nothing more is drawn than before, on any mpv. A VR180 eye stays the half
// sphere as the camera recorded it, unprojected.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:media_kit_video/sphere.dart' show PluginEye;

/// Where the eye is in the frame: the part of the frame it takes ([widthFactor], [heightFactor]) and its corner
typedef FlatEyeCrop = ({Alignment alignment, double widthFactor, double heightFactor});

/// The part of the frame [eye] takes in a frame of [layout], null for a frame of one picture (mono)
FlatEyeCrop? flatEyeCrop(StereoLayout layout, PluginEye eye) => switch (layout) {
  StereoLayout.mono => null,
  StereoLayout.leftRight => (
    alignment: eye == PluginEye.left ? Alignment.topLeft : Alignment.topRight,
    widthFactor: 0.5,
    heightFactor: 1.0,
  ),
  StereoLayout.topBottom => (
    alignment: eye == PluginEye.left ? Alignment.topLeft : Alignment.bottomLeft,
    widthFactor: 1.0,
    heightFactor: 0.5,
  ),
};

/// The video [video] builds (with the fit it is given), cut to [crop] of its frame and fitted to the space, letterboxed;
/// [frame] is the size of the video output (VideoController.rect). Until the frame has a size, the whole video shows,
/// letterboxed, as before.
class FlatEyeView extends StatelessWidget {
  const FlatEyeView({super.key, required this.frame, required this.crop, required this.video});

  final ValueListenable<Rect?> frame;
  final FlatEyeCrop crop;
  final Widget Function(BoxFit fit) video;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Rect?>(
    valueListenable: frame,
    builder: (context, rect, _) {
      // A texture of one pixel is the one media_kit_video makes before the first frame
      if (rect == null || rect.width <= 1 || rect.height <= 1) {
        return video(BoxFit.contain);
      }
      return ClipRect(
        child: Center(
          child: FittedBox(
            child: ClipRect(
              child: Align(
                alignment: crop.alignment,
                widthFactor: crop.widthFactor,
                heightFactor: crop.heightFactor,
                child: SizedBox(width: rect.width, height: rect.height, child: video(BoxFit.fill)),
              ),
            ),
          ),
        ),
      );
    },
  );
}
