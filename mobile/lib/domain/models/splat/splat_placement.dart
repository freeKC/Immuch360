// Where a splat goes when it opens: a Dart port of the splat viewer page's placement.js (itself a port of
// SplatPlacement.kt of the Quest viewer), for the poster a splat photo gets when the view on screen is not at hand
// (plan of 3 November 2026, section 7): drawn from the page's first view, so that the photo shows what the viewer
// opens on. Pure functions, tested against viewer_expected.json, which placement.test.mjs and
// SplatPlacementViewerTest.kt read too.
//
// The frame is three.js's: x right, y up, the camera looking along -z; a point p of the file shows at
// position + Rx(pitch) p.

import 'dart:math' as math;
import 'dart:typed_data';

const splatObjectLimit = 2.5;
const splatObjectGap = 0.6;
const splatObjectDrop = 0.0;
const splatSceneDrop = 0.3;
const splatUnknownDistance = 2.0;
const splatLowPercentile = 5;
const splatHighPercentile = 95;
const splatFloorBand = 0.1;
const splatFloorRatio = 3.0;
const splatFloorShare = 0.15;
const splatSampleLimit = 65536;

/// The height of the eyes above the floor of the headset's frame, in metres
const splatEyeHeight = 1.6;

/// The narrower side of the screen spans this many degrees
const splatNarrowFovDegrees = 60.0;

/// An object framed to fit is this much farther than where the sphere around it touches the narrower side
const splatFitMargin = 1.05;

const splatSpeedDivisor = 8.0;
const splatMinSpeed = 0.5;
const splatMaxSpeed = 4.0;

/// Turn upright cycles these, as on the headset
const splatUprights = ['yUp', 'zUp', 'yDown'];

/// The default orientation: Y down, the axes of a 3D Gaussian Splatting training (those of COLMAP)
const splatDefaultUpright = 'yDown';

/// The rotation about x of three.js that puts [upright] up: minus the headset's pitch
double splatPitchOf(String upright) => switch (upright) {
  'yUp' => 0,
  'zUp' => -math.pi / 2,
  _ => math.pi,
};

/// [v] turned about x by [angle] radians
List<double> splatRotateX(double angle, List<double> v) {
  final c = math.cos(angle);
  final s = math.sin(angle);
  return [v[0], v[1] * c - v[2] * s, v[1] * s + v[2] * c];
}

/// The positions sampled for the placement: every [stride]th gaussian from the first, [samples] of them
({int stride, int samples}) splatSampleOf(int count, {int limit = splatSampleLimit}) {
  if (count <= 0) {
    return (stride: 1, samples: 0);
  }
  final stride = math.max(1, (count + limit - 1) ~/ limit);
  return (stride: stride, samples: (count + stride - 1) ~/ stride);
}

/// The value of rank max(1, (P * N + 99) / 100) of the [sorted] values, as SplatPlacement.percentile
double splatPercentile(List<double> sorted, int p) {
  final rank = math.max(1, (p * sorted.length + 99) ~/ 100);
  return sorted[rank - 1];
}

/// The robust bounds of a splat: the percentiles 5 and 95 of each axis of its sampled positions
final class SplatBounds {
  const SplatBounds(this.low, this.high);

  final List<double> low;
  final List<double> high;

  List<double> get center => [for (var axis = 0; axis < 3; axis++) (low[axis] + high[axis]) / 2];

  /// The largest of the three extents: the same whichever axis is up
  double get size => [for (var axis = 0; axis < 3; axis++) high[axis] - low[axis]].reduce(math.max);

  /// Whether the splat is an object to look at, rather than a place to stand in
  bool get isObject => size < splatObjectLimit;
}

/// The bounds of [positions] (x, y, z of each sample, in the numbers of the file); null without a position, or with
/// one that is not a finite number
SplatBounds? splatBoundsOf(List<double> positions) {
  final count = positions.length ~/ 3;
  if (count == 0) {
    return null;
  }
  final low = [0.0, 0.0, 0.0];
  final high = [0.0, 0.0, 0.0];
  for (var axis = 0; axis < 3; axis++) {
    final values = Float64List(count);
    for (var k = 0; k < count; k++) {
      final value = positions[3 * k + axis];
      if (!value.isFinite) {
        return null;
      }
      values[k] = value;
    }
    values.sort();
    low[axis] = splatPercentile(values, splatLowPercentile);
    high[axis] = splatPercentile(values, splatHighPercentile);
  }
  return SplatBounds(low, high);
}

/// The floor rule of SplatPlacement.uprightOf: a place whose bottom band of y holds at least [splatFloorShare] of the
/// samples and [splatFloorRatio] times those of the top band opens with Y up; otherwise null. Never for an object.
String? splatFloorUprightOf(List<double> positions, SplatBounds? bounds) {
  if (bounds == null || bounds.isObject) {
    return null;
  }
  final low = bounds.low[1];
  final high = bounds.high[1];
  final band = (high - low) * splatFloorBand;
  if (!(band > 0)) {
    return null;
  }
  var total = 0;
  var bottom = 0;
  var top = 0;
  for (var k = 0; 3 * k + 1 < positions.length; k++) {
    final y = positions[3 * k + 1];
    if (!y.isFinite) {
      continue;
    }
    total++;
    if (y <= low + band) {
      bottom++;
    }
    if (y >= high - band) {
      top++;
    }
  }
  if (total == 0) {
    return null;
  }
  return bottom >= splatFloorShare * total && bottom >= splatFloorRatio * top ? 'yUp' : null;
}

