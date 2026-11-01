import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';

/// The probe of the head of a splat file (lot S5), on the fixtures of make_splat_fixtures.py that SplatHeaderTest.kt
/// reads too: the same answers on both sides.
void main() {
  final expected = jsonDecode(File('test/fixtures/splat/expected.json').readAsStringSync()) as Map<String, dynamic>;
  final headers = expected['headers'] as Map<String, dynamic>;

  Uint8List bytesOf(String name) => File('test/fixtures/splat/$name').readAsBytesSync();

  SplatProbe probe(String name, {int? fileLength}) {
    final bytes = bytesOf(name);
    final header = headers[name] as Map<String, dynamic>?;
    final length = fileLength ?? (header?['fileBytes'] as int?) ?? bytes.length;
    return probeSplatHead(bytes.length > splatHeadBytes ? bytes.sublist(0, splatHeadBytes) : bytes, length);
  }

  /// The probe of a PLY of 2 gaussians with [rest] f_rest_*, every property a float but those [types] names
  SplatProbe plyOf(int rest, {Map<String, String> types = const {}}) {
    final names = [
      'x', 'y', 'z', 'nx', 'ny', 'nz', 'f_dc_0', 'f_dc_1', 'f_dc_2', //
      for (var i = 0; i < rest; i++) 'f_rest_$i',
      'opacity', 'scale_0', 'scale_1', 'scale_2', 'rot_0', 'rot_1', 'rot_2', 'rot_3',
    ];
    const sizes = {'float': 4, 'double': 8, 'uchar': 1, 'ushort': 2, 'int': 4};
    final header = StringBuffer('ply\nformat binary_little_endian 1.0\nelement vertex 2\n');
    var row = 0;
    for (final name in names) {
      final type = types[name] ?? 'float';
      header.write('property $type $name\n');
      row += sizes[type]!;
    }
    header.write('end_header\n');
    final bytes = Uint8List.fromList([...ascii.encode(header.toString()), ...Uint8List(2 * row)]);
    return probeSplatHead(bytes, bytes.length);
  }

  /// A gzip SPZ header of [version], 10 points, with [fractional] bits, and room for the probe
  Uint8List spzHeader(int version, {int fractional = 12}) {
    final data = ByteData(16 + 64)
      ..setUint32(0, splatSpzMagic, Endian.little)
      ..setUint32(4, version, Endian.little)
      ..setUint32(8, 10, Endian.little)
      ..setUint8(13, fractional);
    return data.buffer.asUint8List();
  }

  Uint8List gzipOf(Uint8List bytes) => Uint8List.fromList(gzip.encode(bytes));

  SplatFileProblem? refusal(String name) => switch (probe(name)) {
    SplatRefused(:final problem) => problem,
    _ => null,
  };

  test('the SPZ of versions 1 to 4 give their version, count and degree', () {
    for (final (name, version) in [('axes_v1.spz', 1), ('axes_v2.spz', 2), ('axes_v3.spz', 3), ('axes_v4.spz', 4)]) {
      final head = probe(name) as SplatHead;
      expect(head.format, SplatFormat.spz, reason: name);
      expect(head.formatVersion, version, reason: name);
      expect(head.gaussians, (headers[name] as Map)['gaussians'], reason: name);
      expect(head.shDegree, 0);
      expect(head.isZstd, version == 4);
    }
  });

  test('the SPZ of version 4 as Niantic writes them, up to degree 4, give their count and degree', () {
    for (final name in ['axes_v4_niantic.spz', 'turns_v4.spz', 'sh4_v4.spz']) {
      final header = headers[name] as Map<String, dynamic>;
      final head = probe(name) as SplatHead;
      expect(head.formatVersion, 4, reason: name);
      expect(head.gaussians, header['gaussians'], reason: name);
      expect(head.shDegree, header['shDegree'], reason: name);
    }
    expect(splatV4StreamSizes(686, 0, 5), [6174, 686, 2058, 2058, 2744]);
    expect(splatV4StreamSizes(686, 0, 6), [6174, 686, 2058, 2058, 2744, 0]);
    expect(splatV4StreamSizes(8, 4, 6)!.last, 8 * 72);
    expect(splatV4StreamSizes(8, 1, 5), isNull);
  });

  test('a version 4 SPZ whose table of contents does not match its arrays is damaged, as in SplatHeaderTest.kt', () {
    final good = bytesOf('axes_v4_niantic.spz');
    SplatFileProblem? refusalOf(Uint8List bytes, [int? length]) =>
        switch (probeSplatHead(bytes, length ?? bytes.length)) {
          SplatRefused(:final problem) => problem,
          _ => null,
        };
    Uint8List withLong(Uint8List source, int at, int value) {
      final copy = Uint8List.fromList(source);
      ByteData.sublistView(copy).setInt64(at, value, Endian.little);
      return copy;
    }

    expect(refusalOf(good), isNull);
    // A decompressed size that is not the one of its array
    expect(refusalOf(withLong(good, 32 + 8, 686 * 9 + 1)), SplatFileProblem.damaged);
    // A compressed size past the end of the file, streams that end before it, a file cut
    expect(refusalOf(withLong(good, 32, 100000)), SplatFileProblem.damaged);
    expect(refusalOf(good, good.length + 1), SplatFileProblem.damaged);
    expect(refusalOf(Uint8List.sublistView(good, 0, good.length - 1)), SplatFileProblem.damaged);
    // Fewer streams than arrays, or a sixth stream of harmonics of degree 0 that is not empty
    expect(refusalOf(Uint8List.fromList(good)..[15] = 4), SplatFileProblem.damaged);
    expect(refusalOf(withLong(bytesOf('axes_v4.spz'), 32 + 5 * 16 + 8, 1)), SplatFileProblem.damaged);
    // Positions a fixed point of 24 bits cannot hold, harmonics past degree 4
    expect(refusalOf(Uint8List.fromList(good)..[13] = 0), SplatFileProblem.damaged);
    expect(refusalOf(Uint8List.fromList(good)..[12] = 5), SplatFileProblem.damaged);
  });

  test(
    'a version 4 SPZ of a share that does not give its size is read, the end of its streams left to the headset',
    () {
      // A WebDAV server without getcontentlength (review of 1 November 2026): the probe has no length to end the
      // streams at, and every version 4 file was refused as damaged
      for (final name in ['axes_v4.spz', 'axes_v4_niantic.spz', 'turns_v4.spz', 'sh4_v4.spz']) {
        final header = headers[name] as Map<String, dynamic>;
        final head = probeSplatHead(bytesOf(name), null);
        expect(head, isA<SplatHead>(), reason: '$name: $head');
        expect((head as SplatHead).formatVersion, 4, reason: name);
        expect(head.gaussians, header['gaussians'], reason: name);
        expect(head.shDegree, header['shDegree'], reason: name);
      }
      // What needs no length is still checked: a decompressed size that is not the one of its array, a size below 0
      final good = bytesOf('axes_v4_niantic.spz');
      Uint8List withLong(int at, int value) {
        final copy = Uint8List.fromList(good);
        ByteData.sublistView(copy).setInt64(at, value, Endian.little);
        return copy;
      }

      expect(probeSplatHead(withLong(32 + 8, 686 * 9 + 1), null), const SplatRefused(SplatFileProblem.damaged, ''));
      expect(probeSplatHead(withLong(32, -1), null), const SplatRefused(SplatFileProblem.damaged, ''));
      expect(
        probeSplatHead(Uint8List.fromList(good)..[15] = 4, null),
        const SplatRefused(SplatFileProblem.damaged, ''),
      );
      // The other formats as before
      expect(probeSplatHead(bytesOf('axes_v3.spz'), null), isA<SplatHead>());
      expect(probeSplatHead(bytesOf('axes.ply'), null), isA<SplatHead>());
    },
  );

  test('a PLY of gaussians gives its count, its degree and the tool its comment names', () {
    expect(
      probe('axes.ply'),
      SplatHead(
        format: SplatFormat.ply,
        formatVersion: 1,
        gaussians: (headers['axes.ply'] as Map)['gaussians'] as int,
        shDegree: 0,
        tool: 'make_splat_fixtures.py',
      ),
    );
    expect(probe('sh3.ply'), const SplatHead(format: SplatFormat.ply, formatVersion: 1, gaussians: 8, shDegree: 3));
  });

  test('the heads of two files of another writer, read with the length of the whole file', () {
    expect(
      probe('cash_register_head.spz'),
      const SplatHead(format: SplatFormat.spz, formatVersion: 3, gaussians: 47819, shDegree: 0),
    );
    expect(
      probe('measuring_tape_head.ply'),
      const SplatHead(format: SplatFormat.ply, formatVersion: 1, gaussians: 19469, shDegree: 0),
    );
    expect(probe('measuring_tape_head.ply', fileLength: 1000000), const SplatRefused(SplatFileProblem.damaged, ''));
  });

  test('a mesh, a point cloud, a compressed PLY, ASCII, big endian and a long header are refused', () {
    expect(refusal('mesh_cube.ply'), SplatFileProblem.notASplat);
    expect(refusal('point_cloud.ply'), SplatFileProblem.notASplat);
    expect(refusal('compressed.ply'), SplatFileProblem.compressedPly);
    expect(refusal('ascii.ply'), SplatFileProblem.unsupportedPly);
    expect(refusal('big_endian.ply'), SplatFileProblem.unsupportedPly);
    expect(refusal('long_header.ply'), SplatFileProblem.damaged);
  });

  test('a negative count is a damaged file, never a splat of -5 gaussians', () {
    // The header of negative_count.ply says element vertex -5 over four rows of the axes
    expect(refusal('negative_count.ply'), SplatFileProblem.damaged);
    // Nor does a negative count of faces make a mesh pass for a splat
    final mesh = utf8.encode(
      'ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float x\nelement face -12\n'
      'property list uchar int vertex_indices\nend_header\n',
    );
    expect(probeSplatHead(Uint8List.fromList(mesh), mesh.length), const SplatRefused(SplatFileProblem.damaged, ''));
  });

  test('wrong SPZ heads are refused, a newer version said apart', () {
    expect(refusal('bad_magic.spz'), SplatFileProblem.damaged);
    expect(refusal('reserved.spz'), SplatFileProblem.damaged);
    expect(refusal('truncated.spz'), SplatFileProblem.damaged);
    expect(refusal('newer.spz'), SplatFileProblem.newerSpz);
    final clear = ByteData(32)
      ..setUint32(0, splatSpzMagic, Endian.little)
      ..setUint32(4, 5, Endian.little)
      ..setUint32(8, 10, Endian.little);
    expect(probeSplatHead(clear.buffer.asUint8List(), 4096), const SplatRefused(SplatFileProblem.newerSpz, ''));
  });

  test('a PLY the module was never seen to read is refused: harmonics past degree 3, values not stored as floats', () {
    // The same rules as SplatHeader.kt: degrees 0 to 3, floats or doubles (measured on a Quest 3 on 31 October 2026)
    for (final (rest, degree) in [(0, 0), (9, 1), (24, 2), (45, 3)]) {
      expect((plyOf(rest) as SplatHead).shDegree, degree, reason: '$rest');
    }
    final doubles = plyOf(45, types: {'x': 'double', 'rot_0': 'double', 'f_rest_7': 'double'});
    expect((doubles as SplatHead).shDegree, 3);
    for (final rest in [72, 12, 3, 46]) {
      expect(plyOf(rest), const SplatRefused(SplatFileProblem.unsupportedPly, ''), reason: '$rest');
    }
    for (final (name, type) in [
      ('rot_0', 'uchar'),
      ('rot_3', 'ushort'),
      ('f_dc_1', 'uchar'),
      ('f_rest_4', 'uchar'),
      ('f_dc_0', 'int'),
    ]) {
      expect(plyOf(9, types: {name: type}), const SplatRefused(SplatFileProblem.unsupportedPly, ''), reason: name);
    }
  });

  test('an SPZ whose fixed point positions cannot be read is damaged', () {
    for (final bits in [1, 12, 23]) {
      expect(probeSplatHead(gzipOf(spzHeader(2, fractional: bits)), 100), isA<SplatHead>(), reason: '$bits');
    }
    for (final (version, bits) in [(2, 0), (2, 24), (2, 32), (3, 0), (3, 40)]) {
      expect(
        probeSplatHead(gzipOf(spzHeader(version, fractional: bits)), 100),
        const SplatRefused(SplatFileProblem.damaged, ''),
        reason: 'version $version, $bits bits',
      );
    }
    // Version 1 stores its positions as float16: its header may say anything
    expect(probeSplatHead(gzipOf(spzHeader(1, fractional: 0)), 100), isA<SplatHead>());
  });

  test('anything else is no splat', () {
    for (final bytes in [Uint8List(0), Uint8List.fromList(utf8.encode('hello')), Uint8List(100)]) {
      expect(probeSplatHead(bytes, 100), const SplatRefused(SplatFileProblem.notASplat, ''));
    }
  });

  test('the tool is what a comment names, never guessed', () {
    expect(splatToolOf('Generated by Postshot'), 'Postshot');
    expect(splatToolOf('Exported from Polycam 3.2'), 'Polycam 3.2');
    expect(splatToolOf('created with SuperSplat'), 'SuperSplat');
    expect(splatToolOf('vertices 1234'), isNull);
    expect(splatToolOf('Generated by '), isNull);
    expect(splatToolOf('Generated by ${'x' * 200}'), hasLength(splatMaxToolLength));
  });

  test('the probe reads no more than its head', () {
    final bytes = bytesOf('long_header.ply');
    expect(bytes.length, greaterThan(splatHeadBytes));
    expect(probeSplatHead(bytes, bytes.length), const SplatRefused(SplatFileProblem.damaged, ''));
  });
}
