// Gaussian splat files of other tools in the Meta Quest (lot S5, decision D7 of design-final 2026-10-27): what the
// head of a .spz or .ply file says, read from its first 64 KiB on a share or on the headset before anything else of it
// is read. The same rules as SplatHeader.kt of the immersive viewer, which reads the head of the file again and wins.
//
// SPZ (Niantic Labs, MIT, https://github.com/nianticlabs/spz): versions 1 to 3 are one gzip stream that starts with a
// 16 byte header, little endian: magic 0x5053474e ("NGSP"), version, number of points, degree of the spherical
// harmonics (0 to 3), fractional bits (1 to 23 from version 2 on), flags, a reserved byte at 0. Version 4 starts with a
// clear header of 32 bytes: the same first fields (degree 0 to 4), the number of ZSTD streams, the offset of their
// table of contents, 12 reserved bytes at 0; the table gives the compressed and the decompressed size of each stream,
// one for each array that is not empty, the streams ending with the file. The headset reads version 4 too (FreeKC's
// report of 1 November 2026): it writes every SPZ again as version 2, the one its splat module reads. PLY of 3D
// Gaussian Splatting: binary little endian, one element vertex with x y z, f_dc_0 to
// 2, opacity, scale_0 to 2, rot_0 to 3, and 0, 9, 24 or 45 f_rest_* for the degrees 0 to 3, all of them floats or
// doubles (what the splat module of the headset was seen to read). Pure, tested by splat_header_test.dart on the
// fixtures of .github/desktop/ai/make_splat_fixtures.py (test/fixtures/splat).

import 'dart:convert';
import 'dart:io' show RawZLibFilter;
import 'dart:typed_data';

/// The formats of the splat files the headset reads, as the gaussianSplat request names them
enum SplatFormat {
  spz,
  ply;

  /// The name of the format in the request, and the extension of its files
  String get json => name;
}

/// Why a file is not opened as a splat
enum SplatFileProblem {
  /// Neither SPZ nor PLY, or a PLY of a mesh or a point cloud
  notASplat,

  /// The compressed PLY of SuperSplat and PlayCanvas (element chunk, packed_* properties)
  compressedPly,

  /// A PLY written in ASCII or big endian, with values not stored as floats, or with harmonics past degree 3
  unsupportedPly,

  /// An SPZ of a version after 4
  newerSpz,

  /// A wrong magic, a reserved field set, a stream or rows cut short, a header past [splatHeadBytes], a table of
  /// contents of version 4 that does not match the arrays of the header or the length of the file
  damaged,
}

/// What the head of a file says: a splat ([SplatHead]) or why not ([SplatRefused])
sealed class SplatProbe {
  const SplatProbe();
}

/// A splat the headset may open
final class SplatHead extends SplatProbe {
  const SplatHead({
    required this.format,
    required this.formatVersion,
    required this.gaussians,
    required this.shDegree,
    this.tool,
  });

  final SplatFormat format;

  /// The SPZ version (1 to 4), 1 for a PLY
  final int formatVersion;
  final int gaussians;
  final int shDegree;

  /// What a comment of a PLY names as the tool that made it, null when none does
  final String? tool;

  /// A version 4 SPZ, compressed with ZSTD: the headset decompresses it and writes it again as version 2, as it does
  /// every SPZ (SplatReducer.kt)
  bool get isZstd => format == SplatFormat.spz && formatVersion >= 4;

  @override
  bool operator ==(Object other) =>
      other is SplatHead &&
      other.format == format &&
      other.formatVersion == formatVersion &&
      other.gaussians == gaussians &&
      other.shDegree == shDegree &&
      other.tool == tool;

  @override
  int get hashCode => Object.hash(format, formatVersion, gaussians, shDegree, tool);

  @override
  String toString() => 'SplatHead(${format.json} $formatVersion, $gaussians gaussians, degree $shDegree, tool $tool)';
}

/// Not a splat the headset opens, for [problem]; [detail] for the log
final class SplatRefused extends SplatProbe {
  const SplatRefused(this.problem, this.detail);

  final SplatFileProblem problem;
  final String detail;

  @override
  bool operator ==(Object other) => other is SplatRefused && other.problem == problem;

  @override
  int get hashCode => problem.hashCode;

  @override
  String toString() => 'SplatRefused($problem: $detail)';
}

/// The bytes of the head the probe reads
const splatHeadBytes = 65536;

/// "NGSP", little endian
const splatSpzMagic = 0x5053474e;

/// The longest tool name kept from a comment
const splatMaxToolLength = 60;

