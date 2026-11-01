// The scale of a splat scene (store/m2/splat-maker-2026-11-01/plan-2026-11-01.md, section 2.2, lot SP3). The units of
// COLMAP are its own, while the headset reads the units of the file as metres and places by size: an object (under 2.5
// m on its largest side, between the percentiles 5 and 95 of its positions, SplatPlacement.kt) in front of the user, a
// place around them. So the computer sets the scale from what the user said they filmed (SplatSubject):
//
// * an object has its longest side brought to SplatV1.objectSize (1 m);
// * a place has its cameras SplatV1.placeCameraHeight (1.5 m) above the floor found under them, else is kept as it
//   is; and either way it is brought to SplatV1.placeMinSize (3 m) on its longest side when it is smaller, so that the
//   headset opens it around the user.
//
// The floor is the plane under the cameras that most positions lie on: planes through three of them, drawn without
// chance (a fixed sequence), no more than 30 degrees from level in the frame COLMAP gives once turned upright (y down,
// model_orientation_aligner --method IMAGE-ORIENTATION), the cameras above it; it counts when it holds a fifth of the
// positions under the cameras. 30 degrees, not less: that upright is the median "down" of the images, so the photos of
// a room taken looking down leave its floor tilted by about as much (19.9 degrees on the room of measure M1, whose
// floor was found holding 30 % of the gaussians under the cameras, their heights from 2.87 to 4.05 units, median
// 3.33). The positions are those of the gaussians (what the headset measures), the cameras their centres in the same
// frame (colmap_model, lot SP4). [SplatScale.floorNormal] gives that tilt to whoever levels the scene: the scale does
// not turn it. Pure Dart, tested on synthetic clouds by splat_scale_test.dart.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// How the scale of a splat scene was set
enum SplatScaleRule {
  /// An object: its longest side brought to SplatV1.objectSize
  objectSize,

  /// A place whose floor was found: its cameras SplatV1.placeCameraHeight above it
  floor,

  /// A place brought to SplatV1.placeMinSize on its longest side: no floor was found, or the floor left it smaller
  minimumSize,

  /// A place without a floor found, already SplatV1.placeMinSize or larger: kept as COLMAP made it
  kept,

  /// Nothing to measure (no position, or all of them in one point): kept
  none,
}

/// The scale of a splat scene: [factor] metres a unit of COLMAP, set by [rule] for [subject], from a longest side of
/// [sizeBefore] units (percentiles 5 to 95), with the median height of the cameras above the floor in units
/// ([cameraHeight]) when a floor was found
final class SplatScale {
  const SplatScale({
    required this.factor,
    required this.rule,
    required this.subject,
    required this.sizeBefore,
    this.cameraHeight,
    this.floorNormal,
  });

  final double factor;
  final SplatScaleRule rule;
  final SplatSubject subject;
  final double sizeBefore;
  final double? cameraHeight;

  /// The unit normal of the floor found, pointing up (its y negative), x y z: how far from level the upright of COLMAP
  /// left the scene; null without a floor
  final Float64List? floorNormal;

  /// The angle of the floor found from level, in degrees, null without a floor
  double? get floorTilt => floorNormal == null ? null : math.acos(-floorNormal![1].clamp(-1.0, 1.0)) * 180 / math.pi;

  /// What the log scales of the gaussians gain
  double get logFactor => math.log(factor);

  /// The comment of the PLY that says it: "Immuch360 splat-v1, place, scale 0.421337 (floor)"
  String get note =>
      'Immuch360 ${SplatV1.pipeline}, ${subject.name}, scale ${factor.toStringAsFixed(6)} (${rule.name})';

  @override
  String toString() => 'SplatScale($note, size $sizeBefore, camera height $cameraHeight)';
}

/// How far from level a floor may be, and the share of the positions under the cameras it must hold
const splatFloorMaxTilt = 30.0;
const splatFloorMinShare = 0.2;

/// How near a position must be to the plane to lie on it, as a share of the longest side of the scene
const splatFloorThickness = 0.01;

/// The planes tried, and the positions under the cameras they are tried on at most (evenly spread)
const splatFloorTries = 1000;
const splatFloorSample = 6000;

/// The scale of the splat whose gaussians have [positions] (x y z of each) and whose cameras have [cameras] (x y z of
/// each centre, in the same frame), for what the user filmed ([subject])
SplatScale splatScaleOf({required SplatSubject subject, required Float32List positions, Float64List? cameras}) {
  final size = _longestSide(positions);
  if (size == null || !(size > 0)) {
    return SplatScale(factor: 1.0, rule: SplatScaleRule.none, subject: subject, sizeBefore: size ?? 0);
  }
  if (subject == SplatSubject.object) {
    return SplatScale(
      factor: SplatV1.objectSize / size,
      rule: SplatScaleRule.objectSize,
      subject: subject,
      sizeBefore: size,
    );
  }
  final floor = cameras == null || cameras.length < 3 ? null : _floor(positions, cameras, size);
  final height = floor?.height;
  var factor = height == null ? 1.0 : SplatV1.placeCameraHeight / height;
  var rule = height == null ? SplatScaleRule.kept : SplatScaleRule.floor;
  if (size * factor < SplatV1.placeMinSize) {
    factor = SplatV1.placeMinSize / size;
    rule = SplatScaleRule.minimumSize;
  }
  return SplatScale(
    factor: factor,
    rule: rule,
    subject: subject,
    sizeBefore: size,
    cameraHeight: height,
    floorNormal: floor?.normal,
  );
}

