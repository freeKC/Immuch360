// The motion of an Insta360 camera in the trailer of its videos, for the stabilisation of the video at playback.
//
// Record 3 of the trailer holds the samples of the IMU, 1000 a second on the X3, X4 and X5. Raw samples (field 62 set,
// every camera since the X3) are 20 bytes: a u64 LE timestamp in microseconds, then the accelerometer x, y, z and the
// gyroscope x, y, z as u16 LE offset binary around 32768, scaled by the ranges of field 65 (32 g and 2000 degrees per
// second, so 1/1024 g and 0.061 degree per second a step). Older cameras write 56 byte samples: an i64 LE timestamp in
// milliseconds, then six doubles, the accelerometer in g and the gyroscope in radians per second (the units
// telemetry-parser reads them in; no such file was at hand). The samples are already corrected by the camera: the
// offsets of field 31 must not be taken off again.
//
// Record 4 has one entry per frame, 16 bytes: a u64 LE timestamp in microseconds on the clock of the samples (in
// milliseconds on the cameras of 56 byte samples, as field 24: the ONE X2 of lots/feat-raw-2026-48.md), then the
// exposure time of the frame in seconds as an f64 LE. It starts a few entries before the first frame of the video (4
// to 8 on the files measured: frames the camera did not keep); field 24 is the timestamp of the first frame, equal to
// one of the entries within 15 microseconds. Time 0 of the track is that frame; frame i of the video is the i-th entry
// from it, one every 1/fps second to within 40 microseconds.
//
// The IMU axes map to the body frame of dual_fisheye_math.dart as body x = IMU x, body y = IMU z, body z = -IMU y,
// the mapping the leveling already uses for the accelerometer (downBodyFromAccelerometer). Measured on real X3, X4 and
// X5 videos against the rotation of the picture itself: the integrated gyroscope matches it within 0.1 to 0.3 degree a
// frame, the mapping within 1 to 4 degrees, at a time offset of -8 to +4 ms from the frame entries. The ONE X2 follows
// it (0.25 degree a frame, -18 ms); a ONE RS with a 360 module does not: body x = IMU z, body y = IMU x, body z =
// IMU y (Insta360ImuAxes.oneRs360, 0.03 degree a frame on a ONE RS 1-Inch 360 Edition video, +7 ms).
//
// Pure Dart: the caller reads the bytes, from a file on the device or with HTTP range requests.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/raw/camera_motion.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart' show Insta360ImuAxes, insta360ImuAxesOf;
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart' show ByteRangeReader;
import 'package:logging/logging.dart';

final _log = Logger('Insta360Motion');

/// Most bytes of IMU samples read: about 27 minutes of raw samples at 1 kHz (1.2 MB a minute), 1.7 million samples
const insta360MaxMotionImuLength = 32 * 1024 * 1024;

/// Bytes of IMU samples read at once
const insta360MotionChunkLength = 4 * 1024 * 1024;

/// Most bytes of the frame record read: 16 bytes a frame, about 72 hours at 30 frames a second
const insta360MaxFrameRecordLength = 4 * 1024 * 1024;

const _rawSampleLength = 20;
const _sampleLength = 56;
const _rawZero = 32768;
const _frameEntryLength = 16;
const _footerLength = 6;
const _imuRecordId = 3;
const _frameRecordId = 4;

// The ranges of the X3, X4 and X5, taken when field 65 is missing
const _defaultAccelerometerRange = 32.0;
const _defaultGyroscopeRange = 2000.0;

// A frame entry this close to field 24, in microseconds, is the first frame of the video
const _firstFrameToleranceUs = 1000;

const _twoTo32 = 4294967296;

/// Receives the samples of a motion track chunk after chunk, in time order, instead of a track that holds them all: what
/// the stabilisation of a long recording needs (an hour of samples is about 115 MB once decoded)
abstract interface class CameraMotionSampleSink {
  /// Called once, before the first chunk, with the track whose samples are still to come (none in it)
  void begin(CameraMotionTrack track);

  /// The next samples, their times rising past those of the chunk before; the reader does not use these arrays again
  void add(CameraMotionSamples chunk);
}

