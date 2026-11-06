// The attitude of a DJI Osmo 360 in its .osv videos, for the stabilisation of the video at playback.
//
// The per frame records of the mdat of the camd box (field 3, see dji_osv.dart) come two per frame, one for each djmd
// track; the first of each pair holds the attitude:
//
// - 1-1 (as a path inside the record): the index of the record, two a frame (0, 2, 4...; absent for frame 0, the
//   default value of protobuf); 1-2: the time stamp of the frame, microseconds of the camera clock, a varint;
// - 3-2-1: a run of attitude samples, about 1000 a second (40 a frame at 25 frames a second): 1 the time stamp of the
//   first sample, the low 32 bits of the same clock (it wraps every 71.6 minutes); 2 a counter; 3 repeated, one
//   quaternion a sample, w, x, y and z as fixed32 floats; samples 1004 microseconds apart on the sample file;
// - 2-9: one quaternion for the frame, the middle sample of the run (sample 20 of 40);
// - 4-1-5: the frame rate, a float.
//
// The header record of the first track (field 1 of the mdat) holds the time stamp of the first frame of the video in
// 1-9. Frame n of the video is the record whose stamp is n frame durations after it: a frame is counted from the first
// frame of the file, not from the first record kept, so a record that is missing, damaged or without attitude leaves
// a gap and the frames after it keep their place on the timeline of the video (the player looks the table up by the
// presentation time of each frame). Without that stamp, the first record kept is frame (1-1) / 2.
//
// The quaternions take the axes of the camera (x forward along the front lens, y to the right, z down) to a world
// frame whose z is down along gravity. The reader gives them in the body frame of the app (dual_fisheye_math.dart:
// x to the right, y down, z along the optical axis of lens 0, the rear lens of the Osmo 360), from the world to the
// body as the motion track has them: p = (q q_c)^-1 = q_c^-1 q^-1, q_c = (0.5, 0.5, -0.5, -0.5) the turn from the
// body to the axes of the camera, so a body direction v is q q_c v q_c^-1 q^-1 in the world.
//
// Measured on a real Osmo 360 video (firmware 10.00.05.06, 585 frames at 25 frames a second, a motorbike ride) against
// the rotation of the picture itself, from frame to frame, in both lenses: the axes above within 2 to 4 degrees, and
// the picture fits the attitude 8 to 9 ms after the time stamp of its frame. There the residual is 0.27 degree a frame
// on the front lens (0.44 on the rear one, which sees the rider), against 1.01 degree of motion of the picture. The
// quaternion per frame (2-9), 19 ms after the time stamp, leaves 1.08 degree: worse than no correction at all, the
// engine shakes the camera that fast. So the orientation of a frame is the attitude at its time stamp +
// [djiAttitudeDelayUs], interpolated in the run of its record; 2-9 is only taken without the times, and the middle of
// the run without 2-9.
//
// The fusion of the camera leans with the motion: on the sample, the front lens is level in the picture all along,
// but the attitude puts it 20 degrees up at the start, 8 degrees after 2 seconds, within 4 degrees after 4 seconds
// (the ride was speeding up). The orientations are good from frame to frame; their horizon only after a few seconds.
//
// Pure Dart: the caller reads the bytes, from a file on the device or with HTTP range requests.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/raw/camera_motion.dart';
import 'package:immich_mobile/domain/services/raw/dji_osv.dart';
import 'package:immich_mobile/domain/services/raw/protobuf_reader.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart' show ByteRangeReader;
import 'package:logging/logging.dart';

final _log = Logger('DjiMotion');

/// Most bytes of the media data of the camd box read: about 37 minutes at 25 frames a second (30 KB a second)
const djiMaxMotionLength = 64 * 1024 * 1024;

/// Bytes of the media data of the camd box read at once
const djiMotionChunkLength = 4 * 1024 * 1024;

/// Time from the time stamp of a frame to the attitude its picture fits, in microseconds: 8 ms on the rear lens, 9 ms
/// on the front one, measured on a real Osmo 360 video
const djiAttitudeDelayUs = 8500.0;

