import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';

import '../../../fixtures/raw/insta360.stub.dart';

const _degree = math.pi / 180;

// The accelerometer of the MakerNote of the real X3 photo whose calibration the fixtures hold
const _x3Accelerometer = [-1.003906, -0.124023, 0.082031];

/// The calibration of the real X3 photo, levelled by its accelerometer
DualFisheyeCalibration _x3() =>
    parseInsta360OffsetV3(x3OffsetV3)!.copyWith(downBody: downBodyFromAccelerometer(_x3Accelerometer));

// Its 72 MP frame
const _width = 11968;
const _height = 5984;

Matcher _closeToVec(Vec3 expected, [double delta = 1e-9]) => predicate<Vec3>(
  (v) => (v.x - expected.x).abs() <= delta && (v.y - expected.y).abs() <= delta && (v.z - expected.z).abs() <= delta,
  'within $delta of $expected',
);

Vec3 _column(Mat3 m, int column) => (x: m.at(0, column), y: m.at(1, column), z: m.at(2, column));

double _dot(Vec3 a, Vec3 b) => a.x * b.x + a.y * b.y + a.z * b.z;

/// Checks [samples] against the expected (lens, x, y, weight before normalisation) of the prototype of the stitch
void _expectSamples(List<LensSample> samples, List<(int, double, double, double)> expected, {String? reason}) {
  final total = expected.fold(0.0, (sum, entry) => sum + entry.$4);
  expect(samples, hasLength(expected.length), reason: reason);
  for (var i = 0; i < expected.length; i++) {
    final (lens, x, y, weight) = expected[i];
    expect(samples[i].lens, lens, reason: reason);
    expect(samples[i].x, closeTo(x, 1e-4), reason: reason);
    expect(samples[i].y, closeTo(y, 1e-4), reason: reason);
    expect(samples[i].weight, closeTo(weight / total, 1e-9), reason: reason);
  }
}