/// Reads the motion track of the Insta360 video of [fileSize] bytes that [read] reads: the samples of the gyroscope and
/// the accelerometer in the body frame, and the time of each frame of the video, on the clock of the video (time 0 at
/// its first frame, field 24). Null for a file without a version 3 trailer or without IMU samples, or when the
/// directory of an indexed trailer does not match the footer of the IMU record.
///
/// Reads the trailer first (see [readInsta360TrailerRecords], without its mean accelerometer), then the frame record
/// whole and the IMU record [chunkLength] bytes at a time, at most [maxImuLength] bytes of it from its first sample
/// ([CameraMotionTrack.truncated] tells when there is more). Without field 24 time 0 is the first frame entry, without
/// frame entries the first sample (see [CameraMotionTrack.timeOrigin]). A sample whose time does not rise past the one
/// before, or with a value that is not a finite number, is left out and counted. Errors of [read] are not caught.
///
/// With a [sink], the samples of each chunk go to it as they are decoded and the track returned holds none: memory
/// stays one chunk of samples, whatever the length of the recording.
Future<CameraMotionTrack?> readInsta360Motion(
  ByteRangeReader read,
  int fileSize, {
  int maxImuLength = insta360MaxMotionImuLength,
  int chunkLength = insta360MotionChunkLength,
  CameraMotionSampleSink? sink,
}) async {
  final records = await readInsta360TrailerRecords(read, fileSize, maxImuLength: 0);
  final imu = records?.imu;
  if (records == null || imu == null) {
    return null;
  }
  final trailer = records.trailer;
  final sampleLength = trailer.isRawGyro ? _rawSampleLength : _sampleLength;
  final available = imu.length ~/ sampleLength;
  final count = math.min(available, math.max(0, maxImuLength) ~/ sampleLength);
  if (count == 0) {
    return null;
  }
  if (trailer.indexed && !await _footerMatches(read, imu, _imuRecordId)) {
    _log.warning('Insta360 motion: the footer of the IMU record does not match its directory entry');
    return null;
  }

  // The cameras of raw samples write the frame record and field 24 in microseconds, the older ones in milliseconds, as
  // their samples
  final unitUs = trailer.isRawGyro ? 1 : 1000;
  final entries = [
    for (final entry in await _frameEntries(read, records.frames, indexed: trailer.indexed))
      (timeUs: entry.timeUs * unitUs, exposure: entry.exposure),
  ];
  final firstFrame = trailer.firstFrameTimestamp == null ? null : trailer.firstFrameTimestamp! * unitUs;
  final step = math.max(1, math.max(1, chunkLength) ~/ sampleLength) * sampleLength;
  final axes = insta360ImuAxesOf(
    trailer.cameraModel,
    twoLenses: trailer.offsetV3 != null || trailer.offsetV6 != null || trailer.offsetV1 != null,
  );
  final decoder = _SampleDecoder(
    raw: trailer.isRawGyro,
    oneRs360: axes == Insta360ImuAxes.oneRs360,
    accelerometerRange: trailer.accelerometerRange ?? _defaultAccelerometerRange,
    gyroscopeRange: trailer.gyroscopeRange ?? _defaultGyroscopeRange,
    capacity: sink == null ? count : math.min(count, step ~/ sampleLength),
  );
  if (trailer.isRawGyro && (trailer.accelerometerRange == null || trailer.gyroscopeRange == null)) {
    _log.warning('Insta360 motion: no IMU ranges in the trailer, the ones of the X3 to X5 are taken');
  }

  // Time 0: the first frame of the video, else the first frame entry, else the first sample (known once decoded)
  final CameraMotionTimeOrigin timeOrigin;
  double? originUs;
  var frames = entries;
  if (firstFrame != null) {
    timeOrigin = CameraMotionTimeOrigin.firstFrame;
    originUs = firstFrame.toDouble();
    final first = entries.indexWhere((entry) => entry.timeUs >= firstFrame - _firstFrameToleranceUs);
    frames = first < 0 ? const [] : entries.sublist(first);
    if (frames.isNotEmpty && (frames.first.timeUs - firstFrame).abs() > _firstFrameToleranceUs) {
      _log.warning('Insta360 motion: no frame entry at the first frame (${frames.first.timeUs} for $firstFrame us)');
    }
  } else if (entries.isNotEmpty) {
    timeOrigin = CameraMotionTimeOrigin.firstFrameEntry;
    originUs = entries.first.timeUs.toDouble();
  } else {
    timeOrigin = CameraMotionTimeOrigin.firstSample;
  }

  CameraMotionTrack trackOf(CameraMotionSamples samples, double originUs, {required bool truncated}) {
    final frameTimes = Float64List(frames.length);
    final frameExposures = Float32List(frames.length);
    for (var i = 0; i < frames.length; i++) {
      frameTimes[i] = (frames[i].timeUs - originUs) / 1e6;
      frameExposures[i] = frames[i].exposure;
    }
    return CameraMotionTrack(
      source: CameraMotionSource.insta360Imu,
      timeOrigin: timeOrigin,
      samples: samples,
      frameTimes: frameTimes,
      frameExposures: frameExposures,
      cameraModel: trailer.cameraModel,
      firmware: trailer.firmware,
      rollingShutterMs: trailer.rollingShutterMs,
      truncated: truncated,
      droppedSamples: decoder.dropped,
    );
  }

  final end = imu.start + count * sampleLength;
  var begun = false;
  for (var offset = imu.start; offset < end; offset += step) {
    final length = math.min(step, end - offset);
    final bytes = await read(offset, length);
    decoder.add(
      bytes.length < length ? Uint8List.sublistView(bytes, 0, bytes.length - bytes.length % sampleLength) : bytes,
    );
    if (sink != null && decoder.kept > 0) {
      final origin = originUs ??= decoder.firstTimeUs;
      if (!begun) {
        begun = true;
        sink.begin(trackOf(CameraMotionSamples.empty(), origin, truncated: false));
      }
      sink.add(decoder.take(origin));
    }
    if (bytes.length < length) {
      _log.warning('Insta360 motion: the IMU record ends early, ${decoder.read} of $count samples read');
      break;
    }
  }
  if (decoder.total == 0) {
    return null;
  }
  originUs ??= decoder.firstTimeUs;
  final track = trackOf(
    sink == null ? decoder.samples(originUs) : CameraMotionSamples.empty(),
    originUs,
    truncated: available > count || decoder.read < count,
  );
  _log.info('Insta360 motion: $track');
  return track;
}

