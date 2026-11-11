// The relief strength of a 3D photo made from one photo (release 46, lot I1): the whole parallax of relief-v1 the
// user picks, the same three choices on the computers ("Make 3D (AI)") and on the Meta Quest ("AI relief"), Normal
// being the value of every earlier version. The comfort research of 26 October puts the parallax of a still photo at
// 2 to 3 % (Shibata) and 3 % at most in total (Sky): Strong stays within it. The parallax travels in the XMP of the
// file (Immuch360:Parallax), in the depthRelief request of the headset and in the key of its relief cache, so each
// strength is a version and a cache entry of its own.

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

enum ReliefStrength {
  subtle(0.015),
  normal(ReliefV1.parallax),
  strong(0.03);

  const ReliefStrength(this.parallax);

  /// The whole parallax, as a fraction of the width of an eye
  final double parallax;

  /// The strength whose parallax is [parallax], as the XMP of a file or a request gives it; null for none of them (a
  /// file of another tool, or of a later version)
  static ReliefStrength? ofParallax(double? parallax) {
    if (parallax == null) {
      return null;
    }
    return values.where((strength) => (strength.parallax - parallax).abs() < 1e-9).firstOrNull;
  }

  /// The strength named [name], the way the settings keep it; Normal for a missing name or one this build does not
  /// know
  static ReliefStrength named(Object? name) =>
      values.where((strength) => strength.name == name).firstOrNull ?? ReliefStrength.normal;
}

/// The strength a 3D photo of ours was made with, as its XMP tells: a relief estimated by relief-v1, or a later
/// relief-vN whose parallax means the same, with the parallax of one of the strengths; null for any other file
/// (another kind, another pipeline, another tool, another parallax)
ReliefStrength? reliefStrengthOfXmp(StereoPhotoXmp xmp) =>
    xmp.kind == ImmersiveKind.stereoPhoto &&
        xmp.origin == ImmersiveOrigin.estimatedDepth &&
        (xmp.pipeline?.startsWith('relief-v') ?? false)
    ? ReliefStrength.ofParallax(xmp.parallax)
    : null;
