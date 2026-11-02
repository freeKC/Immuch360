// Gaussian splats the tests of the formats of the splat scenes build (lot SP3): PLY files of any layout, gaussians of
// values a format carries, and the SPZ version 2 decoded again, from the public description of the format (Niantic
// Labs, MIT), as make_splat_fixtures.py describes it.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/splat/splat_cloud.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';

/// The bytes of one value of each type of a PLY
const plyTypeBytes = {'char': 1, 'uchar': 1, 'short': 2, 'ushort': 2, 'int': 4, 'uint': 4, 'float': 4, 'double': 8};

/// The properties of a gaussian of [degree] as Brush 0.3.0 orders them: alphabetically, f_rest_10 before f_rest_2
List<String> brushOrder(int degree) => [...splatPlyProperties(degree)]..sort();

/// A PLY of one element vertex holding [rows], its [properties] (name and type) in their order; with [extraHeader]
/// lines before end_header, in [format] and with [newline] at the end of each line of the header
Uint8List plyOf(
  List<(String, String)> properties,
  List<Map<String, double>> rows, {
  List<String> comments = const [],
  String format = 'binary_little_endian',
  String newline = '\n',
  List<String> extraHeader = const [],
  int? count,
}) {
  final header = StringBuffer('ply$newline')..write('format $format 1.0$newline');
  for (final comment in comments) {
    header.write('comment $comment$newline');
  }
  header.write('element vertex ${count ?? rows.length}$newline');
  for (final (name, type) in properties) {
    header.write('property $type $name$newline');
  }
  for (final line in extraHeader) {
    header.write('$line$newline');
  }
  header.write('end_header$newline');
  final row = properties.fold(0, (sum, p) => sum + plyTypeBytes[p.$2]!);
  final data = ByteData(row * rows.length);
  var at = 0;
  final endian = format == 'binary_big_endian' ? Endian.big : Endian.little;
  for (final values in rows) {
    for (final (name, type) in properties) {
      final value = values[name] ?? 0;
      switch (type) {
        case 'float':
          data.setFloat32(at, value, endian);
        case 'double':
          data.setFloat64(at, value, endian);
        case 'uchar':
          data.setUint8(at, value.toInt());
        case 'char':
          data.setInt8(at, value.toInt());
        case 'short':
          data.setInt16(at, value.toInt(), endian);
        case 'ushort':
          data.setUint16(at, value.toInt(), endian);
        case 'int':
          data.setInt32(at, value.toInt(), endian);
        case 'uint':
          data.setUint32(at, value.toInt(), endian);
      }
      at += plyTypeBytes[type]!;
    }
  }
  return Uint8List.fromList([...latin1.encode(header.toString()), ...data.buffer.asUint8List()]);
}

/// [count] gaussians of [degree] whose values all sit inside what SPZ version 2 carries: positions within 50 units,
/// colours within 3.3, log scales from -9.5 to 1, harmonics within 0.99, quaternions of any length but zero
List<Map<String, double>> gaussiansOf(int count, int degree, {int seed = 1}) {
  final random = math.Random(seed);
  double between(double low, double high) => low + random.nextDouble() * (high - low);
  final rest = 3 * splatShCoefficients(degree);
  return [
    for (var i = 0; i < count; i++)
      {
        'x': between(-50, 50),
        'y': between(-20, 20),
        'z': between(-50, 50),
        for (var k = 0; k < 3; k++) 'f_dc_$k': between(-3.3, 3.3),
        for (var k = 0; k < rest; k++) 'f_rest_$k': between(-0.99, 0.99),
        'opacity': between(-6, 6),
        for (var k = 0; k < 3; k++) 'scale_$k': between(-9.5, 1),
        for (var k = 0; k < 4; k++) 'rot_$k': between(0.05, 1) * (random.nextBool() ? 1 : -1),
      },
  ];
}

/// The float32 value of [value], as a PLY of floats stores it
double f32(double value) => (Float32List(1)..[0] = value)[0];

/// An SPZ version 2 decoded again (its data, once inflated), as a reader of the format reads it: the positions in
/// units, the alphas and colours from 0 to 1 and as DC coefficients, the log scales, the quaternions x y z w, the
/// harmonics coefficient by coefficient, three colours each
final class DecodedSpz {
  DecodedSpz(Uint8List payload) {
    final head = ByteData.sublistView(payload, 0, 16);
    count = head.getUint32(8, Endian.little);
    shDegree = head.getUint8(12);
    fractionalBits = head.getUint8(13);
    final dim = splatShCoefficients(shDegree);
    var at = 16;
    positions = Float64List(3 * count);
    for (var i = 0; i < 3 * count; i++, at += 3) {
      var fixed = payload[at] | payload[at + 1] << 8 | payload[at + 2] << 16;
      if (fixed & 0x800000 != 0) {
        fixed -= 1 << 24;
      }
      positions[i] = fixed / (1 << fractionalBits);
    }
    alphas = Float64List.fromList([for (var i = 0; i < count; i++) payload[at + i] / 255]);
    at += count;
    colors = Float64List.fromList([for (var i = 0; i < 3 * count; i++) (payload[at + i] / 255 - 0.5) / 0.15]);
    at += 3 * count;
    scales = Float64List.fromList([for (var i = 0; i < 3 * count; i++) payload[at + i] / 16 - 10]);
    at += 3 * count;
    rotations = Float64List(4 * count);
    for (var i = 0; i < count; i++, at += 3) {
      final xyz = [for (var k = 0; k < 3; k++) payload[at + k] / 127.5 - 1];
      for (var k = 0; k < 3; k++) {
        rotations[4 * i + k] = xyz[k];
      }
      rotations[4 * i + 3] = math.sqrt(math.max(0, 1 - xyz.fold(0.0, (s, c) => s + c * c)));
    }
    sh = Float64List.fromList([for (var i = 0; i < 3 * dim * count; i++) (payload[at + i] - 128) / 128]);
    at += 3 * dim * count;
    length = at;
  }

  late final int count;
  late final int shDegree;
  late final int fractionalBits;
  late final Float64List positions;
  late final Float64List alphas;
  late final Float64List colors;
  late final Float64List scales;
  late final Float64List rotations;
  late final Float64List sh;

  /// Where its arrays end: the length of the payload when nothing is missing or left over
  late final int length;
}