/// An entry of the frame record: the time of the frame on the clock of the samples, its exposure in seconds
typedef _FrameEntry = ({int timeUs, double exposure});

// The entries of the frame record [place], those whose time rises past the one before; none without the record, or
// when the footer of an indexed one does not match its directory entry
Future<List<_FrameEntry>> _frameEntries(
  ByteRangeReader read,
  Insta360RecordPlace? place, {
  required bool indexed,
}) async {
  if (place == null || place.length < _frameEntryLength) {
    return const [];
  }
  final length = math.min(place.length, insta360MaxFrameRecordLength) ~/ _frameEntryLength * _frameEntryLength;
  final withFooter = indexed && length == place.length;
  final bytes = await read(place.start, length + (withFooter ? _footerLength : 0));
  if (bytes.length < length) {
    return const [];
  }
  if (withFooter && !_isFooter(bytes, length, place, _frameRecordId)) {
    _log.warning('Insta360 motion: the footer of the frame record does not match its directory entry');
    return const [];
  }
  final data = ByteData.sublistView(bytes);
  final entries = <_FrameEntry>[];
  for (var offset = 0; offset + _frameEntryLength <= length; offset += _frameEntryLength) {
    final timeUs = data.getUint32(offset, Endian.little) + data.getUint32(offset + 4, Endian.little) * _twoTo32;
    if (entries.isNotEmpty && timeUs <= entries.last.timeUs) {
      continue;
    }
    entries.add((timeUs: timeUs, exposure: data.getFloat64(offset + 8, Endian.little)));
  }
  return entries;
}

// Whether the footer after the payload of [place] names it, as its directory entry does
Future<bool> _footerMatches(ByteRangeReader read, Insta360RecordPlace place, int id) async {
  final footer = await read(place.start + place.length, _footerLength);
  return footer.length == _footerLength && _isFooter(footer, 0, place, id);
}

bool _isFooter(Uint8List bytes, int offset, Insta360RecordPlace place, int id) {
  final data = ByteData.sublistView(bytes, offset, offset + _footerLength);
  return data.getUint8(0) == place.format && data.getUint8(1) == id && data.getUint32(2, Endian.little) == place.length;
}

/// Decodes IMU samples chunk after chunk into the arrays of the body frame
class _SampleDecoder {
  _SampleDecoder({
    required this.raw,
    required this.oneRs360,
    required double accelerometerRange,
    required double gyroscopeRange,
    required int capacity,
  }) : _accelerometerScale = accelerometerRange / _rawZero,
       _gyroscopeScale = gyroscopeRange / _rawZero * math.pi / 180,
       _timesUs = Float64List(capacity),
       _rates = Float32List(3 * capacity),
       _accelerations = Float32List(3 * capacity);

  final bool raw;

  /// Whether the IMU lies as on a ONE RS with a 360 module ([Insta360ImuAxes.oneRs360]), else as on the X series
  final bool oneRs360;
  final double _accelerometerScale;
  final double _gyroscopeScale;

  Float64List _timesUs;
  Float32List _rates;
  Float32List _accelerations;

