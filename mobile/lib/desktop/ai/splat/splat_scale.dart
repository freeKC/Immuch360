// The scale of a splat scene (store/m2/splat-maker-2026-11-01/plan-2026-11-01.md, section 2.2, lot SP3). The units of
// COLMAP are its own, while the headset reads the units of the file as metres and places by size: an object (under 2.5
// m on its largest side, between the percentiles 5 and 95 of its positions, SplatPlacement.kt) in front of the user, a
// place around them. So the computer sets the scale from what the user said they filmed (SplatSubject):
//
// * an object has the gaussians its cameras look at brought to SplatV1.objectSize (1 m) on their longest side, the
//   rest of the scene with them (lot SPF2); its longest side when its cameras look at no one point;
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
// frame (colmap_model, lot SP4). [SplatScale.floorNormal] gives that tilt to whoever levels the scene: the scale of a
// place does not turn it.
//
// An object (lot SPF2, diag-2026-11-03.md, changes 4 and 5) is set upright on the plane it stands on, and measured
// where its cameras look. FreeKC's repeater of 3 November, a Wi-Fi repeater of 8 cm filmed on a white desk in several
// laps, from above and with the phone turned, came out of IMAGE-ORIENTATION lying on its side (its desk 87 to 94
// degrees off level, along x of the file, which the "Turn upright" of the headset cannot mend), and at its real size:
// its longest side was that of the desk, the keyboard and the monitor around it (18.9 units), the repeater 1.5 to 1.8.
// So, for an object:
//
// * the point its cameras look at ([splatLookedAt]): the point nearest to the axes of the cameras, by least squares,
//   the axes passing far from it (a look aside) left out once; none when the axes do not cross (all one way) or the
//   point is behind the cameras. On the repeater: 4.3 units from the cameras (23 cm), its axes 0.47 units from it;
// * the plane it stands on: the planes through three positions drawn as for a floor, of any tilt, that leave nine in
//   ten of the cameras on one side (above it) and the point looked at above it by less than the distance of the
//   cameras; the one most positions lie on, a tenth of them at least, fitted again to them by least squares. On the
//   repeater: the desk, 25 % of the gaussians, all the cameras above it, the point looked at 0.73 units over it;
// * turned so that its normal points up, -y ([SplatScale.turn], splat_turn.dart turns the gaussians); without such a
//   plane (an object filmed all around, a skull on nothing) the upright of COLMAP is kept, and said
//   ([SplatScale.upright]);
// * measured on the gaussians within [splatLookedAtRadius] times the distance of the cameras of the point looked at,
//   above the plane when there is one: their longest side between the percentiles 5 and 95, once turned. On the
//   repeater: 1.9 units, the desk, the keyboard and the monitor left out; so the repeater at about 1 m, and the whole
//   scene with it (about ten metres: the headset opens it as a place, around the user, SplatPlacement.kt).
//
// Pure Dart, tested on synthetic clouds by splat_scale_test.dart.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// How the scale of a splat scene was set
enum SplatScaleRule {
  /// An object: the gaussians its cameras look at brought to SplatV1.objectSize on their longest side (lot SPF2)
  lookedAt,

  /// An object whose cameras look at no one point: its longest side brought to SplatV1.objectSize
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
/// [sizeBefore] units (percentiles 5 to 95: the gaussians looked at for an object, the scene otherwise), with the
/// median height of the cameras above the floor in units ([cameraHeight]) when a floor was found; for an object, how
/// it was set [upright], by the [turn] of the plane it stands on when one was found
final class SplatScale {
  const SplatScale({
    required this.factor,
    required this.rule,
    required this.subject,
    required this.sizeBefore,
    double? sceneSize,
    this.cameraHeight,
    this.floorNormal,
    this.upright = SplatUpright.imageOrientation,
    this.turn,
    this.supportNormal,
    this.lookedAt,
  }) : sceneSize = sceneSize ?? sizeBefore;

  final double factor;
  final SplatScaleRule rule;
  final SplatSubject subject;
  final double sizeBefore;

  /// The longest side of the whole scene in units (percentiles 5 to 95), once turned: what the headset measures, times
  /// [factor]
  final double sceneSize;
  final double? cameraHeight;

  /// How the scene was set upright: an object on the plane it stands on ([turn]), or as COLMAP turned it
  final SplatUpright upright;

  /// The rotation that sets an object upright on the plane it stands on, row by row, applied before the scale; null
  /// when the scene is kept as COLMAP turned it
  final Float64List? turn;

  /// The unit normal of the plane an object stands on, towards its cameras, in the frame of COLMAP; null without one
  final Float64List? supportNormal;

