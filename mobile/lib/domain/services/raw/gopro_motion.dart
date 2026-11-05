// The motion of a GoPro in the GPMF track of its videos, for the stabilisation of the video at playback.
//
// A GoPro MAX .360 (and a MAX 2, a HERO8 or later) keeps a timed metadata track of sample entry "gpmd" (handler
// "GoPro MET"), one sample of about 11 KB a second, after the video frames of that second in the media data. Each
// sample is GPMF: KLV items of a four character key, a type character, the size of one structure (u8), a repeat count
// (u16 BE), then size x repeat bytes padded to a multiple of 4, all big endian; type 0 nests items. A DEVC item holds
// the name of the camera (DVNM) and one STRM per stream, each with its scale (SCAL, one divisor or one per element)
// before its values. The streams read here:
//
// - CORI, the camera orientation: a quaternion (w, x, y, z) as int16 over SCAL 32767, one per video frame. It turns
//   the world (the camera's own reference, not levelled) into the camera: GRAV turned by its inverse stays within 1.7
//   degrees of one direction while the camera turns by 180 degrees on the sample measured, and its frame to frame steps
//   agree with the GPMF gyroscope within 0.29 degree a frame (study of 5 November 2026, gopro_check.py).
// - GRAV, the gravity vector: three int16 over SCAL 32767, one per frame, in the axes of CORI.
// - SHUT, the exposure time of each frame in seconds (float), on its own clock: 29 to 31 entries a payload, 596 in all
//   for the 596 frames of the sample.
//
// The payloads hold 30 entries of each per 1.001 s on a 29.97 fps MAX: entry i of CORI, counted over the payloads in
// order, is frame i of the video, whose time is given by the time to sample table of the first video track (the
// sample measured has 595 entries for 596 frames). The GYRO and ACCL streams (792 and 198 Hz) are not read: the camera
// fused them into CORI already.
//
// Pure Dart: the caller reads the bytes, from a file on the device or with HTTP range requests: the moov box in one
// read, then one read per payload.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/raw/camera_motion.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart' show ByteRangeReader, listTopLevelBoxes;
import 'package:logging/logging.dart';

final _log = Logger('GoProMotion');

/// Most bytes of the moov box read: the sample tables of a GoPro recording of several hours
const goProMaxMoovLength = 16 * 1024 * 1024;

/// Most bytes of GPMF payloads read: about 6 hours at 11 KB a second
const goProMaxMotionLength = 256 * 1024 * 1024;

const _orientationKey = 'CORI';
const _gravityKey = 'GRAV';
const _exposureKey = 'SHUT';

