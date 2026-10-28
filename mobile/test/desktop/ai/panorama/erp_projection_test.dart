// The photo on the sphere of pano-v1 (lot P3, design-final 2026-10-27, section 4.3, points 3, 6 and 8): the control
// frame of the LoRA (the photo projected at the centre, pure green elsewhere), the part of the sphere it covers, the
// roll of half a turn that brings the seam to the centre, and the photo pasted back over the generated panorama, each
// against the golden fixture of .github/desktop/ai/make_pano_golden.py (every byte within one unit, the masks exactly,
// the numbers within 1e-9); then what the fixture does not hold: the photo reduced to the density of the frame before
// it is read, and the sizes of the app.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/panorama/erp_projection.dart';
import 'package:immich_mobile/desktop/ai/panorama/paste_back.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

Map<String, dynamic> _golden() =>
    jsonDecode(File('test/fixtures/ai_immersive/pano_golden_v1.json').readAsStringSync()) as Map<String, dynamic>;

/// RGBA from rows of R, G, B bytes
SbsDecoded _picture(List<dynamic> rows) {
  final height = rows.length;
  final width = (rows.first as List).length ~/ 3;
  final rgba = Uint8List(4 * width * height);
  for (var y = 0; y < height; y++) {
    final row = (rows[y] as List).cast<int>();
    for (var x = 0; x < width; x++) {
      rgba.setRange(4 * (y * width + x), 4 * (y * width + x) + 3, row, 3 * x);
      rgba[4 * (y * width + x) + 3] = 255;
    }
  }
  return SbsDecoded(width: width, height: height, rgba: rgba);
}

/// Every R, G, B byte of [rgba] within one unit of the rows of [expected]
void _expectRgb(Uint8List rgba, List<dynamic> expected, String what) {
  final width = (expected.first as List).length ~/ 3;
  for (var y = 0; y < expected.length; y++) {
    final row = (expected[y] as List).cast<int>();
    for (var x = 0; x < width; x++) {
      for (var c = 0; c < 3; c++) {
        final got = rgba[4 * (y * width + x) + c];
        if ((got - row[3 * x + c]).abs() > 1) {
          fail('$what: pixel ($x, $y) channel $c is $got, ${row[3 * x + c]} expected');
        }
      }
    }
  }
}

void main() {
  final golden = _golden();
  final width = golden['frameWidth'] as int;
  final height = golden['frameHeight'] as int;
  final green = (golden['green'] as List).cast<int>();

  test('the constants of the fixture are those of pano-v1', () {
    expect(golden['pasteFeather'], PanoV1.pasteFeather);
    expect(green, [0, 255, 0]);
  });

  for (final raw in golden['projections'] as List) {
    final example = raw as Map<String, dynamic>;
    final name = example['name'] as String;
    final photo = _picture(example['photo'] as List);
    final hfov = (example['hfov'] as num).toDouble();

    test('$name: the control frame, the photo inside it, its coverage and its vertical field', () {
      final frame = projectPhoto(photo, hfov: hfov, width: width, height: height);
      expect(frame.width, width);
      expect(frame.height, height);
      _expectRgb(frame.rgba, example['control'] as List, 'control');
      final inside = [
        for (var y = 0; y < height; y++)
          [for (var x = 0; x < width; x++) frame.inside[y * width + x] == 1 ? '1' : '0'].join(),
      ];
      expect(inside, (example['inside'] as List).cast<String>());
      expect(frame.coverage, closeTo((example['coverage'] as num).toDouble(), 1e-9));
      expect(verticalFieldOfView(hfov, photo.width, photo.height), closeTo((example['vfov'] as num).toDouble(), 1e-9));
      for (var i = 0; i < width * height; i++) {
        expect(frame.rgba[4 * i + 3], 255);
      }
    });

    test('$name: rolled by half a turn, the seam at the centre', () {
      final frame = projectPhoto(photo, hfov: hfov, width: width, height: height);
      final rolled = rollColumns(frame.rgba, width, height, width ~/ 2);
      _expectRgb(rolled, example['rolled'] as List, 'rolled');
      expect(rollColumns(rolled, width, height, width - width ~/ 2), frame.rgba);
    });

    test('$name: the photo pasted back over the generated panorama, its edge blended', () {
      final generated = _picture(example['generated'] as List);
      expect(generated.width, example['outputWidth']);
      expect(generated.height, example['outputHeight']);
      final pasted = pastePhotoBack(generated, photo, hfov: hfov);
      _expectRgb(pasted, example['pasted'] as List, 'pasted');
      // The generated panorama is not changed in place
      _expectRgb(generated.rgba, example['generated'] as List, 'generated');
    });
  }

  group('the photo read at the density of the frame', () {
    SbsDecoded flat(int w, int h) =>
        SbsDecoded(width: w, height: h, rgba: Uint8List.fromList(List.filled(4 * w * h, 200)));

    test('a large photo is reduced by area to about one and a half pixels of the frame per pixel', () {
      // 65° across a frame of 2048: tan(32.5°) * 2 * 2048 / (2 pi) = 415 pixels, times 1.5
      final reduced = photoForFrame(flat(4000, 3000), hfov: 65, frameWidth: 2048);
      final expected = (1.5 * 2 * math.tan(65 * math.pi / 360) * 2048 / (2 * math.pi)).ceil();
      expect(reduced.width, expected);
      expect(reduced.height, (expected * 3000 / 4000).round());
      expect(reduced.rgba[0], 200);
    });

    test('a photo already small enough is read as it is, never enlarged', () {
      final small = flat(300, 200);
      expect(identical(photoForFrame(small, hfov: 65, frameWidth: 2048), small), isTrue);
    });

    test('at the sizes of the app: the photo covers a few percent of the control frame, green around it', () {
      final photo = SbsDecoded(
        width: 400,
        height: 300,
        rgba: Uint8List.fromList([for (var i = 0; i < 400 * 300; i++) ...[90, 120, 30, 255]]),
      );
      final frame = projectPhoto(photo, hfov: 65, width: PanoV1.controlWidth, height: PanoV1.controlHeight);
      // The centre is the photo, the column of the seam is green
      final centre = 4 * ((PanoV1.controlHeight ~/ 2) * PanoV1.controlWidth + PanoV1.controlWidth ~/ 2);
      expect(frame.rgba.sublist(centre, centre + 3), [90, 120, 30]);
      final edge = 4 * ((PanoV1.controlHeight ~/ 2) * PanoV1.controlWidth);
      expect(frame.rgba.sublist(edge, edge + 3), [0, 255, 0]);
      // 4 asin(sin(32.5°) sin(25.5°)) / 4 pi, the solid angle of the photo: 7.4 % of the sphere
      expect(frame.coverage, closeTo(0.0744, 0.001));
      expect(frame.insideCount, greaterThan(0));
    });
  });
}
