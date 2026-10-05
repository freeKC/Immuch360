import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dji_osv.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import '../../../fixtures/raw/dji_osv.stub.dart';
import '../../../fixtures/raw/insta360.stub.dart';
import '../spherical_probe_fixtures.dart';

ByteRangeReader _reader(Uint8List file, [List<(int, int)>? reads]) => (offset, length) async {
  reads?.add((offset, length));
  final start = math.min(offset, file.length);
  return Uint8List.sublistView(file, start, math.min(file.length, start + length));
};

Future<DjiOsvCalibration?> _read(Uint8List file, {List<(int, int)>? reads}) =>
    readDjiOsvCalibration(_reader(file, reads));

// The view to lens matrices of the sample, docs/18-design-projections-and-parsers.md, section 3.5, example D
const _viewToLens0 = [-0.999691, -0.023657, 0.007672, -0.023572, 0.999662, 0.010951, -0.007928, 0.010766, -0.999911];
const _viewToLens1 = [0.999933, -0.007031, -0.009205, 0.007135, 0.999911, 0.011292, 0.009124, -0.011357, 0.999894];

Matcher _closeToList(List<double> expected, [double delta = 1e-5]) => predicate<List<double>?>(
  (values) =>
      values != null &&
      values.length == expected.length &&
      [for (var i = 0; i < values.length; i++) (values[i] - expected[i]).abs() <= delta].every((close) => close),
  'a list within $delta of $expected',
);

// The angle in degrees of the rotation between two rotation matrices, row major
double _angleBetween(List<double> a, List<double> b) {
  var trace = 0.0;
  for (var row = 0; row < 3; row++) {
    for (var column = 0; column < 3; column++) {
      trace += a[row * 3 + column] * b[row * 3 + column];
    }
  }
  return math.acos(((trace - 1) / 2).clamp(-1.0, 1.0)) * 180 / math.pi;
}