/// Reads the motion track of the GoPro video of [fileSize] bytes that [read] reads: the orientation (CORI) and the
/// gravity vector (GRAV) the camera fused for each frame, and the time of each frame on the clock of the video (time 0
/// at its first frame). Null for a file without a moov box, without a gpmd track, or whose GPMF has no CORI stream.
///
/// Reads the top level boxes to the moov box, the moov box whole when it is at most [maxMoovLength] bytes, then the
/// payloads of the gpmd track one by one, at most [maxPayloadLength] bytes of them ([CameraMotionTrack.truncated] tells
/// when there is more, or when a payload is cut short). The frames are the CORI entries in order, as many as the video
/// track has frames; their times come from that track, or from the times of the payloads without one
/// ([CameraMotionTimeOrigin.firstSample]). Entry i of GRAV and of SHUT, counted over the payloads, is frame i too (SHUT
/// runs on its own clock: 29 to 31 entries a payload on the sample, 596 for its 596 frames); a frame past the entries
/// of one of them gets NaN for it. Errors of [read] are not caught.
Future<CameraMotionTrack?> readGoProMotion(
  ByteRangeReader read,
  int fileSize, {
  int maxMoovLength = goProMaxMoovLength,
  int maxPayloadLength = goProMaxMotionLength,
}) async {
  final moov = await _readMoov(read, fileSize, maxMoovLength);
  if (moov == null) {
    return null;
  }
  final tracks = _tracks(moov.bytes);
  final metadata =
      tracks.where((track) => track.entryType == 'gpmd').firstOrNull ??
      tracks
          .where((track) => track.handlerType == 'meta' && (track.handlerName?.contains('GoPro MET') ?? false))
          .firstOrNull;
  if (metadata == null) {
    return null;
  }
  final video = tracks.where((track) => track.handlerType == 'vide').firstOrNull;
  final samples = metadata.samples();
  if (samples.isEmpty) {
    return null;
  }

  final collector = _Collector();
  var payloadBytes = 0;
  var truncated = false;
  for (final sample in samples) {
    if (payloadBytes + sample.size > maxPayloadLength) {
      truncated = true;
      break;
    }
    if (sample.offset + sample.size > fileSize) {
      _log.warning('GoPro motion: a GPMF payload runs past the end of the file');
      truncated = true;
      break;
    }
    payloadBytes += sample.size;
    final bytes = await read(sample.offset, sample.size);
    if (bytes.length < sample.size) {
      _log.warning('GoPro motion: a GPMF payload ends early (${bytes.length} of ${sample.size} bytes)');
      truncated = true;
    }
    collector.add(bytes.length > sample.size ? Uint8List.sublistView(bytes, 0, sample.size) : bytes, sample);
    if (bytes.length < sample.size) {
      break;
    }
  }
  if (collector.frames == 0) {
    return null;
  }

  // The frames: the CORI entries, as many as the video has frames, at the times of its frames
  final videoBounds = video?.sampleBounds();
  final videoTimes = videoBounds == null ? null : Float64List.sublistView(videoBounds, 0, videoBounds.length - 1);
  final CameraMotionTimeOrigin timeOrigin;
  final Float64List frameTimes;
  if (videoTimes != null && videoTimes.isNotEmpty) {
    timeOrigin = CameraMotionTimeOrigin.firstFrame;
    frameTimes = Float64List.sublistView(videoTimes, 0, math.min(videoTimes.length, collector.frames));
    if (collector.frames > videoTimes.length + 1 && !truncated) {
      _log.warning('GoPro motion: ${collector.frames} CORI entries for ${videoTimes.length} frames');
    }
    if (truncated && collector.frames < videoTimes.length) {
      _log.info('GoPro motion: ${collector.frames} of ${videoTimes.length} frames read');
    }
  } else {
    timeOrigin = CameraMotionTimeOrigin.firstSample;
    frameTimes = Float64List.fromList(collector.payloadTimes);
  }
  final count = frameTimes.length;
  final track = CameraMotionTrack(
    source: CameraMotionSource.goProGpmf,
    timeOrigin: timeOrigin,
    samples: CameraMotionSamples.empty(),
    frameTimes: Float64List.fromList(frameTimes),
    frameExposures: collector.exposures.length == 0
        ? Float32List(0)
        : _Collector.entries(collector.exposures, 1, count),
    frameOrientations: _Collector.entries(collector.orientations, 4, count),
    frameGravity: collector.gravity.length == 0 ? null : _Collector.entries(collector.gravity, 3, count),
    cameraModel: collector.cameraModel,
    firmware: moov.firmware,
    truncated: truncated,
  );
  _log.info('GoPro motion: $track');
  return track;
}

typedef _Moov = ({Uint8List bytes, String? firmware});

// The content of the moov box, and the firmware its udta box names (FIRM, as a GoPro writes it)
Future<_Moov?> _readMoov(ByteRangeReader read, int fileSize, int maxMoovLength) async {
  final boxes = await listTopLevelBoxes(read);
  final moov = boxes.where((box) => box.type == 'moov').firstOrNull;
  if (moov == null) {
    return null;
  }
  final size = moov.size ?? fileSize - moov.offset;
  final length = size - moov.headerLength;
  if (length <= 0) {
    return null;
  }
  if (length > maxMoovLength) {
    _log.warning('GoPro motion: a moov box of $length bytes, more than $maxMoovLength');
    return null;
  }
  final bytes = await read(moov.offset + moov.headerLength, length);
  final content = bytes.length > length ? Uint8List.sublistView(bytes, 0, length) : bytes;
  String? firmware;
  final udta = _child(content, _Box(0, content.length), 'udta');
  final firm = udta == null ? null : _child(content, udta, 'FIRM');
  if (firm != null && firm.end > firm.start) {
    firmware = latin1.decode(Uint8List.sublistView(content, firm.start, firm.end)).replaceAll('\u0000', '').trim();
  }
  return (bytes: content, firmware: firmware == null || firmware.isEmpty ? null : firmware);
}

/// A box in a buffer: the offsets of its content, after the header, from [start] to [end]
class _Box {
  const _Box(this.start, this.end, [this.type = '']);

  final int start;
  final int end;
  final String type;
}

