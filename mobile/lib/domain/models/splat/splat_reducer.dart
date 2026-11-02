// The reduction of a splat that holds more gaussians than a device shows (lot SV4 of the splat viewer): a port of
// SplatReducer.kt of the Quest viewer, for the splat viewer of the computers, phones and tablets. The same rules, so
// that a file reduced here keeps the same gaussians as on the headset:
//
// 1. The score of a gaussian is its opacity times its volume, compared as a logarithm: ln(opacity) plus its three log
//    scales. An SPZ stores the opacity as a byte (value / 255) and the scales as bytes (value / 16 - 10); a PLY the
//    opacity as a logit (ln(sigmoid(o)) = -ln(1 + e^-o)) and the scales as natural logarithms. An opacity of 0 counts
//    as 1e-6; a score that is not a number comes last. Scores are kept as 32 bit floats, as in the Kotlin.
// 2. The [keep] largest scores are kept, a tie going to the lower index ([selectStrongest]).
// 3. The file is written again in its format, the kept gaussians in their order: a PLY by rows under its header with
//    the new count, its bytes untouched; an SPZ array by array in a new gzip stream as version 2 (the float16
//    positions of version 1 as 24 bit fixed point, the "smallest three" rotations of version 3 as the 3 bytes of
//    version 2), everything else copied byte for byte, the source read to the end of its gzip stream so that its CRC
//    and length are checked.
//
// Version 4 (ZSTD) is not read here: Spark reads it whole on the flat screens, and one above the cap is refused by the
// gate until the page reduces it itself (lot SV8). Two streaming passes over the file, never the file in memory: the
// scores (4 bytes a gaussian) and the kept set (1 bit) stay. Pure Dart, run in an isolate by splat_viewer_prepare.dart;
// tested by splat_reducer_test.dart against expected.json of make_splat_fixtures.py, which SplatReducerTest.kt reads
// too.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/splat/splat_header.dart';

/// The points read at a time, and between two checks of the cancellation
const _chunk = 4096;

/// The fractional bits of the positions Niantic's writer gives, for a version 1 header that says none
const splatDefaultFractionalBits = 12;

const _minOpacity = 1e-6;
final _logMinOpacity = math.log(_minOpacity);
final _sqrtHalf = math.sqrt(0.5);

/// The file is not what its head said (cut, a wrong CRC, a stream that ends early): the reduction stops
class SplatReduceException implements Exception {
  const SplatReduceException(this.detail);

  final String detail;

  @override
  String toString() => 'SplatReduceException: $detail';
}

/// The reduction was cancelled between two chunks
class SplatReduceCancelled implements Exception {
  const SplatReduceCancelled();
}

/// What the reduction is told as it goes: the share done, from 0 to 1
typedef SplatReduceProgress = void Function(double done);

/// The layout of a binary little endian PLY of 3D Gaussian Splatting: its header and the offset and size of each
/// property of a row
class SplatPlyLayout {
  SplatPlyLayout._(this.headerBytes, this.rowBytes, this.count, this._properties);

  final int headerBytes;
  final int rowBytes;
  final int count;
  final Map<String, ({int offset, int size})> _properties;

  ({int offset, int size})? property(String name) => _properties[name];

  static const _sizes = {
    'char': 1, 'uchar': 1, 'int8': 1, 'uint8': 1, 'short': 2, 'ushort': 2, 'int16': 2, 'uint16': 2, 'int': 4,
    'uint': 4, 'int32': 4, 'uint32': 4, 'float': 4, 'float32': 4, 'double': 8, 'float64': 8, //
  };

  /// The layout of the header at the start of [head] (the probe already refused what this does not read)
  static SplatPlyLayout parse(Uint8List head) {
    final marker = ascii.encode('end_header');
    var end = -1;
    for (var i = 0; i + marker.length <= head.length && end < 0; i++) {
      var match = true;
      for (var k = 0; k < marker.length && match; k++) {
        match = head[i + k] == marker[k];
      }
      if (match) {
        end = i + marker.length;
      }
    }
    if (end < 0) {
      throw const SplatReduceException('no end_header');
    }
    while (end < head.length && head[end] != 0x0a) {
      end++;
    }
    final headerBytes = end + 1;
    final lines = latin1.decode(head.sublist(0, headerBytes)).split('\n').map((line) => line.trim());
    var inVertex = false;
    var count = 0;
    var row = 0;
    final properties = <String, ({int offset, int size})>{};
    for (final line in lines) {
      final words = line.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
      if (words.isEmpty) {
        continue;
      }
      if (words[0] == 'element') {
        inVertex = words.length > 2 && words[1] == 'vertex';
        if (inVertex) {
          count = int.parse(words[2]);
        }
      } else if (words[0] == 'property' && inVertex && words.length > 2) {
        final size = _sizes[words[1]];
        if (size == null) {
          throw SplatReduceException('property type ${words[1]}');
        }
        properties[words[2]] = (offset: row, size: size);
        row += size;
      }
    }
    return SplatPlyLayout._(headerBytes, row, count, properties);
  }
}

