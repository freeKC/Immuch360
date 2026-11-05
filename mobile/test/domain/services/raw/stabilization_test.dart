import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/camera_motion.dart';
import 'package:immich_mobile/domain/models/raw/stabilization.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/insta360_motion.dart';
import 'package:immich_mobile/domain/services/raw/stabilization.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import '../../../fixtures/raw/insta360.stub.dart';
import '../../../fixtures/raw/insta360_motion_slices.dart';
import '../../../fixtures/raw/stabilization_slices.dart';

const _degree = math.pi / 180;

// The math of these tests is written apart from the code under test: rotation matrices, Rodrigues' formula

/// The rotation matrix of the unit quaternion [q] (w, x, y, z)
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

/// The rotation by [angle] radians about [axis], Rodrigues' formula
Mat3 _axisAngle(Vec3 axis, double angle) {
  final n = math.sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z);
  final (x, y, z) = (axis.x / n, axis.y / n, axis.z / n);
  final c = math.cos(angle);
  final s = math.sin(angle);
  final t = 1 - c;
  return Mat3([
    t * x * x + c,
    t * x * y - s * z,
    t * x * z + s * y,
    t * x * y + s * z,
    t * y * y + c,
    t * y * z - s * x,
    t * x * z - s * y,
    t * y * z + s * x,
    t * z * z + c,
  ]);
}

/// The quaternion (w, x, y, z) of the rotation by [angle] radians about [axis]
List<double> _quaternion(Vec3 axis, double angle) {
  final n = math.sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z);
  final s = math.sin(angle / 2) / n;
  return [math.cos(angle / 2), axis.x * s, axis.y * s, axis.z * s];
}

/// The angle in degrees of the rotation that takes [a] to [b]
double _angleBetween(Mat3 a, Mat3 b) {
  final m = a.transposed * b;
  final cosine = ((m.at(0, 0) + m.at(1, 1) + m.at(2, 2)) - 1) / 2;
  return math.acos(cosine.clamp(-1.0, 1.0)) / _degree;
}

/// The angle in degrees of the rotation of the quaternion [q]
double _quaternionAngle(List<double> q) =>
    2 * math.atan2(math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3]), q[0].abs()) / _degree;

double _maxDifference(Mat3 a, Mat3 b) =>
    [for (var i = 0; i < 9; i++) (a.values[i] - b.values[i]).abs()].reduce(math.max);

List<double> _at(List<double> values, int i, [int size = 4]) => [for (var j = 0; j < size; j++) values[size * i + j]];

double _dot(Vec3 a, Vec3 b) => a.x * b.x + a.y * b.y + a.z * b.z;

/// [q] or -[q], whichever is on the side of [reference]
List<double> _aligned(List<double> q, List<double> reference) {
  final dot = q[0] * reference[0] + q[1] * reference[1] + q[2] * reference[2] + q[3] * reference[3];
  return dot < 0 ? [for (final v in q) -v] : q;
}

Matcher _closeToList(List<double> expected, double delta) => predicate<List<double>>(
  (values) =>
      values.length == expected.length &&
      [for (var i = 0; i < values.length; i++) (values[i] - expected[i]).abs() <= delta].every((close) => close),
  'a list within $delta of $expected',
);

/// Samples at [rate] a second from [start] to [end] seconds: the body rotation rate and accelerometer [at] each time
CameraMotionSamples _samples(
  double start,
  double end,
  ({Vec3 rate, Vec3 acceleration}) Function(double time) at, {
  double rate = 1000,
}) {
  final count = ((end - start) * rate).round() + 1;
  final times = Float64List(count);
  final rates = Float32List(3 * count);
  final accelerations = Float32List(3 * count);
  for (var i = 0; i < count; i++) {
    final time = start + i / rate;
    final sample = at(time);
    times[i] = time;
    rates.setAll(3 * i, [sample.rate.x, sample.rate.y, sample.rate.z]);
    accelerations.setAll(3 * i, [sample.acceleration.x, sample.acceleration.y, sample.acceleration.z]);
  }
  return CameraMotionSamples(times: times, rotationRates: rates, accelerations: accelerations);
}

/// A track of [samples] and frames at [fps] from time 0 to [seconds], of [exposure] seconds
CameraMotionTrack _track(CameraMotionSamples samples, {double seconds = 1, double fps = 30, double exposure = 0}) {
  final count = (seconds * fps).floor() + 1;
  return CameraMotionTrack(
    source: CameraMotionSource.insta360Imu,
    timeOrigin: CameraMotionTimeOrigin.firstFrame,
    samples: samples,
    frameTimes: Float64List.fromList([for (var i = 0; i < count; i++) i / fps]),
    frameExposures: Float32List.fromList(List.filled(count, exposure)),
    cameraModel: 'Insta360 X4',
  );
}