/// The largest extent of [positions] between the percentiles SplatV1.boundsLowPercentile and boundsHighPercentile of
/// each axis, as the headset takes them (the value of rank max(1, (P * N + 99) / 100)); null without positions or with
/// one that is not finite
double? _longestSide(Float32List positions) {
  final n = positions.length ~/ 3;
  if (n == 0) {
    return null;
  }
  var size = 0.0;
  final values = Float64List(n);
  for (var axis = 0; axis < 3; axis++) {
    for (var i = 0; i < n; i++) {
      values[i] = positions[3 * i + axis];
      if (!values[i].isFinite) {
        return null;
      }
    }
    values.sort();
    double percentile(int p) => values[math.max(1, (p * n + 99) ~/ 100) - 1];
    size = math.max(size, percentile(SplatV1.boundsHighPercentile) - percentile(SplatV1.boundsLowPercentile));
  }
  return size;
}

/// The floor under [cameras], its normal pointing up and the median height of the cameras above it in units, null when
/// none is found (see the top of this file); y points down
({Float64List normal, double height})? _floor(Float32List positions, Float64List cameras, double size) {
  final cameraCount = cameras.length ~/ 3;
  final cameraY = _median([for (var c = 0; c < cameraCount; c++) cameras[3 * c + 1]]);
  final below = <int>[];
  for (var i = 0; i < positions.length ~/ 3; i++) {
    if (positions[3 * i + 1] > cameraY) {
      below.add(i);
    }
  }
  if (below.length < 30) {
    return null;
  }
  // An even spread of at most splatFloorSample of them, always the same
  final step = math.max(1, (below.length / splatFloorSample).ceil());
  final sample = Float64List.fromList([
    for (var k = 0; k < below.length; k += step) ...[
      positions[3 * below[k]],
      positions[3 * below[k] + 1],
      positions[3 * below[k] + 2],
    ],
  ]);
  final m = sample.length ~/ 3;
  final thickness = size * splatFloorThickness;
  final level = math.cos(splatFloorMaxTilt * math.pi / 180);
  var best = 0;
  ({double nx, double ny, double nz, double d})? plane;
  // A linear congruential sequence: the same planes are tried on every system and every run
  var state = 12345;
  int next(int bound) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return state % bound;
  }

  for (var t = 0; t < splatFloorTries; t++) {
    final a = next(m);
    final b = next(m);
    final c = next(m);
    if (a == b || b == c || a == c) {
      continue;
    }
    final ux = sample[3 * b] - sample[3 * a];
    final uy = sample[3 * b + 1] - sample[3 * a + 1];
    final uz = sample[3 * b + 2] - sample[3 * a + 2];
    final vx = sample[3 * c] - sample[3 * a];
    final vy = sample[3 * c + 1] - sample[3 * a + 1];
    final vz = sample[3 * c + 2] - sample[3 * a + 2];
    var nx = uy * vz - uz * vy;
    var ny = uz * vx - ux * vz;
    var nz = ux * vy - uy * vx;
    final length = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (!(length > 0)) {
      continue;
    }
    // The normal that points up, -y
    final up = ny > 0 ? -1.0 : 1.0;
    nx *= up / length;
    ny *= up / length;
    nz *= up / length;
    if (-ny < level) {
      continue;
    }
    final d = -(nx * sample[3 * a] + ny * sample[3 * a + 1] + nz * sample[3 * a + 2]);
    var inliers = 0;
    for (var k = 0; k < m; k++) {
      if ((nx * sample[3 * k] + ny * sample[3 * k + 1] + nz * sample[3 * k + 2] + d).abs() <= thickness) {
        inliers++;
      }
    }
    if (inliers > best) {
      best = inliers;
      plane = (nx: nx, ny: ny, nz: nz, d: d);
    }
  }
  final found = plane;
  if (found == null || best < splatFloorMinShare * m || best < 30) {
    return null;
  }
  // The plane through the middle of the positions on it, then the height of each camera above it
  final offsets = <double>[
    for (var k = 0; k < m; k++)
      if ((found.nx * sample[3 * k] + found.ny * sample[3 * k + 1] + found.nz * sample[3 * k + 2] + found.d).abs() <=
          thickness)
        found.nx * sample[3 * k] + found.ny * sample[3 * k + 1] + found.nz * sample[3 * k + 2],
  ];
  final level0 = _median(offsets);
  final height = _median([
    for (var c = 0; c < cameraCount; c++)
      found.nx * cameras[3 * c] + found.ny * cameras[3 * c + 1] + found.nz * cameras[3 * c + 2] - level0,
  ]);
  return height > thickness ? (normal: Float64List.fromList([found.nx, found.ny, found.nz]), height: height) : null;
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  final n = sorted.length;
  return n.isOdd ? sorted[n ~/ 2] : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
}