/// Time between two attitude samples when the file does not give two runs to measure it, in microseconds (the sample
/// file: 1004)
const djiAttitudeSampleStepUs = 1004.0;

// The frame rate taken when the records do not give it
const _defaultFrameRate = 25.0;

// A sample step measured from two runs is taken between these, in microseconds; another value is a gap
const _minSampleStepUs = 500.0;
const _maxSampleStepUs = 2000.0;

// A frame further than this from the first frame of the file (about 25 hours at 25 frames a second) is taken as a
// stamp of another clock
const _maxFrameIndex = 1 << 21;

// A record longer than this is taken as damaged media data
const _maxRecordLength = 1024 * 1024;

const _twoTo32 = 0x100000000;

// The rotation from the body frame of the app to the axes of the camera (x forward, y right, z down), w x y z
const _bodyToCamera = [0.5, 0.5, -0.5, -0.5];

/// Reads the attitude of the DJI Osmo 360 video of [fileSize] bytes that [read] reads: an orientation for each frame of
/// the video, from the world to the body frame ([CameraMotionTrack.frameOrientations]), and the time of each frame on
/// the timeline of the video (time 0 at the first frame of the file, whether or not its record was kept: a frame n
/// frame durations after it is at n / frame rate), from the per frame records of the camd box, [chunkLength] bytes at a time, at most [maxLength] bytes of them ([CameraMotionTrack.truncated] tells when
/// there are more). The orientation of a frame is the attitude [attitudeDelayUs] microseconds after its time stamp.
/// Null for a file without a camd box or without attitude in it. A record whose frame does not come after the one
/// before is left out and counted in [CameraMotionTrack.droppedSamples]. Errors of [read] are not caught.
Future<CameraMotionTrack?> readDjiMotion(
  ByteRangeReader read,
  int fileSize, {
  int maxLength = djiMaxMotionLength,
  int chunkLength = djiMotionChunkLength,
  double attitudeDelayUs = djiAttitudeDelayUs,
}) async {
  final mdat = await findDjiCamdMdat(read, fileSize: fileSize);
  if (mdat == null) {
    return null;
  }
  final available = math.min(mdat.length ?? fileSize - mdat.start, fileSize - mdat.start);
  final length = math.max(0, math.min(available, maxLength));
  final collector = _AttitudeCollector(attitudeDelayUs);
  final step = math.max(1024, chunkLength);
  var pending = Uint8List(0);
  var offset = 0;
  while (offset < length) {
    final want = math.min(step, length - offset);
    final chunk = await read(mdat.start + offset, want);
    offset += chunk.length;
    final bytes = pending.isEmpty
        ? chunk
        : (BytesBuilder(copy: false)
                ..add(pending)
                ..add(chunk))
              .takeBytes();
    final used = _walkRecords(bytes, collector);
    if (used < 0) {
      _log.warning(
        'Dji motion: damaged records before byte $offset of the camd media data, the frames before are kept',
      );
      pending = Uint8List(0);
      break;
    }
    pending = Uint8List.fromList(Uint8List.sublistView(bytes, used));
    if (pending.length > _maxRecordLength + 32) {
      _log.warning('Dji motion: no whole record in the last ${pending.length} bytes read, the frames before are kept');
      pending = Uint8List(0);
      break;
    }
    if (chunk.length < want) {
      _log.warning('Dji motion: the media data of the camd box ends early, $offset of $length bytes read');
      break;
    }
  }
  if (pending.isNotEmpty && offset >= available) {
    _log.info('Dji motion: the last record of the camd box is cut short (${pending.length} bytes)');
  }
  final track = collector.track(truncated: available > length);
  if (track == null) {
    _log.info('Dji motion: no attitude in the camd box');
    return null;
  }
  _log.info('Dji motion: $track');
  return track;
}

