// The gaussians of a splat scene made on a computer (store/m2/splat-maker-2026-11-01/plan-2026-11-01.md, sections 2.2
// and 2.5, lot SP3), between the export of Brush and the files the headset gets: the PLY Brush 0.3.0 writes (its 59
// properties in alphabetical order, f_rest_10 before f_rest_2) read whatever the order and the type of its properties,
// and the PLY written again in the order of 3D Gaussian Splatting (Kerbl et al. 2023), the one every reader knows: x y z,
// f_dc_0 to 2, f_rest_0 to 44 (the harmonics colour by colour), opacity (a logit), scale_0 to 2 (natural logarithms),
// rot_0 to 3 (w first), all float32, binary little endian.
//
// What the reader of the headset takes (SplatHeader.kt, splat_header.dart) is what is written: floats only, 0, 9, 24 or
// 45 f_rest for the degrees 0 to 3 (degree 4 and any other count refused here, never cut), one element, our comment
// first so that the probe names the tool ("Made with Immuch360 Desktop (COLMAP, Brush)"). A gaussian holding a NaN or
// an infinity is left out: neither format can carry it. Pure Dart, run in an isolate by the desktop (splat_files.dart);
// tested by splat_cloud_test.dart on the fixtures of .github/desktop/ai/make_splat_fixtures.py (brush_sh3.ply and its
// golden scene_sh3.ply).

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/splat/splat_header.dart';

/// Why the export of the training cannot become a splat scene: not a PLY of gaussians the headset reads, cut short,
/// or more gaussians than the training was asked for
class SplatFormatException implements Exception {
  const SplatFormatException(this.message);

  final String message;

  @override
  String toString() => 'SplatFormatException: $message';
}

/// The first comment of the PLY of a splat scene, the tool the probe of the headset names (splatToolOf)
const splatSceneToolComment = 'Made with Immuch360 Desktop (COLMAP, Brush)';

/// How many comments of the export are kept, and how long each may be: the header stays far under the 64 KiB the probe
/// reads (splatHeadBytes)
const splatMaxSourceComments = 16;
const splatMaxCommentLength = 200;

/// The highest degree of the harmonics the headset reads: 45 f_rest
const splatMaxShDegree = 3;

/// The properties of a gaussian of [degree] in the order of 3D Gaussian Splatting, without normals
List<String> splatPlyProperties(int degree) => [
  'x', 'y', 'z', 'f_dc_0', 'f_dc_1', 'f_dc_2', //
  for (var k = 0; k < 3 * splatShCoefficients(degree); k++) 'f_rest_$k',
  'opacity', 'scale_0', 'scale_1', 'scale_2', 'rot_0', 'rot_1', 'rot_2', 'rot_3', //
];

/// The values of one gaussian of [degree]: 14, and 3 for each coefficient of its harmonics past the first
int splatRowValues(int degree) => 14 + 3 * splatShCoefficients(degree);

/// The gaussians of a splat: [count] rows of [stride] float32 values in the order of [splatPlyProperties], the body of
/// the PLY written as it is; the [comments] of the file read, and the gaussians [dropped] for a value no format carries
final class SplatCloud {
  SplatCloud({
    required this.count,
    required this.shDegree,
    required this.rows,
    this.comments = const [],
    this.dropped = 0,
  }) {
    if (shDegree < 0 || shDegree > splatMaxShDegree) {
      throw ArgumentError.value(shDegree, 'shDegree', 'from 0 to $splatMaxShDegree');
    }
    if (rows.length != count * stride) {
      throw ArgumentError.value(rows.length, 'rows', '$count gaussians of $stride values');
    }
  }

  final int count;
  final int shDegree;
  final Float32List rows;
  final List<String> comments;
  final int dropped;

  int get stride => splatRowValues(shDegree);

  /// Where the values of each kind start in a row
  int get restAt => 6;
  int get opacityAt => 6 + 3 * splatShCoefficients(shDegree);
  int get scaleAt => opacityAt + 1;
  int get rotationAt => opacityAt + 4;

  /// x y z of each gaussian
  Float32List get positions {
    final out = Float32List(3 * count);
    for (var i = 0; i < count; i++) {
      out[3 * i] = rows[i * stride];
      out[3 * i + 1] = rows[i * stride + 1];
      out[3 * i + 2] = rows[i * stride + 2];
    }
    return out;
  }

