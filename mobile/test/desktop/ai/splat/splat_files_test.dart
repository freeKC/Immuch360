// The last step of a splat scene (lot SP3): the export of Brush read, scaled and written as the SPZ for the headset
// and, when asked, the PLY for other 3D apps, in an isolate; the two files hold the same gaussians and the probe of
// the headset takes both. 150 000 gaussians of degree 3 go through in seconds (under 3 s on the computer of the
// measure, compiled; the bound here only catches a step gone slow).

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_files.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_scale.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/splat/splat_cloud.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/spz_v2_writer.dart';

import '../../../domain/splat/splat_test_clouds.dart';

/// [count] gaussians of degree 3 as Brush 0.3.0 exports them, on the floor and the walls of a room of 6 x 4 x 2.5 m in
/// units of [unit] metres (y down, the floor at y = 0), and the centres of 40 cameras carried 1.5 m above the floor
({Uint8List ply, Float64List cameras}) _brushRoom(int count, {double unit = 0.4, int seed = 1}) {
  final random = math.Random(seed);
  double between(double low, double high) => low + random.nextDouble() * (high - low);
  final names = brushOrder(3);
  final header = StringBuffer('ply\nformat binary_little_endian 1.0\n')
    ..write('comment Exported from Brush\ncomment Vertical axis: y\ncomment SH degree: 3\n')
    ..write('element vertex $count\n');
  for (final name in names) {
    header.write('property float $name\n');
  }
  header.write('end_header\n');
  final head = header.toString().codeUnits;
  final out = Uint8List(head.length + count * names.length * 4)..setRange(0, head.length, head);
  final data = ByteData.sublistView(out, head.length);
  final slot = {for (var k = 0; k < names.length; k++) names[k]: k};
  final row = Float32List(names.length);
  for (var i = 0; i < count; i++) {
    for (var k = 0; k < row.length; k++) {
      row[k] = between(-0.9, 0.9);
    }
    final onFloor = random.nextDouble() < 0.5;
    final x = between(0, 6);
    final z = between(0, 4);
    row[slot['x']!] = (onFloor ? x : (random.nextBool() ? 0.0 : 6.0)) / unit;
    row[slot['y']!] = -(onFloor ? 0.0 : between(0, 2.5)) / unit;
    row[slot['z']!] = z / unit;
    row[slot['opacity']!] = between(-5, 5);
    for (var k = 0; k < 3; k++) {
      row[slot['scale_$k']!] = between(-8, -3);
      row[slot['f_dc_$k']!] = between(-2, 2);
    }
    for (var k = 0; k < row.length; k++) {
      data.setFloat32((i * row.length + k) * 4, row[k], Endian.little);
    }
  }
  final cameras = Float64List.fromList([
    for (var k = 0; k < 40; k++) ...[
      (3 + 1.8 * math.cos(k * math.pi / 20)) / unit,
      -1.5 / unit,
      (2 + 1.2 * math.sin(k * math.pi / 20)) / unit,
    ],
  ]);
  return (ply: out, cameras: cameras);
}

