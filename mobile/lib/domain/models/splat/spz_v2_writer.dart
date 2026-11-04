// SPZ version 2, the one format of splats the splat module of the headset reads (measured on a Quest 3 on 31 October
// 2026, SplatModuleFormat.kt), written for the splat scenes made on a computer (store/m2/splat-maker-2026-11-01, lot
// SP3). SPZ is Niantic Labs' format (MIT, https://github.com/nianticlabs/spz): one gzip stream of a 16 byte header
// (magic "NGSP", version 2, the number of points, the degree of the harmonics, 12 fractional bits, flags 0, a reserved
// byte at 0) followed by the attributes of all the points one after the other: positions (24 bit fixed point), alphas,
// colours, scales, rotations (3 bytes) and the harmonics past the first coefficient.
//
// The packing is that of packGaussians in load-spz.cc, applied to the float32 values in double precision, exactly as
// spz_v2_payload of .github/desktop/ai/make_splat_fixtures.py writes it, whose golden files the tests compare with byte
// for byte (once inflated): positions times 2^12 rounded and held within 24 bits; alpha the sigmoid of the opacity times
// 255; colours f_dc times 0.15 * 255 plus 127.5; scales (log + 10) times 16; the quaternion (rot_1, rot_2, rot_3, rot_0:
// x y z w) normalised, made positive on w, x y z times 127.5 plus 127.5 (the identity for one of zero length); the
// harmonics coefficient by coefficient, the three colours in each (the PLY holds them colour by colour), x * 128 + 128
// rounded to the middle of a bucket of 8 for degree 1 and of 16 beyond. Every rounding half away from zero
// (std::round), every byte held within 0 to 255. The coordinates are those of the PLY: the splat module shows a PLY and
// an SPZ in the same frame (SplatModuleFrame.kt).

import 'dart:io' show GZipCodec;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/splat/splat_cloud.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';

/// The version written, the one the splat module reads
const spzWrittenVersion = 2;

/// The fractional bits of the positions: 1/4096 of a unit, positions within 2048 units of the origin
const spzFractionalBits = 12;

/// The bytes of a point of version 2 before its harmonics: position 9, alpha 1, colour 3, scale 3, rotation 3
const _spzPointBytes = 19;