/// The orientation a splat opens in: the one chosen for the file ([remembered]), else the floor rule, else Y down
String splatOpeningUpright(String? remembered, List<double> positions, SplatBounds? bounds) {
  if (splatUprights.contains(remembered)) {
    return remembered!;
  }
  return splatFloorUprightOf(positions, bounds) ?? splatDefaultUpright;
}

/// The vertical field of view, in degrees, of a drawing of [aspect] (width over height) whose narrower side spans 60
double splatVerticalFov(double aspect) {
  const half = splatNarrowFovDegrees / 2 * (math.pi / 180);
  if (!(aspect > 0) || aspect >= 1) {
    return splatNarrowFovDegrees;
  }
  return 2 * math.atan(math.tan(half) / aspect) * 180 / math.pi;
}

/// How far an object of [bounds] goes: the headset's distance, or farther so that the sphere around its box fits the
/// narrower side of the screen, whatever way it is turned
double splatObjectDistance(SplatBounds bounds) {
  const half = splatNarrowFovDegrees / 2 * (math.pi / 180);
  final extent = [for (var axis = 0; axis < 3; axis++) bounds.high[axis] - bounds.low[axis]];
  final radius = math.sqrt(extent[0] * extent[0] + extent[1] * extent[1] + extent[2] * extent[2]) / 2;
  return math.max(splatObjectGap + bounds.size / 2, radius / math.sin(half) * splatFitMargin);
}

/// The box of [bounds] once turned by [pitch] about x and moved by [position]
SplatBounds splatWorldBounds(SplatBounds bounds, double pitch, List<double> position) {
  final low = [double.infinity, double.infinity, double.infinity];
  final high = [double.negativeInfinity, double.negativeInfinity, double.negativeInfinity];
  for (var corner = 0; corner < 8; corner++) {
    final point = [
      for (var axis = 0; axis < 3; axis++) (corner >> axis) & 1 == 1 ? bounds.high[axis] : bounds.low[axis],
    ];
    final turned = splatRotateX(pitch, point);
    for (var axis = 0; axis < 3; axis++) {
      final value = turned[axis] + position[axis];
      low[axis] = math.min(low[axis], value);
      high[axis] = math.max(high[axis], value);
    }
  }
  return SplatBounds(low, high);
}

/// The first view of a splat: where its mesh goes ([position], turned by [pitch] about x), where the eye is and what
/// it looks at, and for an object the centre it is turned around and the distance
final class SplatFirstView {
  const SplatFirstView({
    required this.object,
    required this.upright,
    required this.pitch,
    required this.position,
    required this.eye,
    required this.look,
    required this.center,
    required this.distance,
    required this.size,
    required this.speed,
  });

  final bool object;
  final String upright;
  final double pitch;
  final List<double> position;
  final List<double> eye;
  final List<double> look;
  final List<double> center;
  final double distance;
  final double size;
  final double speed;

  /// [p], a point of the file, where it shows
  List<double> place(List<double> p) {
    final turned = splatRotateX(pitch, p);
    return [for (var axis = 0; axis < 3; axis++) turned[axis] + position[axis]];
  }
}

/// The first view of a splat whose sampled positions gave [bounds] (null without positions), turned [upright]
SplatFirstView splatFirstView(SplatBounds? bounds, String upright) {
  final pitch = splatPitchOf(upright);
  const eye = [0.0, splatEyeHeight, 0.0];
  if (bounds == null) {
    const target = [0.0, splatEyeHeight - splatSceneDrop, -splatUnknownDistance];
    return SplatFirstView(
      object: false,
      upright: upright,
      pitch: pitch,
      position: target,
      eye: eye,
      look: const [0.0, splatEyeHeight, -1.0],
      center: target,
      distance: splatUnknownDistance,
      size: 0,
      speed: splatMinSpeed,
    );
  }
  final size = bounds.size;
  final object = bounds.isObject;
  final distance = object ? splatObjectDistance(bounds) : 0.0;
  final target = object
      ? [0.0, splatEyeHeight - splatObjectDrop, -distance]
      : [0.0, splatEyeHeight - splatSceneDrop, 0.0];
  final rotated = splatRotateX(pitch, bounds.center);
  return SplatFirstView(
    object: object,
    upright: upright,
    pitch: pitch,
    position: [for (var axis = 0; axis < 3; axis++) target[axis] - rotated[axis]],
    eye: eye,
    look: object ? target : const [0.0, splatEyeHeight, -1.0],
    center: target,
    distance: distance,
    size: size,
    speed: math.min(splatMaxSpeed, math.max(splatMinSpeed, size / splatSpeedDivisor)),
  );
}
