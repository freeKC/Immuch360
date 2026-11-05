import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/camera_motion.dart';
import 'package:immich_mobile/domain/services/raw/dji_motion.dart';
import 'package:immich_mobile/domain/services/raw/dji_osv.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import '../../../fixtures/raw/dji_motion_slices.dart';
import '../../../fixtures/raw/dji_osv.stub.dart';
import '../../../fixtures/raw/insta360.stub.dart';

ByteRangeReader _reader(Uint8List file, [List<(int, int)>? reads]) => (offset, length) async {
  reads?.add((offset, length));
  final start = math.min(offset, file.length);
  return Uint8List.sublistView(file, start, math.min(file.length, start + length));
};

Uint8List _file(List<int> records) => djiOsvFile(camd: djiCamdBox(records));

Future<CameraMotionTrack?> _read(
  Uint8List file, {
  List<(int, int)>? reads,
  int maxLength = djiMaxMotionLength,
  int chunkLength = djiMotionChunkLength,
  double attitudeDelayUs = djiAttitudeDelayUs,
}) => readDjiMotion(
  _reader(file, reads),
  file.length,
  maxLength: maxLength,
  chunkLength: chunkLength,
  attitudeDelayUs: attitudeDelayUs,
);

// The real records of the kept frames of the sample
List<(List<int>, List<int>)> _realFrames() => [
  for (final (attitude, second) in djiMotionSliceRecords) (base64.decode(attitude), base64.decode(second)),
];

// The frame time stamp of frame 0 of the sample, and the low 32 bits of the time stamp of its first attitude sample
const _frameStamp0 = 18471494232;
const _runStamp0 = 1291624387;
const _twoTo32 = 0x100000000;

// The quaternion of a turn of [degrees] about the unit [axis]
List<double> _turn(List<double> axis, double degrees) {
  final half = degrees * math.pi / 360;
  final s = math.sin(half);
  return [math.cos(half), axis[0] * s, axis[1] * s, axis[2] * s];
}

List<double> _multiply(List<double> a, List<double> b) => [
  a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
  a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
  a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
  a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
];

List<double> _conjugate(List<double> q) => [q[0], -q[1], -q[2], -q[3]];

// The orientation of frame [frame] of [track]
List<double> _orientation(CameraMotionTrack track, int frame) => [
  for (var k = 0; k < 4; k++) track.frameOrientations![4 * frame + k],
];

// The angle in degrees between two orientations, whatever their signs and the rounding of their norms: that of a* b
double _angle(List<double> a, List<double> b) {
  final r = _multiply(_conjugate(a), b);
  return 2 * math.atan2(math.sqrt(r[1] * r[1] + r[2] * r[2] + r[3] * r[3]), r[0].abs()) * 180 / math.pi;
}

// The axis of the rotation that takes the body at frame [a] to the body at frame [b], in the body frame at [a], and
// its angle in degrees: q_a* q_b
({List<double> axis, double degrees}) _relative(CameraMotionTrack track, int a, int b) {
  final r = _multiply(_conjugate(_orientation(track, a)), _orientation(track, b));
  final sign = r[0] < 0 ? -1.0 : 1.0;
  final s = math.sqrt(r[1] * r[1] + r[2] * r[2] + r[3] * r[3]);
  return (axis: [for (var k = 1; k < 4; k++) sign * r[k] / s], degrees: 2 * math.atan2(s, r[0].abs()) * 180 / math.pi);
}

// A run of [count] attitude samples turning about the camera [axis] by 0.1 degree a sample from [startDegrees]
List<List<double>> _run(List<double> axis, {double startDegrees = 0, int count = 40}) => [
  for (var m = 0; m < count; m++) _turn(axis, startDegrees + 0.1 * m),
];

// Frames of attitude records [attitude], each with the record of the second track after it
List<(List<int>, List<int>)> _withSecondTrack(List<List<int>> attitude) => [
  for (final (i, record) in attitude.indexed) (record, djiSecondTrackRecord(index: 2 * i)),
];

// The body orientation the reader gives for the camera quaternion [q]: q times the turn from the body to the camera
// axes, (0.5, 0.5, -0.5, -0.5)
List<double> _body(List<double> q) => _multiply(q, const [0.5, 0.5, -0.5, -0.5]);

Matcher _sameOrientation(List<double> expected, [double degrees = 1e-4]) => predicate<List<double>>(
  (q) => _angle(q, expected) <= degrees,
  'an orientation within $degrees degree of $expected',
);

