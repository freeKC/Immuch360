// The PLY of the splat scenes made on a computer (store/m2/splat-maker-2026-11-01/plan-2026-11-01.md, lot SP3): the
// export of Brush read whatever the order and the type of its properties, what no format carries left out, and the
// PLY written again in the order of 3D Gaussian Splatting, byte for byte the golden file of make_splat_fixtures.py,
// one the probe of the headset takes (float32, degrees 0 to 3, 45 f_rest at most).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/splat/splat_cloud.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';

import 'splat_test_clouds.dart';

void main() {
  final expected = jsonDecode(File('test/fixtures/splat/expected.json').readAsStringSync()) as Map<String, dynamic>;
  final headers = expected['headers'] as Map<String, dynamic>;
  final scene = headers['scene_sh3.ply'] as Map<String, dynamic>;

  Uint8List bytesOf(String name) => File('test/fixtures/splat/$name').readAsBytesSync();

  /// The rows of [cloud] as name -> value, in the order of the file
  List<Map<String, double>> rowsOf(SplatCloud cloud) {
    final names = splatPlyProperties(cloud.shDegree);
    return [
      for (var i = 0; i < cloud.count; i++)
        {for (var k = 0; k < names.length; k++) names[k]: cloud.rows[i * names.length + k]},
    ];
  }

  test('the properties of a gaussian in the order of 3D Gaussian Splatting, 14 and the harmonics', () {
    expect(splatPlyProperties(0), [
      'x', 'y', 'z', 'f_dc_0', 'f_dc_1', 'f_dc_2', 'opacity', //
      'scale_0', 'scale_1', 'scale_2', 'rot_0', 'rot_1', 'rot_2', 'rot_3',
    ]);
    expect(splatPlyProperties(3).sublist(6, 51), [for (var k = 0; k < 45; k++) 'f_rest_$k']);
    expect([for (var d = 0; d <= 3; d++) splatRowValues(d)], [14, 23, 38, 59]);
  });

  test("Brush's export is read in its alphabetical order, the rows a format cannot carry left out", () {
    final brush = readSplatPly(bytesOf('brush_sh3.ply'));
    expect(brush.count, 38);
    expect(brush.dropped, 2, reason: 'a NaN position and an infinite scale');
    expect(brush.shDegree, 3);
    expect(brush.comments, ['Exported from Brush', 'Vertical axis: y', 'SH degree: 3']);
    expect(brush.rows.length, 38 * 59);
    // The golden scene holds the same gaussians halved: every other value equal, bit for bit
    final golden = readSplatPly(bytesOf('scene_sh3.ply'));
    expect(golden.count, brush.count);
    final a = rowsOf(brush);
    final b = rowsOf(golden);
    for (var i = 0; i < a.length; i++) {
      for (final name in splatPlyProperties(3)) {
        if (name == 'x' || name == 'y' || name == 'z') {
          expect(b[i][name], f32(a[i][name]! * 0.5), reason: '$i $name');
        } else if (name.startsWith('scale_')) {
          expect(b[i][name], f32(a[i][name]! + math.log(0.5)), reason: '$i $name');
        } else {
          expect(b[i][name], a[i][name], reason: '$i $name');
        }
      }
    }
  });

  test('any order, floats or doubles, other properties of any type skipped, a header ending in CR LF', () {
    final gaussians = gaussiansOf(12, 2, seed: 3);
    final reference = readSplatPly(plyOf([for (final n in splatPlyProperties(2)) (n, 'float')], gaussians));
    expect(reference.count, 12);
    expect(reference.shDegree, 2);
    final random = math.Random(7);
    for (var attempt = 0; attempt < 6; attempt++) {
      final names = [...splatPlyProperties(2), 'nx', 'ny', 'nz', 'red', 'filter_3D']..shuffle(random);
      final properties = [
        for (final name in names)
          (
            name,
            switch (name) {
              'red' => 'uchar',
              'nx' => 'short',
              _ => attempt.isEven && name.startsWith('f_') ? 'double' : 'float',
            },
          ),
      ];
      final read = readSplatPly(plyOf(properties, gaussians, newline: attempt == 3 ? '\r\n' : '\n'));
      expect(read.count, 12, reason: '$names');
      expect(read.shDegree, 2);
      expect(read.rows, reference.rows, reason: '$names');
    }
    // In Brush's order, degree 0 to 3
    for (var degree = 0; degree <= 3; degree++) {
      final rows = gaussiansOf(5, degree, seed: degree);
      final read = readSplatPly(plyOf([for (final n in brushOrder(degree)) (n, 'float')], rows));
      expect(read.shDegree, degree);
      expect(rowsOf(read), [
        for (final row in rows) {for (final name in splatPlyProperties(degree)) name: f32(row[name]!)},
      ]);
    }
  });

  test('what the headset would not read is refused, with why', () {
    final rows = gaussiansOf(4, 3);
    List<(String, String)> floats(List<String> names) => [for (final n in names) (n, 'float')];
    final all = splatPlyProperties(3);
    final plain = plyOf(floats(all), rows);
    final refused = <String, Uint8List>{
      'ascii': plyOf(floats(all), rows, format: 'ascii'),
      'big endian': plyOf(floats(all), rows, format: 'binary_big_endian'),
      'degree 4': plyOf(floats([...splatPlyProperties(0), for (var k = 0; k < 72; k++) 'f_rest_$k']), rows),
      '10 f_rest': plyOf(floats([...splatPlyProperties(0), for (var k = 0; k < 10; k++) 'f_rest_$k']), rows),
      'f_rest_45 without f_rest_44': plyOf(
        floats([...splatPlyProperties(2), for (var k = 24; k < 44; k++) 'f_rest_$k', 'f_rest_45']),
        rows,
      ),
      'no rot_3': plyOf(floats(all.where((n) => n != 'rot_3').toList()), rows),
      'opacity in a byte': plyOf([for (final n in all) (n, n == 'opacity' ? 'uchar' : 'float')], rows),
      'harmonics as integers': plyOf([for (final n in all) (n, n == 'f_rest_7' ? 'int' : 'float')], rows),
      'x twice': plyOf([...floats(all), ('x', 'float')], rows),
      'a list': plyOf(floats(all), rows, extraHeader: ['property list uchar int vertex_indices']),
      'faces': plyOf(floats(all), rows, extraHeader: ['element face 2', 'property list uchar int vertex_indices']),
      'rows cut': Uint8List.sublistView(plain, 0, plain.length - 7),
      'no gaussian': plyOf(floats(all), const []),
      'every gaussian NaN': plyOf(floats(all), [
        for (final row in rows) {...row, 'z': double.nan},
      ]),
      'no end_header': ascii.encode('ply\nformat binary_little_endian 1.0\nelement vertex 1\n'),
      'not a PLY': Uint8List.fromList([0x1f, 0x8b, 8, 0, 0, 0, 0, 0]),
      'a count that is no number': latin1.encode(latin1.decode(plain).replaceFirst('vertex 4', 'vertex four')),
    };
    for (final MapEntry(key: why, value: bytes) in refused.entries) {
      expect(() => readSplatPly(bytes), throwsA(isA<SplatFormatException>()), reason: why);
    }
    // More gaussians than the cap of the training: refused, never cut
    expect(() => readSplatPly(bytesOf('brush_sh3.ply'), maxGaussians: 39), throwsA(isA<SplatFormatException>()));
    expect(readSplatPly(bytesOf('brush_sh3.ply'), maxGaussians: 40).count, 38);
    // Bytes after the rows are left alone, as the probe leaves them
    final longer = Uint8List.fromList([...plain, 1, 2, 3]);
    expect(readSplatPly(longer).count, 4);
  });

  test('written in the order of 3D Gaussian Splatting: byte for byte the golden file of make_splat_fixtures.py', () {
    final brush = readSplatPly(bytesOf('brush_sh3.ply'));
    final comments = splatScenePlyComments(brush.comments, scene['note'] as String);
    expect(comments, [
      'Made with Immuch360 Desktop (COLMAP, Brush)',
      'Exported from Brush',
      'Vertical axis: y',
      'SH degree: 3',
      'Immuch360 splat-v1, place, scale 0.500000 (floor)',
    ]);
    final written = writeSplatPly(brush.scaled(scene['scale'] as double), comments: comments);
    expect(written, bytesOf('scene_sh3.ply'));
    // Read and written again, the same bytes
    expect(writeSplatPly(readSplatPly(written), comments: comments), written);
  });

  test('the PLY written is one the probe of the headset takes: floats, degree 0 to 3, 45 f_rest at most', () {
    for (var degree = 0; degree <= 3; degree++) {
      final cloud = readSplatPly(
        plyOf([for (final n in brushOrder(degree)) (n, 'double')], gaussiansOf(9, degree, seed: 11 + degree)),
      );
      final written = writeSplatPly(cloud, comments: splatScenePlyComments(const ['Exported from Brush'], 'a note'));
      final head = latin1.decode(written.sublist(0, written.length - 9 * 4 * splatRowValues(degree)));
      final properties = head.split('\n').where((line) => line.startsWith('property ')).toList();
      expect(properties, [for (final n in splatPlyProperties(degree)) 'property float $n']);
      expect(properties.where((p) => p.contains('f_rest_')).length, 3 * splatShCoefficients(degree));
      expect(head, startsWith('ply\nformat binary_little_endian 1.0\ncomment Made with Immuch360 Desktop'));
      expect(head, endsWith('end_header\n'));
      expect(
        probeSplatHead(written, written.length),
        SplatHead(
          format: SplatFormat.ply,
          formatVersion: 1,
          gaussians: 9,
          shDegree: degree,
          tool: 'Immuch360 Desktop (COLMAP, Brush)',
        ),
      );
    }
    final golden = bytesOf('scene_sh3.ply');
    expect(
      probeSplatHead(golden, golden.length),
      SplatHead(
        format: SplatFormat.ply,
        formatVersion: 1,
        gaussians: scene['gaussians'] as int,
        shDegree: 3,
        tool: scene['tool'] as String,
      ),
    );
  });

  test('our comment first, the others in printable ASCII, ours never twice, the header kept short', () {
    expect(splatScenePlyComments(const [], 'n'), ['Made with Immuch360 Desktop (COLMAP, Brush)', 'n']);
    expect(
      splatScenePlyComments(const [
        'Made with Immuch360 Desktop (COLMAP, Brush)',
        'Été\u0007 at\tnoon ',
        '  ',
        'x',
      ], 'n'),
      ['Made with Immuch360 Desktop (COLMAP, Brush)', 't atnoon', 'x', 'n'],
    );
    final many = splatScenePlyComments([for (var k = 0; k < 100; k++) 'comment $k ${'y' * 500}'], 'n');
    expect(many.length, lessThanOrEqualTo(2 + splatMaxSourceComments));
    expect(many.every((c) => c.length <= splatMaxCommentLength), isTrue);
    // The note of the scale is always there, at the end
    expect(many.last, 'n');
  });

  test('scaled: the positions multiplied, the log of the factor added to the log scales, nothing else moved', () {
    final cloud = readSplatPly(plyOf([for (final n in brushOrder(1)) (n, 'float')], gaussiansOf(3, 1, seed: 5)));
    final scaled = cloud.scaled(2.5);
    final before = rowsOf(cloud);
    final after = rowsOf(scaled);
    for (var i = 0; i < 3; i++) {
      for (final name in splatPlyProperties(1)) {
        final value = before[i][name]!;
        final want = switch (name) {
          'x' || 'y' || 'z' => f32(value * 2.5),
          'scale_0' || 'scale_1' || 'scale_2' => f32(value + math.log(2.5)),
          _ => value,
        };
        expect(after[i][name], want, reason: '$i $name');
      }
    }
    expect(identical(cloud.scaled(1.0).rows, cloud.rows), isFalse);
    expect(cloud.scaled(1.0).rows, cloud.rows);
    expect(() => cloud.scaled(0), throwsArgumentError);
    expect(() => cloud.scaled(double.nan), throwsArgumentError);
    // The positions alone, x y z of each gaussian
    expect(cloud.positions, [
      for (final row in before) ...[row['x'], row['y'], row['z']],
    ]);
  });
}
