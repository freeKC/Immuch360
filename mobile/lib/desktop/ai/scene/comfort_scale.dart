// The depth of a scene before its layers (design-final 2026-10-27, section 2.3, steps 4 and 5; lot S1), as the header
// of .github/desktop/ai/make_scene_golden.py writes it (its steps 1 and 2) and its fixture scene_golden_v1.json holds:
//  1. the sky, and every value of the map without depth (the mask of MoGe under SceneV1.validMask), on a far plane
//     at twice the percentile 99 of the valid depths, clamped to 20 and 200 m; the flag sky beyond 15 % of the map;
//  2. the comfort scale: when the percentile 2 of the depth is under 0.45 m, the whole scene grows around the eye
//     until it is 0.45 m. A scaling around the eye changes nothing of the view from the start, only the stereo, the
//     parallax and the size of the zone: nothing of the scene is then closer than 0.45 m to the eye at the start.
// Percentiles are by nearest rank, as relief-v1 takes them: the value of rank max(1, (P * N + 99) ~/ 100).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The percentile [percent] of [sorted] (in increasing order) by nearest rank
double nearestRank(Float64List sorted, int percent) => sorted[math.max(1, (percent * sorted.length + 99) ~/ 100) - 1];

/// A copy of [values] in increasing order
Float64List sortedCopy(Float64List values) => Float64List.fromList(values)..sort();

/// The depth of a map once its values without depth are on the far plane
class SkyPlane {
  const SkyPlane({required this.depth, required this.far, required this.sky});

  /// The depth of every value, in metres
  final Float64List depth;

  /// The depth of the far plane
  final double far;

  /// More than SceneV1.skyRatio of the map had no depth
  final bool sky;
}

/// [depth] with every value whose [mask] is under SceneV1.validMask on the far plane (a map without any valid value is
/// all on the plane at SceneV1.skyNearest)
SkyPlane skyPlaneOf(Float64List depth, Float64List mask) {
  final valid = <double>[];
  var count = 0;
  for (var i = 0; i < depth.length; i++) {
    if (mask[i] >= SceneV1.validMask) {
      valid.add(depth[i]);
    } else {
      count++;
    }
  }
  final far = valid.isEmpty
      ? SceneV1.skyNearest
      : (2 * nearestRank(Float64List.fromList(valid)..sort(), SceneV1.skyPercentile)).clamp(
          SceneV1.skyNearest,
          SceneV1.skyFarthest,
        );
  final out = Float64List(depth.length);
  for (var i = 0; i < depth.length; i++) {
    out[i] = mask[i] >= SceneV1.validMask ? depth[i] : far;
  }
  return SkyPlane(depth: out, far: far, sky: count > SceneV1.skyRatio * depth.length);
}

/// The depth after the comfort scale, and the scale (1 most of the time)
class ComfortScale {
  const ComfortScale({required this.depth, required this.scale});

  final Float64List depth;
  final double scale;
}

/// [depth] grown around the eye until its percentile SceneV1.comfortPercentile is SceneV1.comfortDistance, when it
/// is under it
ComfortScale comfortScaleOf(Float64List depth) {
  final p2 = nearestRank(sortedCopy(depth), SceneV1.comfortPercentile);
  final scale = p2 < SceneV1.comfortDistance ? SceneV1.comfortDistance / p2 : 1.0;
  final out = Float64List(depth.length);
  for (var i = 0; i < depth.length; i++) {
    out[i] = depth[i] * scale;
  }
  return ComfortScale(depth: out, scale: scale);
}
