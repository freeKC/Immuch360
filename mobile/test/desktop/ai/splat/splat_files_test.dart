// The last step of a splat scene (lot SP3): the export of Brush read, scaled and written as the SPZ for the headset
// and, when asked, the PLY for other 3D apps, in an isolate; the two files hold the same gaussians and the probe of
// the headset takes both, but for an object whose whole scene the headset would open as a place: its SPZ is cropped
// around the point its cameras look at, the PLY kept whole (review of lot SPF2). 150 000 gaussians of degree 3 go
// through in seconds (under 3 s on the computer of the measure, compiled; the bound here only catches a step gone
// slow).

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_files.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_scale.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/splat/splat_cloud.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/spz_v2_writer.dart';

import '../../../domain/splat/splat_test_clouds.dart';

/// The gaussians of [cloud] whose entry of [kept] is not 0, in their order
SplatCloud _keptRows(SplatCloud cloud, Uint8List kept) => SplatCloud(
  count: kept.where((k) => k != 0).length,
  shDegree: cloud.shDegree,
  rows: Float32List.fromList([
    for (var i = 0; i < cloud.count; i++)
      if (kept[i] != 0) ...cloud.rows.sublist(i * cloud.stride, (i + 1) * cloud.stride),
  ]),
);

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

/// [count] gaussians of degree 3 as Brush 0.3.0 exports them, of an object filmed on a desk as FreeKC filmed his
/// repeater on 3 November, lying on its side as COLMAP turned it: the up of the room along -x of the file, 0.05 m a
/// unit. The first half of the rows on the desk (1 x 0.6 m), the next fifth on a box of 8 x 9 x 5 cm standing on it,
/// the rest on a monitor behind; the centres of 60 cameras going round the box 25 cm away, 20 to 60 degrees above the
/// desk, and where each looks (at the box)
({Uint8List ply, Float64List cameras, Float64List axes, int desk, int box}) _brushDesk(int count, {int seed = 1}) {
  final random = math.Random(seed);
  double between(double low, double high) => low + random.nextDouble() * (high - low);
  const unit = 0.05;
  // Metres, y up, to the file: up along -x
  List<double> file(List<double> m) => [-m[1] / unit + 2, m[0] / unit - 1, m[2] / unit + 3];
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
  final desk = count ~/ 2;
  final box = count ~/ 5;
  for (var i = 0; i < count; i++) {
    for (var k = 0; k < row.length; k++) {
      row[k] = between(-0.9, 0.9);
    }
    final List<double> metres;
    if (i < desk) {
      metres = [between(-0.5, 0.5), 0, between(-0.3, 0.3)];
    } else if (i < desk + box) {
      metres = switch (random.nextInt(3)) {
        0 => [between(-0.04, 0.04), 0.09, between(-0.025, 0.025)],
        1 => [random.nextBool() ? -0.04 : 0.04, between(0, 0.09), between(-0.025, 0.025)],
        _ => [between(-0.04, 0.04), between(0, 0.09), random.nextBool() ? -0.025 : 0.025],
      };
    } else {
      metres = [between(-0.3, 0.3), between(0.1, 0.45), -0.28];
    }
    final at = file(metres);
    row[slot['x']!] = at[0];
    row[slot['y']!] = at[1];
    row[slot['z']!] = at[2];
    row[slot['opacity']!] = between(-5, 5);
    for (var k = 0; k < 3; k++) {
      row[slot['scale_$k']!] = between(-8, -3);
    }
    for (var k = 0; k < row.length; k++) {
      data.setFloat32((i * row.length + k) * 4, row[k], Endian.little);
    }
  }
  final cameras = <double>[];
  final axes = <double>[];
  for (var k = 0; k < 60; k++) {
    final azimuth = 4 * math.pi * k / 60;
    final elevation = between(20, 60) * math.pi / 180;
    final centre = [
      0.25 * math.cos(elevation) * math.cos(azimuth),
      0.045 + 0.25 * math.sin(elevation),
      0.25 * math.cos(elevation) * math.sin(azimuth),
    ];
    final look = [-centre[0], 0.045 - centre[1], -centre[2]];
    final length = math.sqrt(look[0] * look[0] + look[1] * look[1] + look[2] * look[2]);
    cameras.addAll(file(centre));
    // A direction, not a point: turned as the points are, not moved
    axes.addAll([-look[1] / length, look[0] / length, look[2] / length]);
  }
  return (ply: out, cameras: Float64List.fromList(cameras), axes: Float64List.fromList(axes), desk: desk, box: box);
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
    expect((written.crop, written.cropped), (null, 0), reason: 'no point looked at: the whole scene at 1 m');
    expect(written.gaussians, 500);
    expect(written.shDegree, 1);
    final spz = File('${folder.path}/vase_splat.spz.part').readAsBytesSync();
    expect((probeSplatHead(spz, spz.length) as SplatHead).shDegree, 1);
  });

  test('an object lying on its side: both files set upright on its desk, the box standing on it at 1 m, the note '
      'saying so; the SPZ cropped around the box, which the headset opens as an object, the PLY whole', () async {
    final scene = _brushDesk(6000);
    final brush = File('${folder.path}/export_20000.ply')..writeAsBytesSync(scene.ply);
    final written = await writeSplatFiles(
      brushPly: brush.path,
      spzPath: '${folder.path}/repeteur_splat.spz.part',
      plyPath: '${folder.path}/repeteur_splat.ply.part',
      subject: SplatSubject.object,
      cameras: scene.cameras,
      axes: scene.axes,
    );
    expect(written.scale.upright, SplatUpright.supportPlane);
    expect(written.scale.rule, SplatScaleRule.lookedAt);
    expect(written.scale.supportTilt, closeTo(90, 1));
    final ply = readSplatPly(File('${folder.path}/repeteur_splat.ply.part').readAsBytesSync());
    expect(ply.comments, contains(written.scale.note));
    expect(written.scale.note, endsWith('(lookedAt), upright supportPlane'));
    final positions = ply.positions;
    List<double> axis(int from, int to, int axis) => [for (var i = from; i < to; i++) positions[3 * i + axis]]..sort();
    // The desk level (y down): its heights within a few millimetres of the metre-sized box
    final desk = axis(0, scene.desk, 1);
    expect(desk.last - desk.first, lessThan(0.01));
    // The box on it, its 9 cm of height above the desk, its longest side at 1 m between the percentiles 5 and 95 (as
    // the headset measures it: 9 cm of the box are some 8 cm so)
    final heights = axis(scene.desk, scene.desk + scene.box, 1);
    expect(heights.last, lessThan(desk.first + 0.01), reason: 'above the desk, y down');
    expect(desk.first - heights.first, closeTo(0.09 * written.scale.factor * 20, 0.01));
    double side(int axis) {
      final values = [for (var i = scene.desk; i < scene.desk + scene.box; i++) positions[3 * i + axis]]..sort();
      return values[values.length * 95 ~/ 100] - values[values.length * 5 ~/ 100];
    }

    expect([side(0), side(1), side(2)].reduce(math.max), closeTo(SplatV1.objectSize, 0.1));
    // The PLY whole, some ten metres: the headset would open it as a place
    expect(ply.count, 6000);
    expect(splatHeadsetSeesObject(positions), isFalse);
    // The SPZ: the gaussians of the PLY within 1.5 m of the box, all of the box, which the headset opens as an object
    final crop = written.crop!;
    expect(crop.radius, closeTo(1.5, 1e-9));
    expect(written.gaussians, crop.count);
    expect(written.cropped, 6000 - crop.count);
    expect(written.cropped, greaterThan(0));
    expect([for (var i = scene.desk; i < scene.desk + scene.box; i++) crop.kept[i]], everyElement(1));
    final spzBytes = File('${folder.path}/repeteur_splat.spz.part').readAsBytesSync();
    expect(written.spzBytes, spzBytes.length);
    expect(gzip.decode(spzBytes), spzV2Payload(_keptRows(ply, crop.kept)));
    final spz = DecodedSpz(Uint8List.fromList(gzip.decode(spzBytes)));
    expect(spz.count, crop.count);
    expect(splatHeadsetSeesObject(Float32List.fromList(spz.positions)), isTrue, reason: 'OBJECT_LIMIT 2.5 m');
    expect(
      (probeSplatHead(spzBytes, spzBytes.length) as SplatHead).gaussians,
      crop.count,
      reason: 'what the headset reads',
    );
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