  /// Samples decoded, kept or not
  int read = 0;

  /// Samples kept in the arrays, since the last [take]
  int kept = 0;

  /// Samples kept in all
  int total = 0;

  /// Samples left out
  int dropped = 0;

  /// Time of the first sample kept, of the last one
  double firstTimeUs = 0;
  double _lastTimeUs = double.negativeInfinity;

  // Whether the arrays went out with a chunk
  bool _taken = false;

  void add(Uint8List bytes) {
    if (_taken) {
      final capacity = _timesUs.length;
      _timesUs = Float64List(capacity);
      _rates = Float32List(3 * capacity);
      _accelerations = Float32List(3 * capacity);
      _taken = false;
    }
    final data = ByteData.sublistView(bytes);
    final sampleLength = raw ? _rawSampleLength : _sampleLength;
    for (var offset = 0; offset + sampleLength <= bytes.length && kept < _timesUs.length; offset += sampleLength) {
      read++;
      final double timeUs;
      final double ax;
      final double ay;
      final double az;
      final double gx;
      final double gy;
      final double gz;
      if (raw) {
        timeUs =
            data.getUint32(offset, Endian.little) + data.getUint32(offset + 4, Endian.little) * _twoTo32.toDouble();
        ax = (data.getUint16(offset + 8, Endian.little) - _rawZero) * _accelerometerScale;
        ay = (data.getUint16(offset + 10, Endian.little) - _rawZero) * _accelerometerScale;
        az = (data.getUint16(offset + 12, Endian.little) - _rawZero) * _accelerometerScale;
        gx = (data.getUint16(offset + 14, Endian.little) - _rawZero) * _gyroscopeScale;
        gy = (data.getUint16(offset + 16, Endian.little) - _rawZero) * _gyroscopeScale;
        gz = (data.getUint16(offset + 18, Endian.little) - _rawZero) * _gyroscopeScale;
      } else {
        // A signed 64 bit count of milliseconds, read as two 32 bit halves (no getInt64 on the web)
        timeUs =
            (data.getUint32(offset, Endian.little) + data.getInt32(offset + 4, Endian.little) * _twoTo32.toDouble()) *
            1000;
        ax = data.getFloat64(offset + 8, Endian.little);
        ay = data.getFloat64(offset + 16, Endian.little);
        az = data.getFloat64(offset + 24, Endian.little);
        gx = data.getFloat64(offset + 32, Endian.little);
        gy = data.getFloat64(offset + 40, Endian.little);
        gz = data.getFloat64(offset + 48, Endian.little);
      }
      if (timeUs <= _lastTimeUs ||
          !(ax.isFinite && ay.isFinite && az.isFinite && gx.isFinite && gy.isFinite && gz.isFinite)) {
        dropped++;
        continue;
      }
      if (total == 0) {
        firstTimeUs = timeUs;
      }
      _lastTimeUs = timeUs;
      _timesUs[kept] = timeUs;
      final i = 3 * kept;
      if (oneRs360) {
        // Body x = IMU z, body y = IMU x, body z = IMU y
        _rates[i] = gz;
        _rates[i + 1] = gx;
        _rates[i + 2] = gy;
        _accelerations[i] = az;
        _accelerations[i + 1] = ax;
        _accelerations[i + 2] = ay;
      } else {
        // Body x = IMU x, body y = IMU z, body z = -IMU y
        _rates[i] = gx;
        _rates[i + 1] = gz;
        _rates[i + 2] = -gy;
        _accelerations[i] = ax;
        _accelerations[i + 1] = az;
        _accelerations[i + 2] = -ay;
      }
      kept++;
      total++;
    }
  }

  /// The samples kept since the last call, their times in seconds from [originUs]; the arrays are the chunk's, new
  /// ones take the next samples
  CameraMotionSamples take(double originUs) {
    final chunk = samples(originUs);
    kept = 0;
    _taken = true;
    return chunk;
  }

  /// The samples kept, their times in seconds from [originUs]
  CameraMotionSamples samples(double originUs) {
    final times = Float64List(kept);
    for (var i = 0; i < kept; i++) {
      times[i] = (_timesUs[i] - originUs) / 1e6;
    }
    return CameraMotionSamples(
      times: times,
      rotationRates: kept == _timesUs.length
          ? _rates
          : Float32List.fromList(Float32List.sublistView(_rates, 0, 3 * kept)),
      accelerations: kept == _timesUs.length
          ? _accelerations
          : Float32List.fromList(Float32List.sublistView(_accelerations, 0, 3 * kept)),
    );
  }
}