// The boxes of [data] from [start] to [end]; a box running past [end] ends there and ends the list
Iterable<_Box> _boxes(Uint8List data, int start, int end) sync* {
  final bytes = ByteData.sublistView(data);
  final limit = math.min(end, data.length);
  var offset = start;
  while (offset + 8 <= limit) {
    var size = bytes.getUint32(offset);
    final type = latin1.decode(Uint8List.sublistView(data, offset + 4, offset + 8));
    var header = 8;
    if (size == 1) {
      if (offset + 16 > limit) {
        return;
      }
      size = bytes.getUint32(offset + 8) * 0x100000000 + bytes.getUint32(offset + 12);
      header = 16;
    } else if (size == 0) {
      size = limit - offset;
    }
    if (size < header) {
      return;
    }
    final boxEnd = offset + size;
    yield _Box(offset + header, math.min(boxEnd, limit), type);
    if (boxEnd > limit) {
      return;
    }
    offset = boxEnd;
  }
}

_Box? _child(Uint8List data, _Box? parent, String type) =>
    parent == null ? null : _boxes(data, parent.start, parent.end).where((box) => box.type == type).firstOrNull;

/// Where a sample of a track is in the file, how long it is, and its time and duration in seconds
typedef _Sample = ({int offset, int size, double time, double duration});

/// What the moov box says of a track: its handler, the type of its first sample entry, and its sample tables
class _Track {
  _Track(this._data, this.mdia);

  final Uint8List _data;
  final _Box mdia;

  late final _Box? _stbl = _child(_data, _child(_data, mdia, 'minf'), 'stbl');

  ByteData get _bytes => ByteData.sublistView(_data);

  /// The handler type of its hdlr box ("vide", "soun", "meta")
  late final String? handlerType = () {
    final hdlr = _child(_data, mdia, 'hdlr');
    return hdlr == null || hdlr.start + 12 > hdlr.end
        ? null
        : latin1.decode(Uint8List.sublistView(_data, hdlr.start + 8, hdlr.start + 12));
  }();

  /// The name of its hdlr box, counted (QuickTime) or NUL terminated
  late final String? handlerName = () {
    final hdlr = _child(_data, mdia, 'hdlr');
    if (hdlr == null || hdlr.start + 24 >= hdlr.end) {
      return null;
    }
    return latin1.decode(Uint8List.sublistView(_data, hdlr.start + 24, hdlr.end)).replaceAll('\u0000', '');
  }();

  /// The type of its first sample entry ("hvc1", "gpmd")
  late final String? entryType = () {
    final stsd = _child(_data, _stbl, 'stsd');
    return stsd == null || stsd.start + 16 > stsd.end
        ? null
        : latin1.decode(Uint8List.sublistView(_data, stsd.start + 12, stsd.start + 16));
  }();

  // The time scale of its mdhd box, null when missing or 0
  int? get _timescale {
    final mdhd = _child(_data, mdia, 'mdhd');
    if (mdhd == null || mdhd.start + 4 > mdhd.end) {
      return null;
    }
    final at = mdhd.start + (_data[mdhd.start] == 1 ? 20 : 12);
    if (at + 4 > mdhd.end) {
      return null;
    }
    final timescale = _bytes.getUint32(at);
    return timescale == 0 ? null : timescale;
  }

  /// The start time of each sample in seconds, from its time to sample table (stts), then the end of the last one;
  /// null without the table or a time scale
  Float64List? sampleBounds() {
    final timescale = _timescale;
    final stts = _child(_data, _stbl, 'stts');
    if (timescale == null || stts == null || stts.start + 8 > stts.end) {
      return null;
    }
    final bytes = _bytes;
    final entries = bytes.getUint32(stts.start + 4);
    final times = <double>[];
    var ticks = 0;
    for (var i = 0, at = stts.start + 8; i < entries && at + 8 <= stts.end; i++, at += 8) {
      final count = bytes.getUint32(at);
      final duration = bytes.getUint32(at + 4);
      for (var k = 0; k < count && times.length < _maxSamples; k++) {
        times.add(ticks / timescale);
        ticks += duration;
      }
    }
    if (times.isEmpty) {
      return null;
    }
    times.add(ticks / timescale);
    return Float64List.fromList(times);
  }