  /// The same gaussians [factor] times larger: the positions multiplied, ln([factor]) added to the log scales, every
  /// value rounded to float32 as the PLY stores it; a copy, the rotations, colours and opacities untouched
  SplatCloud scaled(double factor) {
    if (!(factor > 0) || !factor.isFinite) {
      throw ArgumentError.value(factor, 'factor', 'a positive number');
    }
    final out = Float32List.fromList(rows);
    if (factor != 1.0) {
      final log = math.log(factor);
      final scaleAt = this.scaleAt;
      for (var at = 0; at < out.length; at += stride) {
        out[at] = rows[at] * factor;
        out[at + 1] = rows[at + 1] * factor;
        out[at + 2] = rows[at + 2] * factor;
        out[at + scaleAt] = rows[at + scaleAt] + log;
        out[at + scaleAt + 1] = rows[at + scaleAt + 1] + log;
        out[at + scaleAt + 2] = rows[at + scaleAt + 2] + log;
      }
    }
    return SplatCloud(count: count, shDegree: shDegree, rows: out, comments: comments, dropped: dropped);
  }
}

const _typeBytes = {
  'char': 1,
  'uchar': 1,
  'int8': 1,
  'uint8': 1,
  'short': 2,
  'ushort': 2,
  'int16': 2,
  'uint16': 2,
  'int': 4,
  'uint': 4,
  'int32': 4,
  'uint32': 4,
  'float': 4,
  'float32': 4,
  'double': 8,
  'float64': 8,
};

/// The gaussians of the PLY [bytes]: binary little endian, one element vertex holding x y z, f_dc_0 to 2, opacity,
/// scale_0 to 2, rot_0 to 3 and 0, 9, 24 or 45 f_rest_0 to N as floats or doubles, in any order; other properties of
/// any type are skipped (normals, colours). The gaussians holding a NaN or an infinity are left out. Throws a
/// [SplatFormatException] for anything else, for rows cut short, for more than [maxGaussians] in the file, and when no
/// gaussian is left
SplatCloud readSplatPly(Uint8List bytes, {int? maxGaussians}) {
  final end = _headerEnd(bytes);
  if (end < 0 || !(_startsWith(bytes, 'ply\n') || _startsWith(bytes, 'ply\r\n'))) {
    throw const SplatFormatException('not a PLY with an end_header');
  }
  String? format;
  int? count;
  final comments = <String>[];
  final properties = <(String, String)>[];
  var inVertex = false;
  for (final raw in latin1.decode(Uint8List.sublistView(bytes, 0, end)).split('\n').skip(1)) {
    final line = raw.trim();
    final words = line.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    if (words.isEmpty) {
      continue;
    }
    switch (words[0]) {
      case 'format':
        format = words.length > 1 ? words[1] : null;
      case 'comment':
        comments.add(line.substring('comment'.length).trim());
      case 'element':
        if (words.length < 3 || int.tryParse(words[2]) == null) {
          throw SplatFormatException('element without a count: $line');
        }
        final n = int.parse(words[2]);
        inVertex = words[1] == 'vertex';
        if (inVertex) {
          if (count != null || n < 0) {
            throw SplatFormatException('element vertex $n');
          }
          count = n;
        } else if (n != 0) {
          throw SplatFormatException('another element than the gaussians: ${words[1]} $n');
        }
      case 'property':
        if (!inVertex) {
          continue;
        }
        if (words.length < 3 || words[1] == 'list' || !_typeBytes.containsKey(words[1])) {
          throw SplatFormatException('a property the gaussians cannot hold: $line');
        }
        properties.add((words[2], words[1]));
    }
  }
  if (format != 'binary_little_endian') {
    throw SplatFormatException('PLY $format: binary little endian only');
  }
  if (count == null) {
    throw const SplatFormatException('no element vertex');
  }
  if (maxGaussians != null && count > maxGaussians) {
    throw SplatFormatException('$count gaussians, at most $maxGaussians asked for');
  }
  final names = {for (final (name, _) in properties) name};
  if (names.length != properties.length) {
    throw const SplatFormatException('a property named twice');
  }
  final rest = names.where((name) => name.startsWith('f_rest_')).length;
  final degree = const {0: 0, 9: 1, 24: 2, 45: 3}[rest];
  if (degree == null) {
    throw SplatFormatException('$rest f_rest: no degree from 0 to $splatMaxShDegree');
  }
  final order = splatPlyProperties(degree);
  final missing = order.where((name) => !names.contains(name)).toList();
  if (missing.isNotEmpty) {
    throw SplatFormatException('no ${missing.join(', ')}');
  }
  // Where each value of a row of the file goes in a row of the cloud, read as float or double; the others skipped
  final slot = {for (var k = 0; k < order.length; k++) order[k]: k};
  final targets = <int>[];
  final offsets = <int>[];
  final doubles = <bool>[];
  var rowBytes = 0;
  for (final (name, type) in properties) {
    final target = slot[name];
    if (target != null) {
      if (!const {'float', 'float32', 'double', 'float64'}.contains(type)) {
        throw SplatFormatException('$name stored as $type, not as a float');
      }
      targets.add(target);
      offsets.add(rowBytes);
      doubles.add(_typeBytes[type] == 8);
    }
    rowBytes += _typeBytes[type]!;
  }
  if (end + count * rowBytes > bytes.length) {
    throw SplatFormatException('$count rows of $rowBytes bytes do not fit in ${bytes.length - end} bytes');
  }
  final stride = order.length;
  final data = ByteData.sublistView(bytes, end);
  final out = Float32List(count * stride);
  final row = Float32List(stride);
  var kept = 0;
  for (var i = 0; i < count; i++) {
    final base = i * rowBytes;
    var finite = true;
    for (var k = 0; k < targets.length; k++) {
      final value = doubles[k]
          ? data.getFloat64(base + offsets[k], Endian.little)
          : data.getFloat32(base + offsets[k], Endian.little);
      row[targets[k]] = value;
      // The value as float32: a double past its range is no gaussian either
      if (!row[targets[k]].isFinite) {
        finite = false;
      }
    }
    if (finite) {
      out.setRange(kept * stride, (kept + 1) * stride, row);
      kept++;
    }
  }
  if (kept == 0) {
    throw SplatFormatException(count == 0 ? 'no gaussian' : 'no gaussian of finite values in $count');
  }
  return SplatCloud(
    count: kept,
    shDegree: degree,
    rows: kept == count ? out : Float32List.fromList(Float32List.sublistView(out, 0, kept * stride)),
    comments: List.unmodifiable(comments),
    dropped: count - kept,
  );
}