  /// The point the cameras of an object look at, in the frame of COLMAP; null when they look at no one point
  final Float64List? lookedAt;

  /// How far the plane an object stands on was from level in the upright of COLMAP, in degrees; null without one
  double? get supportTilt =>
      supportNormal == null ? null : math.acos(-supportNormal![1].clamp(-1.0, 1.0)) * 180 / math.pi;

  /// The unit normal of the floor found, pointing up (its y negative), x y z: how far from level the upright of COLMAP
  /// left the scene; null without a floor
  final Float64List? floorNormal;

  /// The angle of the floor found from level, in degrees, null without a floor
  double? get floorTilt => floorNormal == null ? null : math.acos(-floorNormal![1].clamp(-1.0, 1.0)) * 180 / math.pi;

  /// What the log scales of the gaussians gain
  double get logFactor => math.log(factor);

  /// The comment of the PLY that says it: "Immuch360 splat-v1, place, scale 0.421337 (floor)"; an object says how it
  /// was set upright too: "Immuch360 splat-v1, object, scale 0.526316 (lookedAt), upright supportPlane"
  String get note =>
      'Immuch360 ${SplatV1.pipeline}, ${subject.name}, scale ${factor.toStringAsFixed(6)} (${rule.name})'
      '${subject == SplatSubject.object ? ', upright ${upright.name}' : ''}';

