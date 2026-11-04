// The drawn poster of a splat photo (lot L5, plan of 3 November 2026, section 7): the gaussians read for it (the
// positions the placement samples are those of viewer_expected.json), the drawing of the first view, the mark behind
// its switch, the card of a version 4, and a poster the writer takes.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// The JPEG encoder of package:image (MIT), resolved for the TIFF photos and the 3D conversions, as they import it
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/models/splat/splat_reducer.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_exif.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_writer.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_poster_card.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_poster_cloud.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_poster_draw.dart';

final Map<String, dynamic> _expected =
    jsonDecode(File('test/fixtures/splat_viewer/viewer_expected.json').readAsStringSync()) as Map<String, dynamic>;

File _scene(String name) {
  final viewer = File('test/fixtures/splat_viewer/$name');
  return viewer.existsSync() ? viewer : File('test/fixtures/splat/$name');
}

SplatHead _head(File file) {
  final bytes = file.readAsBytesSync();
  return probeSplatHead(Uint8List.sublistView(bytes, 0, math.min(bytes.length, splatHeadBytes)), bytes.length)
      as SplatHead;
}

/// The share of the pixels of [jpeg] brighter than [level] in the box given
double _lit(img.Image image, {int level = 24, int left = 0, int top = 0, int? right, int? bottom}) {
  var seen = 0;
  var lit = 0;
  for (var y = top; y < (bottom ?? image.height); y += 2) {
    for (var x = left; x < (right ?? image.width); x += 2) {
      final pixel = image.getPixel(x, y);
      seen++;
      if (pixel.r + pixel.g + pixel.b > 3 * level) {
        lit++;
      }
    }
  }
  return seen == 0 ? 0 : lit / seen;
}

/// The posters of the tests, kept for the review when SPLAT_POSTER_SAMPLES names a folder
void _keepSample(String name, List<int> jpeg) {
  final folder = Platform.environment['SPLAT_POSTER_SAMPLES'];
  if (folder != null) {
    File('$folder/$name').writeAsBytesSync(jpeg);
  }
}