// Hands the whole top level fields at the start of [bytes] to [collector]; returns how many bytes they took, or -1 at
// damaged bytes
int _walkRecords(Uint8List bytes, _AttitudeCollector collector) {
  var offset = 0;
  while (offset < bytes.length) {
    final key = _varint(bytes, offset);
    if (key == null) {
      return offset;
    }
    final number = key.value >> 3;
    final wireType = key.value & 7;
    var end = key.end;
    var payloadStart = end;
    switch (wireType) {
      case protoVarint:
        final value = _varint(bytes, end);
        if (value == null) {
          return offset;
        }
        end = value.end;
      case protoFixed64:
        end += 8;
      case protoFixed32:
        end += 4;
      case protoLengthDelimited:
        final size = _varint(bytes, end);
        if (size == null) {
          return offset;
        }
        if (size.value < 0 || size.value > _maxRecordLength) {
          return -1;
        }
        payloadStart = size.end;
        end = size.end + size.value;
      default:
        return -1;
    }
    if (number == 0) {
      return -1;
    }
    if (end > bytes.length) {
      return offset;
    }
    if (wireType == protoLengthDelimited && (number == 1 || number == 3)) {
      final payload = Uint8List.sublistView(bytes, payloadStart, end);
      if (number == 3) {
        collector.add(payload);
      } else {
        collector.header(payload);
      }
    }
    offset = end;
  }
  return offset;
}

// The varint at [offset] of [bytes] and the offset after it; null when the bytes end before it does
({int value, int end})? _varint(Uint8List bytes, int offset) {
  var value = 0;
  for (var shift = 0, i = offset; shift < 64 && i < bytes.length; shift += 7, i++) {
    final byte = bytes[i];
    value |= (byte & 0x7f) << shift;
    if (byte & 0x80 == 0) {
      return (value: value, end: i + 1);
    }
  }
  return null;
}

/// What a per frame record says of the attitude
class _AttitudeRecord {
  int? recordIndex;
  int? frameStampUs;
  int? runStampUs;
  final List<double> run = [];
  List<double>? frameQuaternion;
  double? frameRate;

  int get runLength => run.length ~/ 4;
}

// The record [bytes], null when it holds no attitude (the record of the second track)
_AttitudeRecord? _parseRecord(Uint8List bytes) {
  final record = _AttitudeRecord();
  for (final field in protoFieldsLenient(bytes)) {
    if (field.wireType != protoLengthDelimited) {
      continue;
    }
    final payload = field.bytes!;
    switch (field.number) {
      case 1:
        record.frameStampUs ??= _firstVarint(payload, 2);
        record.recordIndex ??= _firstVarint(payload, 1) ?? 0;
      case 2:
        if (record.frameQuaternion == null) {
          final message = protoPath(payload, [9]);
          record.frameQuaternion = message == null ? null : _quaternion(message);
        }
      case 3:
        if (record.run.isEmpty) {
          _readRun(payload, record);
        }
      case 4:
        if (record.frameRate == null) {
          final message = protoPath(payload, [1]);
          if (message != null) {
            for (final sub in protoFieldsLenient(message)) {
              final value = sub.float32;
              if (sub.number == 5 && value != null && value.isFinite && value > 0) {
                record.frameRate = value;
                break;
              }
            }
          }
        }
    }
  }
  return record.run.isEmpty && record.frameQuaternion == null ? null : record;
}

// The first run of attitude samples of field 3 of a record (3-2-1), with its time stamp
void _readRun(Uint8List field3, _AttitudeRecord record) {
  for (final level2 in protoFieldsLenient(field3)) {
    if (level2.number != 2 || level2.wireType != protoLengthDelimited) {
      continue;
    }
    for (final run in protoFieldsLenient(level2.bytes!)) {
      if (run.number != 1 || run.wireType != protoLengthDelimited) {
        continue;
      }
      int? stamp;
      final samples = <double>[];
      for (final field in protoFieldsLenient(run.bytes!)) {
        if (field.number == 1 && field.wireType == protoVarint) {
          stamp ??= field.integer;
        } else if (field.number == 3 && field.wireType == protoLengthDelimited) {
          final q = _quaternion(field.bytes!);
          if (q != null) {
            samples.addAll(q);
          }
        }
      }
      if (samples.isNotEmpty) {
        record.runStampUs = stamp;
        record.run.addAll(samples);
        return;
      }
    }
  }
}