/// Reads exact counts of bytes from a stream of chunks
class _Reader {
  _Reader(Stream<List<int>> stream) : _chunks = StreamIterator(stream);

  final StreamIterator<List<int>> _chunks;
  List<int> _current = const [];
  int _at = 0;

  /// Bytes read so far
  int position = 0;

  Future<void> readInto(Uint8List into, int count) async {
    var filled = 0;
    while (filled < count) {
      if (_at >= _current.length) {
        if (!await _next()) {
          throw const SplatReduceException('the file ends too early');
        }
        continue;
      }
      final n = math.min(count - filled, _current.length - _at);
      into.setRange(filled, filled + n, _current, _at);
      _at += n;
      filled += n;
    }
    position += count;
  }

  Future<Uint8List> read(int count) async {
    final bytes = Uint8List(count);
    await readInto(bytes, count);
    return bytes;
  }

  Future<void> skip(int count) async {
    var left = count;
    while (left > 0) {
      if (_at >= _current.length) {
        if (!await _next()) {
          throw const SplatReduceException('the file ends too early');
        }
        continue;
      }
      final n = math.min(left, _current.length - _at);
      _at += n;
      left -= n;
    }
    position += count;
  }

  /// Reads what is left to the end of the stream, which checks a gzip stream's CRC and length
  Future<void> drain(bool Function() cancelled) async {
    while (await _next()) {
      if (cancelled()) {
        throw const SplatReduceCancelled();
      }
    }
  }

  Future<bool> _next() async {
    try {
      if (!await _chunks.moveNext()) {
        return false;
      }
    } on FormatException catch (error) {
      throw SplatReduceException('stream damaged: ${error.message}');
    } on FileSystemException catch (error) {
      throw SplatReduceException('stream damaged: ${error.message}');
    }
    _current = _chunks.current;
    _at = 0;
    return true;
  }

  Future<void> cancel() => _chunks.cancel();
}

/// The data of an SPZ of versions 1 to 3 (its gzip stream inflated), or the rows of a PLY
Stream<List<int>> _payloadOf(File file, SplatHead head) =>
    head.format == SplatFormat.spz ? file.openRead().transform(gzip.decoder) : file.openRead();

double _clean(double score) => score.isNaN ? -3.4028234663852886e38 : score;

/// The score of each gaussian of [file], whose head is [head]; [progress] goes from 0 to 1 as it reads
Future<Float32List> scoreSplat(
  File file,
  SplatHead head, {
  SplatReduceProgress? progress,
  bool Function()? cancelled,
}) async {
  final stop = cancelled ?? () => false;
  if (head.isZstd) {
    throw const SplatReduceException('version 4 is not reduced here');
  }
  final count = head.gaussians;
  final scores = Float32List(count);
  final reader = _Reader(_payloadOf(file, head));
  try {
    if (head.format == SplatFormat.ply) {
      final layout = SplatPlyLayout.parse(await _headOf(file));
      await reader.skip(layout.headerBytes);
      final opacity = _floatOf(layout, 'opacity');
      final s0 = _floatOf(layout, 'scale_0');
      final s1 = _floatOf(layout, 'scale_1');
      final s2 = _floatOf(layout, 'scale_2');
      final chunk = Uint8List(_chunk * layout.rowBytes);
      final data = ByteData.sublistView(chunk);
      for (var i = 0; i < count; i += _chunk) {
        if (stop()) {
          throw const SplatReduceCancelled();
        }
        final n = math.min(_chunk, count - i);
        await reader.readInto(chunk, n * layout.rowBytes);
        for (var k = 0; k < n; k++) {
          final base = k * layout.rowBytes;
          final o = opacity(data, base);
          // ln(sigmoid(o)), steady for a large negative o
          final logAlpha = o > -30 ? -_log1p(math.exp(-o)) : o;
          scores[i + k] = _clean(math.max(logAlpha, _logMinOpacity) + s0(data, base) + s1(data, base) + s2(data, base));
        }
        progress?.call((i + n) / count);
      }
    } else {
      final header = await reader.read(16);
      final version = ByteData.sublistView(header).getInt32(4, Endian.little);
      final positionBytes = version == 1 ? 6 : 9;
      await reader.skip(positionBytes * count);
      final alphas = await reader.read(count);
      await reader.skip(3 * count);
      final scales = Uint8List(3 * _chunk);
      for (var i = 0; i < count; i += _chunk) {
        if (stop()) {
          throw const SplatReduceCancelled();
        }
        final n = math.min(_chunk, count - i);
        await reader.readInto(scales, 3 * n);
        for (var k = 0; k < n; k++) {
          var score = math.log(math.max(alphas[i + k] / 255.0, _minOpacity));
          for (var axis = 0; axis < 3; axis++) {
            score += scales[3 * k + axis] / 16.0 - 10.0;
          }
          scores[i + k] = _clean(score);
        }
        progress?.call((i + n) / count);
      }
    }
  } finally {
    await reader.cancel();
  }
  return scores;
}