void main() {
  test('the positions the placement samples are those of viewer_expected.json, for every reader', () async {
    for (final MapEntry(key: name, value: wanted as Map<String, dynamic>) in _expected.entries.where(
      (entry) => entry.key != 'about',
    )) {
      final file = _scene(name);
      final cloud = await readSplatPosterCloud(file, _head(file));
      final positions = wanted['positions'] as List;
      expect(cloud.fileGaussians, wanted['count'], reason: name);
      expect(cloud.samples.length, positions.length, reason: name);
      for (var k = 0; k < positions.length; k++) {
        expect((cloud.samples[k] - (positions[k] as num)).abs(), lessThan(1e-6), reason: '$name $k');
      }
      expect(cloud.count, wanted['count'], reason: '$name: all kept below the limit');
      for (var i = 0; i < cloud.count; i++) {
        expect(cloud.opacities[i], inInclusiveRange(0, 1));
        final q = cloud.rotations;
        final norm =
            q[4 * i] * q[4 * i] +
            q[4 * i + 1] * q[4 * i + 1] +
            q[4 * i + 2] * q[4 * i + 2] +
            q[4 * i + 3] * q[4 * i + 3];
        expect(norm, closeTo(1, 1e-4), reason: '$name rotation $i');
      }
    }
  });

  test('above the limit, the strongest are kept, as the reducer keeps them', () async {
    final file = File('test/fixtures/splat/ranked_v3.spz');
    final head = _head(file);
    final keep = head.gaussians ~/ 3;
    final cloud = await readSplatPosterCloud(file, head, keep: keep);
    expect(cloud.count, keep);
    expect(cloud.fileGaussians, head.gaussians);
    final kept = selectStrongest(await scoreSplat(file, head), keep);
    final all = await readSplatPosterCloud(file, head, keep: head.gaussians);
    var at = 0;
    for (var i = 0; i < head.gaussians; i++) {
      if (kept[i]) {
        expect(cloud.positions[3 * at], all.positions[3 * i], reason: 'gaussian $i');
        expect(cloud.opacities[at], all.opacities[i], reason: 'gaussian $i');
        at++;
      }
    }
  });

  test('a degree 0 colour of an SPZ and of a PLY of the same gaussians agree', () async {
    final spz = await readSplatPosterCloud(_scene('axes_v2.spz'), _head(_scene('axes_v2.spz')));
    final ply = await readSplatPosterCloud(_scene('axes.ply'), _head(_scene('axes.ply')));
    expect(spz.count, ply.count);
    for (var i = 0; i < spz.count; i += 37) {
      for (var c = 0; c < 3; c++) {
        expect(spz.colors[3 * i + c], closeTo(ply.colors[3 * i + c], 0.02), reason: 'colour $i');
        expect(spz.scales[3 * i + c], closeTo(ply.scales[3 * i + c], ply.scales[3 * i + c] * 0.05), reason: 'scale $i');
      }
      expect(spz.opacities[i], closeTo(ply.opacities[i], 0.01), reason: 'opacity $i');
    }
  });

  test('the first view of an object shows it in the middle of a poster of 3:2, the same bytes each time', () async {
    final file = _scene('axes_v2.spz');
    final first = await drawSplatPoster(file: file, head: _head(file), mark: false);
    expect(first.width, 1600);
    expect(first.height, 1067);
    expect(isSplatPosterShape(first.width, first.height), isTrue);
    expect(first.upright, 'yDown');
    expect(first.drawn, greaterThan(600));
    final image = img.decodeJpg(first.jpeg)!;
    expect(image.width, 1600);
    expect(image.height, 1067);
    // The object fits the narrower side: lit in the middle, the edges black
    expect(_lit(image, left: 500, top: 250, right: 1100, bottom: 820), greaterThan(0.01));
    expect(_lit(image, right: 200), 0);
    expect(_lit(image, left: 1400), 0);
    _keepSample('render_axes_v2.jpg', first.jpeg);
    final again = await drawSplatPoster(file: file, head: _head(file), mark: false);
    expect(again.jpeg, first.jpeg);
  });

  test('a place is drawn from inside, the orientation chosen before the save wins over the floor rule', () async {
    final file = _scene('room_floor.spz');
    final byFloor = await drawSplatPoster(file: file, head: _head(file), mark: false);
    expect(byFloor.upright, 'yUp');
    _keepSample('render_room_floor.jpg', byFloor.jpeg);
    expect(_lit(img.decodeJpg(byFloor.jpeg)!), greaterThan(0.1));
    final chosen = await drawSplatPoster(file: file, head: _head(file), up: 'zUp', mark: false);
    expect(chosen.upright, 'zUp');
    expect(chosen.jpeg, isNot(byFloor.jpeg));
  });

  test('a PLY and a version 1 or 3 SPZ draw too; a version 4 is left to the card', () async {
    for (final name in ['axes.ply', 'axes_v1.spz', 'axes_v3.spz', 'small_object.ply']) {
      final file = _scene(name);
      final drawing = await drawSplatPoster(file: file, head: _head(file));
      expect(drawing.drawn, greaterThan(100), reason: name);
    }
    final v4 = _scene('axes_v4.spz');
    await expectLater(drawSplatPoster(file: v4, head: _head(v4)), throwsA(isA<SplatReduceException>()));
  });

  test('the mark: a dark square and a white glyph at the bottom right, nothing else touched; none when off', () {
    const width = 1600;
    const height = 1067;
    final marked = img.decodeJpg(encodeSplatPoster(Uint8List(3 * width * height), width, height))!;
    final short = math.min(width, height);
    final side = (short * SplatMark.size).round();
    final margin = (short * SplatMark.margin).round();
    final left = width - margin - side;
    final top = height - margin - side;
    expect(_lit(marked, level: 128, left: left, top: top, right: left + side, bottom: top + side), greaterThan(0.1));
    expect(_lit(marked, level: 128, right: left - 4), 0);
    expect(_lit(marked, level: 128, bottom: top - 4), 0);
    final plain = img.decodeJpg(encodeSplatPoster(Uint8List(3 * width * height), width, height, mark: false))!;
    expect(_lit(plain, level: 8), 0);
    // On white, the square darkens its corner of the poster
    final white = Uint8List(3 * width * height)..fillRange(0, 3 * width * height, 255);
    final onWhite = img.decodeJpg(encodeSplatPoster(white, width, height))!;
    final corner = onWhite.getPixel(left + 3, top + side ~/ 2);
    expect(corner.r, lessThan(200));
  });

  test('the glyph is the view_in_ar_rounded outline of the viewer\'s tiles: 8 contours in its box of 24', () {
    final contours = splatPathContours(splatMarkPath);
    // Four corners, the cube, and its three faces as holes
    expect(contours, hasLength(8));
    for (final contour in contours) {
      for (final value in contour) {
        expect(value, inInclusiveRange(0.9, 23.1));
      }
    }
    final coverage = splatFillCoverage(contours, 24, 24);
    double at(int x, int y) => coverage[y * 24 + x];
    expect(at(2, 2), greaterThan(0.95), reason: 'a corner');
    expect(at(2, 12), 0, reason: 'between two corners');
    expect(at(5, 12), greaterThan(0.9), reason: 'the side of the cube');
    expect(at(8, 13), lessThan(0.05), reason: 'the left face, a hole');
    expect(at(11, 8), lessThan(0.05), reason: 'the top face, a hole');
    expect(at(12, 12), greaterThan(0.5), reason: 'the edge between the faces');
  });

  test('the page draws the same mark: the path and the numbers of mark.js are those of SplatMark', () {
    final js = File('assets/splat_viewer/mark.js').readAsStringSync();
    final path = RegExp(r"MARK_PATH =\s*'([^']+)'").firstMatch(js)!.group(1);
    expect(path, splatMarkPath);
    final numbers = RegExp(r'MARK = \{([^}]+)\}').firstMatch(js)!.group(1)!;
    final values = {
      for (final pair in numbers.split(',')) pair.split(':')[0].trim(): double.parse(pair.split(':')[1].trim()),
    };
    expect(values, {
      'size': SplatMark.size,
      'margin': SplatMark.margin,
      'radius': SplatMark.radius,
      'backAlpha': SplatMark.backAlpha,
      'glyph': SplatMark.glyph,
      'glyphAlpha': SplatMark.glyphAlpha,
    });
  });

  test('a drawn poster goes into a splat photo whose scene reads back', () async {
    final file = _scene('axes_v2.spz');
    final drawing = await drawSplatPoster(file: file, head: _head(file));
    final dir = Directory.systemTemp.createTempSync('splat_poster');
    addTearDown(() => dir.deleteSync(recursive: true));
    final out = File('${dir.path}/axes_splat.jpg');
    final written = await writeSplatPhotoFile(
      spz: file,
      posterJpeg: drawing.jpeg,
      meta: const SplatPhotoMeta(
        name: 'axes_v2.spz',
        date: SplatPhotoDate(2026, 11, 4, 12, 0, 0, offsetMinutes: 60),
        software: 'Immuch360 tests',
        creatorTool: 'Immuch360 tests',
        poster: SplatPosterKind.render,
      ),
      out: out,
    );
    expect(written.xmp.splatPoster, SplatPosterKind.render);
    final bytes = out.readAsBytesSync();
    expect(bytes.sublist(bytes.length - file.lengthSync()), file.readAsBytesSync());
  });

  testWidgets('the card of a version 4: 3:2, dark, the mark at the bottom right', (tester) async {
    final jpeg = await tester.runAsync(() => drawSplatPosterCard(name: 'axes_v4.spz', countLine: '686 gaussians'));
    final image = img.decodeJpg(jpeg!)!;
    expect(image.width, 1600);
    expect(image.height, 1067);
    final corner = image.getPixel(10, 10);
    expect(corner.r + corner.g + corner.b, lessThan(3 * 60));
    // The glyph in the middle of the upper part
    expect(_lit(image, level: 160, left: 600, top: 200, right: 1000, bottom: 560), greaterThan(0.05));
    final plain = img.decodeJpg(
      (await tester.runAsync(() => drawSplatPosterCard(name: 'axes_v4.spz', countLine: '686 gaussians', mark: false)))!,
    )!;
    expect(_lit(plain, level: 128, left: 1450, top: 920), 0);
    expect(_lit(image, level: 128, left: 1450, top: 920), greaterThan(0.01));
    _keepSample('card_axes_v4.jpg', jpeg);
  });
}