void main() {
  group('readDjiOsvCalibration', () {
    test('reads the camera and the Kannala-Brandt calibration of the camd box of an Osmo 360 file', () async {
      final reads = <(int, int)>[];

      final dji = await _read(djiOsvFile(), reads: reads);

      expect(dji, isNotNull);
      expect((dji!.model, dji.serial, dji.firmware, dji.schema), (djiModel, djiSerial, djiFirmware, djiOsvSchema));
      final calibration = dji.calibration;
      expect(calibration.model, DualFisheyeModel.kannalaBrandt);
      expect(calibration.source, DualFisheyeSource.file);
      expect(calibration.canvasSquare, 3840);
      expect(calibration.serial, djiSerial);
      expect(calibration.cameraModel, djiModel);
      expect((calibration.maxTheta, calibration.blendStart, calibration.blendEnd), (94, 87, 93));
      expect(calibration.downBody, [1, 0, 0]);
      expect(calibration.gravity, GravitySource.none);

      final [lens0, lens1] = calibration.lenses;
      expect(lens0.cx, closeTo(1920.85339355, 1e-4));
      expect(lens0.cy, closeTo(1916.73022461, 1e-4));
      expect(lens0.fx, closeTo(1046.37927246, 1e-4));
      expect(lens0.fy, closeTo(1046.16796875, 1e-4));
      expect(lens1.cx, closeTo(1910.76611328 + 3840, 1e-4));
      expect(lens1.cy, closeTo(1916.24243164, 1e-4));
      expect(
        [lens0.k1, lens0.k2, lens0.k3, lens0.k4, lens0.k5],
        [
          closeTo(0.068134, 1e-7),
          closeTo(-0.013797, 1e-7),
          closeTo(0.0117944, 1e-7),
          closeTo(-0.00733225, 1e-8),
          closeTo(0.00104408, 1e-8),
        ],
      );
      expect(lens1.k5, closeTo(0.00095551, 1e-8));
      expect(lens0.yaw, closeTo(179.5457, 1e-4));
      expect(lens0.pitch, closeTo(90.616882, 1e-5));
      expect(lens0.roll, closeTo(-1.3556259, 1e-6));
      expect(lens0.xi, isNull);
      expect((lens0.p1, lens0.p2), (0, 0), reason: 'the tangential pair is left out');
      expect(lens0.viewToLens, _closeToList(_viewToLens0));
      expect(lens1.viewToLens, _closeToList(_viewToLens1));
      // The camd box takes a read for its first bytes, its media data being in them: the walk to it, then that
      expect(reads.where((read) => read.$2 > 16), hasLength(2), reason: '$reads');
    });

    test('places lens 1 by its yaw, pitch and roll without the quaternions, within 1.5 degrees of them', () async {
      final file = djiOsvFile(
        camd: djiCamdBox(djiCamdRecords(config: djiConfig(calibration: djiSampleCalibration(withQuaternion: false)))),
      );

      final calibration = (await _read(file))!.calibration;

      final [lens0, lens1] = calibration.lenses;
      expect(lens0.viewToLens, _closeToList(_viewToLens0), reason: 'lens 0 is placed by its angles either way');
      final byAngles = (djiLensRotation(lens1.yaw, lens1.pitch, lens1.roll) * djiViewToWorld).values;
      expect(lens1.viewToLens, _closeToList(byAngles, 1e-12));
      final angle = _angleBetween(lens1.viewToLens!, _viewToLens1);
      expect(angle, greaterThan(0.01));
      expect(angle, lessThan(1.5));
    });

    test('finds a calibration in another field of the config, by its content, as the Avata 360 keeps it', () async {
      final config = djiConfig(
        calibrationField: 5,
        calibration: djiCalibration({
          1: djiZeroSlot(),
          2: djiZeroSlot(),
          3: djiDewarpSlot(djiLens0),
          4: djiDewarpSlot(djiLens1),
        }),
      );

      final calibration = (await _read(djiOsvFile(camd: djiCamdBox(djiCamdRecords(config: config)))))!.calibration;

      expect(calibration.lenses[0].cx, closeTo(djiLens0.cx, 1e-3));
      expect(calibration.lenses[1].cx, closeTo(djiLens1.cx + 3840, 1e-3));
    });

    test('skips a slot whose first sub-fields are not all floats', () async {
      final broken = [...pbVarintField(1, 1046), ...djiDewarpSlot(djiLens0).skip(5)];
      final calibration = djiCalibration({1: broken, 2: djiDewarpSlot(djiLens0), 3: djiDewarpSlot(djiLens1)});

      final dji = await _read(
        djiOsvFile(
          camd: djiCamdBox(djiCamdRecords(config: djiConfig(calibration: calibration))),
        ),
      );

      expect(dji!.calibration.lenses[1].cx, closeTo(djiLens1.cx + 3840, 1e-3));
    });

    test('gives nothing without a camd box, without media data in it, or without a populated slot', () async {
      expect(await _read(mp4File(djiOsvMoov(), moovAtEnd: true)), isNull);
      expect(await _read(djiOsvFile(camd: djiCamdBox([]))), isNull);
      expect(
        await _read(
          djiOsvFile(
            camd: djiCamdBox(
              djiCamdRecords(
                config: djiConfig(
                  calibration: djiCalibration({for (var slot = 1; slot <= 10; slot++) slot: djiZeroSlot()}),
                ),
              ),
            ),
          ),
        ),
        isNull,
      );
      // One populated slot is not a pair
      expect(
        await _read(
          djiOsvFile(
            camd: djiCamdBox(
              djiCamdRecords(config: djiConfig(calibration: djiCalibration({1: djiDewarpSlot(djiLens0)}))),
            ),
          ),
        ),
        isNull,
      );
      // A lens that is not square
      expect(
        await _read(
          djiOsvFile(
            camd: djiCamdBox(
              djiCamdRecords(
                config: djiConfig(
                  calibration: djiCalibration({
                    1: djiDewarpSlot(djiLens0, width: 3840, height: 2160),
                    2: djiDewarpSlot(djiLens1),
                  }),
                ),
              ),
            ),
          ),
        ),
        isNull,
      );
      // Damaged records: no failure
      expect(await _read(djiOsvFile(camd: djiCamdBox(List.generate(500, (i) => i * 37 % 256)))), isNull);
    });

    test('reads the header even with a schema of another name', () async {
      final dji = await _read(
        djiOsvFile(
          camd: djiCamdBox(djiCamdRecords(header: djiHeader(schema: 'dvtm_oq102.proto'))),
        ),
      );

      expect(dji!.schema, 'dvtm_oq102.proto');
      expect(dji.model, djiModel);
    });
  });

  group('nominalOsmo360', () {
    test('gives the mean lenses of two units, rear and front, the camera upright', () {
      final calibration = nominalOsmo360();

      expect(calibration.model, DualFisheyeModel.kannalaBrandt);
      expect(calibration.source, DualFisheyeSource.nominal);
      expect(calibration.canvasSquare, 3840);
      expect((calibration.maxTheta, calibration.blendStart, calibration.blendEnd), (94, 87, 93));
      final [lens0, lens1] = calibration.lenses;
      expect((lens0.fx, lens0.fy, lens0.cx, lens0.cy), (1047.3, 1047.3, 1912.9, 1918.4));
      expect((lens1.cx, lens1.cy), (1912.9 + 3840, 1918.4));
      expect([lens1.k1, lens1.k2, lens1.k3, lens1.k4, lens1.k5], [0.06586, -0.01104, 0.009376, -0.006463, 0.0009427]);
      expect(lens0.viewToLens, [-1, 0, 0, 0, 1, 0, 0, 0, -1]);
      expect(lens1.viewToLens, [1, 0, 0, 0, 1, 0, 0, 0, 1]);
      // The same as the rotations of their angles
      for (final lens in calibration.lenses) {
        expect(
          lens.viewToLens,
          _closeToList((djiLensRotation(lens.yaw, lens.pitch, lens.roll) * djiViewToWorld).values, 1e-12),
        );
      }
    });
  });

  group('Kannala-Brandt', () {
    test('puts the radii of the rear lens of OSVplat where its bundle adjustment does, k5 included', () {
      const lens = DualFisheyeLens(
        cx: 1920,
        cy: 1920,
        yaw: 0,
        pitch: 0,
        roll: 0,
        fx: 1043.0132,
        fy: 1043.0132,
        k1: 0.0659303,
        k2: -0.00934961,
        k3: 0.00795592,
        k4: -0.00577805,
        k5: 0.000818,
      );
      double radius(double degrees) {
        final theta = degrees * math.pi / 180;
        final pixel = kannalaBrandtProject(lens, (x: math.sin(theta), y: 0, z: math.cos(theta)), maxTheta: 100)!;
        return pixel.x - lens.cx;
      }

      for (final (degrees, expected, adjusted) in [
        (30.0, 555.68, null),
        (60.0, 1162.68, 1162.0),
        (80.0, 1589.60, 1586.0),
        (85.0, 1688.62, 1685.0),
        (90.0, 1779.12, 1775.0),
        (95.0, 1857.87, 1850.0),
      ]) {
        final r = radius(degrees);
        expect(r, closeTo(expected, 0.05), reason: '$degrees degrees');
        if (adjusted != null) {
          expect((r - adjusted).abs() / adjusted, lessThan(0.005), reason: '$degrees degrees');
        }
      }
      // Past the image circle of the Osmo 360, nothing
      const theta = 95 * math.pi / 180;
      expect(kannalaBrandtProject(lens, (x: math.sin(theta), y: 0, z: math.cos(theta))), isNull);
      expect(kannalaBrandtProject(lens, (x: 1, y: 0, z: 0)), isNotNull);
    });
  });
}
