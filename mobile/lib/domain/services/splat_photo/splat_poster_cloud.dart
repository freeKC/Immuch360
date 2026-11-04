// The gaussians a drawn poster shows (plan of 3 November 2026, section 7): the strongest [splatPosterKeep] of an SPZ of
// versions 1 to 3 or of a PLY, by the reducer's score (splat_reducer.dart), so that a scene of a million costs about
// what one of 200,000 does; and the positions the placement samples from all of them, every stride-th from the first,
// as the page samples them. Two streaming passes over the file, never the file in memory: the scores, then the
// arrays of the kept gaussians, degree 0 colours only. Version 4 (ZSTD) is not read here: its poster is the card.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_placement.dart';
import 'package:immich_mobile/domain/models/splat/splat_reducer.dart';

/// The gaussians a drawn poster keeps at most
const splatPosterKeep = 200000;

/// The degree 0 harmonic's factor: a colour is 0.5 + this times its coefficient
const splatShC0 = 0.28209479177387814;

/// The scale of the colours of an SPZ: a byte is (coefficient times this plus 0.5) times 255
const _spzColorScale = 0.15;

/// The points read at a time, and between two checks of the cancellation
const _chunk = 4096;

/// The gaussians kept for a poster, in the numbers of the file
final class SplatPosterCloud {
  SplatPosterCloud(this.count)
    : positions = Float32List(3 * count),
      colors = Float32List(3 * count),
      opacities = Float32List(count),
      scales = Float32List(3 * count),
      rotations = Float32List(4 * count);

  /// The gaussians kept
  final int count;

  /// x, y, z of each
  final Float32List positions;

  /// r, g, b of each, from 0 to 1 (degree 0)
  final Float32List colors;

  /// From 0 to 1
  final Float32List opacities;

  /// The three scales of each, in the units of the positions (not their logarithms)
  final Float32List scales;

  /// w, x, y, z of each, normalised
  final Float32List rotations;

  /// The positions the placement samples, from all the gaussians of the file
  Float64List samples = Float64List(0);

  /// The gaussians of the file
  int fileGaussians = 0;
}

/// Reads exact counts of bytes from a stream of chunks
class _Reader {
  _Reader(Stream<List<int>> stream) : _chunks = StreamIterator(stream);

  final StreamIterator<List<int>> _chunks;
  List<int> _current = const [];
  int _at = 0;

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

double _sigmoid(double x) => 1 / (1 + math.exp(-x));

/// The IEEE 754 half float, little endian, at [at]
double _half(Uint8List bytes, int at) {
  final bits = bytes[at] | (bytes[at + 1] << 8);
  final sign = bits & 0x8000 != 0 ? -1.0 : 1.0;
  final exponent = (bits >> 10) & 0x1f;
  final mantissa = bits & 0x3ff;
  if (exponent == 0) {
    return sign * mantissa / 1024 * (1 / 16384);
  }
  if (exponent == 0x1f) {
    return mantissa == 0 ? sign * double.infinity : double.nan;
  }
  return sign * (1 + mantissa / 1024) * math.pow(2, exponent - 15);
}

/// The kept gaussians of [file] (whose head is [head]) and the samples of the placement; [progress] goes from 0 to 1
Future<SplatPosterCloud> readSplatPosterCloud(
  File file,
  SplatHead head, {
  int keep = splatPosterKeep,
  void Function(double done)? progress,
  bool Function()? cancelled,
}) async {
  final stop = cancelled ?? () => false;
  if (head.isZstd) {
    throw const SplatReduceException('version 4 is not read here');
  }
  final count = head.gaussians;
  final scored = count > keep;
  final kept = scored
      ? selectStrongest(
          await scoreSplat(file, head, progress: (done) => progress?.call(done / 2), cancelled: stop),
          keep,
        )
      : null;
  // The index in the cloud of each kept gaussian of the file
  final slot = Int32List(count);
  var n = 0;
  for (var i = 0; i < count; i++) {
    slot[i] = kept == null || kept[i] ? n++ : -1;
  }
  final cloud = SplatPosterCloud(n)..fileGaussians = count;
  final sample = splatSampleOf(count);
  cloud.samples = Float64List(3 * sample.samples);
  final start = scored ? 0.5 : 0.0;
  void step(double done) => progress?.call(start + (1 - start) * done);
  if (head.format == SplatFormat.ply) {
    await _readPly(file, cloud, slot, sample.stride, stop, step);
  } else {
    await _readSpz(file, head, cloud, slot, sample.stride, stop, step);
  }
  progress?.call(1);
  return cloud;
}

Future<void> _readPly(
  File file,
  SplatPosterCloud cloud,
  Int32List slot,
  int stride,
  bool Function() stop,
  void Function(double) progress,
) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead(0, math.min(splatHeadBytes, await file.length()))) {
    builder.add(chunk);
  }
  final layout = SplatPlyLayout.parse(builder.toBytes());
  double Function(ByteData, int) floatOf(String name) {
    final property = layout.property(name);
    if (property == null) {
      throw SplatReduceException('no $name');
    }
    final offset = property.offset;
    return property.size == 8
        ? (data, base) => data.getFloat64(base + offset, Endian.little)
        : (data, base) => data.getFloat32(base + offset, Endian.little);
  }

  final x = floatOf('x');
  final y = floatOf('y');
  final z = floatOf('z');
  final dc = [floatOf('f_dc_0'), floatOf('f_dc_1'), floatOf('f_dc_2')];
  final opacity = floatOf('opacity');
  final scale = [floatOf('scale_0'), floatOf('scale_1'), floatOf('scale_2')];
  final rot = [floatOf('rot_0'), floatOf('rot_1'), floatOf('rot_2'), floatOf('rot_3')];
  final count = slot.length;
  final reader = _Reader(file.openRead(layout.headerBytes));
  final chunk = Uint8List(_chunk * layout.rowBytes);
  final data = ByteData.sublistView(chunk);
  try {
    for (var i = 0; i < count; i += _chunk) {
      if (stop()) {
        throw const SplatReduceCancelled();
      }
      final rows = math.min(_chunk, count - i);
      await reader.readInto(chunk, rows * layout.rowBytes);
      for (var k = 0; k < rows; k++) {
        final index = i + k;
        final base = k * layout.rowBytes;
        if (index % stride == 0) {
          final s = 3 * (index ~/ stride);
          cloud.samples[s] = x(data, base);
          cloud.samples[s + 1] = y(data, base);
          cloud.samples[s + 2] = z(data, base);
        }
        final at = slot[index];
        if (at < 0) {
          continue;
        }
        cloud.positions[3 * at] = x(data, base);
        cloud.positions[3 * at + 1] = y(data, base);
        cloud.positions[3 * at + 2] = z(data, base);
        for (var c = 0; c < 3; c++) {
          cloud.colors[3 * at + c] = 0.5 + splatShC0 * dc[c](data, base);
          cloud.scales[3 * at + c] = math.exp(scale[c](data, base));
        }
        cloud.opacities[at] = _sigmoid(opacity(data, base));
        final w = rot[0](data, base);
        final qx = rot[1](data, base);
        final qy = rot[2](data, base);
        final qz = rot[3](data, base);
        _putRotation(cloud.rotations, at, w, qx, qy, qz);
      }
      progress((i + rows) / count);
    }
  } finally {
    await reader.cancel();
  }
}