/// The data of the SPZ version 2 of [cloud], before gzip: its 16 byte header and its arrays. The harmonics of degree
/// [shDegree] at most (those of the cloud by default), the first coefficients of each point kept for a lower one
Uint8List spzV2Payload(SplatCloud cloud, {int? shDegree}) {
  if (shDegree != null && shDegree < 0) {
    throw ArgumentError.value(shDegree, 'shDegree', 'from 0 to $splatMaxShDegree');
  }
  final n = cloud.count;
  if (n == 0) {
    throw const SplatFormatException('no gaussian to write');
  }
  final degree = math.min(shDegree ?? cloud.shDegree, cloud.shDegree);
  final dim = splatShCoefficients(degree);
  final dimIn = splatShCoefficients(cloud.shDegree);
  final stride = cloud.stride;
  final rows = cloud.rows;
  final opacityAt = cloud.opacityAt;
  final scaleAt = cloud.scaleAt;
  final rotationAt = cloud.rotationAt;
  final out = Uint8List(16 + n * (_spzPointBytes + 3 * dim));
  ByteData.sublistView(out, 0, 16)
    ..setUint32(0, splatSpzMagic, Endian.little)
    ..setUint32(4, spzWrittenVersion, Endian.little)
    ..setUint32(8, n, Endian.little)
    ..setUint8(12, degree)
    ..setUint8(13, spzFractionalBits)
    ..setUint8(14, 0)
    ..setUint8(15, 0);
  const positions = 16;
  final alphas = positions + 9 * n;
  final colors = alphas + n;
  final scales = colors + 3 * n;
  final rotations = scales + 3 * n;
  final harmonics = rotations + 3 * n;
  const unit = 1 << spzFractionalBits;
  const fixedMax = (1 << 23) - 1;
  const fixedMin = -(1 << 23);
  const colorScale = 0.15 * 255.0;
  for (var i = 0; i < n; i++) {
    final at = i * stride;
    for (var k = 0; k < 3; k++) {
      final fixed = _roundAway(rows[at + k] * unit, fixedMin - 1, fixedMax + 1).clamp(fixedMin, fixedMax);
      final p = positions + 9 * i + 3 * k;
      out[p] = fixed & 0xff;
      out[p + 1] = (fixed >> 8) & 0xff;
      out[p + 2] = (fixed >> 16) & 0xff;
    }
    out[alphas + i] = _byte(1.0 / (1.0 + math.exp(-rows[at + opacityAt])) * 255.0);
    for (var k = 0; k < 3; k++) {
      out[colors + 3 * i + k] = _byte(rows[at + 3 + k] * colorScale + 0.5 * 255.0);
      out[scales + 3 * i + k] = _byte((rows[at + scaleAt + k] + 10.0) * 16.0);
    }
    // x y z w from rot_1, rot_2, rot_3, rot_0; summed in that order, as the script sums them
    final double x = rows[at + rotationAt + 1];
    final double y = rows[at + rotationAt + 2];
    final double z = rows[at + rotationAt + 3];
    final double w = rows[at + rotationAt];
    final norm = math.sqrt(x * x + y * y + z * z + w * w);
    final r = rotations + 3 * i;
    if (norm > 0) {
      final sign = (w / norm) < 0 ? -127.5 : 127.5;
      out[r] = _byte((x / norm) * sign + 127.5);
      out[r + 1] = _byte((y / norm) * sign + 127.5);
      out[r + 2] = _byte((z / norm) * sign + 127.5);
    } else {
      // A quaternion of zero length turns nothing: the identity, x y z at 0
      out[r] = out[r + 1] = out[r + 2] = _byte(127.5);
    }
    final h = harmonics + 3 * dim * i;
    for (var j = 0; j < dim; j++) {
      final bucket = j < 3 ? 8 : 16;
      for (var c = 0; c < 3; c++) {
        out[h + 3 * j + c] = _quantizeSh(rows[at + 6 + c * dimIn + j], bucket);
      }
    }
  }
  return out;
}

/// The SPZ version 2 file of [cloud] (see [spzV2Payload]): one gzip member without name, date or options, which the
/// headset reads to its end (SplatModuleFormat.checkWhole). Level 6, the default of zlib: on the 150 000 gaussians of
/// the room of measure M1 it took 0.28 s for 3 351 912 bytes, level 9 2.19 s for 3 289 286 (2 % smaller)
Uint8List writeSpzV2(SplatCloud cloud, {int? shDegree}) =>
    Uint8List.fromList(GZipCodec(level: 6).encode(spzV2Payload(cloud, shDegree: shDegree)));

/// [value] rounded to the nearest integer, a half away from zero (std::round), held within [low] and [high] first so
/// that no value past the range of an integer is rounded
int _roundAway(double value, int low, int high) {
  final held = value < low ? low.toDouble() : (value > high ? high.toDouble() : value);
  final magnitude = (held.abs() + 0.5).floor();
  return held >= 0 ? magnitude : -magnitude;
}

/// toUint8 of load-spz.cc: rounded half away from zero, held within a byte
int _byte(double value) => _roundAway(value, -1, 256).clamp(0, 255);

/// quantizeSH of load-spz.cc: x * 128 + 128 rounded, then to the middle of its bucket, held within a byte
int _quantizeSh(double value, int bucket) {
  final q = _roundAway(value * 128.0, -1024, 1024) + 128;
  // (q + bucket / 2) / bucket in C++ truncates towards zero, Python floors: both give 0 once held within a byte
  return ((q + bucket ~/ 2) ~/ bucket * bucket).clamp(0, 255);
}