  /// The samples, from its size (stsz), sample to chunk (stsc) and chunk offset (stco or co64) tables, as far as they
  /// agree; with their times from stts when it has them
  List<_Sample> samples() {
    final stbl = _stbl;
    final stsz = _child(_data, stbl, 'stsz');
    final stsc = _child(_data, stbl, 'stsc');
    final stco = _child(_data, stbl, 'stco');
    final co64 = stco == null ? _child(_data, stbl, 'co64') : null;
    final chunks = stco ?? co64;
    if (stsz == null || stsc == null || chunks == null || stsz.start + 12 > stsz.end) {
      return const [];
    }
    final bytes = _bytes;
    final fixedSize = bytes.getUint32(stsz.start + 4);
    final sampleCount = math.min(bytes.getUint32(stsz.start + 8), _maxSamples);
    int? sizeOf(int index) {
      if (fixedSize != 0) {
        return fixedSize;
      }
      final at = stsz.start + 12 + 4 * index;
      return at + 4 <= stsz.end ? bytes.getUint32(at) : null;
    }

    final chunkCount = chunks.start + 8 <= chunks.end ? bytes.getUint32(chunks.start + 4) : 0;
    final width = co64 != null ? 8 : 4;
    int? chunkOffset(int index) {
      final at = chunks.start + 8 + width * index;
      if (index >= chunkCount || at + width > chunks.end) {
        return null;
      }
      return width == 4 ? bytes.getUint32(at) : bytes.getUint32(at) * 0x100000000 + bytes.getUint32(at + 4);
    }

    final runs = <(int, int)>[];
    if (stsc.start + 8 <= stsc.end) {
      final entries = bytes.getUint32(stsc.start + 4);
      for (var i = 0, at = stsc.start + 8; i < entries && at + 12 <= stsc.end; i++, at += 12) {
        runs.add((bytes.getUint32(at), bytes.getUint32(at + 4)));
      }
    }

    // Without a time table, the samples are taken a second each
    final bounds = sampleBounds();
    final out = <_Sample>[];
    for (var run = 0; run < runs.length && out.length < sampleCount; run++) {
      final (firstChunk, perChunk) = runs[run];
      final lastChunk = run + 1 < runs.length ? runs[run + 1].$1 - 1 : chunkCount;
      if (firstChunk < 1 || perChunk == 0) {
        continue;
      }
      for (var chunk = firstChunk; chunk <= lastChunk && out.length < sampleCount; chunk++) {
        final start = chunkOffset(chunk - 1);
        if (start == null) {
          return out;
        }
        var offset = start;
        for (var k = 0; k < perChunk && out.length < sampleCount; k++) {
          final index = out.length;
          final size = sizeOf(index);
          if (size == null) {
            return out;
          }
          final known = bounds != null && index + 1 < bounds.length;
          final time = known ? bounds[index] : index.toDouble();
          out.add((offset: offset, size: size, time: time, duration: known ? bounds[index + 1] - time : 1.0));
          offset += size;
        }
      }
    }
    return out;
  }
}

// Most samples taken from one table: 24 hours of frames at 60 a second
const _maxSamples = 24 * 3600 * 60;

List<_Track> _tracks(Uint8List moov) => [
  for (final trak in _boxes(moov, 0, moov.length).where((box) => box.type == 'trak'))
    if (_child(moov, trak, 'mdia') case final mdia?) _Track(moov, mdia),
];

/// A growing list of floats
class _Floats {
  Float32List _values = Float32List(1024);
  int length = 0;

  void add(double value) {
    if (length == _values.length) {
      _values = Float32List(2 * _values.length)..setAll(0, _values);
    }
    _values[length++] = value;
  }

  void addNaN(int count) {
    for (var i = 0; i < count; i++) {
      add(double.nan);
    }
  }

  Float32List toFloat32List() => Float32List.sublistView(_values, 0, length);
}

/// The entries of CORI, GRAV and SHUT, each counted over the payloads in order: entry i of each is frame i
class _Collector {
  final orientations = _Floats();
  final gravity = _Floats();
  final exposures = _Floats();
  final payloadTimes = <double>[];
  String? cameraModel;

  /// Frames read: CORI entries
  int get frames => orientations.length ~/ 4;