void _putRotation(Float32List into, int at, double w, double x, double y, double z) {
  final norm = math.sqrt(w * w + x * x + y * y + z * z);
  if (!(norm > 0) || !norm.isFinite) {
    into[4 * at] = 1;
    into[4 * at + 1] = 0;
    into[4 * at + 2] = 0;
    into[4 * at + 3] = 0;
    return;
  }
  into[4 * at] = w / norm;
  into[4 * at + 1] = x / norm;
  into[4 * at + 2] = y / norm;
  into[4 * at + 3] = z / norm;
}

Future<void> _readSpz(
  File file,
  SplatHead head,
  SplatPosterCloud cloud,
  Int32List slot,
  int stride,
  bool Function() stop,
  void Function(double) progress,
) async {
  final count = slot.length;
  final reader = _Reader(file.openRead().transform(gzip.decoder));
  try {
    final header = Uint8List(16);
    await reader.readInto(header, 16);
    final version = ByteData.sublistView(header).getInt32(4, Endian.little);
    final fractional = splatFractionalBitsOf(version, header[13]);
    final unit = 1 / math.pow(2, fractional);
    // Five arrays read here, in order: positions, alphas, colours, scales, rotations
    const steps = 5;
    var stepAt = 0;
    Future<void> each(int size, void Function(Uint8List bytes, int at, int index) take) async {
      final chunk = Uint8List(_chunk * size);
      for (var i = 0; i < count; i += _chunk) {
        if (stop()) {
          throw const SplatReduceCancelled();
        }
        final n = math.min(_chunk, count - i);
        await reader.readInto(chunk, n * size);
        for (var k = 0; k < n; k++) {
          take(chunk, k * size, i + k);
        }
        progress((stepAt + (i + n) / count) / steps);
      }
      stepAt++;
    }

    // Positions: 24 bit fixed point, or float16 in version 1
    await each(version == 1 ? 6 : 9, (bytes, at, index) {
      final into = slot[index];
      final sampled = index % stride == 0;
      if (into < 0 && !sampled) {
        return;
      }
      for (var axis = 0; axis < 3; axis++) {
        final double value;
        if (version == 1) {
          value = _half(bytes, at + 2 * axis);
        } else {
          var v = bytes[at + 3 * axis] | (bytes[at + 3 * axis + 1] << 8) | (bytes[at + 3 * axis + 2] << 16);
          if (v & 0x800000 != 0) {
            v -= 0x1000000;
          }
          value = v * unit;
        }
        if (into >= 0) {
          cloud.positions[3 * into + axis] = value;
        }
        if (sampled) {
          cloud.samples[3 * (index ~/ stride) + axis] = value;
        }
      }
    });
    await each(1, (bytes, at, index) {
      final into = slot[index];
      if (into >= 0) {
        cloud.opacities[into] = bytes[at] / 255;
      }
    });
    await each(3, (bytes, at, index) {
      final into = slot[index];
      if (into >= 0) {
        for (var c = 0; c < 3; c++) {
          cloud.colors[3 * into + c] = 0.5 + splatShC0 * ((bytes[at + c] / 255 - 0.5) / _spzColorScale);
        }
      }
    });
    await each(3, (bytes, at, index) {
      final into = slot[index];
      if (into >= 0) {
        for (var c = 0; c < 3; c++) {
          cloud.scales[3 * into + c] = math.exp(bytes[at + c] / 16 - 10);
        }
      }
    });
    final v2 = Uint8List(3);
    await each(version >= 3 ? 4 : 3, (bytes, at, index) {
      final into = slot[index];
      if (into < 0) {
        return;
      }
      if (version >= 3) {
        firstThreeOfSmallestThree(bytes, at, v2, 0);
      } else {
        v2.setRange(0, 3, bytes, at);
      }
      final x = v2[0] / 127.5 - 1;
      final y = v2[1] / 127.5 - 1;
      final z = v2[2] / 127.5 - 1;
      final w = math.sqrt(math.max(0.0, 1 - x * x - y * y - z * z));
      _putRotation(cloud.rotations, into, w, x, y, z);
    });
  } finally {
    await reader.cancel();
  }
}