const _requiredPly = [
  'x',
  'y',
  'z',
  'f_dc_0',
  'f_dc_1',
  'f_dc_2',
  'opacity',
  'scale_0',
  'scale_1',
  'scale_2',
  'rot_0',
  'rot_1',
  'rot_2',
  'rot_3',
];

/// The counts of f_rest_* properties the splat module was seen to read, and the degree each gives (degree 4, its 72,
/// and any other count refused)
const _plyRestDegrees = {0: 0, 9: 1, 24: 2, 45: 3};

/// The fractional bits a 24 bit fixed point position of an SPZ of version 2 to 4 can have
const _spzMinFractionalBits = 1;
const _spzMaxFractionalBits = 23;

const _plySizes = {
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

const _floatTypes = {'float', 'float32', 'double', 'float64'};

final _toolComment = RegExp(
  r'^(?:generated|exported|created|made|written|saved)\s+(?:by|with|from|using|in)\s+(.+)$',
  caseSensitive: false,
);

/// The coefficients of the spherical harmonics past the first, for [degree]: 0, 3, 8, 15, 24
int splatShCoefficients(int degree) => (degree + 1) * (degree + 1) - 1;

/// The decompressed size of each stream of a version 4 file of [count] points of degree [shDegree] holding [streams]
/// streams, in the order of the file (positions, alphas, colours, scales, rotations, harmonics): 5 without harmonics
/// (Niantic's writer leaves an empty array out), 6 with them, or 6 with an empty sixth (the file of the owner's kit);
/// null for any other count, as SplatHeader.v4StreamSizes says
List<int>? splatV4StreamSizes(int count, int shDegree, int streams) {
  final arrays = [9 * count, count, 3 * count, 3 * count, 4 * count, 3 * splatShCoefficients(shDegree) * count];
  if (streams == arrays.length) {
    return arrays;
  }
  if (streams == arrays.length - 1 && arrays.last == 0) {
    return arrays.sublist(0, streams);
  }
  return null;
}

/// The tool a comment of a PLY names ("Generated by Postshot"), null when it names none
String? splatToolOf(String comment) {
  final name = _toolComment.firstMatch(comment.trim())?.group(1)?.trim();
  if (name == null || name.isEmpty) {
    return null;
  }
  return (name.length > splatMaxToolLength ? name.substring(0, splatMaxToolLength) : name).trim();
}

/// What [head], the first bytes of a file of [fileLength] bytes, says; only its first [splatHeadBytes] are read
SplatProbe probeSplatHead(Uint8List head, int fileLength) {
  final bytes = head.length > splatHeadBytes ? Uint8List.sublistView(head, 0, splatHeadBytes) : head;
  if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    return _probeGzipSpz(bytes);
  }
  if (bytes.length >= 4 && _littleInt(bytes, 0) == splatSpzMagic) {
    return _probeClearSpz(bytes, fileLength);
  }
  if (_startsWith(bytes, 'ply\n') || _startsWith(bytes, 'ply\r\n')) {
    return _probePly(bytes, fileLength);
  }
  return const SplatRefused(SplatFileProblem.notASplat, 'neither SPZ nor PLY');
}

SplatProbe _probeGzipSpz(Uint8List bytes) {
  final out = BytesBuilder(copy: false);
  try {
    // Inflates what the head holds, without asking for the end of the stream
    final filter = RawZLibFilter.inflateFilter();
    filter.process(bytes, 0, bytes.length);
    List<int>? chunk;
    while (out.length < 16 && (chunk = filter.processed(flush: false)) != null) {
      out.add(chunk!);
    }
  } catch (error) {
    return SplatRefused(SplatFileProblem.damaged, 'gzip stream damaged: $error');
  }
  if (out.length < 16) {
    return const SplatRefused(SplatFileProblem.damaged, 'gzip stream cut before the header');
  }
  final header = out.toBytes();
  if (_littleInt(header, 0) != splatSpzMagic) {
    return const SplatRefused(SplatFileProblem.damaged, 'gzip without NGSP');
  }
  final version = _littleInt(header, 4);
  final count = _littleUint(header, 8);
  final degree = header[12];
  final fractional = header[13];
  final reserved = header[15];
  if (version > 4) {
    return SplatRefused(SplatFileProblem.newerSpz, 'SPZ version $version');
  }
  if (version < 1 || version > 3) {
    return SplatRefused(SplatFileProblem.damaged, 'SPZ version $version in gzip');
  }
  if (reserved != 0) {
    return SplatRefused(SplatFileProblem.damaged, 'reserved byte $reserved');
  }
  if (count == 0) {
    return const SplatRefused(SplatFileProblem.damaged, 'no point');
  }
  if (degree > 3) {
    return SplatRefused(SplatFileProblem.damaged, 'degree $degree');
  }
  // Version 1 stores its positions as float16 and never reads them
  if (version >= 2 && (fractional < _spzMinFractionalBits || fractional > _spzMaxFractionalBits)) {
    return SplatRefused(SplatFileProblem.damaged, '$fractional fractional bits');
  }
  return SplatHead(format: SplatFormat.spz, formatVersion: version, gaussians: count, shDegree: degree);
}