  void add(Uint8List payload, _Sample sample) {
    final streams = <String, List<double>>{};
    final widths = <String, int>{};
    _walk(payload, 0, payload.length, (key, type, size, repeat, start) {
      if (key == 'DEVC' && type == 0) {
        _walk(payload, start, start + size * repeat, (key, type, size, repeat, start) {
          if (key == 'DVNM' && type == _char) {
            cameraModel ??= _string(payload, start, size * repeat);
          } else if (key == 'STRM' && type == 0) {
            _stream(payload, start, start + size * repeat, streams, widths);
          }
        });
      }
    });
    final orientation = streams[_orientationKey];
    if (orientation != null && widths[_orientationKey] == 4) {
      final count = orientation.length ~/ 4;
      orientation.take(4 * count).forEach(orientations.add);
      for (var i = 0; i < count; i++) {
        payloadTimes.add(sample.time + i * sample.duration / count);
      }
    }
    final grav = streams[_gravityKey];
    if (grav != null && widths[_gravityKey] == 3) {
      grav.take(grav.length ~/ 3 * 3).forEach(gravity.add);
    }
    final shut = streams[_exposureKey];
    if (shut != null && widths[_exposureKey] == 1) {
      shut.forEach(exposures.add);
    }
  }

  /// The first [count] entries of [values], [width] values each, NaN past its end
  static Float32List entries(_Floats values, int width, int count) {
    final out = Float32List(width * count)..fillRange(0, width * count, double.nan);
    final available = math.min(values.length, width * count);
    out.setRange(0, available, values.toFloat32List());
    return out;
  }
}

const _char = 0x63; // 'c'

/// Calls [item] for each KLV item of [data] from [start] to [end] with its key, type, structure size, repeat and the
/// offset of its payload; stops at an item whose payload runs past [end]
void _walk(Uint8List data, int start, int end, void Function(String key, int type, int size, int repeat, int at) item) {
  final limit = math.min(end, data.length);
  var offset = start;
  while (offset + 8 <= limit) {
    final key = latin1.decode(Uint8List.sublistView(data, offset, offset + 4));
    final type = data[offset + 4];
    final size = data[offset + 5];
    final repeat = data[offset + 6] << 8 | data[offset + 7];
    final length = size * repeat;
    if (offset + 8 + length > limit) {
      _log.warning('GoPro motion: a GPMF item $key runs past its parent');
      return;
    }
    item(key, type, size, repeat, offset + 8);
    offset += 8 + ((length + 3) & ~3);
  }
}

String _string(Uint8List data, int start, int length) =>
    latin1.decode(Uint8List.sublistView(data, start, start + length)).replaceAll('\u0000', '').trim();

// The values of CORI, GRAV and SHUT in the stream from [start] to [end], over its SCAL, into [streams], with the number
// of elements of one entry into [widths]
void _stream(Uint8List data, int start, int end, Map<String, List<double>> streams, Map<String, int> widths) {
  var scale = const <double>[1];
  _walk(data, start, end, (key, type, size, repeat, at) {
    if (key == 'SCAL') {
      final values = _numbers(data, type, size, repeat, at);
      if (values != null && values.isNotEmpty) {
        scale = values;
      }
    } else if (key == _orientationKey || key == _gravityKey || key == _exposureKey) {
      final values = _numbers(data, type, size, repeat, at);
      final elementSize = _elementSize(type);
      if (values == null || elementSize == null || repeat == 0) {
        return;
      }
      final width = size ~/ elementSize;
      for (var i = 0; i < values.length; i++) {
        final divisor = scale.length == width ? scale[i % width] : scale.first;
        values[i] = divisor == 0 ? values[i] : values[i] / divisor;
      }
      streams[key] = values;
      widths[key] = width;
    }
  });
}

int? _elementSize(int type) => switch (type) {
  0x62 || 0x42 => 1, // b B
  0x73 || 0x53 => 2, // s S
  0x6c || 0x4c || 0x66 => 4, // l L f
  0x64 => 8, // d
  _ => null,
};

// The numbers of a KLV item of a numeric [type], element after element; null for another type
List<double>? _numbers(Uint8List data, int type, int size, int repeat, int at) {
  final elementSize = _elementSize(type);
  if (elementSize == null || size % elementSize != 0) {
    return null;
  }
  final bytes = ByteData.sublistView(data, at, at + size * repeat);
  final count = size * repeat ~/ elementSize;
  return List<double>.generate(count, (i) {
    final offset = i * elementSize;
    return switch (type) {
      0x62 => bytes.getInt8(offset).toDouble(),
      0x42 => bytes.getUint8(offset).toDouble(),
      0x73 => bytes.getInt16(offset).toDouble(),
      0x53 => bytes.getUint16(offset).toDouble(),
      0x6c => bytes.getInt32(offset).toDouble(),
      0x4c => bytes.getUint32(offset).toDouble(),
      0x66 => bytes.getFloat32(offset),
      _ => bytes.getFloat64(offset),
    };
  });
}