// An upright camera: gravity along body +x, the accelerometer reads 1 g along body -x; the view looks along body -z,
// its right is body +y
const _upright = [1.0, 0.0, 0.0];
const _upBody = (x: -1.0, y: 0.0, z: 0.0);

/// The orientation of the camera at [time] when it turns about the fixed body [axis] by [angle] of the time; the gyro
/// then reads the derivative of the angle about that axis, the accelerometer the up of the world turned into the body
({Vec3 rate, Vec3 acceleration}) Function(double) _aboutAxis(
  Vec3 axis,
  double Function(double) angle,
  double Function(double) rate, {
  Vec3 up = _upBody,
  double g = 1,
}) {
  final n = math.sqrt(_dot(axis, axis));
  final unit = (x: axis.x / n, y: axis.y / n, z: axis.z / n);
  return (time) {
    final body = _axisAngle(unit, angle(time)).transposed.apply(up);
    final r = rate(time);
    return (
      rate: (x: unit.x * r, y: unit.y * r, z: unit.z * r),
      acceleration: (x: body.x * g, y: body.y * g, z: body.z * g),
    );
  };
}

/// Reads [file] as a local file does
ByteRangeReader _reader(Uint8List file) => (offset, length) async {
  if (offset >= file.length) {
    return Uint8List(0);
  }
  return Uint8List.sublistView(file, offset, math.min(file.length, offset + length));
};

final _mp4 = [0, 0, 0, 8, ...'free'.codeUnits];

/// A video of the real [slice] in a walked (X3) or an indexed (X4, X5) trailer, as insta360_motion_test.dart builds it
Uint8List _sliceVideo(Insta360MotionSlice slice, {required bool indexed}) {
  final metadata = [
    ...pbStringField(1, x3Serial),
    ...pbStringField(2, slice.model),
    ...pbStringField(3, slice.firmware),
    ...pbVarintField(24, slice.firstFrameTimestamp),
    ...pbDoubleField(25, slice.rollingShutterMs),
    ...pbVarintField(62, 1),
    ...pbBytesField(65, [...pbVarintField(1, 32), ...pbVarintField(2, 2000)]),
  ];
  if (indexed) {
    return Uint8List.fromList([
      ..._mp4,
      ...insta360IndexedTail(metadata: metadata, imu: slice.imu, frames: slice.frames, padTo: 128 * 1024),
    ]);
  }
  return insta360File([
    insta360Record(4, slice.frames),
    insta360Record(3, slice.imu),
    insta360Record(2, List.filled(300, 0x55)),
    insta360Record(1, metadata, format: 1),
  ], body: _mp4);
}