double _log1p(double x) => x.abs() < 1e-5 ? x - x * x / 2 + x * x * x / 3 : math.log(1 + x);

double Function(ByteData, int) _floatOf(SplatPlyLayout layout, String name) {
  final property = layout.property(name);
  if (property == null) {
    throw SplatReduceException('no $name');
  }
  final offset = property.offset;
  return property.size == 8
      ? (data, base) => data.getFloat64(base + offset, Endian.little)
      : (data, base) => data.getFloat32(base + offset, Endian.little);
}

Future<Uint8List> _headOf(File file) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead(0, math.min(splatHeadBytes, await file.length()))) {
    builder.add(chunk);
  }
  return builder.toBytes();
}

/// The kept set of [selectStrongest]: one bit a gaussian
class SplatKept {
  SplatKept(this.length) : _bits = Uint32List((length + 31) >> 5);

  final int length;
  final Uint32List _bits;
  int _count = 0;

  int get count => _count;

  bool operator [](int index) => (_bits[index >> 5] >> (index & 31)) & 1 == 1;

  void keep(int index) {
    if (!this[index]) {
      _bits[index >> 5] |= 1 << (index & 31);
      _count++;
    }
  }

  List<int> get indices => [
    for (var i = 0; i < length; i++)
      if (this[i]) i,
  ];
}

/// The indices of the [keep] largest [scores], a tie going to the lower index; all of them when [keep] is more
SplatKept selectStrongest(Float32List scores, int keep) {
  final n = scores.length;
  final kept = SplatKept(n);
  if (keep >= n) {
    for (var i = 0; i < n; i++) {
      kept.keep(i);
    }
    return kept;
  }
  if (keep <= 0) {
    return kept;
  }
  double cleanFloat(double score) => score.isNaN ? double.negativeInfinity : score;
  final sorted = Float32List(n);
  for (var i = 0; i < n; i++) {
    sorted[i] = cleanFloat(scores[i]);
  }
  sorted.sort();
  final threshold = sorted[n - keep];
  for (var i = 0; i < n; i++) {
    if (cleanFloat(scores[i]) > threshold) {
      kept.keep(i);
    }
  }
  var remaining = keep - kept.count;
  for (var i = 0; remaining > 0 && i < n; i++) {
    if (cleanFloat(scores[i]) == threshold && !kept[i]) {
      kept.keep(i);
      remaining--;
    }
  }
  return kept;
}

/// The fractional bits of the fixed point positions written: those of the header, unless version 1 gives a number
/// a 24 bit position cannot hold (then 12, the writer of Niantic's)
int splatFractionalBitsOf(int version, int headerBits) =>
    version != 1 || (headerBits >= 1 && headerBits <= 23) ? headerBits : splatDefaultFractionalBits;