// The first varint field [number] of [message]
int? _firstVarint(Uint8List message, int number) {
  for (final field in protoFieldsLenient(message)) {
    if (field.number == number && field.wireType == protoVarint) {
      return field.integer;
    }
  }
  return null;
}

// A quaternion message: w (1), x (2), y (3), z (4) as floats, normalised; null unless all four are there and make a
// rotation
List<double>? _quaternion(Uint8List message) {
  double? w;
  double? x;
  double? y;
  double? z;
  for (final field in protoFieldsLenient(message)) {
    final value = field.float32;
    if (value == null || !value.isFinite) {
      continue;
    }
    switch (field.number) {
      case 1:
        w ??= value;
      case 2:
        x ??= value;
      case 3:
        y ??= value;
      case 4:
        z ??= value;
    }
  }
  if (w == null || x == null || y == null || z == null) {
    return null;
  }
  final norm = math.sqrt(w * w + x * x + y * y + z * z);
  if (!(norm > 0.5 && norm < 1.5)) {
    return null;
  }
  return [w / norm, x / norm, y / norm, z / norm];
}

/// Turns the attitude records, in their order, into a frame time and an orientation each
class _AttitudeCollector {
  _AttitudeCollector(this.delayUs);

  final double delayUs;
  final List<int> _frameIndices = [];
  final List<double> _orientations = [];
  _AttitudeRecord? _previous;
  int _frameIndex = -1;
  double? _frameRate;
  double _sampleStepUs = djiAttitudeSampleStepUs;
  int _dropped = 0;
  bool _fromRuns = false;
  bool _fromFrameQuaternions = false;
  String? _model;
  String? _firmware;
  bool _headerRead = false;

  // The time stamp of the first frame of the video (1-9 of the first header), microseconds of the camera clock
  int? _startStampUs;

  /// The first header record: the name of the camera (1-10), its firmware (1-6) and the time stamp of the first frame
  /// of the video (1-9)
  void header(Uint8List bytes) {
    if (_headerRead) {
      return;
    }
    _headerRead = true;
    final info = protoPath(bytes, [1]);
    if (info == null) {
      return;
    }
    for (final field in protoFieldsLenient(info)) {
      if (field.number == 9 && field.wireType == protoVarint) {
        _startStampUs ??= field.integer;
        continue;
      }
      if (field.wireType != protoLengthDelimited) {
        continue;
      }
      final text = field.string?.trim();
      if (text == null || text.isEmpty) {
        continue;
      }
      if (field.number == 10) {
        _model ??= text;
      } else if (field.number == 6) {
        _firmware ??= text;
      }
    }
  }

  void add(Uint8List bytes) {
    final record = _parseRecord(bytes);
    if (record == null) {
      return;
    }
    _frameRate ??= record.frameRate;
    final previous = _previous;

    // The frame of the video: as many frame durations after the first frame of the file as its stamp says, else after
    // the frame before, else one after it; the first record kept without a stamp to start from is frame (1-1) / 2
    final rate = _frameRate ?? _defaultFrameRate;
    final stamp = record.frameStampUs;
    final previousStamp = previous?.frameStampUs;
    final start = _startStampUs;
    int index;
    if (stamp != null && start != null) {
      index = ((stamp - start) * rate / 1e6).round();
      if (index < 0 || index > _maxFrameIndex) {
        _log.warning('Dji motion: a frame stamp $stamp does not follow the first frame at $start, frames counted on');
        _startStampUs = null;
        index = _frameIndex + 1;
      }
    } else if (stamp != null && previousStamp != null) {
      index = _frameIndex + ((stamp - previousStamp) * rate / 1e6).round();
    } else if (previous == null) {
      index = (record.recordIndex ?? 0) ~/ 2;
    } else {
      index = _frameIndex + 1;
    }
    if (previous != null && index <= _frameIndex) {
      _dropped++;
      return;
    }

    // The sample step, from the run before and its count
    final runStamp = record.runStampUs;
    final previousRunStamp = previous?.runStampUs;
    if (previous != null && runStamp != null && previousRunStamp != null && previous.runLength > 0) {
      final step = ((runStamp - previousRunStamp) % _twoTo32) / previous.runLength;
      if (step >= _minSampleStepUs && step <= _maxSampleStepUs) {
        _sampleStepUs = step;
      }
    }

    final q = _orientation(record);
    if (q == null) {
      return;
    }
    _frameIndex = index;
    _previous = record;
    _frameIndices.add(index);
    // From the world to the body: the inverse of q times the turn from the body to the axes of the camera
    final bodyToWorld = _multiply(q, _bodyToCamera);
    var body = [bodyToWorld[0], -bodyToWorld[1], -bodyToWorld[2], -bodyToWorld[3]];
    final count = _orientations.length;
    if (count >= 4) {
      final dot =
          body[0] * _orientations[count - 4] +
          body[1] * _orientations[count - 3] +
          body[2] * _orientations[count - 2] +
          body[3] * _orientations[count - 1];
      if (dot < 0) {
        body = [-body[0], -body[1], -body[2], -body[3]];
      }
    }
    _orientations.addAll(body);
  }

