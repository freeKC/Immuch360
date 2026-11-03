// The scale of a splat scene (store/m2/splat-maker-2026-11-01/plan-2026-11-01.md, section 2.2 and lot SP3), on
// synthetic clouds in the frame COLMAP gives once turned upright (y down, units of its own): an object has its longest
// side at 1 m, a place its cameras 1.5 m above the floor found under them, else its longest side at 3 m at least, so
// that the headset (an object under 2.5 m, SplatPlacement.kt) places the scene as the user said. Lot SPF2: an object
// filmed on a desk is set upright on the plane it stands on, found under its cameras, whatever the upright of COLMAP
// made of it (FreeKC's repeater of 3 November lay on its side, its desk along x), and the gaussians its cameras look at
// are brought to 1 m, the desk and the rest of the scene with them; an object with nothing under it keeps the upright
// of COLMAP, and says so.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_scale.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// A cloud and its cameras in the frame of COLMAP: y down, [unit] metres a unit, its origin anywhere
typedef _Scene = ({Float32List positions, Float64List cameras});

/// [points] points of a room of [width] x [depth] metres and [height] high (its floor, walls, ceiling, a table and
/// floaters), seen from 60 cameras carried [cameraHeight] above the floor, turned by [tilt] degrees about x (an
/// upright found a little wrong), in units of [unit] metres; when [floor] is false, nothing flat under the cameras
/// (no floor, no table, the walls from 1.7 m up: a ground the photos never caught)
_Scene _room({
  required double unit,
  double width = 6,
  double depth = 4,
  double height = 2.5,
  double cameraHeight = 1.5,
  double tilt = 0,
  bool floor = true,
  int points = 30000,
  int seed = 1,
}) {
  final random = math.Random(seed);
  double between(double low, double high) => low + random.nextDouble() * (high - low);
  final metres = <List<double>>[];
  for (var i = 0; i < points; i++) {
    final kind = random.nextDouble();
    if (kind < 0.35) {
      if (floor) {
        metres.add([between(0, width), between(-0.005, 0.005), between(0, depth)]);
      }
    } else if (kind < 0.75) {
      final side = random.nextInt(4);
      final along = between(0, side < 2 ? width : depth);
      final y = between(floor ? 0 : 1.7, height);
      metres.add(switch (side) {
        0 => [along, y, 0],
        1 => [along, y, depth],
        2 => [0, y, along],
        _ => [width, y, along],
      });
    } else if (kind < 0.83) {
      metres.add([between(0, width), height, between(0, depth)]);
    } else if (kind < 0.90) {
      if (floor) {
        metres.add([between(2, 3.2), 0.75, between(1.5, 2.3)]);
      }
    } else {
      metres.add([between(-1, width + 1), between(-0.5, height + 0.5), between(-1, depth + 1)]);
    }
  }
  final cameras = <List<double>>[
    for (var k = 0; k < 60; k++)
      [
        width / 2 + (width / 2 - 0.8) * math.cos(k * math.pi / 30),
        cameraHeight + between(-0.05, 0.05),
        depth / 2 + (depth / 2 - 0.8) * math.sin(k * math.pi / 30),
      ],
  ];
  return _toColmap(metres, cameras, unit: unit, tilt: tilt);
}

/// [metres] (y up) in the frame of COLMAP: y down, turned by [tilt] degrees about x, [unit] metres a unit, moved
_Scene _toColmap(List<List<double>> metres, List<List<double>> cameras, {required double unit, double tilt = 0}) {
  final a = tilt * math.pi / 180;
  List<double> map(List<double> p) {
    final x = p[0];
    final y = -p[1];
    final z = p[2];
    final y2 = y * math.cos(a) - z * math.sin(a);
    final z2 = y * math.sin(a) + z * math.cos(a);
    return [x / unit + 1.3, y2 / unit - 0.4, z2 / unit + 2.1];
  }

  return (
    positions: Float32List.fromList([for (final p in metres) ...map(p)]),
    cameras: Float64List.fromList([for (final c in cameras) ...map(c)]),
  );
}