/// Writes the gaussians of [file] (whose head is [head]) that [kept] holds into [out], in the same format, an SPZ as
/// version 2; [progress] goes from 0 to 1 as it reads
Future<void> writeKept(
  File file,
  SplatHead head,
  SplatKept kept,
  File out, {
  SplatReduceProgress? progress,
  bool Function()? cancelled,
}) async {
  final stop = cancelled ?? () => false;
  if (head.isZstd) {
    throw const SplatReduceException('version 4 is not reduced here');
  }
  final count = head.gaussians;
  final reader = _Reader(_payloadOf(file, head));
  final sink = out.openWrite();
  try {
    if (head.format == SplatFormat.ply) {
      final layout = SplatPlyLayout.parse(await _headOf(file));
      final header = latin1.decode(await reader.read(layout.headerBytes));
      sink.add(latin1.encode(_withCount(header, kept.count)));
      await _copyKept(reader, (bytes) => sink.add(bytes), count, layout.rowBytes, kept, stop, progress);
    } else {
      final encoder = ZLibEncoder(gzip: true, level: 6);
      // The file is closed below, once: the encoder's close would close it too, and a second close never completes
      final gzipSink = encoder.startChunkedConversion(_KeptOpen(sink));
      final header = await reader.read(16);
      final fields = ByteData.sublistView(header);
      final version = fields.getInt32(4, Endian.little);
      final fractional = splatFractionalBitsOf(version, header[13]);
      fields.setInt32(4, 2, Endian.little);
      fields.setUint32(8, kept.count, Endian.little);
      header[12] = math.min(head.shDegree, 3);
      header[13] = fractional;
      header[14] = header[14] & ~0x2;
      header[15] = 0;
      gzipSink.add(header);
      void write(List<int> bytes) => gzipSink.add(bytes);
      // Arrays of every point, one after the other: positions, alphas, colours, scales, rotations, harmonics
      final shBytes = 3 * splatShCoefficients(head.shDegree);
      final steps = 6;
      var step = 0;
      void stepProgress(double share) => progress?.call((step + share) / steps);
      if (version == 1) {
        final scale = math.pow(2, fractional).toDouble();
        await _recodeKept(reader, write, count, 6, 9, kept, stop, stepProgress, (from, at, into, to) {
          for (var axis = 0; axis < 3; axis++) {
            _putFixed24(into, to + 3 * axis, _halfToDouble(from, at + 2 * axis) * scale);
          }
        });
      } else {
        await _copyKept(reader, write, count, 9, kept, stop, stepProgress);
      }
      for (final size in const [1, 3, 3]) {
        step++;
        await _copyKept(reader, write, count, size, kept, stop, stepProgress);
      }
      step++;
      if (version >= 3) {
        await _recodeKept(reader, write, count, 4, 3, kept, stop, stepProgress, firstThreeOfSmallestThree);
      } else {
        await _copyKept(reader, write, count, 3, kept, stop, stepProgress);
      }
      step++;
      if (shBytes > 0) {
        await _copyKept(reader, write, count, shBytes, kept, stop, stepProgress);
      }
      // The rest of the source, to the end of its gzip stream: what is past the data is not copied, but a cut trailer
      // or a wrong CRC means the points read may not be those that were written
      await reader.drain(stop);
      gzipSink.close();
    }
    await sink.flush();
  } catch (_) {
    await reader.cancel();
    rethrow;
  } finally {
    await sink.close();
  }
}

/// [sink] whose close does nothing: its owner closes it
class _KeptOpen implements Sink<List<int>> {
  _KeptOpen(this._sink);

  final IOSink _sink;

  @override
  void add(List<int> data) => _sink.add(data);

  @override
  void close() {}
}

String _withCount(String header, int count) =>
    header.replaceFirstMapped(RegExp(r'^(element\s+vertex\s+)\d+', multiLine: true), (m) => '${m.group(1)}$count');

Future<void> _copyKept(
  _Reader reader,
  void Function(List<int>) out,
  int count,
  int size,
  SplatKept kept,
  bool Function() stop,
  SplatReduceProgress? progress,
) async {
  final chunk = Uint8List(_chunk * size);
  for (var i = 0; i < count; i += _chunk) {
    if (stop()) {
      throw const SplatReduceCancelled();
    }
    final n = math.min(_chunk, count - i);
    await reader.readInto(chunk, n * size);
    final written = BytesBuilder(copy: true);
    for (var k = 0; k < n; k++) {
      if (kept[i + k]) {
        written.add(Uint8List.sublistView(chunk, k * size, (k + 1) * size));
      }
    }
    if (written.isNotEmpty) {
      out(written.takeBytes());
    }
    progress?.call((i + n) / count);
  }
}