void main() {
  group('rotations', () {
    test('turn the axes the standard way', () {
      const x = (x: 1.0, y: 0.0, z: 0.0);
      const y = (x: 0.0, y: 1.0, z: 0.0);
      const z = (x: 0.0, y: 0.0, z: 1.0);

      expect(rotationZ(math.pi / 2).apply(x), _closeToVec(y));
      expect(rotationX(math.pi / 2).apply(y), _closeToVec(z));
      expect(rotationY(math.pi / 2).apply(z), _closeToVec(x));
      expect((rotationZ(0.3) * rotationZ(0.4)).apply(x), _closeToVec(rotationZ(0.7).apply(x)));
      expect((rotationX(0.3) * rotationX(0.3).transposed).values, [
        for (final value in Mat3.identity.values) closeTo(value, 1e-12),
      ]);
    });

    test('mirror the roll about the nearest quarter turn', () {
      expect(mirroredRoll(89.510), closeTo(90.490, 1e-9));
      expect(mirroredRoll(89.487), closeTo(90.513, 1e-9));
      expect(mirroredRoll(90), 90);
      expect(mirroredRoll(0.3), closeTo(-0.3, 1e-12));
      expect(mirroredRoll(-91), closeTo(-89, 1e-12));
      expect(mirroredRoll(180.4), closeTo(179.6, 1e-9));
    });

    test('pose the lenses with the mirrored roll, lens 1 looking the other way', () {
      const lens = DualFisheyeLens(cx: 0, cy: 0, yaw: 0, pitch: 0, roll: 90);
      const bodyX = (x: 1.0, y: 0.0, z: 0.0);
      const bodyZ = (x: 0.0, y: 0.0, z: 1.0);
      const lensAxis = (x: 0.0, y: 0.0, z: 1.0);
      const imageDown = (x: 0.0, y: 1.0, z: 0.0);

      // Sensors sideways: body x, gravity of the upright camera, is down in the image of both lenses
      expect(lensPose(lens, 0).apply(bodyX), _closeToVec(imageDown, 1e-12));
      expect(lensPose(lens, 1).apply(bodyX), _closeToVec(imageDown, 1e-12));
      expect(lensPose(lens, 0).apply(bodyZ), _closeToVec(lensAxis, 1e-12));
      expect(lensPose(lens, 1).apply((x: 0.0, y: 0.0, z: -1.0)), _closeToVec(lensAxis, 1e-12));

      // A roll of 89.51 degrees turns by 90.49: body x leans to -x in the image, not to +x
      final rolled = lensPose(_x3().lenses[0], 0).apply(bodyX);
      expect(rolled.x, closeTo(-math.sin(0.49 * _degree), 2e-3));
      expect(rolled.x, lessThan(0));
    });
  });

  group('gravity and the body frame', () {
    test('maps the accelerometer of the X3 to the body frame', () {
      expect(downBodyFromAccelerometer(null), [1.0, 0.0, 0.0]);
      expect(downBodyFromAccelerometer(const [0, 0, 0]), [1.0, 0.0, 0.0]);
      expect(downBodyFromAccelerometer(const [-9.81, 0, 0]), [1.0, 0.0, 0.0]);
      // The prototype of the stitch, for the accelerometer of the MakerNote of the real photo
      final down = downBodyFromAccelerometer(_x3Accelerometer);
      expect(down[0], closeTo(0.98920772, 1e-8));
      expect(down[1], closeTo(-0.08082998, 1e-8));
      expect(down[2], closeTo(-0.12220717, 1e-8));
    });

    test('looks along lens 1 laid level, with gravity down in the view', () {
      final upright = bodyFrame(const [1, 0, 0]);

      expect(upright.apply((x: 0.0, y: 0.0, z: 1.0)), _closeToVec((x: 0.0, y: 0.0, z: -1.0)));
      expect(upright.apply((x: 0.0, y: 1.0, z: 0.0)), _closeToVec((x: 1.0, y: 0.0, z: 0.0)));
      expect(upright.apply((x: 1.0, y: 0.0, z: 0.0)), _closeToVec((x: 0.0, y: 1.0, z: 0.0)));

      final tilted = bodyFrame(downBodyFromAccelerometer(_x3Accelerometer));
      final down = downBodyFromAccelerometer(_x3Accelerometer);
      expect(_column(tilted, 1), _closeToVec((x: down[0], y: down[1], z: down[2]), 1e-12));
      expect(_column(tilted, 2).x.abs(), lessThan(0.2), reason: 'forward stays near the axis of lens 1');
      expect(_column(tilted, 2).z, lessThan(-0.99));
    });

    test('is a proper rotation for any gravity, lens 1 pointing straight down included', () {
      for (final down in const [
        [1.0, 0.0, 0.0],
        [0.3, -0.5, 0.8],
        [0.0, 0.0, 1.0],
        [0.0, 0.0, -2.0],
        [0.0, 0.0, 0.0],
      ]) {
        final g = bodyFrame(down);
        final columns = [for (var i = 0; i < 3; i++) _column(g, i)];
        for (var i = 0; i < 3; i++) {
          for (var j = 0; j < 3; j++) {
            expect(_dot(columns[i], columns[j]), closeTo(i == j ? 1 : 0, 1e-12), reason: 'gravity $down');
          }
        }
        final c = columns;
        final determinant =
            c[0].x * (c[1].y * c[2].z - c[1].z * c[2].y) -
            c[1].x * (c[0].y * c[2].z - c[0].z * c[2].y) +
            c[2].x * (c[0].y * c[1].z - c[0].z * c[1].y);
        expect(determinant, closeTo(1, 1e-12), reason: 'gravity $down');
      }
    });

    test('gives a shader the pose of each lens after the levelling', () {
      final calibration = _x3();
      final rotations = viewToLens(calibration);

      expect(rotations, hasLength(2));
      for (var i = 0; i < 2; i++) {
        final expected = lensPose(calibration.lenses[i], i) * bodyFrame(calibration.downBody);
        expect(rotations[i].values, [for (final value in expected.values) closeTo(value, 1e-15)]);
      }
    });
  });

  group('equirect directions', () {
    test('put longitude 0 in the middle and the top row up', () {
      final corner = equirectAngles(0, 0, 4, 2);
      expect(corner.lon, closeTo(-0.75 * math.pi, 1e-12));
      expect(corner.lat, closeTo(0.25 * math.pi, 1e-12));
      expect(directionForEquirect(1000, 500, 2000, 1000), _closeToVec((x: 0.0, y: 0.0, z: 1.0), 4e-3));
      expect(directionForEquirect(0, 0, 2000, 1000).y, closeTo(-1, 1e-4));
      expect(directionForEquirect(0, 999, 2000, 1000).y, closeTo(1, 1e-4));
      expect(viewDirection(math.pi / 2, 0), _closeToVec((x: 1.0, y: 0.0, z: 0.0), 1e-12));
    });
  });

  group('projections', () {
    test('put the optical axis on the centre of the lens', () {
      final lens0 = _x3().lenses[0];

      expect(meiProject(lens0, (x: 0.0, y: 0.0, z: 1.0)), (x: lens0.cx, y: lens0.cy));
    });

    test('read a lens up to 100 degrees off axis', () {
      final lens0 = _x3().lenses[0];
      Vec3 at(double degrees) => (x: math.sin(degrees * _degree), y: 0.0, z: math.cos(degrees * _degree));

      expect(meiProject(lens0, at(99)), isNotNull);
      expect(meiProject(lens0, at(100.5)), isNull);
      expect(meiProject(const DualFisheyeLens(cx: 0, cy: 0, yaw: 0, pitch: 0, roll: 0, radius: 10), at(10)), isNull);
      // About 2886 canvas pixels from the centre at 100 degrees on the X3, in a half square of 2976
      final edge = meiProject(lens0, at(99.99))!;
      expect(edge.x - lens0.cx, closeTo(2886, 15));
    });

    test('move an equidistant lens linearly with the angle, its radius at 100 degrees', () {
      const lens = DualFisheyeLens(cx: 2000, cy: 1500, yaw: 0, pitch: 0, roll: 0, radius: 1000);

      final half = equidistantProject(lens, (x: math.sin(50 * _degree), y: 0.0, z: math.cos(50 * _degree)))!;
      expect(half.x, closeTo(2500, 1e-9));
      expect(half.y, closeTo(1500, 1e-9));
      final below = equidistantProject(lens, (x: 0.0, y: math.sin(80 * _degree), z: math.cos(80 * _degree)))!;
      expect(below.x, closeTo(2000, 1e-9));
      expect(below.y, closeTo(2300, 1e-9));
      expect(equidistantProject(lens, (x: 0.0, y: 0.0, z: 1.0)), (x: 2000.0, y: 1500.0));
      expect(equidistantProject(lens, (x: 1.0, y: 0.0, z: math.cos(100 * _degree))), isNull);
    });
  });

  group('blending', () {
    test('fades a lens out between 85 and 95 degrees', () {
      expect(blendWeight(60), 1);
      expect(blendWeight(85), 1);
      expect(blendWeight(90), closeTo(0.5, 1e-12));
      expect(blendWeight(95), 0);
      expect(blendWeight(99), 0);
      expect(blendWeight(87.5) + blendWeight(92.5), closeTo(1, 1e-12));
      expect(blendWeight(88), greaterThan(blendWeight(89)));
    });
  });

  group('samplePixel', () {
    test('matches the prototype of the stitch on a real X3 calibration', () {
      final calibration = _x3();
      final cases = <(double, double, List<(int, double, double, double)>)>[
        (0.0, 0.0, [(1, 8996.31389767046, 2823.327976401671, 1)]),
        (1.0, 0.3, [(1, 10677.499999277406, 2439.0583802395777, 1)]),
        (-2.0, -0.5, [(0, 4854.524842446458, 4052.329350255675, 1)]),
        (3.0, 1.2, [(0, 2745.7723786888637, 1224.2829168552112, 1)]),
        (0.5, -1.4, [(1, 8968.346137479013, 5215.31265584399, 1)]),
        (
          math.pi / 2,
          0.1,
          [
            (0, 322.7702348679374, 2948.2439238953725, 0.5985043487682111),
            (1, 11666.845324265989, 2989.352812624088, 0.4085804086030531),
          ],
        ),
        (
          -math.pi / 2,
          0.0,
          [
            (0, 5642.941833648929, 2823.5916072466625, 0.5053267105053574),
            (1, 6326.732490650213, 2771.98516713095, 0.4875104876875901),
          ],
        ),
      ];

      for (final (lon, lat, expected) in cases) {
        _expectSamples(samplePixel(calibration, _width, _height, lon, lat), expected, reason: 'lon $lon, lat $lat');
      }
    });

    test('lands on the centre of lens 0 behind the view, and of lens 1 ahead', () {
      final calibration = _x3().copyWith(downBody: const [1, 0, 0]);
      final scale = _height / calibration.canvasSquare;

      final [behind] = samplePixel(calibration, _width, _height, math.pi, 0);
      expect(behind.lens, 0);
      expect(behind.x, closeTo(calibration.lenses[0].cx * scale, 3));
      expect(behind.y, closeTo(calibration.lenses[0].cy * scale, 3));
      expect(behind.weight, 1);

      final [ahead] = samplePixel(calibration, _width, _height, 0, 0);
      expect(ahead.lens, 1);
      expect(ahead.x, closeTo(calibration.lenses[1].cx * scale, 3));
      expect(ahead.y, closeTo(calibration.lenses[1].cy * scale, 3));
    });

    test('shares the seam half and half, and gives a direction 95 degrees off a lens to the other', () {
      final calibration = nominalX3(2976);

      final seam = samplePixel(calibration, 5952, 2976, math.pi / 2, 0);
      expect([for (final sample in seam) sample.lens], [0, 1]);
      expect([for (final sample in seam) sample.weight], [closeTo(0.5, 1e-9), closeTo(0.5, 1e-9)]);
      expect(seam[0].x, inInclusiveRange(0, 2976));
      expect(seam[1].x, inInclusiveRange(2976, 5952));

      // 95 degrees off lens 0 is 85 off lens 1
      final [past] = samplePixel(calibration, 5952, 2976, 85 * _degree, 0);
      expect(past.lens, 1);
      expect(past.weight, 1);

      final within = samplePixel(calibration, 5952, 2976, 87.5 * _degree, 0);
      expect([for (final sample in within) sample.weight], [closeTo(0.15625, 1e-9), closeTo(0.84375, 1e-9)]);
    });

    test('takes the lens closer to its axis alone when no lens has weight, and nothing when none sees', () {
      final nominal = nominalX3(2976);
      DualFisheyeLens away(DualFisheyeLens lens) =>
          DualFisheyeLens(cx: -100000, cy: lens.cy, yaw: 0, pitch: 0, roll: 90, xi: lens.xi, fx: lens.fx, fy: lens.fy);
      final lens1Away = nominal.copyWith(lenses: [nominal.lenses[0], away(nominal.lenses[1])]);

      // 97 degrees off lens 0, whose weight is 0 there; lens 1 lands off its square
      final [alone] = samplePixel(lens1Away, 5952, 2976, 83 * _degree, 0);
      expect(alone.lens, 0);
      expect(alone.weight, 1);

      final bothAway = nominal.copyWith(lenses: [away(nominal.lenses[0]), away(nominal.lenses[1])]);
      expect(samplePixel(bothAway, 5952, 2976, 83 * _degree, 0), isEmpty);
    });

    test('draws an equidistant calibration too', () {
      final calibration = parseInsta360OffsetV1(x3OffsetV1)!;
      final scale = _height / calibration.canvasSquare;

      final [behind] = samplePixel(calibration, _width, _height, math.pi, 0);
      expect(behind.lens, 0);
      expect(behind.x, closeTo(calibration.lenses[0].cx * scale, 25));
      expect(behind.y, closeTo(calibration.lenses[0].cy * scale, 25));
    });
  });

  group('nominalX3 and calibrationForFrame', () {
    test('centre the nominal lenses in their squares', () {
      final calibration = nominalX3(2976);

      expect(calibration.model, DualFisheyeModel.mei);
      expect(calibration.source, DualFisheyeSource.nominal);
      expect(calibration.canvasSquare, 2976);
      expect(calibration.downBody, [1, 0, 0]);
      final [lens0, lens1] = calibration.lenses;
      expect((lens0.cx, lens0.cy), (1488, 1488));
      expect((lens1.cx, lens1.cy), (4464, 1488));
      for (final lens in calibration.lenses) {
        expect(lens.xi, 1.948);
        expect(lens.fx, closeTo(0.777 * 2976, 1e-9));
        expect(lens.fy, lens.fx);
        expect((lens.k1, lens.k2, lens.k3, lens.p1, lens.p2), (0.39, 1.28, -3.94, 0, 0));
        expect((lens.yaw, lens.pitch, lens.roll), (0, 0, 90));
      }

      final [behind] = samplePixel(calibration, 5952, 2976, math.pi, 0);
      expect(behind.x, closeTo(1488, 1e-6));
      expect(behind.y, closeTo(1488, 1e-6));
      final [ahead] = samplePixel(calibration, 5952, 2976, 0, 0);
      expect(ahead.x, closeTo(4464, 1e-6));
      expect(ahead.y, closeTo(1488, 1e-6));
    });

    test('scale a calibration to the pixels of a frame, which then draws the same', () {
      final calibration = _x3();
      final scaled = calibrationForFrame(calibration, _height);
      const scale = _height / 5952;

      expect(scaled.canvasSquare, _height);
      expect(scaled.lenses[0].cx, closeTo(2967.48 * scale, 1e-9));
      expect(scaled.lenses[1].fy, closeTo(4615.53 * scale, 1e-9));
      expect(scaled.lenses[0].xi, calibration.lenses[0].xi);
      expect(scaled.lenses[0].roll, calibration.lenses[0].roll);
      expect(scaled.lenses[0].k3, calibration.lenses[0].k3);
      expect(scaled.downBody, calibration.downBody);
      expect(canvasToFrameScale(scaled, _height), 1);
      for (final (lon, lat) in [(0.0, 0.0), (1.0, 0.3), (-math.pi / 2, 0.0), (3.0, 1.2)]) {
        final original = samplePixel(calibration, _width, _height, lon, lat);
        final again = samplePixel(scaled, _width, _height, lon, lat);
        expect(again, hasLength(original.length));
        for (var i = 0; i < original.length; i++) {
          expect(again[i].x, closeTo(original[i].x, 1e-6));
          expect(again[i].y, closeTo(original[i].y, 1e-6));
          expect(again[i].weight, closeTo(original[i].weight, 1e-12));
        }
      }

      final v1 = calibrationForFrame(parseInsta360OffsetV1(x3OffsetV1)!, 2976);
      expect(v1.lenses[0].radius, closeTo(2905.88 / 2, 1e-9));
      expect(v1.lenses[0].fx, isNull);
    });
  });
}