/// The comments of the PLY of a splat scene: [splatSceneToolComment] first, then those of the export ([source], in
/// printable ASCII, the empty ones and ours left out, [splatMaxSourceComments] at most, each cut at
/// [splatMaxCommentLength]), then [note] (the scale, SplatScale.note)
List<String> splatScenePlyComments(List<String> source, String note) {
  final kept = <String>[];
  for (final comment in source) {
    final text = _printable(comment);
    if (text.isNotEmpty && text != splatSceneToolComment && kept.length < splatMaxSourceComments) {
      kept.add(text.length > splatMaxCommentLength ? text.substring(0, splatMaxCommentLength).trim() : text);
    }
  }
  final last = _printable(note);
  return [
    splatSceneToolComment,
    ...kept,
    if (last.isNotEmpty) last.length > splatMaxCommentLength ? last.substring(0, splatMaxCommentLength) : last,
  ];
}

/// The PLY of [cloud] in the order of 3D Gaussian Splatting, float32, binary little endian, with [comments] (each in
/// printable ASCII); its body is the rows of the cloud as they are
Uint8List writeSplatPly(SplatCloud cloud, {List<String> comments = const []}) {
  final header = StringBuffer('ply\nformat binary_little_endian 1.0\n');
  for (final comment in comments) {
    final text = _printable(comment);
    if (text.isNotEmpty) {
      header.write('comment $text\n');
    }
  }
  header.write('element vertex ${cloud.count}\n');
  for (final name in splatPlyProperties(cloud.shDegree)) {
    header.write('property float $name\n');
  }
  header.write('end_header\n');
  final head = ascii.encode(header.toString());
  final out = Uint8List(head.length + cloud.rows.length * 4);
  out.setRange(0, head.length, head);
  final body = ByteData.sublistView(out, head.length);
  final rows = cloud.rows;
  if (Endian.host == Endian.little) {
    out.setRange(head.length, out.length, Uint8List.sublistView(rows));
  } else {
    for (var k = 0; k < rows.length; k++) {
      body.setFloat32(4 * k, rows[k], Endian.little);
    }
  }
  return out;
}

String _printable(String text) => String.fromCharCodes(text.codeUnits.where((c) => c >= 0x20 && c <= 0x7e)).trim();

/// The end of the header (past "end_header" and its line end), -1 when there is none
int _headerEnd(Uint8List bytes) {
  const marker = 'end_header';
  final limit = bytes.length;
  for (var i = 0; i + marker.length <= limit; i++) {
    var match = true;
    for (var j = 0; j < marker.length; j++) {
      if (bytes[i + j] != marker.codeUnitAt(j)) {
        match = false;
        break;
      }
    }
    if (match && (i == 0 || bytes[i - 1] == 0x0a)) {
      var at = i + marker.length;
      if (at < limit && bytes[at] == 0x0d) {
        at++;
      }
      if (at < limit && bytes[at] == 0x0a) {
        return at + 1;
      }
    }
    // The header is text: past a byte of the body no end_header follows that counts
    if (bytes[i] == 0) {
      return -1;
    }
  }
  return -1;
}

bool _startsWith(Uint8List bytes, String text) {
  if (bytes.length < text.length) {
    return false;
  }
  for (var i = 0; i < text.length; i++) {
    if (bytes[i] != text.codeUnitAt(i)) {
      return false;
    }
  }
  return true;
}