  /// What the log of the app says of it beyond [note]: the sizes, the tilt of the plane under an object
  String get said => [
    'measured ${sizeBefore.toStringAsFixed(3)} units, the scene ${(sceneSize * factor).toStringAsFixed(2)} m',
    if (supportTilt case final tilt?)
      'the plane it stands on ${tilt.toStringAsFixed(1)} degrees off the upright of COLMAP',
    if (cameraHeight case final height?) 'the cameras ${(height * factor).toStringAsFixed(2)} m above the floor',
  ].join(', ');

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

/// The plane an object stands on: the share of the cameras above it, and of the positions on it, at least
const splatSupportCameraShare = 0.9;
const splatSupportMinShare = 0.1;

/// The point the cameras of an object look at: their axes must spread, the least eigenvalue of the sum of their
/// projections (the identity less a aᵀ) this share of their count at least; nine in ten of them must have it ahead
const splatLookedAtMinSpread = 0.1;
const splatLookedAtAheadShare = 0.9;

/// The gaussians an object is measured on: those within this share of the distance of its cameras of the point they
/// look at, a hundredth of all of them at least
const splatLookedAtRadius = 0.5;
const splatLookedAtMinShare = 0.01;

/// The scale of the splat whose gaussians have [positions] (x y z of each) and whose cameras have [cameras] (x y z of
/// each centre, in the same frame) and look along [axes] (x y z of each, unit), for what the user filmed ([subject])
SplatScale splatScaleOf({
  required SplatSubject subject,
  required Float32List positions,
  Float64List? cameras,
  Float64List? axes,
}) {
  final size = _longestSide(positions);
  if (size == null || !(size > 0)) {
    return SplatScale(factor: 1.0, rule: SplatScaleRule.none, subject: subject, sizeBefore: size ?? 0);
  }
  if (subject == SplatSubject.object) {
    return _objectScale(positions, cameras, axes, size);
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

/// The scale of an object (see the top of this file), the whole scene [size] units on its longest side
SplatScale _objectScale(Float32List positions, Float64List? cameras, Float64List? axes, double size) {
  final looked = cameras == null || axes == null ? null : splatLookedAt(cameras, axes);
  final thickness = size * splatFloorThickness;
  final support = looked == null ? null : _support(positions, cameras!, looked.point, looked.distance, thickness);
  final turn = support == null ? null : splatTurnOf(support.normal);
  final cluster = looked == null
      ? null
      : _lookedAtSide(
          positions,
          looked.point,
          splatLookedAtRadius * looked.distance,
          support: support,
          thickness: thickness,
          turn: turn,
        );
  final scene = turn == null ? size : _longestSide(_turnedPositions(positions, turn)) ?? size;
  final measured = cluster ?? scene;
  return SplatScale(
    factor: SplatV1.objectSize / measured,
    rule: cluster == null ? SplatScaleRule.objectSize : SplatScaleRule.lookedAt,
    subject: SplatSubject.object,
    sizeBefore: measured,
    sceneSize: scene,
    upright: support == null ? SplatUpright.imageOrientation : SplatUpright.supportPlane,
    turn: turn,
    supportNormal: support?.normal,
    lookedAt: looked?.point,
  );
}

/// The point the cameras whose centres are [cameras] and whose axes are [axes] (x y z of each, in the same frame) look
/// at, and the median distance of the cameras from it; null when there are fewer than three, when their axes do not
/// spread enough to cross (all one way), or when the point is behind more than one in ten of them (see the top of this
/// file)
({Float64List point, double distance})? splatLookedAt(Float64List cameras, Float64List axes) {
  final count = cameras.length ~/ 3;
  if (count < 3 || axes.length != cameras.length) {
    return null;
  }
  final units = <(List<double>, List<double>)>[];
  for (var k = 0; k < count; k++) {
    final a = [axes[3 * k], axes[3 * k + 1], axes[3 * k + 2]];
    final length = math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
    if (length > 0 && length.isFinite) {
      units.add(([cameras[3 * k], cameras[3 * k + 1], cameras[3 * k + 2]], [for (final v in a) v / length]));
    }
  }
  // The point nearest to the axes of [used]: the sum of (the identity less a aᵀ) times p, that of the same times c
  List<double>? nearest(List<(List<double>, List<double>)> used) {
    if (used.length < 3) {
      return null;
    }
    final m = List<double>.filled(9, 0);
    final b = List<double>.filled(3, 0);
    for (final (c, a) in used) {
      for (var i = 0; i < 3; i++) {
        for (var j = 0; j < 3; j++) {
          final value = (i == j ? 1.0 : 0.0) - a[i] * a[j];
          m[3 * i + j] += value;
          b[i] += value * c[j];
        }
      }
    }
    if (_eigen(m).values.first < splatLookedAtMinSpread * used.length) {
      return null;
    }
    return _solve(m, b);
  }

  double off(List<double> point, (List<double>, List<double>) camera) {
    final (c, a) = camera;
    final v = [for (var j = 0; j < 3; j++) point[j] - c[j]];
    final along = v[0] * a[0] + v[1] * a[1] + v[2] * a[2];
    return math.sqrt(math.max(0, v[0] * v[0] + v[1] * v[1] + v[2] * v[2] - along * along));
  }

  var point = nearest(units);
  if (point == null) {
    return null;
  }
  // The axes passing far from it left out once: a look aside, a close-up of something else
  final offs = [for (final camera in units) off(point, camera)];
  final limit = 3 * _median(offs);
  if (limit > 0) {
    final kept = [
      for (final (k, camera) in units.indexed)
        if (offs[k] <= limit) camera,
    ];
    point = nearest(kept) ?? point;
  }
  final found = point;
  var ahead = 0;
  final distances = <double>[];
  for (final (c, a) in units) {
    final v = [for (var j = 0; j < 3; j++) found[j] - c[j]];
    if (v[0] * a[0] + v[1] * a[1] + v[2] * a[2] > 0) {
      ahead++;
    }
    distances.add(math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]));
  }
  final distance = _median(distances);
  if (ahead < splatLookedAtAheadShare * units.length || !(distance > 0) || !distance.isFinite) {
    return null;
  }
  return (point: Float64List.fromList(found), distance: distance);
}

/// The rotation that takes the unit vector [normal] to -y, the up of the headset, row by row: about the axis square to
/// both, by the angle between them; half a turn about x when [normal] is y itself
Float64List splatTurnOf(Float64List normal) {
  // v = normal x (0, -1, 0), c = normal . (0, -1, 0)
  final v = [normal[2], 0.0, -normal[0]];
  final c = -normal[1];
  if (c < -1 + 1e-12) {
    return Float64List.fromList([1, 0, 0, 0, -1, 0, 0, 0, -1]);
  }
  final k = 1 / (1 + c);
  return Float64List.fromList([
    1 - k * (v[1] * v[1] + v[2] * v[2]),
    -v[2] + k * v[0] * v[1],
    v[1] + k * v[0] * v[2],
    v[2] + k * v[0] * v[1],
    1 - k * (v[0] * v[0] + v[2] * v[2]),
    -v[0] + k * v[1] * v[2],
    -v[1] + k * v[0] * v[2],
    v[0] + k * v[1] * v[2],
    1 - k * (v[0] * v[0] + v[1] * v[1]),
  ]);
}

/// The plane an object stands on (see the top of this file): its unit normal towards the cameras and its offset (a
/// position p lies on it when normal . p + offset is 0, above it when more), null when none is found
({Float64List normal, double offset})? _support(
  Float32List positions,
  Float64List cameras,
  Float64List target,
  double distance,
  double thickness,
) {
  final n = positions.length ~/ 3;
  final cameraCount = cameras.length ~/ 3;
  if (n < 30 || cameraCount < 3) {
    return null;
  }
  // An even spread of at most splatFloorSample of them, always the same
  final step = math.max(1, (n / splatFloorSample).ceil());
  final sample = Float64List.fromList([
    for (var i = 0; i < n; i += step) ...[positions[3 * i], positions[3 * i + 1], positions[3 * i + 2]],
  ]);
  final m = sample.length ~/ 3;

  /// The cameras above the plane, and how high the target stands over it
  (int, double) sides(List<double> normal, double offset) {
    var above = 0;
    for (var c = 0; c < cameraCount; c++) {
      if (normal[0] * cameras[3 * c] + normal[1] * cameras[3 * c + 1] + normal[2] * cameras[3 * c + 2] + offset > 0) {
        above++;
      }
    }
    return (above, normal[0] * target[0] + normal[1] * target[1] + normal[2] * target[2] + offset);
  }

  bool holds(int above, double height) =>
      above >= splatSupportCameraShare * cameraCount && height > thickness && height <= distance;

  int onIt(List<double> normal, double offset) {
    var count = 0;
    for (var k = 0; k < m; k++) {
      if ((normal[0] * sample[3 * k] + normal[1] * sample[3 * k + 1] + normal[2] * sample[3 * k + 2] + offset).abs() <=
          thickness) {
        count++;
      }
    }
    return count;
  }

  var best = 0;
  List<double>? bestNormal;
  var bestOffset = 0.0;
  // The same linear congruential sequence as the floor: the same planes on every system and every run
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
    final u = [for (var j = 0; j < 3; j++) sample[3 * b + j] - sample[3 * a + j]];
    final v = [for (var j = 0; j < 3; j++) sample[3 * c + j] - sample[3 * a + j]];
    var normal = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
    final length = math.sqrt(normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]);
    if (!(length > 0)) {
      continue;
    }
    normal = [for (final value in normal) value / length];
    var offset = -(normal[0] * sample[3 * a] + normal[1] * sample[3 * a + 1] + normal[2] * sample[3 * a + 2]);
    var (above, height) = sides(normal, offset);
    // Its normal towards the side most cameras are on
    if (2 * above < cameraCount) {
      normal = [for (final value in normal) -value];
      offset = -offset;
      above = cameraCount - above;
      height = -height;
    }
    if (!holds(above, height)) {
      continue;
    }
    final count = onIt(normal, offset);
    if (count > best) {
      best = count;
      bestNormal = normal;
      bestOffset = offset;
    }
  }
  final found = bestNormal;
  if (found == null || best < splatSupportMinShare * m || best < 30) {
    return null;
  }
  // Fitted again to the positions on it, twice: the normal of their least spread (least squares)
  var normal = found;
  var offset = bestOffset;
  for (var round = 0; round < 2; round++) {
    final on = <int>[
      for (var k = 0; k < m; k++)
        if ((normal[0] * sample[3 * k] + normal[1] * sample[3 * k + 1] + normal[2] * sample[3 * k + 2] + offset)
                .abs() <=
            thickness)
          k,
    ];
    if (on.length < 30) {
      break;
    }
    final mean = List<double>.filled(3, 0);
    for (final k in on) {
      for (var j = 0; j < 3; j++) {
        mean[j] += sample[3 * k + j] / on.length;
      }
    }
    final spread = List<double>.filled(9, 0);
    for (final k in on) {
      for (var i = 0; i < 3; i++) {
        for (var j = 0; j < 3; j++) {
          spread[3 * i + j] += (sample[3 * k + i] - mean[i]) * (sample[3 * k + j] - mean[j]);
        }
      }
    }
    var fitted = _eigen(spread).vectors.first;
    if (fitted[0] * normal[0] + fitted[1] * normal[1] + fitted[2] * normal[2] < 0) {
      fitted = [for (final value in fitted) -value];
    }
    final fittedOffset = -(fitted[0] * mean[0] + fitted[1] * mean[1] + fitted[2] * mean[2]);
    final (above, height) = sides(fitted, fittedOffset);
    if (!holds(above, height)) {
      break;
    }
    normal = fitted;
    offset = fittedOffset;
  }
  return (normal: Float64List.fromList(normal), offset: offset);
}

