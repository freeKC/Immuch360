import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/camera_motion.dart';
import 'package:immich_mobile/domain/models/raw/stabilization.dart';
import 'package:immich_mobile/domain/services/raw/dji_motion.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/gopro_motion.dart';
import 'package:immich_mobile/domain/services/raw/stabilization.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import '../../../fixtures/raw/dji_motion_slices.dart';
import '../../../fixtures/raw/dji_osv.stub.dart';
import '../../../fixtures/raw/gopro_gpmf.stub.dart';
import '../../../fixtures/raw/gopro_gpmf_frames.dart';

// From the real slices of the GoPro MAX and DJI Osmo 360 samples to the table the player applies. The math of these
// tests is written apart from the code under test: rotation matrices of the quaternions.

const _degree = math.pi / 180;

/// The rotation matrix of the quaternion [q] (w, x, y, z), made unit long
Mat3 _matrix(List<double> q) {
  final n = math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
  final (w, x, y, z) = (q[0] / n, q[1] / n, q[2] / n, q[3] / n);
  return Mat3([
    1 - 2 * (y * y + z * z),
    2 * (x * y - w * z),
    2 * (x * z + w * y),
    2 * (x * y + w * z),
    1 - 2 * (x * x + z * z),
    2 * (y * z - w * x),
    2 * (x * z - w * y),
    2 * (y * z + w * x),
    1 - 2 * (x * x + y * y),
  ]);
}

List<double> _at(List<double> values, int i, [int size = 4]) => [for (var j = 0; j < size; j++) values[size * i + j]];

Vec3 _unit(Vec3 v) {
  final n = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
  return (x: v.x / n, y: v.y / n, z: v.z / n);
}

/// The angle in degrees between two directions
double _angle(Vec3 a, Vec3 b) {
  final ua = _unit(a);
  final ub = _unit(b);
  return math.acos((ua.x * ub.x + ua.y * ub.y + ua.z * ub.z).clamp(-1.0, 1.0)) / _degree;
}

double _determinant(Mat3 m) =>
    m.at(0, 0) * (m.at(1, 1) * m.at(2, 2) - m.at(1, 2) * m.at(2, 1)) -
    m.at(0, 1) * (m.at(1, 0) * m.at(2, 2) - m.at(1, 2) * m.at(2, 0)) +
    m.at(0, 2) * (m.at(1, 0) * m.at(2, 1) - m.at(1, 1) * m.at(2, 0));

/// The axis (unit) and the angle in degrees of the rotation matrix [m]
({Vec3 axis, double degrees}) _axisAngle(Mat3 m) {
  final cosine = ((m.at(0, 0) + m.at(1, 1) + m.at(2, 2)) - 1) / 2;
  final angle = math.acos(cosine.clamp(-1.0, 1.0));
  final axis = (x: m.at(2, 1) - m.at(1, 2), y: m.at(0, 2) - m.at(2, 0), z: m.at(1, 0) - m.at(0, 1));
  return (axis: _unit(axis), degrees: angle / _degree);
}

ByteRangeReader _reader(Uint8List file) => (offset, length) async {
  final start = math.min(offset, file.length);
  return Uint8List.sublistView(file, start, math.min(file.length, start + length));
};

/// Where the display shows the down of the world of frame [i]: the correction of the table turns the camera's view
/// direction [cameraDown] (the down of the world as the camera's view sees it) to this direction of the display
Vec3 _shownDown(StabilizationTable table, int i, Vec3 cameraDown) =>
    _matrix(_at(table.corrections, i)).apply(cameraDown);

const _displayDown = (x: 0.0, y: 1.0, z: 0.0);

/// The 24 real frames of the GoPro MAX sample, every 25th one over its 20 s, one payload each, 0.834 s apart as on the
/// sample (25 frames of 1001 / 30000 s)
Uint8List _goProFile() => goProMotionFile(
  [
    for (var i = 0; i < goProSpreadFrames.length; i++)
      goProPayload(cori: [goProSpreadCori[i]], grav: [goProSpreadGrav[i]], shut: [0.0003]),
  ],
  withVideo: false,
  payloadTicks: List.filled(goProSpreadFrames.length, 834),
);