SplatProbe _probeClearSpz(Uint8List bytes, int fileLength) {
  if (bytes.length < 8) {
    return const SplatRefused(SplatFileProblem.damaged, 'clear SPZ header cut');
  }
  final version = _littleInt(bytes, 4);
  if (version > 4) {
    return SplatRefused(SplatFileProblem.newerSpz, 'SPZ version $version');
  }
  if (version != 4) {
    return SplatRefused(SplatFileProblem.damaged, 'clear SPZ header of version $version');
  }
  if (bytes.length < 32) {
    return const SplatRefused(SplatFileProblem.damaged, 'clear SPZ header cut');
  }
  final count = _littleUint(bytes, 8);
  final degree = bytes[12];
  final fractional = bytes[13];
  final streams = bytes[15];
  final toc = _littleUint(bytes, 16);
  if (bytes.sublist(20, 32).any((b) => b != 0)) {
    return const SplatRefused(SplatFileProblem.damaged, 'reserved bytes set');
  }
  if (count == 0) {
    return const SplatRefused(SplatFileProblem.damaged, 'no point');
  }
  if (degree > 4) {
    return SplatRefused(SplatFileProblem.damaged, 'degree $degree');
  }
  if (fractional < _spzMinFractionalBits || fractional > _spzMaxFractionalBits) {
    return SplatRefused(SplatFileProblem.damaged, '$fractional fractional bits');
  }
  if (streams == 0) {
    return const SplatRefused(SplatFileProblem.damaged, 'no stream');
  }
  final sizes = splatV4StreamSizes(count, degree, streams);
  if (sizes == null) {
    return SplatRefused(SplatFileProblem.damaged, '$streams streams for degree $degree');
  }
  if (toc < 32 || toc + 16 * streams > fileLength) {
    return SplatRefused(SplatFileProblem.damaged, 'table of contents at $toc out of the file');
  }
  final problem = _tocProblem(bytes, toc, sizes, fileLength);
  if (problem != null) {
    return SplatRefused(SplatFileProblem.damaged, problem);
  }
  return SplatHead(format: SplatFormat.spz, formatVersion: version, gaussians: count, shDegree: degree);
}

/// What is wrong with the table of contents of a version 4 file at [toc] of its head [bytes], null when each stream
/// decompresses to the size of its array ([sizes]) and the streams end with the file of [fileLength] bytes; a table
/// past the head is left to the headset, which checks the same as it reads the file
String? _tocProblem(Uint8List bytes, int toc, List<int> sizes, int fileLength) {
  final end = toc + 16 * sizes.length;
  if (end > bytes.length) {
    return null;
  }
  final table = ByteData.sublistView(bytes, toc, end);
  var streamsEnd = end;
  for (var i = 0; i < sizes.length; i++) {
    final compressed = table.getInt64(16 * i, Endian.little);
    final decompressed = table.getInt64(16 * i + 8, Endian.little);
    if (decompressed != sizes[i]) {
      return 'stream $i of $decompressed bytes, ${sizes[i]} expected';
    }
    if (compressed < 0 || compressed > fileLength - streamsEnd) {
      return 'stream $i runs past the end of the file';
    }
    streamsEnd += compressed;
  }
  return streamsEnd == fileLength ? null : 'the streams end at $streamsEnd, the file at $fileLength';
}

