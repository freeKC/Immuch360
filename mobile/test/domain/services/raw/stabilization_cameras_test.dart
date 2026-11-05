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

/// The real frames 0, 1, 2, 300 and 301 of the DJI Osmo 360 sample, from frame [from] of them on
Uint8List _djiFile({int from = 0}) => djiOsvFile(
  camd: djiCamdBox(
    djiMotionCamdRecords([
      for (final (attitude, second) in djiMotionSliceRecords.skip(from))
        (base64.decode(attitude), base64.decode(second)),
    ]),
  ),
);

/// The rotation from the view of the stitch of the GoPro MAX sample to its GPMF axes as the picture itself gives it,
/// row major: fitted by Procrustes over the rotation vectors of 594 frame pairs (lots/gopro_vision.py, residual 1.01
/// degree a pair against 2.77 without correction), before it was taken square ([goProViewToGpmf], 22 degrees off
/// about the view's x axis, which that one turn cannot settle)
const _goProPictureViewToGpmf = Mat3([0.0114, 0.9263, -0.3765, -0.9999, 0.0079, -0.0107, -0.007, 0.3766, 0.9263]);

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
    // A check that the table levels with GRAV as it should, not of the axes of the view: the shown down K B^T g is
    // T^T G^T R(q) g whatever B, the view to GPMF rotation cancels out. The axes are checked by the turns below.
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

    test(
      'turns the camera of the table the way the picture of the sample turned, about the same signed axis',
      () async {
        final file = _goProFile();
        final track = (await readGoProMotion(_reader(file), file.length))!;
        final orientations = track.frameOrientations!;
        final details = StabilizationDetails();
        stabilizationOfCameraMotion(track, details: details);

        // The turn of the camera from frame 0, in the view of frame 0: the table's (C_i, the world being the view of
        // frame 0), and the one of the picture, with the axes the picture fit gave
        Mat3 picture(int i) => _matrix(_at(orientations, i)).transposed * _goProPictureViewToGpmf;
        var large = 0;
        for (var i = 1; i < goProSpreadFrames.length; i++) {
          final table = _axisAngle(_matrix(_at(details.camera, i)).transposed);
          final seen = _axisAngle(picture(0).transposed * picture(i));
          if (table.degrees > 50) {
            large++;
            expect(table.degrees, closeTo(seen.degrees, 3), reason: 'frame ${goProSpreadFrames[i]}');
            // 0.8 to 3.9 degrees apart on the sample (the 22 degrees of the pitch about view x left to judgement
            // barely move an axis along x); the axes of the view rolled by 90 or 180 degrees about its forward (the
            // MAX 2 rule) would be 90 degrees off or more
            expect(_angle(table.axis, seen.axis), lessThan(10), reason: 'frame ${goProSpreadFrames[i]}');
          }
        }
        expect(large, greaterThan(8));
      },
    );

    test('would turn the other way with the axes of the view rolled by 180 degrees', () async {
      final file = _goProFile();
      final track = (await readGoProMotion(_reader(file), file.length))!;
      final orientations = track.frameOrientations!;
      // The view turned by 180 degrees about its forward, then into GPMF as shipped
      final rolled = goProViewToGpmf * const Mat3([-1, 0, 0, 0, -1, 0, 0, 0, 1]);
      expect(rolled.apply((x: 0, y: 1, z: 0)), (x: -1.0, y: 0.0, z: 0.0), reason: 'the view down to GPMF -x');
      final details = StabilizationDetails();
      stabilizationOfCameraMotion(track, viewToBody: rolled, details: details);

      Mat3 picture(int i) => _matrix(_at(orientations, i)).transposed * _goProPictureViewToGpmf;
      for (var i = 1; i < goProSpreadFrames.length; i++) {
        final table = _axisAngle(_matrix(_at(details.camera, i)).transposed);
        if (table.degrees > 50) {
          final seen = _axisAngle(picture(0).transposed * picture(i));
          expect(_angle(table.axis, seen.axis), greaterThan(150), reason: 'frame ${goProSpreadFrames[i]}');
        }
      }
    });

    test('gives no table for a GoPro whose axes were not measured, the MAX 2', () async {
      expect(goProAxesMeasured(goProMaxName), isTrue);
      expect(goProAxesMeasured('GoPro MAX'), isTrue);
      expect(goProAxesMeasured(null), isTrue, reason: 'the caller checks the faces');
      expect(goProAxesMeasured('GoPro Max2'), isFalse);
      expect(goProAxesMeasured('GoPro MAX 2'), isFalse);
      expect(goProAxesMeasured('HERO13 Black'), isFalse);

      final max2 = goProMotionFile(
        [
          for (var i = 0; i < 3; i++)
            goProPayload(cori: [goProSpreadCori[i]], grav: [goProSpreadGrav[i]], shut: [0.0003], name: 'GoPro Max2'),
        ],
        withVideo: false,
        payloadTicks: List.filled(3, 834),
      );
      expect(await readGoProMotion(_reader(max2), max2.length), isNotNull, reason: 'the track itself reads');
      expect(await readGoProStabilization(_reader(max2), max2.length), isNull);
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
    test('levels every frame with the world of the attitude, whose z is down, once the correction faded in', () async {
      final file = _djiFile();
      final track = (await readDjiMotion(_reader(file), file.length))!;
      final count = djiMotionSliceFrames.length;
      final details = StabilizationDetails();

      // Applied whole from the start: every frame levelled by the attitude
      final whole = stabilizationOfCameraMotion(
        track,
        options: const StabilizationOptions(djiFadeInSeconds: 0),
        details: details,
      );
      final table = stabilizationOfCameraMotion(track)!;

      expect(whole, isNotNull);
      whole!;
      expect(whole.length, count);
      expect(whole.summary.source, 'DJI attitude');
      expect(whole.summary.levelWindows, 0);
      expect(details.viewToBody.values, djiViewToBody.values);
      final tilts = <double>[];
      for (var i = 0; i < count; i++) {
        // The down of the world (its z) in the body, then in the view of the stitch
        final body = _matrix(_at(track.frameOrientations!, i)).apply((x: 0, y: 0, z: 1));
        final cameraDown = djiViewToBody.transposed.apply(body);
        tilts.add(_angle(cameraDown, _displayDown));
        expect(_angle(_shownDown(whole, i, cameraDown), _displayDown), lessThan(1e-3), reason: 'frame $i');
        // Faded in over 5 s: frames 300 and 301, at 12 s, get the whole of it
        if (i >= 3) {
          expect(_angle(_shownDown(table, i, cameraDown), _displayDown), lessThan(1e-3), reason: 'frame $i');
          expect(_at(table.corrections, i), _at(whole.corrections, i));
        }
      }
      // The attitude leans by 20 degrees at the start of the ride (lot a3), 4 degrees after 12 s
      expect(tilts[0], closeTo(20.2, 0.1));
      expect(tilts[3], lessThan(5));

      final read = (await readDjiStabilization(_reader(file), file.length))!;
      expect(read.corrections, table.corrections);
    });

    test('puts each frame at its place on the timeline of the video, as the app asks', () async {
      // The app gives the frame duration of the video track, 40 ms at 25 frames a second
      final file = _djiFile();
      final table = (await readDjiStabilization(_reader(file), file.length, frameDurationUs: 40000))!;
      expect(table.presentationTimesUs, [0, 40000, 80000, 12000000, 12040000]);
      // Without the records of frames 0, 1 and 2: frame 300 stays at 12 s
      final late = _djiFile(from: 3);
      final lateTable = (await readDjiStabilization(_reader(late), late.length, frameDurationUs: 40000))!;
      expect(lateTable.presentationTimesUs, [12000000, 12040000]);
      // And on the times of the track without a frame duration
      final untimed = (await readDjiStabilization(_reader(file), file.length))!;
      expect(untimed.presentationTimesUs, [0, 40000, 80000, 12000000, 12040000]);
    });

    test('fades the correction in while the fusion settles, so that the horizon does not slide', () async {
      // The picture of the sample is level at the start (the horizon on the centre row of the front lens, lot a3),
      // while the attitude leans by 20 degrees: there the down of the world is the down of the view of the stitch.
      // At 12 s the attitude has settled (within 4 degrees of the picture): its down is the down of the world.
      final file = _djiFile();
      final track = (await readDjiMotion(_reader(file), file.length))!;
      Vec3 attitudeDown(int i) =>
          djiViewToBody.transposed.apply(_matrix(_at(track.frameOrientations!, i)).apply((x: 0, y: 0, z: 1)));
      // The down of the world in the view of the stitch: level in the picture at frames 0 to 2, the attitude's at 12 s
      Vec3 worldDown(int i) => i < 3 ? _displayDown : attitudeDown(i);
      double shownTilt(StabilizationTable table, int i) => _angle(_shownDown(table, i, worldDown(i)), _displayDown);

      final faded = (await readDjiStabilization(_reader(file), file.length, frameDurationUs: 40000))!;
      final whole = (await readDjiStabilization(
        _reader(file),
        file.length,
        frameDurationUs: 40000,
        options: const StabilizationOptions(djiFadeInSeconds: 0),
      ))!;

      // From frame 0 to frame 301 the shown horizon stays within a degree of level, where the lean of the fusion
      // shown whole tilts it by 20 degrees at the start
      for (var i = 0; i < djiMotionSliceFrames.length; i++) {
        expect(shownTilt(faded, i), lessThan(1), reason: 'frame ${djiMotionSliceFrames[i]}');
        expect(shownTilt(whole, i), i < 3 ? greaterThan(15) : lessThan(1), reason: 'frame ${djiMotionSliceFrames[i]}');
      }
      // Frame 0 is shown as the camera saw it; frame 2, 80 ms in, nearly so
      expect(_at(faded.corrections, 0), [1, 0, 0, 0]);
      expect(_axisAngle(_matrix(_at(faded.corrections, 2))).degrees, lessThan(0.1));
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