/// The real frames 0, 1, 2, 300 and 301 of the DJI Osmo 360 sample
Uint8List _djiFile() => djiOsvFile(
  camd: djiCamdBox(
    djiMotionCamdRecords([
      for (final (attitude, second) in djiMotionSliceRecords) (base64.decode(attitude), base64.decode(second)),
    ]),
  ),
);

/// A GoPro like track of [frames] frames turning about GPMF y, its gravity along GPMF x, [orientations] given
CameraMotionTrack _goProTrack(Float32List orientations, {Float32List? gravity}) {
  final frames = orientations.length ~/ 4;
  return CameraMotionTrack(
    source: CameraMotionSource.goProGpmf,
    timeOrigin: CameraMotionTimeOrigin.firstFrame,
    samples: CameraMotionSamples.empty(),
    frameTimes: Float64List.fromList([for (var i = 0; i < frames; i++) i / 30]),
    frameExposures: Float32List(0),
    frameOrientations: orientations,
    frameGravity: gravity,
  );
}

void main() {
  group('the view frames of the stitches', () {
    test('are proper rotations, the GoPro one as measured on the picture of the MAX sample', () {
      for (final m in [goProViewToGpmf, djiViewToBody]) {
        final product = m.transposed * m;
        for (var i = 0; i < 9; i++) {
          expect(product.values[i], closeTo(Mat3.identity.values[i], 1e-12));
        }
        expect(_determinant(m), closeTo(1, 1e-12));
      }
      // GPMF x is the view's down, y its left, z its forward
      expect(goProViewToGpmf.apply((x: 0, y: 1, z: 0)), (x: 1.0, y: 0.0, z: 0.0));
      expect(goProViewToGpmf.apply((x: -1, y: 0, z: 0)), (x: 0.0, y: 1.0, z: 0.0));
      expect(goProViewToGpmf.apply((x: 0, y: 0, z: 1)), (x: 0.0, y: 0.0, z: 1.0));
      // DJI: the view of an upright Insta360 (lot a3)
      expect(djiViewToBody.values, bodyFrame(const [0, 1, 0]).values);
      expect(viewToBodyOf(CameraMotionSource.goProGpmf), goProViewToGpmf);
      expect(viewToBodyOf(CameraMotionSource.djiAttitude), djiViewToBody);
      expect(viewToBodyOf(CameraMotionSource.insta360Imu), isNull);
    });
  });

  group('cameraOrientationTrackOf', () {
    test('takes the inverse of the orientations, made unit long, and the gravity of the same frames', () {
      final track = _goProTrack(
        Float32List.fromList([0.8, 0, 0, 0, 0, 2, 0, 0, double.nan, 0, 0, 0, 0.6, 0, 0.8, 0]),
        gravity: Float32List.fromList([1, 0, 0, 0, 1, 0, 0, 0, 1, double.nan, double.nan, double.nan]),
      );

      final orientations = cameraOrientationTrackOf(track);

      expect(orientations, isNotNull);
      orientations!;
      expect(orientations.label, 'GoPro CORI');
      expect(orientations.worldUp, isNull);
      // Frame 0 is a little short and kept; frame 1 is twice too long and frame 2 not a number: both are left out
      expect(orientations.times, [0, 3 / 30]);
      const expected = [1.0, 0.0, 0.0, 0.0, 0.6, 0.0, -0.8, 0.0];
      for (var k = 0; k < 8; k++) {
        expect(orientations.orientations[k], closeTo(expected[k], 1e-7));
      }
      expect(orientations.gravity!.sublist(0, 3), [1, 0, 0]);
      expect(orientations.gravity!.sublist(3).every((v) => v.isNaN), isTrue);
    });

    test('leaves out the frames far from unit long, and gives the up of the world for DJI', () {
      final track = CameraMotionTrack(
        source: CameraMotionSource.djiAttitude,
        timeOrigin: CameraMotionTimeOrigin.firstFrame,
        samples: CameraMotionSamples.empty(),
        frameTimes: Float64List.fromList([0, 0.04, 0.08]),
        frameExposures: Float32List(0),
        frameOrientations: Float32List.fromList([0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 2]),
      );

      final orientations = cameraOrientationTrackOf(track)!;

      expect(orientations.label, 'DJI attitude');
      expect(orientations.times, [0.04]);
      expect(orientations.worldUp, djiWorldUp);
      expect(orientations.gravity, isNull);
    });

    test('is null without orientations or with none that can be used', () {
      final noOrientation = CameraMotionTrack(
        source: CameraMotionSource.insta360Imu,
        timeOrigin: CameraMotionTimeOrigin.firstFrame,
        samples: CameraMotionSamples.empty(),
        frameTimes: Float64List.fromList([0]),
        frameExposures: Float32List(0),
      );
      expect(cameraOrientationTrackOf(noOrientation), isNull);
      expect(stabilizationOfCameraMotion(noOrientation), isNull);
      expect(cameraOrientationTrackOf(_goProTrack(Float32List.fromList([double.nan, 0, 0, 0]))), isNull);
    });
  });

  group('the real GoPro MAX slice to the table', () {
    test('keeps the down of the world at the bottom of the display at every frame, from GRAV', () async {
      final file = _goProFile();
      final track = (await readGoProMotion(_reader(file), file.length))!;
      final count = goProSpreadFrames.length;
      final details = StabilizationDetails();

      final table = stabilizationOfCameraMotion(track, details: details);

      expect(table, isNotNull);
      table!;
      expect(table.length, count);
      expect(table.summary.source, 'GoPro CORI');
      // Windows of 2 s spanning at least 1 s: 4 with frames 0.834 s apart
      expect(table.summary.levelWindowsKept, 4);
      expect(details.viewToBody.values, goProViewToGpmf.values);
      for (var i = 0; i < count; i++) {
        // The gravity the camera wrote (GRAV points down), seen from the view of the stitch
        final grav = (
          x: goProSpreadGravExpected[i][0],
          y: goProSpreadGravExpected[i][1],
          z: goProSpreadGravExpected[i][2],
        );
        final cameraDown = goProViewToGpmf.transposed.apply(grav);
        expect(_angle(_shownDown(table, i, cameraDown), _displayDown), lessThan(2.5), reason: 'frame $i');
      }
      // The same table from the reader of the file
      final read = (await readGoProStabilization(_reader(file), file.length))!;
      expect(read.corrections, table.corrections);
      expect(read.presentationTimesUs, table.presentationTimesUs);
    });

    test('puts the front lens of frame 0 on the ground and turns the picture about the view right axis', () async {
      final file = _goProFile();
      final track = (await readGoProMotion(_reader(file), file.length))!;
      final gravity = track.frameGravity!;
      final orientations = track.frameOrientations!;

      // Frame 0 of the sample: the front face of the stitch shows the asphalt, so gravity is along the view forward
      final down0 = goProViewToGpmf.transposed.apply((x: gravity[0], y: gravity[1], z: gravity[2]));
      expect(_unit(down0).z, greaterThan(0.9));

      // The camera pitches over the clip: its large turns are about the view's x axis (the picture fit says the same)
      Mat3 viewToWorld(int i) => _matrix(_at(orientations, i)).transposed * goProViewToGpmf;
      var large = 0;
      for (var i = 1; i < goProSpreadFrames.length; i++) {
        final turn = _axisAngle(viewToWorld(0).transposed * viewToWorld(i));
        if (turn.degrees > 50) {
          large++;
          expect(turn.axis.x.abs(), greaterThan(0.95), reason: 'frame ${goProSpreadFrames[i]}');
        }
      }
      expect(large, greaterThan(8));
    });

    test('would put the sky at the bottom with GRAV taken the other way', () async {
      final file = _goProFile();
      final track = (await readGoProMotion(_reader(file), file.length))!;
      final flipped = Float32List.fromList([for (final v in track.frameGravity!) -v]);
      final wrong = CameraMotionTrack(
        source: track.source,
        timeOrigin: track.timeOrigin,
        samples: track.samples,
        frameTimes: track.frameTimes,
        frameExposures: track.frameExposures,
        frameOrientations: track.frameOrientations,
        frameGravity: flipped,
      );

      final table = stabilizationOfCameraMotion(wrong)!;

      final grav = (
        x: goProSpreadGravExpected[5][0],
        y: goProSpreadGravExpected[5][1],
        z: goProSpreadGravExpected[5][2],
      );
      expect(_angle(_shownDown(table, 5, goProViewToGpmf.transposed.apply(grav)), _displayDown), greaterThan(170));
    });

    test('blends over a frame without orientation', () {
      // A turn about GPMF y of 1 degree a frame, frame 2 unknown
      final orientations = Float32List(4 * 5);
      for (var i = 0; i < 5; i++) {
        final half = i * _degree / 2;
        orientations.setAll(4 * i, [math.cos(half), 0, math.sin(half), 0]);
      }
      orientations.fillRange(8, 12, double.nan);
      final details = StabilizationDetails();

      final table = stabilizationOfCameraMotion(_goProTrack(orientations), details: details)!;

      expect(table.length, 5);
      expect(table.corrections.every((v) => v.isFinite), isTrue);
      final camera = [for (var i = 0; i < 5; i++) _matrix(_at(details.camera, i))];
      expect(_axisAngle(camera[0].transposed * camera[2]).degrees, closeTo(2, 1e-4));
    });
  });

  group('the real DJI Osmo 360 slice to the table', () {
    test('levels every frame with the world of the attitude, whose z is down', () async {
      final file = _djiFile();
      final track = (await readDjiMotion(_reader(file), file.length))!;
      final count = djiMotionSliceFrames.length;
      final details = StabilizationDetails();

      final table = stabilizationOfCameraMotion(track, details: details);

      expect(table, isNotNull);
      table!;
      expect(table.length, count);
      expect(table.summary.source, 'DJI attitude');
      expect(table.summary.levelWindows, 0);
      expect(details.viewToBody.values, djiViewToBody.values);
      final tilts = <double>[];
      for (var i = 0; i < count; i++) {
        // The down of the world (its z) in the body, then in the view of the stitch
        final body = _matrix(_at(track.frameOrientations!, i)).apply((x: 0, y: 0, z: 1));
        final cameraDown = djiViewToBody.transposed.apply(body);
        tilts.add(_angle(cameraDown, _displayDown));
        expect(_angle(_shownDown(table, i, cameraDown), _displayDown), lessThan(1e-3), reason: 'frame $i');
      }
      // The attitude leans by 20 degrees at the start of the ride (lot a3), 4 degrees after 12 s
      expect(tilts[0], closeTo(20.2, 0.1));
      expect(tilts[3], lessThan(5));
      // Frames 0, 1, 2 then 300 and 301: presentation times on the clock of the camera
      expect(table.presentationTimesUs[1], 40000);
      expect(table.presentationTimesUs[3], 12000000);

      final read = (await readDjiStabilization(_reader(file), file.length))!;
      expect(read.corrections, table.corrections);
    });
  });

  group('stabilizationOfCameraMotion on raw samples', () {
    test('integrates the gyroscope as stabilizationOfMotionTrack does', () {
      // An upright camera turning at 0.5 rad/s about body x, the accelerometer reading 1 g up (body -x)
      const count = 2001;
      final times = Float64List.fromList([for (var i = 0; i < count; i++) i / 1000]);
      final rates = Float32List(3 * count);
      final accelerations = Float32List(3 * count);
      for (var i = 0; i < count; i++) {
        rates[3 * i] = 0.5;
        accelerations[3 * i] = -1;
      }
      final track = CameraMotionTrack(
        source: CameraMotionSource.insta360Imu,
        timeOrigin: CameraMotionTimeOrigin.firstFrame,
        samples: CameraMotionSamples(times: times, rotationRates: rates, accelerations: accelerations),
        frameTimes: Float64List.fromList([for (var i = 0; i < 60; i++) i / 30]),
        frameExposures: Float32List(60),
      );

      final table = stabilizationOfCameraMotion(track, downBody: const [1, 0, 0])!;
      final expected = stabilizationOfMotionTrack(track, downBody: const [1, 0, 0])!;

      expect(table.corrections, expected.corrections);
      expect(table.summary.source, expected.summary.source);
    });
  });
}