  // The attitude of the picture of [record]: in its run at the frame time stamp plus the delay, else the quaternion of
  // the frame, else the middle of the run
  List<double>? _orientation(_AttitudeRecord record) {
    final run = record.run;
    final count = record.runLength;
    final frameStamp = record.frameStampUs;
    final runStamp = record.runStampUs;
    if (count > 0 && frameStamp != null && runStamp != null) {
      _fromRuns = true;
      // The run stamp keeps the low 32 bits of the clock of the frame stamp
      final first = runStamp + ((frameStamp - runStamp) / _twoTo32).round() * _twoTo32;
      final position = ((frameStamp + delayUs - first) / _sampleStepUs).clamp(0.0, count - 1.0);
      final i = math.min(position.floor(), math.max(0, count - 2));
      final t = count == 1 ? 0.0 : position - i;
      if (t == 0) {
        return run.sublist(4 * i, 4 * i + 4);
      }
      final a = run.sublist(4 * i, 4 * i + 4);
      var b = run.sublist(4 * i + 4, 4 * i + 8);
      if (a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3] < 0) {
        b = [-b[0], -b[1], -b[2], -b[3]];
      }
      final q = [for (var k = 0; k < 4; k++) a[k] + (b[k] - a[k]) * t];
      final norm = math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
      return [for (final v in q) v / norm];
    }
    final frameQuaternion = record.frameQuaternion;
    if (frameQuaternion != null) {
      _fromFrameQuaternions = true;
      return frameQuaternion;
    }
    final middle = count ~/ 2;
    return count == 0 ? null : run.sublist(4 * middle, 4 * middle + 4);
  }

  CameraMotionTrack? track({required bool truncated}) {
    if (_frameIndices.isEmpty) {
      return null;
    }
    final rate = _frameRate ?? _defaultFrameRate;
    final frameTimes = Float64List.fromList([for (final index in _frameIndices) index / rate]);
    if (_frameIndices.first != 0) {
      _log.info('Dji motion: the first frame kept is frame ${_frameIndices.first} of the video');
    }
    if (_fromFrameQuaternions) {
      _log.info(
        'Dji motion: ${_fromRuns ? 'some' : 'all'} frames take the quaternion of the frame, without the times of the '
        'attitude samples',
      );
    }
    return CameraMotionTrack(
      source: CameraMotionSource.djiAttitude,
      timeOrigin: CameraMotionTimeOrigin.firstFrame,
      samples: CameraMotionSamples.empty(),
      frameTimes: frameTimes,
      frameExposures: Float32List(0),
      frameOrientations: Float32List.fromList(_orientations),
      cameraModel: _model,
      firmware: _firmware,
      truncated: truncated,
      droppedSamples: _dropped,
    );
  }
}

// The Hamilton product a b of two quaternions w, x, y, z
List<double> _multiply(List<double> a, List<double> b) => [
  a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
  a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
  a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
  a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
];
