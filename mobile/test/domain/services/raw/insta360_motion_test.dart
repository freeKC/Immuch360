import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/camera_motion.dart';
import 'package:immich_mobile/domain/services/raw/insta360_motion.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import '../../../fixtures/raw/insta360.stub.dart';
import '../../../fixtures/raw/insta360_motion_slices.dart';

/// Reads [file] as a local file or a server does: fewer bytes at the end, none past it. Records each read.
ByteRangeReader _reader(Uint8List file, [List<(int, int)>? reads]) => (offset, length) async {
  reads?.add((offset, length));
  if (offset >= file.length) {
    return Uint8List(0);
  }
  return Uint8List.sublistView(file, offset, math.min(file.length, offset + length));
};

Future<CameraMotionTrack?> _motion(
  Uint8List file, {
  List<(int, int)>? reads,
  int maxImuLength = insta360MaxMotionImuLength,
  int chunkLength = insta360MotionChunkLength,
}) => readInsta360Motion(_reader(file, reads), file.length, maxImuLength: maxImuLength, chunkLength: chunkLength);

// The bytes of an MP4 of no consequence, before an indexed trailer
final _mp4 = [0, 0, 0, 8, ...'free'.codeUnits];

/// The metadata of a video: model, firmware, first frame time (field 24), rolling shutter time (25), raw samples (62),
/// IMU ranges (65), a V3 calibration string (54)
List<int> _videoMetadata({
  String model = x3Model,
  String firmware = x3Firmware,
  int? firstFrame = 1000000,
  double rollingShutterMs = 15.727346420288086,
  bool rawGyro = true,
  bool withRanges = true,
  String? offsetV3,
}) => [
  ...pbStringField(1, x3Serial),
  ...pbStringField(2, model),
  ...pbStringField(3, firmware),
  if (offsetV3 != null) ...pbStringField(54, offsetV3),
  if (firstFrame != null) ...pbVarintField(24, firstFrame),
  ...pbDoubleField(25, rollingShutterMs),
  ...pbVarintField(62, rawGyro ? 1 : 0),
  if (withRanges) ...pbBytesField(65, [...pbVarintField(1, 32), ...pbVarintField(2, 2000)]),
];

/// A video with a walked trailer as the X3 writes it: frames, IMU, a thumbnail, then the metadata next to the tail
Uint8List _x3Video({required List<int> metadata, List<int>? imu, List<int>? frames}) => insta360File([
  if (frames != null) insta360Record(4, frames),
  if (imu != null) insta360Record(3, imu),
  insta360Record(2, List.filled(300, 0x55)),
  insta360Record(1, metadata, format: 1),
], body: _mp4);

/// A video with an indexed trailer as the X4 and X5 write it, the records padded to 128 KiB
Uint8List _x5Video({required List<int> metadata, List<int>? imu, List<int>? frames, bool badImuFooter = false}) =>
    Uint8List.fromList([
      ..._mp4,
      ...insta360IndexedTail(
        metadata: metadata,
        imu: imu,
        frames: frames,
        padTo: 128 * 1024,
        badImuFooter: badImuFooter,
      ),
    ]);

/// Ten raw samples a millisecond apart from 1 s on, still but for [gyro] (raw steps from 32768 about the IMU x, y, z
/// axes) and an accelerometer of 1 g along IMU -y
List<int> _stillSamples({(int, int, int) gyro = (0, 0, 0), int count = 10, int start = 1000000}) => rawImuSamplesAt(
  [for (var i = 0; i < count; i++) start + 1000 * i],
  [for (var i = 0; i < count; i++) (32768, 32768 - 1024, 32768, 32768 + gyro.$1, 32768 + gyro.$2, 32768 + gyro.$3)],
);

/// The frame entries of a 30 fps video whose first frame is at 1 s, with two frames before it
List<int> _frames({int count = 5}) =>
    insta360FrameEntries([for (var i = -2; i < count; i++) 1000000 + 33368 * i], exposure: 0.0004);

const _gyroStep = 2000 / 32768 * math.pi / 180;

Matcher _closeToList(List<double> expected, double delta) => predicate<List<double>>(
  (values) =>
      values.length == expected.length &&
      [for (var i = 0; i < values.length; i++) (values[i] - expected[i]).abs() <= delta].every((close) => close),
  'a list within $delta of $expected',
);

List<double> _sums(Float32List values) {
  final sums = [0.0, 0.0, 0.0];
  for (var i = 0; i < values.length; i++) {
    sums[i % 3] += values[i];
  }
  return sums;
}