Future<void> _recodeKept(
  _Reader reader,
  void Function(List<int>) out,
  int count,
  int size,
  int outSize,
  SplatKept kept,
  bool Function() stop,
  SplatReduceProgress? progress,
  void Function(Uint8List from, int at, Uint8List into, int to) recode,
) async {
  final chunk = Uint8List(_chunk * size);
  for (var i = 0; i < count; i += _chunk) {
    if (stop()) {
      throw const SplatReduceCancelled();
    }
    final n = math.min(_chunk, count - i);
    await reader.readInto(chunk, n * size);
    final written = Uint8List(_chunk * outSize);
    var to = 0;
    for (var k = 0; k < n; k++) {
      if (!kept[i + k]) {
        continue;
      }
      recode(chunk, k * size, written, to);
      to += outSize;
    }
    if (to > 0) {
      out(Uint8List.sublistView(written, 0, to));
    }
    progress?.call((i + n) / count);
  }
}

/// [value] rounded half up as a 24 bit signed little endian number at [at], held within its range
void _putFixed24(Uint8List into, int at, double value) {
  final n = (value + 0.5).floorToDouble().clamp(-8388608.0, 8388607.0).toInt();
  into[at] = n & 0xff;
  into[at + 1] = (n >> 8) & 0xff;
  into[at + 2] = (n >> 16) & 0xff;
}

/// The IEEE 754 half float, little endian, at [at], as SplatReducer.halfToFloat reads it (a float)
double _halfToDouble(Uint8List bytes, int at) {
  final bits = bytes[at] | (bytes[at + 1] << 8);
  final sign = bits & 0x8000 != 0 ? -1.0 : 1.0;
  final exponent = (bits >> 10) & 0x1f;
  final mantissa = bits & 0x3ff;
  final double value;
  if (exponent == 0) {
    value = sign * mantissa / 1024 * (1 / 16384);
  } else if (exponent == 0x1f) {
    value = mantissa == 0 ? sign * double.infinity : double.nan;
  } else {
    value = sign * (1 + mantissa / 1024) * math.pow(2, exponent - 15);
  }
  // The Kotlin computes it as a float
  return Float32List.fromList([value])[0];
}

/// The rotation of version 3 at [at] of [from] (the index of the largest component of (x, y, z, w) in the top 2 bits,
/// then for the others, from the low bits and from w down to x, a magnitude of 9 bits over 1/sqrt(2) and a sign bit)
/// written as version 2 at [to] of [into]: x, y, z of the normalised quaternion with w made positive, each
/// floor(q * 127.5 + 127.5 + 0.5)
void firstThreeOfSmallestThree(Uint8List from, int at, Uint8List into, int to) {
  var comp = from[at] | (from[at + 1] << 8) | (from[at + 2] << 16) | (from[at + 3] << 24);
  comp &= 0xffffffff;
  final largest = comp >> 30;
  final q = List<double>.filled(4, 0);
  var squares = 0.0;
  for (var i = 3; i >= 0; i--) {
    if (i == largest) {
      continue;
    }
    final magnitude = (comp & 511).toDouble();
    final negative = (comp >> 9) & 1;
    comp >>= 10;
    q[i] = _sqrtHalf * magnitude / 511.0;
    if (negative == 1) {
      q[i] = -q[i];
    }
    squares += q[i] * q[i];
  }
  q[largest] = math.sqrt(math.max(0.0, 1.0 - squares));
  final norm = math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
  final sign = q[3] / norm < 0 ? -1.0 : 1.0;
  for (var axis = 0; axis < 3; axis++) {
    final c = sign * (q[axis] / norm);
    into[to + axis] = (c * 127.5 + 127.5 + 0.5).floorToDouble().clamp(0.0, 255.0).toInt();
  }
}

/// Reduces [source] (whose head is [head]) to its [keep] strongest gaussians into [out]: the scores (the first half
/// of [progress]), the choice, then the writing (the second half). [out] is deleted when it stops.
Future<int> reduceSplatFile({
  required File source,
  required SplatHead head,
  required int keep,
  required File out,
  SplatReduceProgress? progress,
  bool Function()? cancelled,
}) async {
  try {
    final scores = await scoreSplat(source, head, progress: (done) => progress?.call(done / 2), cancelled: cancelled);
    final kept = selectStrongest(scores, keep);
    await writeKept(source, head, kept, out, progress: (done) => progress?.call(0.5 + done / 2), cancelled: cancelled);
    progress?.call(1);
    return kept.count;
  } catch (_) {
    try {
      await out.delete();
    } on FileSystemException {
      // Never written
    }
    rethrow;
  }
}
