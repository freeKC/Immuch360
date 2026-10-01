// Stereoscopic (3D) 360° media hold one equirectangular image per eye in a single frame. Nothing the server indexes
// tells them apart from regular 360° media, so the viewers guess the layout from the frame dimensions, and the user
// can change it with the 3D control of every viewer.

import 'dart:ui';

import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart';

export 'package:immich_mobile/platform/spherical_video_api.g.dart' show StereoLayout;

/// Guesses how the eyes of a 360° photo or video of [width] x [height] pixels are laid out.
///
/// Each eye of a full sphere is a 2:1 equirectangular image: stacked, they make a square frame (left eye on top),
/// side by side a 4:1 frame (left eye on the left). Each eye of a half sphere ([coverage], VR180 media) is a square
/// 180° image: stacked, they make a 1:2 frame, side by side a 2:1 frame. Within 10% of those. Anything else is mono, as
/// are unknown dimensions and partial panoramas, whose GPano crop ([hasGPanoCrop]) gives the image any aspect ratio.
StereoLayout guessStereoLayout({
  required int? width,
  required int? height,
  bool hasGPanoCrop = false,
  SphereCoverage coverage = SphereCoverage.full,
}) {
  if (hasGPanoCrop || width == null || height == null || width <= 0 || height <= 0) {
    return StereoLayout.mono;
  }
  final eyeAspectRatio = switch (coverage) {
    SphereCoverage.full => 2.0,
    SphereCoverage.half => 1.0,
  };
  bool near(double aspectRatio) => (width / height - aspectRatio).abs() <= aspectRatio * 0.1 + 1e-9;
  if (near(eyeAspectRatio / 2)) {
    return StereoLayout.topBottom;
  }
  if (near(eyeAspectRatio * 2)) {
    return StereoLayout.leftRight;
  }
  return StereoLayout.mono;
}

/// Translated labels of the 3D control of the native viewers, under the keys they read. They fall back to their
/// English texts for a missing key.
Map<String, String> stereoLayoutLabels(Translations t) => {
  'stereo': t.panorama_stereo_layout,
  'mono': t.panorama_stereo_mono,
  'topBottom': t.panorama_stereo_top_bottom,
  'leftRight': t.panorama_stereo_left_right,
};

extension StereoLayoutExtension on StereoLayout {
  /// The layout the 3D control switches to: mono, then top and bottom, then side by side, then mono again.
  StereoLayout get next => switch (this) {
    StereoLayout.mono => StereoLayout.topBottom,
    StereoLayout.topBottom => StereoLayout.leftRight,
    StereoLayout.leftRight => StereoLayout.mono,
  };

  /// Part of the frame the left eye fills, normalised to [0, 1]. A phone screen shows that eye only.
  Rect get leftEyeRect => switch (this) {
    StereoLayout.mono => const Rect.fromLTWH(0, 0, 1, 1),
    StereoLayout.topBottom => const Rect.fromLTWH(0, 0, 1, 0.5),
    StereoLayout.leftRight => const Rect.fromLTWH(0, 0, 0.5, 1),
  };

  /// The same layout, for the immersive viewer of the Meta Quest
  ImmersiveStereoLayout toImmersive() => switch (this) {
    StereoLayout.mono => ImmersiveStereoLayout.mono,
    StereoLayout.topBottom => ImmersiveStereoLayout.topBottom,
    StereoLayout.leftRight => ImmersiveStereoLayout.leftRight,
  };

  /// Name of the layout, as the 3D control shows it
  String label(Translations t) => switch (this) {
    StereoLayout.mono => t.panorama_stereo_mono,
    StereoLayout.topBottom => t.panorama_stereo_top_bottom,
    StereoLayout.leftRight => t.panorama_stereo_left_right,
  };
}