/// Keeps what a reader gives it, chunk after chunk
class _RecordingSink implements CameraMotionSampleSink {
  final calls = <String>[];
  final chunks = <CameraMotionSamples>[];
  CameraMotionTrack? track;

  @override
  void begin(CameraMotionTrack track) {
    calls.add('begin');
    this.track = track;
  }

  @override
  void add(CameraMotionSamples chunk) {
    calls.add('add');
    chunks.add(chunk);
  }
}

void main() {
  group('readInsta360Motion on slices of real videos', () {
    final slices = {
      'X3 (walked trailer)': (insta360X3MotionSlice, false),
      'X4 (indexed trailer)': (insta360X4MotionSlice, true),
      'X5 (indexed trailer)': (insta360X5MotionSlice, true),
    };
    for (final MapEntry(key: name, value: (slice, indexed)) in slices.entries) {
      test('reads the samples and the frames of the $name as the prototype of the study does', () async {
        final metadata = _videoMetadata(
          model: slice.model,
          firmware: slice.firmware,
          firstFrame: slice.firstFrameTimestamp,
          rollingShutterMs: slice.rollingShutterMs,
        );
        final file = indexed
            ? _x5Video(metadata: metadata, imu: slice.imu, frames: slice.frames)
            : _x3Video(metadata: metadata, imu: slice.imu, frames: slice.frames);

        final track = await _motion(file);

        expect(track, isNotNull);
        expect(track!.source, CameraMotionSource.insta360Imu);
        expect(track.timeOrigin, CameraMotionTimeOrigin.firstFrame);
        expect(track.cameraModel, slice.model);
        expect(track.firmware, slice.firmware);
        expect(track.rollingShutterMs, slice.rollingShutterMs);
        expect(track.truncated, isFalse);
        expect(track.droppedSamples, 0);
        expect(track.samples.length, slice.sampleCount);
        expect(track.samples.times.first, closeTo(slice.firstTime, 1e-9));
        expect(track.samples.times.last, closeTo(slice.lastTime, 1e-9));
        expect(track.sampleRate, closeTo(1000, 5));
        // Stored as 32 bit floats: about 1e-7 of each value, 200 of them summed
        expect(_sums(track.samples.rotationRates), _closeToList(slice.rateSums, 1e-4));
        expect(_sums(track.samples.accelerations), _closeToList(slice.accelerationSums, 1e-4));
        expect(track.samples.rotationRates.sublist(0, 3), _closeToList(slice.firstRates, 1e-6));
        // The two entries before the first frame are left out: frame 0 is at time 0
        expect(track.frameTimes, _closeToList(slice.frameTimes, 1e-9));
        expect(track.frameTimes.first, closeTo(0, 2e-5));
        expect(track.frameExposures, _closeToList(slice.frameExposures, 1e-9));
      });
    }
  });

  group('readInsta360Motion', () {
    test('maps the IMU axes to the body frame: body x = IMU x, body y = IMU z, body z = -IMU y', () async {
      final track = await _motion(
        _x3Video(
          metadata: _videoMetadata(),
          imu: _stillSamples(gyro: (100, 200, 300)),
          frames: _frames(),
        ),
      );

      final rates = track!.samples.rotationRates;
      expect(rates.sublist(0, 3), _closeToList([100 * _gyroStep, 300 * _gyroStep, -200 * _gyroStep], 1e-7));
      // 1 g along IMU -y is 1 g along body +z
      expect(track.samples.accelerations.sublist(0, 3), _closeToList([0, 0, 1], 1e-7));
    });

    test('puts time 0 on the first frame of field 24 and leaves the frame entries before it out', () async {
      final track = await _motion(_x3Video(metadata: _videoMetadata(), imu: _stillSamples(), frames: _frames()));

      expect(track!.timeOrigin, CameraMotionTimeOrigin.firstFrame);
      expect(track.samples.times.first, 0);
      expect(track.samples.times[9], closeTo(0.009, 1e-12));
      expect(track.frameTimes, _closeToList([0, 0.033368, 0.066736, 0.100104, 0.133472], 1e-12));
      expect(track.frameExposures, everyElement(closeTo(0.0004, 1e-9)));
    });

    test('without field 24, puts time 0 on the first frame entry', () async {
      final track = await _motion(
        _x3Video(metadata: _videoMetadata(firstFrame: null), imu: _stillSamples(), frames: _frames()),
      );

      expect(track!.timeOrigin, CameraMotionTimeOrigin.firstFrameEntry);
      expect(track.frameTimes.length, 7);
      expect(track.frameTimes.first, 0);
      expect(track.samples.times.first, closeTo(2 * 0.033368, 1e-12));
    });

    test('without field 24 nor frame record, puts time 0 on the first sample and lists no frame', () async {
      final track = await _motion(
        _x3Video(metadata: _videoMetadata(firstFrame: null), imu: _stillSamples(start: 7000)),
      );

      expect(track!.timeOrigin, CameraMotionTimeOrigin.firstSample);
      expect(track.samples.times.first, 0);
      expect(track.frameTimes, isEmpty);
      expect(track.frameExposures, isEmpty);
    });

    test('with field 24 but no frame record, keeps the first frame as time 0 and lists no frame', () async {
      final track = await _motion(_x3Video(metadata: _videoMetadata(), imu: _stillSamples()));

      expect(track!.timeOrigin, CameraMotionTimeOrigin.firstFrame);
      expect(track.frameTimes, isEmpty);
    });

    test('reads the samples of doubles of the older cameras: milliseconds, g and radians per second', () async {
      final samples = [
        for (var i = 0; i < 4; i++) ...[
          ...u64le(1000 + 2 * i),
          ...f64le(0.1),
          ...f64le(-0.9),
          ...f64le(0.2),
          ...f64le(0.5),
          ...f64le(-0.25),
          ...f64le(0.125),
        ],
      ];
      final track = await _motion(
        _x3Video(metadata: _videoMetadata(firstFrame: null, rawGyro: false, withRanges: false), imu: samples),
      );

      expect(track!.samples.length, 4);
      expect(track.samples.times, _closeToList([0, 0.002, 0.004, 0.006], 1e-12));
      expect(track.samples.rotationRates.sublist(0, 3), _closeToList([0.5, 0.125, 0.25], 1e-7));
      expect(track.samples.accelerations.sublist(0, 3), _closeToList([0.1, 0.2, 0.9], 1e-7));
    });

    test('reads the frames of the older cameras in milliseconds, as their samples, field 24 too', () async {
      // As the ONE X2 of the lot writes them: samples of doubles 2 ms apart, the frame record and field 24 in
      // milliseconds, entries before the first frame (6983, 7016, 8085) the video does not keep
      List<int> sample(int ms) => [
        ...u64le(ms),
        ...f64le(0.1),
        ...f64le(-0.9),
        ...f64le(0.2),
        for (var i = 0; i < 3; i++) ...f64le(0),
      ];
      final samples = [for (var ms = 8300; ms < 8420; ms += 2) ...sample(ms)];
      final frames = insta360FrameEntries([6983, 7016, 8085, 8308, 8341, 8375, 8408], exposure: 0.0005);

      final track = (await _motion(
        _x3Video(
          metadata: _videoMetadata(firstFrame: 8308, rawGyro: false, withRanges: false),
          imu: samples,
          frames: frames,
        ),
      ))!;

      expect(track.timeOrigin, CameraMotionTimeOrigin.firstFrame);
      expect(track.frameTimes, _closeToList([0, 0.033, 0.067, 0.1], 1e-9));
      expect(track.samples.times.first, closeTo(-0.008, 1e-9));
      expect(track.samples.times.last, closeTo(0.110, 1e-9));
    });

    test('turns the IMU of a ONE RS with a 360 module by its own axes: body x = IMU z, y = IMU x, z = IMU y', () async {
      Future<CameraMotionTrack> read(String model, {String? offsetV3 = x3OffsetV3}) async => (await _motion(
        _x3Video(
          metadata: _videoMetadata(model: model, offsetV3: offsetV3),
          imu: _stillSamples(gyro: (100, 0, 0)),
          frames: _frames(),
        ),
      ))!;

      final rs = await read('Insta360 OneRS');
      final x3 = await read(x3Model);
      final flat = await read('Insta360 OneRS', offsetV3: null);

      // A turn about IMU x, the accelerometer 1 g along IMU -y
      expect(rs.samples.rotationRates.sublist(0, 3), _closeToList([0, 100 * _gyroStep, 0], 1e-6));
      expect(rs.samples.accelerations.sublist(0, 3), _closeToList([0, 0, -1], 1e-9));
      expect(x3.samples.rotationRates.sublist(0, 3), _closeToList([100 * _gyroStep, 0, 0], 1e-6));
      expect(x3.samples.accelerations.sublist(0, 3), _closeToList([0, 0, 1], 1e-9));
      expect(flat.samples.rotationRates.sublist(0, 3), x3.samples.rotationRates.sublist(0, 3), reason: 'one lens');
    });

    test('leaves out the samples whose time does not rise, and those that are not finite numbers', () async {
      final raw = rawImuSamplesAt([
        1000000,
        1001000,
        1001000,
        1000500,
        1002000,
      ], List.filled(5, (32768, 32768, 32768 + 1024, 32768, 32768, 32768)));
      final rawTrack = await _motion(_x3Video(metadata: _videoMetadata(), imu: raw));
      expect(rawTrack!.samples.times, _closeToList([0, 0.001, 0.002], 1e-12));
      expect(rawTrack.droppedSamples, 2);

      List<int> sample(int ms, double value) => [...u64le(ms), for (var i = 0; i < 6; i++) ...f64le(value)];
      final doubles = [...sample(1, 0.5), ...sample(2, double.nan), ...sample(3, double.infinity), ...sample(4, 0.5)];
      final doubleTrack = await _motion(
        _x3Video(metadata: _videoMetadata(firstFrame: null, rawGyro: false), imu: doubles),
      );
      expect(doubleTrack!.samples.length, 2);
      expect(doubleTrack.droppedSamples, 2);
    });

    test('reads the IMU record in chunks of whole samples, the same samples as at once', () async {
      final file = _x3Video(
        metadata: _videoMetadata(),
        imu: _stillSamples(gyro: (5, -7, 9), count: 50),
      );
      final whole = await _motion(file);
      final reads = <(int, int)>[];

      final chunked = await _motion(file, reads: reads, chunkLength: 7 * 20 + 3);

      expect(chunked!.samples.times, whole!.samples.times);
      expect(chunked.samples.rotationRates, whole.samples.rotationRates);
      expect(chunked.samples.accelerations, whole.samples.accelerations);
      // 50 samples, 7 a read
      expect(reads.where((read) => read.$2 == 140).length, 7);
      expect(reads.where((read) => read.$2 == 20).length, 1);
    });

    test('gives the samples to a sink chunk after chunk, the same as read whole, and keeps none itself', () async {
      final file = _x3Video(
        metadata: _videoMetadata(),
        imu: [
          ..._stillSamples(gyro: (5, -7, 9), count: 30),
          // A sample whose time does not rise, left out in the middle of a chunk
          ...rawImuSamplesAt([1029000], [(32768, 32768, 32768, 32768, 32768, 32768)]),
          ..._stillSamples(gyro: (1, 2, 3), count: 20, start: 1030000),
        ],
        frames: _frames(),
      );
      final whole = await _motion(file);
      final sink = _RecordingSink();

      final streamed = await readInsta360Motion(_reader(file), file.length, chunkLength: 7 * 20, sink: sink);

      expect(sink.calls.first, 'begin');
      expect(sink.calls.where((call) => call == 'begin').length, 1);
      // 51 samples, 7 a chunk
      expect(sink.chunks.length, 8);
      expect(sink.track!.samples.isEmpty, isTrue);
      expect(sink.track!.frameTimes, whole!.frameTimes);
      expect(sink.track!.timeOrigin, whole.timeOrigin);
      expect(Float64List.fromList([for (final chunk in sink.chunks) ...chunk.times]), whole.samples.times);
      expect(
        Float32List.fromList([for (final chunk in sink.chunks) ...chunk.rotationRates]),
        whole.samples.rotationRates,
      );
      expect(
        Float32List.fromList([for (final chunk in sink.chunks) ...chunk.accelerations]),
        whole.samples.accelerations,
      );
      expect(streamed!.samples.isEmpty, isTrue);
      expect(streamed.droppedSamples, 1);
      expect(streamed.truncated, isFalse);
      expect(streamed.frameTimes, whole.frameTimes);
    });

    test('with a sink and neither field 24 nor frames, puts time 0 on the first sample kept', () async {
      final sink = _RecordingSink();
      final file = _x3Video(metadata: _videoMetadata(firstFrame: null), imu: _stillSamples(start: 7000, count: 12));

      final streamed = await readInsta360Motion(_reader(file), file.length, chunkLength: 5 * 20, sink: sink);

      expect(streamed!.timeOrigin, CameraMotionTimeOrigin.firstSample);
      expect(sink.track!.timeOrigin, CameraMotionTimeOrigin.firstSample);
      expect(sink.chunks.first.times.first, 0);
      expect(sink.chunks.last.times.last, closeTo(0.011, 1e-12));
    });

    test('reads at most maxImuLength bytes of samples, from the first, and says the track is cut short', () async {
      final track = await _motion(
        _x3Video(metadata: _videoMetadata(), imu: _stillSamples(count: 100)),
        maxImuLength: 30 * 20 + 7,
      );

      expect(track!.samples.length, 30);
      expect(track.samples.times.last, closeTo(0.029, 1e-12));
      expect(track.truncated, isTrue);
    });

    test('takes the ranges of the X3 to X5 when the trailer gives none', () async {
      final track = await _motion(
        _x3Video(
          metadata: _videoMetadata(withRanges: false),
          imu: _stillSamples(gyro: (16384, 0, 0)),
        ),
      );

      expect(track!.samples.rotationRates[0], closeTo(1000 * math.pi / 180, 1e-5));
    });

    test('reads the records of an indexed trailer, padded apart', () async {
      final reads = <(int, int)>[];
      final track = await _motion(
        _x5Video(
          metadata: _videoMetadata(model: x5Model),
          imu: _stillSamples(),
          frames: _frames(),
        ),
        reads: reads,
      );

      expect(track!.cameraModel, x5Model);
      expect(track.samples.length, 10);
      expect(track.frameTimes.length, 5);
    });

    test('is null for an indexed trailer whose IMU footer does not match its directory entry', () async {
      final track = await _motion(
        _x5Video(
          metadata: _videoMetadata(model: x5Model),
          imu: _stillSamples(),
          badImuFooter: true,
        ),
      );

      expect(track, isNull);
    });

    test('is null for a file without trailer, without IMU record, or with less than one sample', () async {
      expect(await _motion(Uint8List.fromList([..._mp4, ...List.filled(100, 0)])), isNull);
      expect(await _motion(_x3Video(metadata: _videoMetadata(), frames: _frames())), isNull);
      expect(await _motion(_x3Video(metadata: _videoMetadata(), imu: List.filled(19, 0))), isNull);
      expect(await _motion(_x3Video(metadata: _videoMetadata(), imu: _stillSamples()), maxImuLength: 0), isNull);
    });
  });

  group('readInsta360TrailerRecords', () {
    test('gives the first frame time, the rolling shutter time and the places of the IMU and frame records', () async {
      for (final file in [
        _x3Video(metadata: _videoMetadata(), imu: _stillSamples(), frames: _frames()),
        _x5Video(metadata: _videoMetadata(), imu: _stillSamples(), frames: _frames()),
      ]) {
        final records = await readInsta360TrailerRecords(_reader(file), file.length, maxImuLength: 0);

        expect(records!.trailer.firstFrameTimestamp, 1000000);
        expect(records.trailer.rollingShutterMs, 15.727346420288086);
        expect(records.trailer.meanAccelerometer, isNull);
        expect(records.imu!.length, 200);
        expect(records.frames!.length, 7 * 16);
        // The payloads are where the places say
        final firstSample = ByteData.sublistView(file, records.imu!.start, records.imu!.start + 8);
        expect(firstSample.getUint32(0, Endian.little), 1000000);
        final firstEntry = ByteData.sublistView(file, records.frames!.start, records.frames!.start + 8);
        expect(firstEntry.getUint32(0, Endian.little), 1000000 - 2 * 33368);
      }
    });

    test('readInsta360Trailer still stops its walk at the IMU record: one footer read less', () async {
      // 80 KB of samples: the footer of the frame record before them is out of the first read of the tail
      final file = _x3Video(metadata: _videoMetadata(), imu: _stillSamples(count: 4000), frames: _frames());
      final trailerReads = <(int, int)>[];
      final recordsReads = <(int, int)>[];

      final trailer = await readInsta360Trailer(_reader(file, trailerReads), file.length);
      final records = await readInsta360TrailerRecords(_reader(file, recordsReads), file.length);

      expect(trailer!.firstFrameTimestamp, 1000000);
      expect(trailer.meanAccelerometer, isNotNull);
      expect(records!.frames, isNotNull);
      expect(records.trailer.meanAccelerometer, trailer.meanAccelerometer);
      expect(trailerReads.where((read) => read.$2 == 6), isEmpty);
      expect(recordsReads.where((read) => read.$2 == 6).length, 1);
      expect(recordsReads.length, trailerReads.length + 1);
    });
  });
}