SplatProbe _probePly(Uint8List bytes, int fileLength) {
  final end = _indexOf(bytes, ascii.encode('end_header\n'));
  final endCr = _indexOf(bytes, ascii.encode('end_header\r\n'));
  final int headerBytes;
  if (end >= 0) {
    headerBytes = end + 'end_header\n'.length;
  } else if (endCr >= 0) {
    headerBytes = endCr + 'end_header\r\n'.length;
  } else {
    return const SplatRefused(SplatFileProblem.damaged, 'no end_header in the first $splatHeadBytes bytes');
  }
  final lines = latin1.decode(bytes.sublist(0, headerBytes)).split('\n').map((line) => line.trim()).toList();
  String? format;
  String? tool;
  int? vertexCount;
  final properties = <String, String>{};
  final names = <String>[];
  var vertexList = false;
  var inVertex = false;
  var rowBytes = 0;
  String? unknownType;
  final others = <String, int>{};
  for (final line in lines.skip(1)) {
    final words = line.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    if (words.isEmpty) {
      continue;
    }
    switch (words[0]) {
      case 'format':
        format = words.length > 1 ? words[1] : null;
      case 'comment':
        tool ??= splatToolOf(line.substring('comment'.length).trim());
      case 'element':
        if (words.length < 3) {
          return const SplatRefused(SplatFileProblem.damaged, 'element without name or count');
        }
        final count = int.tryParse(words[2]);
        if (count == null) {
          return SplatRefused(SplatFileProblem.damaged, 'element ${words[1]} without count');
        }
        // A count below 0 is no count: damaged, rather than a splat of -5 gaussians or a mesh of -12 faces
        if (count < 0) {
          return SplatRefused(SplatFileProblem.damaged, 'element ${words[1]} of $count');
        }
        inVertex = words[1] == 'vertex';
        if (inVertex) {
          vertexCount = count;
        } else {
          others[words[1]] = (others[words[1]] ?? 0) + count;
        }
      case 'property':
        if (!inVertex) {
          continue;
        }
        if (words.length > 1 && words[1] == 'list') {
          vertexList = true;
          continue;
        }
        final type = words.length > 1 ? words[1] : '';
        final name = words.length > 2 ? words[2] : '';
        final size = _plySizes[type];
        if (size == null) {
          unknownType = type;
        } else {
          properties[name] = type;
          names.add(name);
          rowBytes += size;
        }
    }
  }
  switch (format) {
    case 'binary_little_endian':
      break;
    case 'ascii' || 'binary_big_endian':
      return SplatRefused(SplatFileProblem.unsupportedPly, 'PLY format $format');
    default:
      return SplatRefused(SplatFileProblem.damaged, 'PLY format $format');
  }
  if ((others['chunk'] ?? 0) > 0 || names.any((name) => name.startsWith('packed_'))) {
    return const SplatRefused(SplatFileProblem.compressedPly, 'compressed PLY');
  }
  if ((others['face'] ?? 0) > 0 || vertexList) {
    return const SplatRefused(SplatFileProblem.notASplat, 'a mesh');
  }
  final count = vertexCount;
  if (count == null) {
    return const SplatRefused(SplatFileProblem.notASplat, 'no vertex element');
  }
  final missing = _requiredPly.where((name) => !properties.containsKey(name)).toList();
  if (missing.isNotEmpty) {
    return SplatRefused(SplatFileProblem.notASplat, 'no ${missing.join(', ')}: a point cloud or a mesh');
  }
  if (unknownType != null) {
    return SplatRefused(SplatFileProblem.unsupportedPly, 'type $unknownType');
  }
  // Floats or doubles, what the module was seen to read, for every property of the gaussians and their harmonics
  final notFloats = names
      .where((name) => _requiredPly.contains(name) || name.startsWith('f_rest_'))
      .where((name) => !_floatTypes.contains(properties[name]))
      .toList();
  if (notFloats.isNotEmpty) {
    return SplatRefused(SplatFileProblem.unsupportedPly, 'not stored as floats: ${notFloats.join(', ')}');
  }
  final rest = names.where((name) => name.startsWith('f_rest_')).length;
  final degree = _plyRestDegrees[rest];
  if (degree == null) {
    return SplatRefused(SplatFileProblem.unsupportedPly, '$rest f_rest properties: no degree from 0 to 3');
  }
  if (others.values.any((value) => value > 0)) {
    return SplatRefused(SplatFileProblem.unsupportedPly, 'other elements: ${others.keys.join(', ')}');
  }
  if (count == 0) {
    return const SplatRefused(SplatFileProblem.damaged, 'no gaussian');
  }
  if (headerBytes + count * rowBytes > fileLength) {
    return SplatRefused(SplatFileProblem.damaged, '$count rows of $rowBytes bytes do not fit in $fileLength');
  }
  return SplatHead(format: SplatFormat.ply, formatVersion: 1, gaussians: count, shDegree: degree, tool: tool);
}

int _littleInt(Uint8List bytes, int at) => ByteData.sublistView(bytes, at, at + 4).getInt32(0, Endian.little);

int _littleUint(Uint8List bytes, int at) => ByteData.sublistView(bytes, at, at + 4).getUint32(0, Endian.little);

bool _startsWith(Uint8List bytes, String text) {
  final prefix = ascii.encode(text);
  if (bytes.length < prefix.length) {
    return false;
  }
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}

int _indexOf(Uint8List bytes, List<int> pattern) {
  outer:
  for (var i = 0; i <= bytes.length - pattern.length; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) {
        continue outer;
      }
    }
    return i;
  }
  return -1;
}