void main() {
  late Directory folder;

  setUp(() => folder = Directory.systemTemp.createTempSync('splat-files'));
  tearDown(() => folder.deleteSync(recursive: true));

  test('the SPZ for the headset and the PLY for other apps, the same gaussians scaled, in an isolate', () async {
    final room = _brushRoom(2000);
    final brush = File('${folder.path}/export_20000.ply')..writeAsBytesSync(room.ply);
    final written = await writeSplatFiles(
      brushPly: brush.path,
      spzPath: '${folder.path}/salon_splat.spz.part',
      plyPath: '${folder.path}/salon_splat.ply.part',
      subject: SplatSubject.place,
      cameras: room.cameras,
    );
    expect(written.gaussians, 2000);
    expect(written.dropped, 0);
    expect(written.shDegree, 3);
    expect(written.scale.rule, SplatScaleRule.floor);
    expect(written.scale.factor, closeTo(0.4, 0.4 * 0.02));
    final spz = File('${folder.path}/salon_splat.spz.part').readAsBytesSync();
    final ply = File('${folder.path}/salon_splat.ply.part').readAsBytesSync();
    expect(written.spzBytes, spz.length);
    expect(written.plyBytes, ply.length);
    // The same gaussians in both: the PLY read again gives the data of the SPZ
    final cloud = readSplatPly(room.ply).scaled(written.scale.factor);
    expect(
      ply,
      writeSplatPly(cloud, comments: splatScenePlyComments(readSplatPly(room.ply).comments, written.scale.note)),
    );
    expect(gzip.decode(spz), spzV2Payload(readSplatPly(ply)));
    expect(
      probeSplatHead(spz, spz.length),
      const SplatHead(format: SplatFormat.spz, formatVersion: 2, gaussians: 2000, shDegree: 3),
    );
    expect(
      probeSplatHead(ply, ply.length),
      const SplatHead(
        format: SplatFormat.ply,
        formatVersion: 1,
        gaussians: 2000,
        shDegree: 3,
        tool: 'Immuch360 Desktop (COLMAP, Brush)',
      ),
    );
  });

  test('the golden files of make_splat_fixtures.py on this system too (the job of Windows runs test/desktop)', () {
    Uint8List bytesOf(String name) => File('test/fixtures/splat/$name').readAsBytesSync();
    for (final (ply, spz) in [('edges_sh3.ply', 'edges_sh3_v2.spz'), ('scene_sh3.ply', 'scene_sh3_v2.spz')]) {
      expect(spzV2Payload(readSplatPly(bytesOf(ply))), gzip.decode(bytesOf(spz)), reason: ply);
    }
    final brush = readSplatPly(bytesOf('brush_sh3.ply'));
    const note = 'Immuch360 splat-v1, place, scale 0.500000 (floor)';
    expect(
      writeSplatPly(brush.scaled(0.5), comments: splatScenePlyComments(brush.comments, note)),
      bytesOf('scene_sh3.ply'),
    );
  });

  test('no .ply unless asked; an object of 1 m; a lower degree for the headset', () async {
    final room = _brushRoom(500, seed: 2);
    final brush = File('${folder.path}/export.ply')..writeAsBytesSync(room.ply);
    final written = await writeSplatFiles(
      brushPly: brush.path,
      spzPath: '${folder.path}/vase_splat.spz.part',
      subject: SplatSubject.object,
      shDegree: 1,
    );
    expect(written.plyBytes, isNull);
    expect(folder.listSync().map((e) => e.uri.pathSegments.last).toSet(), {'export.ply', 'vase_splat.spz.part'});
    expect(written.scale.rule, SplatScaleRule.objectSize);
    expect(written.shDegree, 1);
    final spz = File('${folder.path}/vase_splat.spz.part').readAsBytesSync();
    expect((probeSplatHead(spz, spz.length) as SplatHead).shDegree, 1);
  });

  test('an export the headset could not read, or none, fails with why', () async {
    final room = _brushRoom(50, seed: 3);
    final brush = File('${folder.path}/export.ply')..writeAsBytesSync(room.ply);
    await expectLater(
      writeSplatFiles(
        brushPly: brush.path,
        spzPath: '${folder.path}/a.spz.part',
        subject: SplatSubject.place,
        maxGaussians: 49,
      ),
      throwsA(isA<SplatFormatException>()),
    );
    await expectLater(
      writeSplatFiles(
        brushPly: '${folder.path}/gone.ply',
        spzPath: '${folder.path}/b.spz',
        subject: SplatSubject.place,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(File('${folder.path}/a.spz.part').existsSync(), isFalse);
  });

  test('150 000 gaussians of degree 3, as the copy for the headset, in seconds', () async {
    final room = _brushRoom(SplatV1.maxGaussians, seed: 4);
    final brush = File('${folder.path}/export_20000.ply')..writeAsBytesSync(room.ply);
    final watch = Stopwatch()..start();
    final written = await writeSplatFiles(
      brushPly: brush.path,
      spzPath: '${folder.path}/salon_splat.spz.part',
      plyPath: '${folder.path}/salon_splat.ply.part',
      subject: SplatSubject.place,
      cameras: room.cameras,
    );
    watch.stop();
    // ignore: avoid_print
    print('150 000 gaussians: ${watch.elapsedMilliseconds} ms, SPZ ${written.spzBytes} bytes, PLY ${written.plyBytes}');
    expect(written.gaussians, SplatV1.maxGaussians);
    // The rows of Brush, 236 bytes each, under our header: its comments in place of those of Brush
    int lines(List<String> comments) => comments.fold(0, (sum, c) => sum + 'comment $c\n'.length);
    const brushComments = ['Exported from Brush', 'Vertical axis: y', 'SH degree: 3'];
    expect(
      written.plyBytes,
      room.ply.length - lines(brushComments) + lines(splatScenePlyComments(brushComments, written.scale.note)),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 30)));
  });
}