/// The longest side, between the percentiles 5 and 95 once turned by [turn], of the [positions] within [radius] of
/// [target] (and above the plane of [support] by more than [thickness] when there is one); null when they are fewer
/// than splatLookedAtMinShare of all of them, or 30
double? _lookedAtSide(
  Float32List positions,
  Float64List target,
  double radius, {
  required ({Float64List normal, double offset})? support,
  required double thickness,
  required Float64List? turn,
}) {
  final n = positions.length ~/ 3;
  final near = <double>[];
  final r2 = radius * radius;
  for (var i = 0; i < n; i++) {
    final x = positions[3 * i];
    final y = positions[3 * i + 1];
    final z = positions[3 * i + 2];
    final dx = x - target[0];
    final dy = y - target[1];
    final dz = z - target[2];
    if (dx * dx + dy * dy + dz * dz > r2) {
      continue;
    }
    if (support != null) {
      final s = support.normal;
      if (s[0] * x + s[1] * y + s[2] * z + support.offset <= thickness) {
        continue;
      }
    }
    near
      ..add(x)
      ..add(y)
      ..add(z);
  }
  final count = near.length ~/ 3;
  if (count < 30 || count < splatLookedAtMinShare * n) {
    return null;
  }
  final cluster = Float32List.fromList(near);
  final side = _longestSide(turn == null ? cluster : _turnedPositions(cluster, turn));
  return side != null && side > 0 ? side : null;
}

