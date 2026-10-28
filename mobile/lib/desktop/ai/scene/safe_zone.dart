// The zone the eye may move in within a scene, in metres after the comfort scale (design-final 2026-10-27, section
// 2.4; lot S1), as the header of .github/desktop/ai/make_scene_golden.py writes it (its step 9). A break between a near
// disparity q1 and a far one q2 moves by f * t * (q1 - q2) values of the map for a step aside t, f the focal length in
// values of the map; it stays covered while that is within its band w: t <= w / (f * (q1 - q2)).
//  1. lateral: the percentile 10 (nearest rank) of that step over the breaks, one per break so that a longer break
//     counts more, within 0.10 and 0.50 m; 0.50 without a break;
//  2. vertical: 0.6 of the lateral;
//  3. forward: 0.35 of the percentile 5 of the depth, within 0.10 and 1.00 m;
//  4. backward: half the lateral, within 0.05 and 0.25 m.
// It goes to SafeLateral, SafeVertical, SafeForward and SafeBackward of the XMP and to extras.immuch360 of the glTF:
// nothing is computed again in the headset.

import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/scene/comfort_scale.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_layers.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The zone of a scene of depth [z] and disparity [q] (1 / z) whose breaks are [breaks], [focal] the focal length in
/// values of the map
SceneSafeZone safeZoneOf(Float64List z, Float64List q, SceneBreaks breaks, double focal) {
  final steps = Float64List(breaks.length);
  for (var b = 0; b < breaks.length; b++) {
    steps[b] = bandWidthOf(breaks.jump[b]) / (focal * (q[breaks.near[b]] - q[breaks.far[b]]));
  }
  steps.sort();
  final lateral = steps.isEmpty
      ? SceneV1.lateralMax
      : nearestRank(steps, SceneV1.zonePercentile).clamp(SceneV1.lateralMin, SceneV1.lateralMax);
  final p5 = nearestRank(sortedCopy(z), SceneV1.forwardPercentile);
  return SceneSafeZone(
    lateral: lateral,
    vertical: SceneV1.verticalShare * lateral,
    forward: (SceneV1.forwardShare * p5).clamp(SceneV1.forwardMin, SceneV1.forwardMax),
    backward: (SceneV1.backwardShare * lateral).clamp(SceneV1.backwardMin, SceneV1.backwardMax),
  );
}

/// smallZone: barely any movement is possible, the 3D photo may suit the picture better
bool isSmallZone(SceneSafeZone safe) => safe.lateral < SceneV1.smallZone;
