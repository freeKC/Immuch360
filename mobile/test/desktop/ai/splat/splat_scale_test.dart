// The scale of a splat scene (store/m2/splat-maker-2026-11-01/plan-2026-11-01.md, section 2.2 and lot SP3), on
// synthetic clouds in the frame COLMAP gives once turned upright (y down, units of its own): an object has its longest
// side at 1 m, a place its cameras 1.5 m above the floor found under them, else its longest side at 3 m at least, so
// that the headset (an object under 2.5 m, SplatPlacement.kt) places the scene as the user said.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
    expect(object.note, 'Immuch360 splat-v1, object, scale 0.421337 (objectSize)');
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
}