/// The percentiles 5 and 95 of each axis of [positions], as SplatPlacement.kt of the headset takes them: the value of
/// rank max(1, (P * N + 99) / 100)
double _headsetSize(Float32List positions) {
  final n = positions.length ~/ 3;
  var size = 0.0;
  for (var axis = 0; axis < 3; axis++) {
    final values = [for (var i = 0; i < n; i++) positions[3 * i + axis]]..sort();
    double percentile(int p) => values[math.max(1, (p * n + 99) ~/ 100) - 1];
    size = math.max(size, percentile(95) - percentile(5));
  }
  return size;
}

Float32List _times(Float32List positions, double factor) =>
    Float32List.fromList([for (final v in positions) v * factor]);

/// [v] turned by [r], a rotation row by row
List<double> _turn(Float64List r, List<double> v) => [
  for (var i = 0; i < 3; i++) r[3 * i] * v[0] + r[3 * i + 1] * v[1] + r[3 * i + 2] * v[2],
];

/// The angle in degrees between the unit vectors [a] and [b]
double _angle(List<double> a, List<double> b) =>
    math.acos((a[0] * b[0] + a[1] * b[1] + a[2] * b[2]).clamp(-1.0, 1.0)) * 180 / math.pi;

/// The rotation that takes the unit vector [a] to the unit vector [b], row by row (Rodrigues)
Float64List _rotationTo(List<double> a, List<double> b) {
  final v = [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  final c = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  if (c < -1 + 1e-9) {
    // Opposite: half a turn about x, square to y
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

/// An object filmed on a desk, as FreeKC filmed his repeater on 3 November, in the frame COLMAP gave it: the cloud, the
/// centres of the cameras and their axes (where each looks), with what the test knows of it: the up of the room in the
/// file ([up], the normal of the desk towards the cameras), the points of the desk and of the object (x y z of each)
typedef _Desk = ({
  Float32List positions,
  Float64List cameras,
  Float64List axes,
  List<double> up,
  Float32List desk,
  Float32List object,
});

/// In metres, y up: a box of 8 x 9 x 5 cm standing on a desk of 1 x 0.6 m, a keyboard on the desk, a monitor behind,
/// floaters; [cameras] cameras going round it [laps] times, 20 to 30 cm away, 15 to 65 degrees above the desk, each
/// looking at the box with an aim off by up to 1 cm; then in the frame of COLMAP: the up of the room along [up] (the
/// normal of FreeKC's desk in the file by default, (-0.996, 0.075, 0.053)), [unit] metres a unit, moved. With
/// [desk] false nothing lies under the box: it floats among its floaters, its cameras all around it, above and below
_Desk _desk({
  List<double> up = const [-0.996, 0.075, 0.053],
  double unit = 0.053,
  int points = 40000,
  int cameras = 80,
  int laps = 2,
  bool desk = true,
  int seed = 1,
}) {
  final random = math.Random(seed);
  double between(double low, double high) => low + random.nextDouble() * (high - low);
  final deskPoints = <List<double>>[];
  final objectPoints = <List<double>>[];
  final others = <List<double>>[];
  for (var i = 0; i < points; i++) {
    final kind = random.nextDouble();
    if (kind < 0.4) {
      if (desk) {
        deskPoints.add([between(-0.5, 0.5), between(-0.001, 0.001), between(-0.3, 0.3)]);
      }
    } else if (kind < 0.6) {
      // A face of the box, of 8 x 9 x 5 cm, its bottom on the desk
      final face = random.nextInt(5);
      final (a, b) = (random.nextDouble(), random.nextDouble());
      objectPoints.add(switch (face) {
        0 => [-0.04 + 0.08 * a, 0.09, -0.025 + 0.05 * b],
        1 => [-0.04, 0.09 * a, -0.025 + 0.05 * b],
        2 => [0.04, 0.09 * a, -0.025 + 0.05 * b],
        3 => [-0.04 + 0.08 * a, 0.09 * b, -0.025],
        _ => [-0.04 + 0.08 * a, 0.09 * b, 0.025],
      });
    } else if (kind < 0.7) {
      if (desk) {
        others.add([between(-0.2, 0.2), between(0.015, 0.02), between(0.14, 0.26)]);
      }
    } else if (kind < 0.9) {
      if (desk) {
        others.add([between(-0.3, 0.3), between(0.1, 0.45), -0.28 + between(-0.002, 0.002)]);
      }
    } else {
      others.add([between(-1, 1), between(-0.5, 1), between(-1, 1)]);
    }
  }
  final centres = <List<double>>[];
  final looks = <List<double>>[];
  for (var k = 0; k < cameras; k++) {
    final azimuth = 2 * math.pi * laps * k / cameras;
    final elevation = (desk ? between(15, 65) : between(-65, 65)) * math.pi / 180;
    final distance = between(0.2, 0.3);
    final centre = [
      distance * math.cos(elevation) * math.cos(azimuth),
      0.045 + distance * math.sin(elevation),
      distance * math.cos(elevation) * math.sin(azimuth),
    ];
    final aim = [between(-0.01, 0.01), 0.045 + between(-0.01, 0.01), between(-0.01, 0.01)];
    final look = [for (var j = 0; j < 3; j++) aim[j] - centre[j]];
    final length = math.sqrt(look[0] * look[0] + look[1] * look[1] + look[2] * look[2]);
    centres.add(centre);
    looks.add([for (final v in look) v / length]);
  }
  final length = math.sqrt(up[0] * up[0] + up[1] * up[1] + up[2] * up[2]);
  final fileUp = [for (final v in up) v / length];
  final r = _rotationTo(const [0, 1, 0], fileUp);
  List<double> place(List<double> p) => [
    for (final (j, v) in _turn(r, p).indexed) v / unit + const [3.1, -0.7, 1.9][j],
  ];
  Float32List cloud(List<List<double>> list) => Float32List.fromList([for (final p in list) ...place(p)]);
  return (
    positions: cloud([...deskPoints, ...objectPoints, ...others]),
    cameras: Float64List.fromList([for (final c in centres) ...place(c)]),
    axes: Float64List.fromList([for (final l in looks) ..._turn(r, l)]),
    up: fileUp,
    desk: cloud(deskPoints),
    object: cloud(objectPoints),
  );
}

/// The points x y z of [positions] turned by [r]
Float32List _turned(Float32List positions, Float64List r) => Float32List.fromList([
  for (var i = 0; i < positions.length ~/ 3; i++)
    ..._turn(r, [positions[3 * i], positions[3 * i + 1], positions[3 * i + 2]]),
]);

/// The values of axis [axis] of the points [positions]
List<double> _axis(Float32List positions, int axis) => [
  for (var i = 0; i < positions.length ~/ 3; i++) positions[3 * i + axis],
];

void main() {
  test('an object: its longest side brought to 1 m, which the headset takes for an object', () {
    final random = math.Random(4);
    final metres = <List<double>>[];
    for (var i = 0; i < 20000; i++) {
      // An ellipsoid of 2.6 x 1.4 x 0.9 units, and 3 % of floaters far around it
      if (random.nextDouble() < 0.97) {
        final u = random.nextDouble() * 2 * math.pi;
        final v = math.acos(2 * random.nextDouble() - 1);
        metres.add([1.3 * math.sin(v) * math.cos(u), 0.7 * math.cos(v), 0.45 * math.sin(v) * math.sin(u)]);
      } else {
        metres.add([for (var k = 0; k < 3; k++) random.nextDouble() * 20 - 10]);
      }
    }
    final cameras = [
      for (var k = 0; k < 40; k++) [3 * math.cos(k * math.pi / 20), 0.3, 3 * math.sin(k * math.pi / 20)],
    ];
    final scene = _toColmap(metres, cameras, unit: 1);
    final scale = splatScaleOf(subject: SplatSubject.object, positions: scene.positions, cameras: scene.cameras);
    expect(scale.rule, SplatScaleRule.objectSize);
    expect(scale.sizeBefore, closeTo(_headsetSize(scene.positions), 1e-6));
    final after = _headsetSize(_times(scene.positions, scale.factor));
    expect(after, closeTo(SplatV1.objectSize, 1e-5));
    expect(after, lessThan(2.5), reason: 'OBJECT_LIMIT of the headset');
    // Its cameras play no part: none gives the same
    expect(splatScaleOf(subject: SplatSubject.object, positions: scene.positions).factor, scale.factor);
  });

  test('a place: its cameras 1.5 m above the floor found under them, whatever the unit of COLMAP', () {
    for (final unit in [0.27, 1.0, 3.9]) {
      final scene = _room(unit: unit, seed: unit.hashCode);
      final scale = splatScaleOf(subject: SplatSubject.place, positions: scene.positions, cameras: scene.cameras);
      expect(scale.rule, SplatScaleRule.floor, reason: '$unit');
      expect(scale.factor, closeTo(unit, unit * 0.02), reason: '$unit metres a unit');
      expect(scale.cameraHeight! * scale.factor, closeTo(SplatV1.placeCameraHeight, 1e-9));
      expect(_headsetSize(_times(scene.positions, scale.factor)), greaterThan(2.5), reason: 'a place to the headset');
    }
  });

  test('a place turned wrong by the upright of COLMAP (20 degrees on the room of M1): the floor is a plane, its tilt '
      'told', () {
    for (final tilt in [-6.0, 3.0, 8.0, 20.0, -25.0]) {
      final scene = _room(unit: 0.5, tilt: tilt, seed: 9);
      final scale = splatScaleOf(subject: SplatSubject.place, positions: scene.positions, cameras: scene.cameras);
      expect(scale.rule, SplatScaleRule.floor, reason: '$tilt degrees');
      expect(scale.factor, closeTo(0.5, 0.5 * 0.03), reason: '$tilt degrees');
      expect(scale.floorTilt, closeTo(tilt.abs(), 1.5), reason: '$tilt degrees');
      final normal = scale.floorNormal!;
      expect(normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2], closeTo(1, 1e-9));
      expect(normal[1], lessThan(0), reason: 'up is -y');
    }
    // Past 30 degrees no floor is looked for: the size decides
    final steep = _room(unit: 0.5, tilt: 40, seed: 9);
    final scale = splatScaleOf(subject: SplatSubject.place, positions: steep.positions, cameras: steep.cameras);
    expect(scale.rule, isNot(SplatScaleRule.floor));
    expect(scale.floorNormal, isNull);
  });

  test('a place without a floor under its cameras: its longest side brought to 3 m, or kept when larger', () {
    final small = _room(unit: 4, floor: false, seed: 2);
    final scale = splatScaleOf(subject: SplatSubject.place, positions: small.positions, cameras: small.cameras);
    expect(scale.rule, SplatScaleRule.minimumSize);
    expect(scale.cameraHeight, isNull);
    expect(_headsetSize(_times(small.positions, scale.factor)), closeTo(SplatV1.placeMinSize, 1e-5));
    final large = _room(unit: 0.5, floor: false, seed: 2);
    final kept = splatScaleOf(subject: SplatSubject.place, positions: large.positions, cameras: large.cameras);
    expect(kept.rule, SplatScaleRule.kept);
    expect(kept.factor, 1.0);
    // No cameras: no floor looked for
    final room = _room(unit: 0.5, seed: 3);
    final blind = splatScaleOf(subject: SplatSubject.place, positions: room.positions);
    expect(blind.rule, SplatScaleRule.kept);
  });

  test('a small place whose floor leaves it under 3 m is brought to 3 m, so that it opens around the user', () {
    final closet = _room(unit: 0.8, width: 1.8, depth: 1.4, height: 2.1, cameraHeight: 1.5, seed: 5);
    final scale = splatScaleOf(subject: SplatSubject.place, positions: closet.positions, cameras: closet.cameras);
    expect(scale.rule, SplatScaleRule.minimumSize);
    expect(scale.cameraHeight, isNotNull, reason: 'the floor was found');
    expect(_headsetSize(_times(closet.positions, scale.factor)), closeTo(SplatV1.placeMinSize, 1e-5));
  });

  test('nothing to measure: kept as it is', () {
    for (final subject in SplatSubject.values) {
      expect(splatScaleOf(subject: subject, positions: Float32List(0)).rule, SplatScaleRule.none);
      final point = Float32List.fromList([
        for (var i = 0; i < 300; i++) ...[1.5, -2, 3],
      ]);
      final scale = splatScaleOf(subject: subject, positions: point, cameras: Float64List.fromList([0, 0, 0]));
      expect(scale.rule, SplatScaleRule.none);
      expect(scale.factor, 1.0);
    }
    final nan = Float32List.fromList([double.nan, 0, 0, 1, 1, 1]);
    expect(splatScaleOf(subject: SplatSubject.object, positions: nan).rule, SplatScaleRule.none);
  });

  test('the note the PLY carries, the same on every system', () {
    const scale = SplatScale(factor: 0.5, rule: SplatScaleRule.floor, subject: SplatSubject.place, sizeBefore: 9);
    expect(scale.note, 'Immuch360 splat-v1, place, scale 0.500000 (floor)');
    const object = SplatScale(
      factor: 0.4213371,
      rule: SplatScaleRule.objectSize,
      subject: SplatSubject.object,
      sizeBefore: 2.37,
    );
    expect(object.note, 'Immuch360 splat-v1, object, scale 0.421337 (objectSize), upright imageOrientation');
    const upright = SplatScale(
      factor: 0.5872,
      rule: SplatScaleRule.lookedAt,
      subject: SplatSubject.object,
      sizeBefore: 1.7,
      upright: SplatUpright.supportPlane,
    );
    expect(upright.note, 'Immuch360 splat-v1, object, scale 0.587200 (lookedAt), upright supportPlane');
    expect(object.logFactor, math.log(0.4213371));
  });

  test('the same cloud gives the same scale every time: the floor is looked for without chance', () {
    final scene = _room(unit: 0.7, tilt: 2, seed: 8);
    final first = splatScaleOf(subject: SplatSubject.place, positions: scene.positions, cameras: scene.cameras);
    for (var k = 0; k < 3; k++) {
      expect(
        splatScaleOf(subject: SplatSubject.place, positions: scene.positions, cameras: scene.cameras).factor,
        first.factor,
      );
    }
  });

  test('an object lying on its side, as the repeater FreeKC filmed on 3 November: set upright on its desk, found under '
      'its cameras, the gaussians they look at brought to 1 m, the desk and the monitor with them', () {
    final scene = _desk();
    final scale = splatScaleOf(
      subject: SplatSubject.object,
      positions: scene.positions,
      cameras: scene.cameras,
      axes: scene.axes,
    );
    expect(scale.upright, SplatUpright.supportPlane);
    expect(scale.rule, SplatScaleRule.lookedAt);
    // The support plane is the desk, its normal towards the cameras; the turn takes it to -y, the up of the headset
    expect(_angle(scale.supportNormal!, scene.up), lessThan(1));
    expect(scale.supportTilt, closeTo(_angle(scene.up, const [0, -1, 0]), 1));
    expect(_angle(_turn(scale.turn!, scene.up), const [0, -1, 0]), lessThan(1));
    // Level once turned: the desk at one height, the box above it (y down), from its foot to its top
    final desk = _axis(_turned(scene.desk, scale.turn!), 1)..sort();
    final deskY = desk[desk.length ~/ 2];
    expect(desk[desk.length * 95 ~/ 100] - desk[desk.length * 5 ~/ 100], lessThan(0.5 * 0.01 / 0.053));
    final box = _axis(_turned(scene.object, scale.turn!), 1)..sort();
    expect(box.first, greaterThan(deskY - 0.095 / 0.053));
    expect(box.last, lessThan(deskY + 0.005 / 0.053), reason: 'standing on the desk, not under it');
    expect((deskY - box.first) * 0.053, closeTo(0.09, 0.005), reason: 'its 9 cm of height');
    // The box, 9 cm on its longest side (5 to 95 % of its points), at 1 m
    final measured = _headsetSize(_turned(scene.object, scale.turn!));
    expect(measured * scale.factor, closeTo(SplatV1.objectSize, 0.15));
    expect(scale.sizeBefore, closeTo(measured, 0.15 * measured));
    expect(scale.note, startsWith('Immuch360 splat-v1, object, scale '));
    expect(scale.note, endsWith(' (lookedAt), upright supportPlane'));
    // The desk and the monitor around it scaled with it: the whole scene some ten metres, which the headset opens as a
    // place around the user (OBJECT_LIMIT 2.5 m of SplatPlacement.kt)
    expect(scale.sceneSize, closeTo(_headsetSize(_turned(scene.positions, scale.turn!)), 1e-3));
    expect(scale.sceneSize * scale.factor, greaterThan(2.5));
  });

  test('the same on other desks: any upright COLMAP gave, any unit, one lap or three', () {
    for (final (up, unit, laps) in [
      (const [0.0, -1.0, 0.0], 0.02, 1),
      (const [0.3, -0.9, 0.2], 0.1, 3),
      (const [0.0, 0.0, 1.0], 1.0, 2),
      (const [0.1, 0.99, 0.0], 0.053, 2),
    ]) {
      final scene = _desk(up: up, unit: unit, laps: laps, seed: laps);
      final scale = splatScaleOf(
        subject: SplatSubject.object,
        positions: scene.positions,
        cameras: scene.cameras,
        axes: scene.axes,
      );
      expect(scale.upright, SplatUpright.supportPlane, reason: '$up');
      expect(_angle(_turn(scale.turn!, scene.up), const [0, -1, 0]), lessThan(1), reason: '$up');
      expect(
        _headsetSize(_turned(scene.object, scale.turn!)) * scale.factor,
        closeTo(SplatV1.objectSize, 0.15),
        reason: '$up',
      );
    }
  });

  test(
    'an object with nothing under it, filmed all around: the upright of COLMAP kept and said, the object at 1 m',
    () {
      final scene = _desk(desk: false, seed: 4);
      final scale = splatScaleOf(
        subject: SplatSubject.object,
        positions: scene.positions,
        cameras: scene.cameras,
        axes: scene.axes,
      );
      expect(scale.upright, SplatUpright.imageOrientation);
      expect((scale.turn, scale.supportNormal, scale.supportTilt), (null, null, null));
      expect(scale.rule, SplatScaleRule.lookedAt);
      expect(_headsetSize(scene.object) * scale.factor, closeTo(SplatV1.objectSize, 0.15));
      expect(scale.note, endsWith(' (lookedAt), upright imageOrientation'));
    },
  );

  test(
    'cameras that look at no one point (all one way), or no axes: the whole scene at 1 m, the upright of COLMAP',
    () {
      final scene = _desk();
      final ahead = Float64List.fromList([for (var k = 0; k < scene.axes.length ~/ 3; k++) ...scene.up.map((v) => -v)]);
      for (final axes in [ahead, null]) {
        final scale = splatScaleOf(
          subject: SplatSubject.object,
          positions: scene.positions,
          cameras: scene.cameras,
          axes: axes,
        );
        expect(scale.rule, SplatScaleRule.objectSize);
        expect(scale.upright, SplatUpright.imageOrientation);
        expect(scale.turn, isNull);
        expect(_headsetSize(_times(scene.positions, scale.factor)), closeTo(SplatV1.objectSize, 1e-5));
      }
    },
  );

  test('the point the cameras look at: the nearest to their axes, a few looks aside left out', () {
    final scene = _desk(cameras: 60);
    final looked = splatLookedAt(scene.cameras, scene.axes)!;
    // The aim of the cameras, 4.5 cm above the desk at the middle of the box
    final aim = [0.0, 0.045 / 0.053, 0.0];
    final r = _rotationTo(const [0, 1, 0], scene.up);
    final expected = [
      for (final (j, v) in _turn(r, aim).indexed) v + const [3.1, -0.7, 1.9][j],
    ];
    final off = math.sqrt(
      [for (var j = 0; j < 3; j++) math.pow(looked.point[j] - expected[j], 2)].fold(0.0, (a, b) => a + b),
    );
    expect(off, lessThan(0.01 / 0.053));
    expect(looked.distance * 0.053, inInclusiveRange(0.2, 0.3));
    // Six of the sixty cameras looking at the monitor instead
    final aside = Float64List.fromList(scene.axes);
    for (var k = 0; k < 6; k++) {
      final up = scene.up;
      aside.setRange(
        3 * k * 10,
        3 * k * 10 + 3,
        [up[1], -up[0], 0].map((v) => v / math.sqrt(up[0] * up[0] + up[1] * up[1])),
      );
    }
    final trimmed = splatLookedAt(scene.cameras, aside)!;
    final off2 = math.sqrt(
      [for (var j = 0; j < 3; j++) math.pow(trimmed.point[j] - expected[j], 2)].fold(0.0, (a, b) => a + b),
    );
    expect(off2, lessThan(0.02 / 0.053));
    // Fewer than three cameras, or all looking one way: none
    expect(
      splatLookedAt(Float64List.fromList(scene.cameras.sublist(0, 6)), Float64List.fromList(scene.axes.sublist(0, 6))),
      isNull,
    );
    expect(
      splatLookedAt(
        scene.cameras,
        Float64List.fromList([
          for (var k = 0; k < 60; k++) ...const [0.0, 0.0, 1.0],
        ]),
      ),
      isNull,
    );
  });

  test('the turn that takes a normal to -y: a rotation, whatever the normal', () {
    for (final normal in [
      const [0.0, -1.0, 0.0],
      const [0.0, 1.0, 0.0],
      const [-0.996, 0.075, 0.053],
      const [0.6, 0.0, 0.8],
    ]) {
      final length = math.sqrt(normal.fold(0.0, (sum, v) => sum + v * v));
      final unit = [for (final v in normal) v / length];
      final r = splatTurnOf(Float64List.fromList(unit));
      expect(_angle(_turn(r, unit), const [0, -1, 0]), lessThan(1e-6), reason: '$normal');
      final det =
          r[0] * (r[4] * r[8] - r[5] * r[7]) - r[1] * (r[3] * r[8] - r[5] * r[6]) + r[2] * (r[3] * r[7] - r[4] * r[6]);
      expect(det, closeTo(1, 1e-9), reason: '$normal');
    }
  });

  test('an object set upright the same way every time, on every system: no chance in the plane looked for', () {
    final scene = _desk(seed: 6);
    SplatScale run() => splatScaleOf(
      subject: SplatSubject.object,
      positions: scene.positions,
      cameras: scene.cameras,
      axes: scene.axes,
    );
    final first = run();
    for (var k = 0; k < 2; k++) {
      final again = run();
      expect(again.factor, first.factor);
      expect(again.turn, first.turn);
    }
  });
}