/// [positions] (x y z of each) turned by [turn], row by row
Float32List _turnedPositions(Float32List positions, Float64List turn) {
  final out = Float32List(positions.length);
  for (var i = 0; i < positions.length; i += 3) {
    final x = positions[i];
    final y = positions[i + 1];
    final z = positions[i + 2];
    out[i] = turn[0] * x + turn[1] * y + turn[2] * z;
    out[i + 1] = turn[3] * x + turn[4] * y + turn[5] * z;
    out[i + 2] = turn[6] * x + turn[7] * y + turn[8] * z;
  }
  return out;
}

/// The eigenvalues of the symmetric matrix [a] (row by row), the least first, and their unit eigenvectors in the same
/// order, by the rotations of Jacobi
({List<double> values, List<List<double>> vectors}) _eigen(List<double> a) {
  final m = [...a];
  final v = <double>[1, 0, 0, 0, 1, 0, 0, 0, 1];
  for (var sweep = 0; sweep < 50; sweep++) {
    final off = m[1] * m[1] + m[2] * m[2] + m[5] * m[5];
    final scale = m[0] * m[0] + m[4] * m[4] + m[8] * m[8];
    if (off <= 1e-30 * (scale + 1e-300)) {
      break;
    }
    for (final (p, q) in const [(0, 1), (0, 2), (1, 2)]) {
      final apq = m[3 * p + q];
      if (apq == 0) {
        continue;
      }
      final theta = (m[3 * q + q] - m[3 * p + p]) / (2 * apq);
      final t = (theta >= 0 ? 1 : -1) / (theta.abs() + math.sqrt(theta * theta + 1));
      final c = 1 / math.sqrt(t * t + 1);
      final s = t * c;
      for (var k = 0; k < 3; k++) {
        final mkp = m[3 * k + p];
        final mkq = m[3 * k + q];
        m[3 * k + p] = c * mkp - s * mkq;
        m[3 * k + q] = s * mkp + c * mkq;
      }
      for (var k = 0; k < 3; k++) {
        final mpk = m[3 * p + k];
        final mqk = m[3 * q + k];
        m[3 * p + k] = c * mpk - s * mqk;
        m[3 * q + k] = s * mpk + c * mqk;
      }
      for (var k = 0; k < 3; k++) {
        final vkp = v[3 * k + p];
        final vkq = v[3 * k + q];
        v[3 * k + p] = c * vkp - s * vkq;
        v[3 * k + q] = s * vkp + c * vkq;
      }
    }
  }
  final order = [0, 1, 2]..sort((i, j) => m[4 * i].compareTo(m[4 * j]));
  return (
    values: [for (final i in order) m[4 * i]],
    vectors: [
      for (final i in order) [v[i], v[3 + i], v[6 + i]],
    ],
  );
}

/// The solution of the 3 x 3 system [m] x = [b] (row by row), by Cramer
List<double>? _solve(List<double> m, List<double> b) {
  double det(List<double> a) =>
      a[0] * (a[4] * a[8] - a[5] * a[7]) - a[1] * (a[3] * a[8] - a[5] * a[6]) + a[2] * (a[3] * a[7] - a[4] * a[6]);
  final d = det(m);
  if (d == 0 || !d.isFinite) {
    return null;
  }
  return [
    for (var col = 0; col < 3; col++) det([for (var k = 0; k < 9; k++) k % 3 == col ? b[k ~/ 3] : m[k]]) / d,
  ];
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
