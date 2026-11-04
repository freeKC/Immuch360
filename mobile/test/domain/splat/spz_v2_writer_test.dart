// The SPZ version 2 of the splat scenes made on a computer (store/m2/splat-maker-2026-11-01/plan-2026-11-01.md, lot
// SP3): its data, once inflated, is byte for byte that of the golden files of make_splat_fixtures.py; read back it is
// within the steps of the format (the tolerances of the measure of 1 November 2026); and it is one file the headset
// reads to its end: version 2, 12 fractional bits, no flag, degree 0 to 3, one gzip member without options.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/splat/splat_cloud.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/spz_v2_writer.dart';

import 'splat_test_clouds.dart';

void main() {
  Uint8List bytesOf(String name) => File('test/fixtures/splat/$name').readAsBytesSync();
  Uint8List inflate(Uint8List bytes) => Uint8List.fromList(gzip.decode(bytes));

  test('the data of the golden files of make_splat_fixtures.py, byte for byte', () {
    for (final (ply, spz) in [
      ('sh3.ply', 'sh3_v2.spz'),
      ('edges_sh3.ply', 'edges_sh3_v2.spz'),
      ('scene_sh3.ply', 'scene_sh3_v2.spz'),
    ]) {
      expect(spzV2Payload(readSplatPly(bytesOf(ply))), inflate(bytesOf(spz)), reason: ply);
    }
    // Brush's export, its NaN and infinite rows left out, scaled as the golden scene: the same data
    expect(spzV2Payload(readSplatPly(bytesOf('brush_sh3.ply')).scaled(0.5)), inflate(bytesOf('scene_sh3_v2.spz')));
  });

  test('the edges of the format: a floater past the fixed point held at its end, a quaternion of zero length turns '
      'nothing', () {
    final payload = spzV2Payload(readSplatPly(bytesOf('scene_sh3.ply')));
    final spz = DecodedSpz(payload);
    expect(spz.count, 38);
    // brush_sh3.ply: row 3 at x = 5000 (2500 once halved), row 11 (10 once row 7 is left out) of zero length
    expect(payload.sublist(16 + 9 * 3, 16 + 9 * 3 + 3), [0xff, 0xff, 0x7f]);
    const rotations = 16 + 38 * (9 + 1 + 3 + 3);
    expect(payload.sublist(rotations + 3 * 10, rotations + 3 * 10 + 3), [128, 128, 128]);
  });

  test('read back, within the steps of the format: the tolerances of the measure (1.2e-4, 0.002, 0.066)', () {
    final rows = gaussiansOf(5000, 3, seed: 21);
    final cloud = readSplatPly(plyOf([for (final n in brushOrder(3)) (n, 'float')], rows));
    final spz = DecodedSpz(spzV2Payload(cloud));
    expect(spz.count, 5000);
    expect(spz.shDegree, 3);
    expect(spz.fractionalBits, 12);
    var position = 0.0;
    var alpha = 0.0;
    var color = 0.0;
    var scale = 0.0;
    var rotation = 0.0;
    var sh1 = 0.0;
    var sh = 0.0;
    for (var i = 0; i < 5000; i++) {
      final g = {for (final e in rows[i].entries) e.key: f32(e.value)};
      for (var k = 0; k < 3; k++) {
        position = math.max(position, (spz.positions[3 * i + k] - g[['x', 'y', 'z'][k]]!).abs());
        color = math.max(color, (spz.colors[3 * i + k] - g['f_dc_$k']!).abs());
        scale = math.max(scale, (spz.scales[3 * i + k] - g['scale_$k']!).abs());
      }
      alpha = math.max(alpha, (spz.alphas[i] - 1 / (1 + math.exp(-g['opacity']!))).abs());
      final q = [g['rot_1']!, g['rot_2']!, g['rot_3']!, g['rot_0']!];
      final norm = math.sqrt(q.fold(0.0, (s, c) => s + c * c)) * (q[3] < 0 ? -1 : 1);
      for (var k = 0; k < 3; k++) {
        rotation = math.max(rotation, (spz.rotations[4 * i + k] - q[k] / norm).abs());
      }
      for (var j = 0; j < 15; j++) {
        for (var c = 0; c < 3; c++) {
          final error = (spz.sh[(i * 15 + j) * 3 + c] - g['f_rest_${c * 15 + j}']!).abs();
          if (j < 3) {
            sh1 = math.max(sh1, error);
          } else {
            sh = math.max(sh, error);
          }
        }
      }
    }
    // Half a step of each: 0.5 / 4096 (the 1.2e-4 of the measure), 0.5 / 255 (0.002), 8.5 / 128 for the harmonics
    // past degree 1 (0.066), 4.5 / 128 for degree 1; colours, scales and rotations half a step of their byte
    const slack = 1e-9;
    expect(position, lessThanOrEqualTo(0.5 / 4096 + slack));
    expect(alpha, lessThanOrEqualTo(0.5 / 255 + slack));
    expect(sh, lessThanOrEqualTo(8.5 / 128 + slack));
    expect(sh1, lessThanOrEqualTo(4.5 / 128 + slack));
    expect(color, lessThanOrEqualTo(0.5 / 255 / 0.15 + slack));
    expect(scale, lessThanOrEqualTo(0.5 / 16 + slack));
    expect(rotation, lessThanOrEqualTo(0.5 / 127.5 + slack));
    // and they are reached, so the bounds say something
    expect(position, greaterThan(0.45 / 4096));
    expect(sh, greaterThan(7.5 / 128));
  });

  test('the file: one gzip member without options, version 2, 12 fractional bits, no flag, as the probe reads it', () {
    final cloud = readSplatPly(bytesOf('brush_sh3.ply')).scaled(0.5);
    final written = writeSpzV2(cloud);
    expect(written.sublist(0, 4), [0x1f, 0x8b, 8, 0], reason: 'deflate, no name, comment or extra field');
    final payload = inflate(written);
    expect(payload, spzV2Payload(cloud));
    final trailer = ByteData.sublistView(written, written.length - 8);
    expect(trailer.getUint32(4, Endian.little), payload.length, reason: 'the member ends the file');
    expect(trailer.getUint32(0, Endian.little), crc32(payload));
    final head = ByteData.sublistView(payload, 0, 16);
    expect(head.getUint32(0, Endian.little), splatSpzMagic);
    expect(head.getUint32(4, Endian.little), 2);
    expect(head.getUint32(8, Endian.little), 38);
    expect([head.getUint8(12), head.getUint8(13), head.getUint8(14), head.getUint8(15)], [3, 12, 0, 0]);
    expect(DecodedSpz(payload).length, payload.length, reason: '19 bytes a gaussian and its 45 harmonics, no more');
    expect(
      probeSplatHead(written, written.length),
      const SplatHead(format: SplatFormat.spz, formatVersion: 2, gaussians: 38, shDegree: 3),
    );
  });

  test('a lower degree keeps the first coefficients of each gaussian, never a higher one', () {
    final cloud = readSplatPly(bytesOf('scene_sh3.ply'));
    final full = spzV2Payload(cloud);
    const arrays = 16 + 38 * 19;
    for (var degree = 0; degree <= 3; degree++) {
      final payload = spzV2Payload(cloud, shDegree: degree);
      final keep = 3 * splatShCoefficients(degree);
      expect(payload[12], degree);
      expect(payload.sublist(13, arrays), full.sublist(13, arrays));
      expect(payload.sublist(arrays), [
        for (var i = 0; i < 38; i++) ...full.sublist(arrays + 45 * i, arrays + 45 * i + keep),
      ]);
    }
    final degree1 = readSplatPly(plyOf([for (final n in brushOrder(1)) (n, 'float')], gaussiansOf(4, 1)));
    expect(spzV2Payload(degree1, shDegree: 3)[12], 1);
    expect(() => spzV2Payload(cloud, shDegree: -1), throwsArgumentError);
  });

  test('no gaussian, no file', () {
    final empty = SplatCloud(count: 0, shDegree: 0, rows: Float32List(0));
    expect(() => spzV2Payload(empty), throwsA(isA<SplatFormatException>()));
  });

  test('the SPZ the Dart writer made of brush_sh3.ply, kept for the Kotlin tests: its data is the golden one', () {
    final made = writeSpzV2(readSplatPly(bytesOf('brush_sh3.ply')).scaled(0.5));
    final file = File('test/fixtures/splat/scene_sh3_v2_dart.spz');
    // IMMUCH360_WRITE_SPLAT_FIXTURES=1 writes it again (its gzip bytes follow the zlib of the system)
    if (Platform.environment['IMMUCH360_WRITE_SPLAT_FIXTURES'] == '1') {
      file.writeAsBytesSync(made);
    }
    final kept = file.readAsBytesSync();
    expect(kept.sublist(0, 4), [0x1f, 0x8b, 8, 0]);
    expect(inflate(kept), inflate(made));
    expect(inflate(kept), inflate(bytesOf('scene_sh3_v2.spz')));
  });

  test('the most bytes of the SPZ of a PLY, known from its head before its conversion, is never passed', () {
    for (final name in ['sh3.ply', 'edges_sh3.ply', 'scene_sh3.ply', 'brush_sh3.ply', 'axes.ply']) {
      final ply = bytesOf(name);
      final head = probeSplatHead(ply, ply.length) as SplatHead;
      expect(writeSpzV2(readSplatPly(ply)).length, lessThanOrEqualTo(spzV2MaxBytes(head.gaussians, head.shDegree)));
    }
    // Values spread over the range of the format
    for (final degree in [0, 3]) {
      final properties = [for (final name in splatPlyProperties(degree)) (name, 'float')];
      final cloud = readSplatPly(plyOf(properties, gaussiansOf(4000, degree)));
      expect(writeSpzV2(cloud).length, lessThanOrEqualTo(spzV2MaxBytes(4000, degree)), reason: 'degree $degree');
    }
  });
}

/// The CRC-32 of gzip (ISO 3309), bit by bit
int crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var k = 0; k < 8; k++) {
      crc = crc & 1 != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}