void main() {
  group('gyroscope integration', () {
    final axes = {
      'x': (x: 1.0, y: 0.0, z: 0.0),
      'y': (x: 0.0, y: 1.0, z: 0.0),
      'z': (x: 0.0, y: 0.0, z: 1.0),
      'a slanted axis': (x: 0.25, y: -0.5, z: 0.75),
    };
    for (final MapEntry(key: name, value: axis) in axes.entries) {
      test('turns at a constant rate about body $name by exactly the rate times the time', () {
        // 0.5 rad/s along the axis; float32 rates, so the rate is what float32 keeps
        final n = math.sqrt(_dot(axis, axis));
        final rate = (x: axis.x / n * 0.5, y: axis.y / n * 0.5, z: axis.z / n * 0.5);
        final kept = Float32List.fromList([rate.x, rate.y, rate.z]);
        final details = StabilizationDetails();
        final track = _track(
          _samples(-0.1, 2.1, (time) => (rate: rate, acceleration: _upBody)),
          seconds: 2,
          exposure: 0.002,
        );

        final table = stabilizationOfMotionTrack(track, downBody: _upright, chunkSamples: 333, details: details);

        expect(table, isNotNull);
        expect(table!.length, 61);
        final keptRate = math.sqrt(kept[0] * kept[0] + kept[1] * kept[1] + kept[2] * kept[2]);
        final keptAxis = (x: kept[0] / keptRate, y: kept[1] / keptRate, z: kept[2] / keptRate);
        final b = details.viewToBody;
        for (var i = 0; i < table.length; i++) {
          // Taken at the frame time less half the exposure (a float32) plus 4 ms, the same shift for every frame
          expect(details.times[i], closeTo(i / 30 - 0.001 + 0.004, 1e-9));
          final elapsed = details.times[i] - details.times[0];
          // C = B^T R B, R the body turning about the axis; details.camera is its inverse, world to view
          final expected = b.transposed * _axisAngle(keptAxis, keptRate * elapsed) * b;
          final camera = _matrix(_at(details.camera, i)).transposed;
          expect(_maxDifference(camera, expected), lessThan(1e-9), reason: 'frame $i');
          expect(_quaternionAngle(_at(details.camera, i)), closeTo(keptRate * elapsed / _degree, 1e-6));
        }
        expect(table.summary.meanCameraStepDegrees, closeTo(0.5 / 30 / _degree, 1e-6));
        expect(table.summary.framesOutsideSamples, 0);
        expect(table.summary.samples, 2201);
        expect(table.summary.sampleGaps, 0);
      });
    }

    test('takes the frames between samples with the rate of their step, and counts the gaps', () {
      // Samples every 7 ms but for one gap of about 50 ms, about one axis; the rate grows with time
      final times = <double>[for (var t = -0.05; t < 1.0; t += 0.007) t]..removeWhere((t) => t > 0.4 && t < 0.45);
      final rates = Float32List.fromList([for (final t in times) 0.2 + 0.6 * t]);
      final samples = CameraMotionSamples(
        times: Float64List.fromList(times),
        rotationRates: Float32List.fromList([
          for (final rate in rates) ...[0, rate, 0],
        ]),
        accelerations: Float32List.fromList([
          for (final _ in times) ...[-1.0, 0.0, 0.0],
        ]),
      );
      // The angle turned by time t: each step at the mean of the rates at its ends, the last one cut at t
      double turned(double t) {
        var angle = 0.0;
        for (var k = 1; k < times.length; k++) {
          if (times[k - 1] >= t) {
            break;
          }
          angle += (rates[k - 1] + rates[k]) / 2 * (math.min(t, times[k]) - times[k - 1]);
        }
        return angle;
      }

      final details = StabilizationDetails();

      final table = stabilizationOfMotionTrack(_track(samples, seconds: 0.9), downBody: _upright, details: details);

      expect(table!.summary.sampleGaps, 1);
      for (var i = 0; i < table.length; i++) {
        final angle = turned(details.times[i]) - turned(details.times[0]);
        expect(_quaternionAngle(_at(details.camera, i)), closeTo(angle / _degree, 1e-9), reason: 'frame $i');
      }
    });

    test('holds the first and last orientations for frames outside the samples', () {
      final track = _track(
        _samples(0.2, 0.6, (time) => (rate: (x: 0.0, y: 0.3, z: 0.0), acceleration: _upBody)),
        seconds: 1,
      );
      final details = StabilizationDetails();

      final table = stabilizationOfMotionTrack(track, downBody: _upright, details: details);

      // Frames before 0.2 s and after 0.6 s
      final outside = [for (final t in details.times) t < 0.2 || t > 0.6].where((v) => v).length;
      expect(table!.summary.framesOutsideSamples, outside);
      expect(_at(details.camera, 0), _closeToList(_at(details.camera, 1), 1e-12));
      expect(_at(details.camera, table.length - 1), _closeToList(_at(details.camera, table.length - 2), 1e-12));
    });

    test('takes a frame whose exposure is not a number at its time plus 4 ms', () {
      final samples = _samples(-0.1, 0.5, (time) => (rate: (x: 0.0, y: 0.2, z: 0.0), acceleration: _upBody));
      final track = CameraMotionTrack(
        source: CameraMotionSource.insta360Imu,
        timeOrigin: CameraMotionTimeOrigin.firstFrame,
        samples: samples,
        frameTimes: Float64List.fromList([0, 0.1, 0.2]),
        frameExposures: Float32List.fromList([0.01, double.nan, 0.01]),
      );
      final details = StabilizationDetails();

      stabilizationOfMotionTrack(track, downBody: _upright, details: details);

      expect(details.times, _closeToList([-0.001, 0.104, 0.199], 1e-9));
    });

    test('is null without frame times or samples', () {
      final samples = _samples(0, 0.1, (time) => (rate: (x: 0.0, y: 0.0, z: 0.0), acceleration: _upBody));
      final noFrames = CameraMotionTrack(
        source: CameraMotionSource.insta360Imu,
        timeOrigin: CameraMotionTimeOrigin.firstSample,
        samples: samples,
        frameTimes: Float64List(0),
        frameExposures: Float32List(0),
      );
      expect(stabilizationOfMotionTrack(noFrames), isNull);
      expect(stabilizationOfMotionTrack(_track(CameraMotionSamples.empty())), isNull);
    });
  });

  group('the sign of the correction', () {
    test('correction x camera = target for random orientations, the target level, the viewer sees the target', () {
      final random = math.Random(14);
      double unit() => 2 * random.nextDouble() - 1;
      List<double> randomQuaternion() {
        final q = [unit(), unit(), unit(), unit()];
        final n = math.sqrt(q.fold(0.0, (sum, v) => sum + v * v));
        return [for (final v in q) v / n];
      }

      const frames = 200;
      final times = Float64List.fromList([for (var i = 0; i < frames; i++) i / 30]);
      final orientations = Float64List(4 * frames);
      for (var i = 0; i < frames; i++) {
        orientations.setAll(4 * i, randomQuaternion());
      }
      final worldUp = [unit(), unit(), unit()];
      final viewToBody = _matrix(randomQuaternion());
      final details = StabilizationDetails();

      final table = stabilizationOfOrientations(
        CameraOrientationTrack(label: 'random', times: times, orientations: orientations, worldUp: worldUp),
        frameTimes: times,
        viewToBody: viewToBody,
        details: details,
      );

      expect(table!.length, frames);
      final upLength = math.sqrt(worldUp.fold(0.0, (sum, v) => sum + v * v));
      // The world of the table is the view of frame 0: G = R(q_0) B turns it into the world of the orientations
      final g = _matrix(_at(orientations, 0)) * viewToBody;
      final up = g.transposed.apply((x: worldUp[0] / upLength, y: worldUp[1] / upLength, z: worldUp[2] / upLength));
      for (var i = 0; i < frames; i++) {
        final k = _matrix(_at(table.corrections, i));
        // The camera, from the world to the view, from the inputs alone: (G^T R(q_i) B)^T
        final camera = (g.transposed * _matrix(_at(orientations, i)) * viewToBody).transposed;
        expect(_maxDifference(_matrix(_at(details.camera, i)), camera), lessThan(1e-9));
        final target = _matrix(_at(details.target, i));
        // k x camera = target
        expect(_maxDifference(k * camera, target), lessThan(1e-6), reason: 'frame $i');
        // The target is level: its down is the down of the world, its forward level
        final targetToWorld = target.transposed;
        final down = targetToWorld.apply((x: 0, y: 1, z: 0));
        expect(_dot(down, up), closeTo(-1, 1e-9));
        expect(_dot(targetToWorld.apply((x: 0, y: 0, z: 1)), up), closeTo(0, 1e-9));
        // The point of the stitched sphere at d, shown at k d, holds the world direction C d: a viewer looking at e
        // sees C k^-1 e = T e, the world as the target sees it
        for (var n = 0; n < 3; n++) {
          final e = (x: unit(), y: unit(), z: unit());
          final seen = camera.transposed.apply(k.transposed.apply(e));
          final wanted = targetToWorld.apply(e);
          expect([seen.x, seen.y, seen.z], _closeToList([wanted.x, wanted.y, wanted.z], 1e-6));
        }
      }
    });
  });

  group('the target', () {
    test('cancels a shake on a straight path: the heading stays, the horizon stays level', () {
      // The camera shakes about a slanted axis, 2 degrees at 5 Hz and 1 degree at 8 Hz, on a straight path
      const axis = (x: 1.0, y: 2.0, z: 3.0);
      double angle(double t) => 2 * _degree * math.sin(2 * math.pi * 5 * t) + _degree * math.sin(2 * math.pi * 8 * t);
      double rate(double t) =>
          2 * _degree * 2 * math.pi * 5 * math.cos(2 * math.pi * 5 * t) +
          _degree * 2 * math.pi * 8 * math.cos(2 * math.pi * 8 * t);
      final track = _track(_samples(-0.5, 20.5, _aboutAxis(axis, angle, rate)), seconds: 20);
      final details = StabilizationDetails();

      final table = stabilizationOfMotionTrack(track, downBody: _upright, details: details);

      final summary = table!.summary;
      expect(summary.meanCameraStepDegrees, greaterThan(1.2));
      expect(summary.cameraShakeDegrees, greaterThan(1));
      // What the viewer still sees turn: next to nothing
      expect(summary.meanViewStepDegrees, lessThan(0.01));
      // The half windows at both ends span less than a second
      expect(summary.levelWindowsKept, summary.levelWindows - 2);
      // At most the shake, 3 degrees, and the shake of the first frame, which the level of the stitch did not see
      expect(summary.largestCorrectionDegrees, lessThan(3.5));
      final headings = details.heading.toList();
      final pathHeading = headings.reduce((a, b) => a + b) / headings.length;
      // The true down of the world, in the world of the table (the view of frame 0)
      final firstBody = _axisAngle(axis, angle(details.times[0]));
      final g = firstBody * details.viewToBody;
      final trueDown = g.transposed.apply((x: 1, y: 0, z: 0));
      for (var i = 0; i < table.length; i++) {
        final targetToWorld = _matrix(_at(details.target, i)).transposed;
        final down = targetToWorld.apply((x: 0, y: 1, z: 0));
        expect(math.acos(_dot(down, trueDown).clamp(-1.0, 1.0)) / _degree, lessThan(0.05), reason: 'frame $i');
        // Straight ahead: the heading of the target stays where the path goes
        expect((details.smoothedHeading[i] - pathHeading).abs() / _degree, lessThan(0.05), reason: 'frame $i');
      }
    });

    test('follows a turn within the time constant of the heading, without lag', () {
      // Straight 5 s, a turn of 90 degrees to the right over 2 s at a constant rate, straight 5 s
      const turnRate = math.pi / 4;
      double angle(double t) => t < 5 ? 0 : (t < 7 ? turnRate * (t - 5) : math.pi / 2);
      double rate(double t) => t < 5 || t >= 7 ? 0 : turnRate;
      // Turning right is turning about the down of the upright camera, body +x
      final track = _track(_samples(-0.2, 12.2, _aboutAxis((x: 1, y: 0, z: 0), angle, rate)), seconds: 12);
      final details = StabilizationDetails();

      final table = stabilizationOfMotionTrack(track, downBody: _upright, details: details);

      expect(table, isNotNull);
      for (var i = 0; i < table!.length; i++) {
        final t = details.times[i];
        final heading = details.heading[i] / _degree;
        final smoothed = details.smoothedHeading[i] / _degree;
        // The rate jumps between two samples at the start and the end of the turn: 0.02 degree for 1 ms
        expect(heading, closeTo(angle(t) / _degree, 0.05), reason: 'camera heading at $t s');
        if (t < 1.5 || t > 10.5) {
          // Three and a half time constants away from the turn: on the heading of the road
          expect(smoothed, closeTo(heading, 1), reason: 'at $t s');
        }
        // Two sided: the target starts turning before the camera and ends after it, never more than the rate times
        // the time constant away
        expect((smoothed - heading).abs(), lessThan(45 * 1.0), reason: 'at $t s');
      }
      // Halfway through the turn the two meet: the smoothing has no lag
      final middle = details.times.indexed.firstWhere((e) => e.$2 >= 6).$1;
      expect(details.smoothedHeading[middle] / _degree, closeTo(details.heading[middle] / _degree, 1.5));
      expect(table.summary.headingRangeDegrees, closeTo(90, 0.05));
      // After the turn the correction is small again: the view looks down the new road
      expect(_angleBetween(_matrix(_at(table.corrections, table.length - 1)), Mat3.identity), lessThan(0.6));
    });

    test('levels slowly towards the accelerometer: the drift of the gyroscope goes, the turns of a vehicle do not', () {
      // The gyroscope reads a bias of 0.2 degree a second about the view's forward (body -z), 12 degrees over a
      // minute, while the camera stays still: the accelerometer stays level
      const bias = 0.2 * _degree;
      final track = _track(
        _samples(-0.5, 60.5, (time) => (rate: (x: 0.0, y: 0.0, z: -bias), acceleration: _upBody)),
        seconds: 60,
      );
      final details = StabilizationDetails();

      final table = stabilizationOfMotionTrack(track, downBody: _upright, details: details);
      final unlevelled = StabilizationDetails();
      stabilizationOfMotionTrack(
        track,
        downBody: _upright,
        options: const StabilizationOptions(levelMinNorm: 2, levelMaxNorm: 3),
        details: unlevelled,
      );

      expect(table!.summary.levelWindowsKept, table.summary.levelWindows - 2);
      double error(StabilizationDetails details, int i) {
        // The camera, as the gyroscope has it, rolls; the true down stays the down of its view
        final trueDown = _matrix(_at(details.camera, i)).transposed.apply((x: 0, y: 1, z: 0));
        final targetDown = _matrix(_at(details.target, i)).transposed.apply((x: 0, y: 1, z: 0));
        return math.acos(_dot(targetDown, trueDown).clamp(-1.0, 1.0)) / _degree;
      }

      final last = table.length - 1;
      // Without the accelerometer the horizon ends 12 degrees off
      expect(error(unlevelled, last), closeTo(12, 0.05));
      for (var i = 0; i < table.length; i++) {
        final t = details.times[i];
        // The two sided mean follows a steady drift exactly in the middle, where both sides are as long; towards the
        // ends one side is shorter and the mean lags, at most by the drift over a time constant (6 degrees here)
        expect(error(details, i), lessThan(t > 29 && t < 31 ? 0.25 : 6), reason: 'at $t s');
      }
      expect(error(details, last), lessThan(5));
    });

    test('leaves out the windows whose accelerometer is not near 1 g, and keeps the level of the stitch then', () {
      final track = _track(
        _samples(-0.5, 10.5, (time) => (rate: (x: 0.0, y: 0.0, z: 0.0), acceleration: (x: -0.7, y: 0.9, z: 0.0))),
        seconds: 10,
      );
      final details = StabilizationDetails();

      final table = stabilizationOfMotionTrack(track, downBody: _upright, details: details);

      expect(table!.summary.levelWindowsKept, 0);
      for (var i = 0; i < table.length; i++) {
        expect(_at(details.up, i, 3), _closeToList([0, -1, 0], 1e-12));
      }
      expect(table.summary.largestCorrectionDegrees, lessThan(1e-6));
    });

    test('holds the heading where the view looks straight up', () {
      // The camera pitches up by 90 degrees and back over 4 s: at the top the view forward has no azimuth
      double angle(double t) => math.pi / 2 * math.sin(math.pi * t / 4).abs();
      double rate(double t) => math.pi / 2 * math.pi / 4 * math.cos(math.pi * t / 4) * (t % 8 < 4 ? 1 : -1);
      // Pitching up is turning about the view's right, body +y: the forward (body -z) goes up (body -x)
      final track = _track(_samples(-0.2, 4.2, _aboutAxis((x: 0, y: 1, z: 0), angle, rate)), seconds: 4);
      final details = StabilizationDetails();

      final table = stabilizationOfMotionTrack(track, downBody: _upright, details: details);

      expect(table!.summary.headingHeldFrames, greaterThan(0));
      for (var i = 0; i < table.length; i++) {
        expect(details.heading[i].abs() / _degree, lessThan(1e-6), reason: 'frame $i');
      }
    });
  });

  group('real slices of the X3, X4 and X5 of lot a', () {
    final slices = {
      'X3 (walked trailer)': (insta360X3MotionSlice, insta360X3StabilizationSlice, false),
      'X4 (indexed trailer)': (insta360X4MotionSlice, insta360X4StabilizationSlice, true),
      'X5 (indexed trailer)': (insta360X5MotionSlice, insta360X5StabilizationSlice, true),
    };
    for (final MapEntry(key: name, value: (slice, expected, indexed)) in slices.entries) {
      test('gives the orientations and the corrections of the reference for the $name', () async {
        final file = _sliceVideo(slice, indexed: indexed);
        final details = StabilizationDetails();

        // Read chunk after chunk, 50 samples at a time
        final table = await readInsta360Stabilization(_reader(file), file.length, chunkLength: 1000, details: details);

        expect(table, isNotNull);
        expect(table!.length, expected.camera.length);
        expect(table.presentationTimesUs.first, 0);
        expect(
          details.viewToBody.values,
          _closeToList(bodyFrame(expected.downBody).values, 1e-6),
          reason: 'the level of the stitch, from the mean of the slice',
        );
        for (var i = 0; i < table.length; i++) {
          final camera = _at(details.camera, i);
          expect(camera, _closeToList(_aligned(expected.camera[i], camera), 1e-6), reason: 'camera at frame $i');
          final correction = _at(table.corrections, i);
          expect(
            correction,
            _closeToList(_aligned(expected.corrections[i], correction), 1e-6),
            reason: 'correction at frame $i',
          );
          expect(details.heading[i], closeTo(expected.heading[i], 1e-6));
          expect(details.smoothedHeading[i], closeTo(expected.smoothedHeading[i], 1e-6));
        }
        // The track read whole gives the same table as the chunks
        final whole = stabilizationOfMotionTrack(
          (await readInsta360Motion(_reader(file), file.length))!,
          chunkSamples: 7,
        );
        expect(whole!.corrections, table.corrections);
        expect(whole.presentationTimesUs, table.presentationTimesUs);
      });
    }
  });

  group('cameras that give their orientation', () {
    test('blends the orientations to the frame times: a constant rotation gives the exact angles', () {
      // 100 orientations a second turning at 0.8 rad/s about a slanted axis, frames at 30 a second
      const axis = (x: 0.3, y: 0.4, z: -0.5);
      final times = Float64List.fromList([for (var i = 0; i <= 300; i++) i / 100]);
      final orientations = Float64List(4 * times.length);
      for (var i = 0; i < times.length; i++) {
        orientations.setAll(4 * i, _quaternion(axis, 0.8 * times[i]));
      }
      final frameTimes = Float64List.fromList([for (var i = 0; i < 90; i++) 0.01 + i / 30]);
      final details = StabilizationDetails();

      final table = stabilizationOfOrientations(
        CameraOrientationTrack(label: 'GoPro CORI', times: times, orientations: orientations),
        frameTimes: frameTimes,
        viewToBody: Mat3.identity,
        details: details,
      );

      expect(table!.summary.source, 'GoPro CORI');
      expect(table.summary.framesOutsideSamples, 0);
      for (var i = 0; i < frameTimes.length; i++) {
        final expected = _axisAngle(axis, 0.8 * (frameTimes[i] - frameTimes[0]));
        expect(_maxDifference(_matrix(_at(details.camera, i)).transposed, expected), lessThan(1e-9));
      }
      // Frame times on the timeline: from frame 0
      expect(table.presentationTimesUs[1], 33333);
    });

    test('holds the first and last orientations outside the track, and counts those frames', () {
      final times = Float64List.fromList([1, 2]);
      final orientations = Float64List.fromList([1, 0, 0, 0, ..._quaternion((x: 0, y: 1, z: 0), 0.5)]);
      final details = StabilizationDetails();

      final table = stabilizationOfOrientations(
        CameraOrientationTrack(label: 'DJI attitude', times: times, orientations: orientations),
        frameTimes: Float64List.fromList([0, 0.5, 1, 1.5, 2, 2.5]),
        viewToBody: Mat3.identity,
        details: details,
      );

      expect(table!.summary.framesOutsideSamples, 3);
      expect(_quaternionAngle(_at(details.camera, 1)), closeTo(0, 1e-9));
      expect(_quaternionAngle(_at(details.camera, 3)), closeTo(0.25 / _degree, 1e-9));
      expect(_quaternionAngle(_at(details.camera, 5)), closeTo(0.5 / _degree, 1e-9));
    });

    // A camera whose world is not level: its world z is 10 degrees off the true up; it rolls slowly
    final tilt = _axisAngle((x: 1, y: 0, z: 0), 10 * _degree);
    final trueUpInWorld = tilt.apply((x: 0, y: 0, z: 1));
    final times = Float64List.fromList([for (var i = 0; i <= 600; i++) i / 30]);
    final orientations = Float64List(4 * times.length);
    for (var i = 0; i < times.length; i++) {
      orientations.setAll(4 * i, _quaternion((x: 0, y: 0, z: 1), 0.1 * times[i]));
    }

    void expectLevelledBy(StabilizationDetails details, Mat3 viewToBody) {
      final g = _matrix(_at(orientations, 0)) * viewToBody;
      final trueDown = g.transposed.apply((x: -trueUpInWorld.x, y: -trueUpInWorld.y, z: -trueUpInWorld.z));
      for (var i = 0; i < times.length; i++) {
        final down = _matrix(_at(details.target, i)).transposed.apply((x: 0, y: 1, z: 0));
        expect(math.acos(_dot(down, trueDown).clamp(-1.0, 1.0)) / _degree, lessThan(1e-3), reason: 'frame $i');
      }
    }

    // The view looks along body x, its down is body -z
    final viewToBody = Mat3.columns((x: 0, y: -1, z: 0), (x: 0, y: 0, z: -1), (x: 1, y: 0, z: 0));

    test('levels with the gravity the camera gives per frame (GoPro GRAV)', () {
      final gravity = Float32List(3 * times.length);
      for (var i = 0; i < times.length; i++) {
        // Gravity in the body: the true down of the world turned into the body, at any length
        final down = _matrix(
          _at(orientations, i),
        ).transposed.apply((x: -trueUpInWorld.x, y: -trueUpInWorld.y, z: -trueUpInWorld.z));
        gravity.setAll(3 * i, [9.81 * down.x, 9.81 * down.y, 9.81 * down.z]);
      }
      final details = StabilizationDetails();

      final table = stabilizationOfOrientations(
        CameraOrientationTrack(label: 'GoPro', times: times, orientations: orientations, gravity: gravity),
        frameTimes: times,
        viewToBody: viewToBody,
        details: details,
      );

      // The last window holds the last frame alone
      expect(table!.summary.levelWindowsKept, table.summary.levelWindows - 1);
      expectLevelledBy(details, viewToBody);
      // The level of the stitch was 10 degrees off
      expect(table.summary.largestLevelDegrees, closeTo(10, 1e-3));
    });

    test('levels with the up of its world when the camera gives one (DJI)', () {
      final details = StabilizationDetails();

      final table = stabilizationOfOrientations(
        CameraOrientationTrack(
          label: 'DJI',
          times: times,
          orientations: orientations,
          worldUp: [trueUpInWorld.x, trueUpInWorld.y, trueUpInWorld.z],
        ),
        frameTimes: times,
        viewToBody: viewToBody,
        details: details,
      );

      expect(table!.summary.levelWindows, 0);
      expectLevelledBy(details, viewToBody);
    });

    test('keeps the level of the stitch without gravity nor world up', () {
      final details = StabilizationDetails();

      stabilizationOfOrientations(
        CameraOrientationTrack(label: 'none', times: times, orientations: orientations),
        frameTimes: times,
        viewToBody: viewToBody,
        details: details,
      );

      for (var i = 0; i < times.length; i++) {
        expect(_at(details.up, i, 3), _closeToList([0, -1, 0], 1e-12));
      }
    });

    test('is null without frames or orientations', () {
      final track = CameraOrientationTrack(label: 'empty', times: Float64List(0), orientations: Float64List(0));
      expect(
        stabilizationOfOrientations(track, frameTimes: Float64List.fromList([0]), viewToBody: Mat3.identity),
        isNull,
      );
    });
  });

  group('StabilizationTable', () {
    final table = StabilizationTable(
      presentationTimesUs: Int64List.fromList([0, 40000, 80000]),
      corrections: Float32List.fromList([1, 0, 0, 0, ..._quaternion((x: 0, y: 0, z: 1), 0.4), 1, 0, 0, 0]),
      summary: const StabilizationSummary(source: 'test', frames: 3),
    );

    test('gives the correction of a frame at its time, blended between frames, held outside', () {
      expect(table.correctionAt(40000), _closeToList(_quaternion((x: 0, y: 0, z: 1), 0.4), 2e-7));
      expect(table.correctionAt(10000), _closeToList(_quaternion((x: 0, y: 0, z: 1), 0.1), 2e-7));
      expect(table.correctionAt(60000), _closeToList(_quaternion((x: 0, y: 0, z: 1), 0.2), 2e-7));
      expect(table.correctionAt(-5), [1, 0, 0, 0]);
      expect(table.correctionAt(1000000), [1, 0, 0, 0]);
    });

    test('blends along the shorter arc whatever the sign of the neighbours', () {
      expect(
        slerpQuaternion([1, 0, 0, 0], [-math.cos(0.2), 0, 0, -math.sin(0.2)], 0.5),
        _closeToList(_quaternion((x: 0, y: 0, z: 1), 0.2), 1e-12),
      );
    });

    test('is the identity when empty', () {
      final empty = StabilizationTable(
        presentationTimesUs: Int64List(0),
        corrections: Float32List(0),
        summary: const StabilizationSummary(source: 'empty', frames: 0),
      );
      expect(empty.correctionAt(0), [1, 0, 0, 0]);
    });

    test('puts frame i at i frame durations when given, 16 bytes of correction a frame, neighbours on one side', () {
      final track = _track(_samples(-0.1, 4.1, _aboutAxis((x: 0, y: 1, z: 0), (t) => 3 * t, (t) => 3)), seconds: 4);

      final timed = stabilizationOfMotionTrack(track, downBody: _upright, frameDurationUs: 1001000 / 30)!;

      expect(timed.presentationTimesUs.take(4), [0, 33367, 66733, 100100]);
      expect(timed.corrections.lengthInBytes, 16 * timed.length);
      for (var i = 1; i < timed.length; i++) {
        final a = _at(timed.corrections, i - 1);
        final b = _at(timed.corrections, i);
        expect(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3], greaterThan(0), reason: 'frame $i');
      }
      expect(timed.toString(), contains('Insta360 X4 gyroscope: 121 frames'));
    });
  });
}