void main() {
  group('readDjiMotion, real records of an Osmo 360 video', () {
    test('gives the frame times and the orientations of the reference reader', () async {
      final track = await _read(_file(djiMotionCamdRecords(_realFrames())));

      expect(track, isNotNull);
      expect(track!.source, CameraMotionSource.djiAttitude);
      expect(track.timeOrigin, CameraMotionTimeOrigin.firstFrame);
      expect((track.cameraModel, track.firmware), (djiModel, djiFirmware));
      expect(track.samples.isEmpty, isTrue);
      expect(track.sampleRate, isNull);
      expect(track.frameExposures, isEmpty);
      expect((track.truncated, track.droppedSamples), (false, 0));
      expect(track.frameTimes, hasLength(djiMotionSliceFrames.length));
      for (var i = 0; i < djiMotionSliceFrames.length; i++) {
        expect(track.frameTimes[i], closeTo(djiMotionSliceTimes[i], 1e-9), reason: 'frame ${djiMotionSliceFrames[i]}');
        final q = _orientation(track, i);
        expect(q, _sameOrientation(djiMotionSliceOrientations[i]), reason: 'frame ${djiMotionSliceFrames[i]}');
        expect(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3], closeTo(1, 1e-6));
      }
    });

    test('reads the same chunk after chunk, with records cut between two reads', () async {
      final file = _file(djiMotionCamdRecords(_realFrames()));
      final reads = <(int, int)>[];

      final whole = (await _read(file))!;
      final chunked = (await _read(file, reads: reads, chunkLength: 1024))!;

      expect(chunked.frameTimes, whole.frameTimes);
      expect(chunked.frameOrientations, whole.frameOrientations);
      expect(reads.where((read) => read.$2 == 1024).length, greaterThan(5), reason: '$reads');
    });

    test('takes the quaternion of the frame, 19 ms after its time stamp, only with no time for the attitude', () async {
      // The picture of the sample fits the attitude 8 to 9 ms after the time stamp; the quaternion per frame is that of
      // the middle of the run, about 19 ms after it
      final atFrameQuaternion = (await _read(_file(djiMotionCamdRecords(_realFrames())), attitudeDelayUs: 19400))!;

      for (var i = 0; i < djiMotionSliceFrames.length; i++) {
        expect(_orientation(atFrameQuaternion, i), _sameOrientation(djiMotionSliceFrameQuaternions[i], 0.06));
      }
      final apart = [
        for (var i = 0; i < djiMotionSliceFrames.length; i++)
          _angle(djiMotionSliceFrameQuaternions[i], djiMotionSliceOrientations[i]),
      ];
      expect(apart.reduce(math.max), greaterThan(0.5), reason: 'the camera shakes within a frame: $apart');
    });

    test('keeps the frames before a damaged record, and tells when the media data is longer than read', () async {
      final frames = _realFrames();
      final records = djiMotionCamdRecords(frames);
      // A record whose length says 4 GiB after the first two frames, then a good record
      final damaged = [
        ...djiMotionCamdRecords(frames.sublist(0, 2)),
        ...pbKey(3, 2),
        0xff,
        0xff,
        0xff,
        0xff,
        0x0f,
        ...pbBytesField(3, frames[2].$1),
      ];

      final cut = await _read(_file(damaged));
      final capped = await _read(_file(records), maxLength: records.length - 1500);

      expect(cut!.frameTimes, [0, closeTo(0.04, 1e-12)]);
      expect(cut.truncated, isFalse);
      expect(capped!.truncated, isTrue);
      expect(capped.frameTimes.length, lessThan(djiMotionSliceFrames.length));
      expect(_orientation(capped, 0), _sameOrientation(djiMotionSliceOrientations[0]));
    });
  });

  group('readDjiMotion, records built to measure', () {
    test('turns each camera axis (x forward, y right, z down) into its body axis', () async {
      // Body x right, y down, z along the rear lens: forward is -z, the right of the camera -x, down +y
      const bodyAxes = [
        ([1.0, 0.0, 0.0], [0.0, 0.0, -1.0]),
        ([0.0, 1.0, 0.0], [-1.0, 0.0, 0.0]),
        ([0.0, 0.0, 1.0], [0.0, 1.0, 0.0]),
      ];
      for (final (axis, bodyAxis) in bodyAxes) {
        final records = [
          for (var k = 0; k < 2; k++)
            djiAttitudeRecord(
              frameStampUs: _frameStamp0 + 40002 * k,
              index: 2 * k,
              runStampUs: _runStamp0 + 40160 * k,
              run: _run(axis, startDegrees: 4.0 * k),
            ),
        ];

        final track = (await _read(_file(djiMotionCamdRecords(_withSecondTrack(records)))))!;

        final turn = _relative(track, 0, 1);
        // 4 degrees from run to run, less the 158 us the run starts later than the frame (40160 against 40002)
        expect(turn.degrees, closeTo(4.0 - 0.1 * 158 / 1004, 1e-4), reason: 'camera axis $axis');
        expect(turn.axis, [for (final v in bodyAxis) closeTo(v, 1e-6)], reason: 'camera axis $axis');
      }
    });

    test('interpolates the run at the frame time stamp plus the delay, on samples 1004 us apart', () async {
      const forward = [1.0, 0.0, 0.0];
      final records = [
        djiAttitudeRecord(frameStampUs: _frameStamp0, runStampUs: _runStamp0, run: _run(forward)),
        djiAttitudeRecord(
          frameStampUs: _frameStamp0 + 40002,
          index: 2,
          runStampUs: _runStamp0 + 40160,
          run: _run(forward, startDegrees: 4),
        ),
      ];

      final track = (await _read(_file(djiMotionCamdRecords(_withSecondTrack(records)))))!;
      final early = (await _read(_file(djiMotionCamdRecords(_withSecondTrack(records))), attitudeDelayUs: -1e6))!;
      final late = (await _read(_file(djiMotionCamdRecords(_withSecondTrack(records))), attitudeDelayUs: 1e6))!;

      // Frame 0: the first sample 661 us before the frame time stamp, so 8.5 ms after it is sample 9.1245
      expect(_orientation(track, 0), _sameOrientation(_body(_turn(forward, 0.91245)), 1e-5));
      // Frame 1: its stamp is 40002 us on, its run 40160 us on
      expect(_orientation(track, 1), _sameOrientation(_body(_turn(forward, 4 + 0.1 * (9161 - 158) / 1004)), 1e-5));
      // Out of the run: its first or its last sample
      expect(_orientation(early, 0), _sameOrientation(_body(_turn(forward, 0))));
      expect(_orientation(late, 1), _sameOrientation(_body(_turn(forward, 7.9))));
    });

    test('measures the sample step from two runs and lifts the 32 bit stamps across their wrap', () async {
      const down = [0.0, 0.0, 1.0];
      // The frame stamp is 300 us past a multiple of 2^32, the stamp of the run 361 us before the wrap of its 32 bits
      const frameStamp = 5 * _twoTo32 + 300;
      final records = [
        djiAttitudeRecord(frameStampUs: frameStamp, runStampUs: _twoTo32 - 361, run: _run(down, count: 25)),
        djiAttitudeRecord(
          frameStampUs: frameStamp + 40000,
          index: 2,
          runStampUs: 40000 - 361,
          run: _run(down, startDegrees: 10, count: 25),
        ),
      ];

      final track = (await _read(_file(djiMotionCamdRecords(_withSecondTrack(records)))))!;

      // Frame 0 takes the step of the sample file, 1004 us: 9161 / 1004 samples in; frame 1 the step of the runs,
      // 40000 / 25 = 1600 us: 9161 / 1600 samples in
      expect(_orientation(track, 0), _sameOrientation(_body(_turn(down, 0.1 * 9161 / 1004)), 1e-5));
      expect(_orientation(track, 1), _sameOrientation(_body(_turn(down, 10 + 0.1 * 9161 / 1600)), 1e-5));
      expect(track.frameTimes, [0, closeTo(0.04, 1e-12)]);
    });

    test('places the frames by their time stamps: a gap, a stamp that does not move on, another frame rate', () async {
      List<int> record(int stamp, {double rate = 25}) => djiAttitudeRecord(
        frameStampUs: stamp,
        runStampUs: (stamp - 661) % _twoTo32,
        run: _run(const [1, 0, 0]),
        frameRate: rate,
      );

      final gap = (await _read(
        _file(
          djiMotionCamdRecords(
            _withSecondTrack([record(_frameStamp0), record(_frameStamp0 + 40002), record(_frameStamp0 + 120006)]),
          ),
        ),
      ))!;
      final repeated = (await _read(
        _file(
          djiMotionCamdRecords(
            _withSecondTrack([record(_frameStamp0), record(_frameStamp0 + 40002), record(_frameStamp0 + 40002)]),
          ),
        ),
      ))!;
      final thirty = (await _read(
        _file(
          djiMotionCamdRecords(
            _withSecondTrack([for (var k = 0; k < 4; k++) record(_frameStamp0 + (k * 1e6 / 30).round(), rate: 30)]),
          ),
        ),
      ))!;

      expect(gap.frameTimes, [0, closeTo(0.04, 1e-12), closeTo(0.12, 1e-12)]);
      expect((repeated.frameTimes.length, repeated.droppedSamples), (2, 1));
      expect(thirty.frameTimes, [for (var k = 0; k < 4; k++) closeTo(k / 30, 1e-12)]);
    });

    test('takes the quaternion of the frame without time stamps, else the middle of the run', () async {
      final frameQuaternion = _turn(const [0, 1, 0], 30);
      final withFrameQuaternion = djiAttitudeRecord(
        runStampUs: _runStamp0,
        run: _run(const [1, 0, 0]),
        frameQuaternion: frameQuaternion,
      );
      final runOnly = djiAttitudeRecord(run: _run(const [1, 0, 0]));
      final frameOnly = djiAttitudeRecord(frameStampUs: _frameStamp0, frameQuaternion: frameQuaternion);

      for (final (record, expected) in [
        (withFrameQuaternion, frameQuaternion),
        (runOnly, _turn(const [1, 0, 0], 2.0)),
        (frameOnly, frameQuaternion),
      ]) {
        final track = (await _read(_file(djiMotionCamdRecords(_withSecondTrack([record])))))!;

        expect(track.frameTimes, [0]);
        expect(_orientation(track, 0), _sameOrientation(_body(expected), 1e-5));
      }
    });

    test('keeps consecutive orientations on the same side, whatever the sign the camera wrote', () async {
      const forward = [1.0, 0.0, 0.0];
      final negated = [
        for (final q in _run(forward, startDegrees: 4)) [for (final v in q) -v],
      ];
      final records = [
        djiAttitudeRecord(frameStampUs: _frameStamp0, runStampUs: _runStamp0, run: _run(forward)),
        djiAttitudeRecord(frameStampUs: _frameStamp0 + 40002, runStampUs: _runStamp0 + 40160, run: negated),
      ];

      final track = (await _read(_file(djiMotionCamdRecords(_withSecondTrack(records)))))!;

      final a = _orientation(track, 0);
      final b = _orientation(track, 1);
      expect(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3], greaterThan(0.99));
    });

    test('gives nothing without a camd box or without attitude in it', () async {
      final noCamd = djiOsvFile(camd: const []);
      final noAttitude = _file(
        djiMotionCamdRecords([(djiSecondTrackRecord(), djiSecondTrackRecord()), (djiSecondTrackRecord(), [])]),
      );
      final emptyRuns = _file(djiMotionCamdRecords(_withSecondTrack([djiAttitudeRecord(frameStampUs: _frameStamp0)])));

      expect(await _read(noCamd), isNull);
      expect(await _read(noAttitude), isNull);
      expect(await _read(emptyRuns), isNull);
    });
  });

  group('findDjiCamdMdat', () {
    test('gives the place of the media data of the camd box, as the calibration reads it', () async {
      final records = djiMotionCamdRecords(_realFrames());
      final file = _file(records);

      final mdat = (await findDjiCamdMdat(_reader(file), fileSize: file.length))!;

      expect(mdat.length, records.length);
      expect(file.sublist(mdat.start, mdat.start + mdat.length!), records);
      expect(mdat.head, records.sublist(0, mdat.head.length));
      expect((await readDjiOsvCalibration(_reader(file)))?.firmware, djiFirmware);
    });
  });

  test('a track checks the length of its orientations', () {
    expect(
      () => CameraMotionTrack(
        source: CameraMotionSource.djiAttitude,
        timeOrigin: CameraMotionTimeOrigin.firstFrame,
        samples: CameraMotionSamples.empty(),
        frameTimes: Float64List(2),
        frameExposures: Float32List(0),
        frameOrientations: Float32List(4),
      ),
      throwsA(isA<AssertionError>()),
    );
    // The rotation of an orientation is that of dual_fisheye_math.dart
    final m = quaternionMatrix(0.5, 0.5, -0.5, -0.5)!.values;
    expect(m, [0, 0, -1, -1, 0, 0, 0, 1, 0].map((v) => closeTo(v, 1e-12)).toList());
  });
}
