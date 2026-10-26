// The Dart of relief-v1 against its golden fixture, made by .github/desktop/ai/make_relief_golden.py: the same right
// eye within one unit per channel and the same mask of filled pixels, on the four cases. The steps in between are held
// exactly, so that a difference shows where it starts.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_flags.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/desktop/ai/relief/right_eye.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

void main() {
  final golden =
      jsonDecode(File('test/fixtures/ai_immersive/relief_golden_v1.json').readAsStringSync()) as Map<String, dynamic>;
  final eyeWidth = golden['eyeWidth'] as int;
  final eyeHeight = golden['eyeHeight'] as int;
  final mapWidth = golden['mapWidth'] as int;
  final mapHeight = golden['mapHeight'] as int;
  final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();

  List<double> flat(Object? rows) => [
    for (final row in (rows! as List).cast<List<dynamic>>()) ...row.map((value) => (value as num).toDouble()),
  ];

  Uint8List rgbaOf(Object? rows) {
    final rgb = [for (final row in (rows! as List).cast<List<dynamic>>()) ...row.cast<int>()];
    final rgba = Uint8List(rgb.length ~/ 3 * 4);
    for (var pixel = 0; pixel < rgb.length ~/ 3; pixel++) {
      rgba[pixel * 4] = rgb[pixel * 3];
      rgba[pixel * 4 + 1] = rgb[pixel * 3 + 1];
      rgba[pixel * 4 + 2] = rgb[pixel * 3 + 2];
      rgba[pixel * 4 + 3] = 255;
    }
    return rgba;
  }

  test('the fixture has the four cases and the sizes this test reads', () {
    expect(cases.map((entry) => entry['name']), ['production', 'strong', 'flat', 'dark']);
    expect([eyeWidth, eyeHeight, mapWidth, mapHeight], [32, 8, 16, 4]);
  });

  for (final entry in cases) {
    final name = entry['name'] as String;
    group('case $name', () {
      final parallax = (entry['parallax'] as num).toDouble();
      final convergence = (entry['convergence'] as num).toDouble();
      final raw = ReliefDepth(mapWidth, mapHeight, Float64List.fromList(flat(entry['depth'])));
      final left = rgbaOf(entry['image']);

      test('normalises between the same percentiles, to the same values', () {
        final normalised = normaliseDepth(raw);
        expect(normalised.p2, entry['p2']);
        expect(normalised.p98, entry['p98']);
        expect(normalised.depth.values, flat(entry['normalized']));
        expect(normalised.lowRelief, (entry['flags'] as List).contains('lowRelief'));
      });

      test('dilates the foreground to the same map', () {
        expect(dilateForeground(normaliseDepth(raw).depth).values, flat(entry['dilated']));
        expect(reliefMapOf(raw).depth.values, flat(entry['dilated']));
      });

      test('reads the same depth at every pixel of the eye', () {
        final sampler = EyeDepthSampler(reliefMapOf(raw).depth, eyeWidth, eyeHeight);
        final row = Float64List(eyeWidth);
        final eyeDepth = <double>[];
        for (var y = 0; y < eyeHeight; y++) {
          sampler.sampleRow(y, row);
          eyeDepth.addAll(row);
        }
        expect(eyeDepth, flat(entry['eyeDepth']));
      });

      test('builds the right eye within one unit, with the same holes and the same flags', () {
        final map = reliefMapOf(raw);
        final right = Uint8List(eyeWidth * eyeHeight * 4);
        final holes = Uint8List(eyeWidth * eyeHeight);
        final eye = writeRightEye(
          left: left,
          width: eyeWidth,
          height: eyeHeight,
          map: map.depth,
          parallax: parallax,
          convergence: convergence,
          target: right,
          holes: holes,
        );
        final expected = [for (final row in (entry['rightEye'] as List).cast<List<dynamic>>()) ...row.cast<int>()];
        var worst = 0;
        for (var pixel = 0; pixel < eyeWidth * eyeHeight; pixel++) {
          for (var channel = 0; channel < 3; channel++) {
            final difference = (right[pixel * 4 + channel] - expected[pixel * 3 + channel]).abs();
            if (difference > worst) {
              worst = difference;
            }
          }
          expect(right[pixel * 4 + 3], 255, reason: 'opaque pixel $pixel');
        }
        expect(worst, lessThanOrEqualTo(1), reason: 'largest difference of a channel');
        final mask = [
          for (var y = 0; y < eyeHeight; y++)
            [for (var x = 0; x < eyeWidth; x++) holes[y * eyeWidth + x] == 1 ? '1' : '0'].join(),
        ];
        expect(mask, (entry['holes'] as List).cast<String>());
        expect(eye.filledPixels, entry['filledPixels']);

        final luma = meanLuma(left, width: eyeWidth, height: eyeHeight);
        expect(luma, entry['meanLuma']);
        final flags = reliefFlags(
          lowRelief: map.lowRelief,
          filledPixels: eye.filledPixels,
          width: eyeWidth,
          height: eyeHeight,
          meanLuma: luma,
        );
        expect(flags.map((flag) => flag.xmp), (entry['flags'] as List).cast<String>());
      });

      test('gives the same right eye and flags through the whole of relief-v1', () {
        final right = Uint8List(eyeWidth * eyeHeight * 4);
        final result = reliefV1RightEye(
          left: left,
          width: eyeWidth,
          height: eyeHeight,
          depth: raw,
          parallax: parallax,
          convergence: convergence,
          target: right,
        );
        expect(result.filledPixels, entry['filledPixels']);
        expect(result.flags.map((flag) => flag.xmp), (entry['flags'] as List).cast<String>());
        expect(result.meanLuma, entry['meanLuma']);
        expect(result.flags, everyElement(isA<ReliefQualityFlag>()));
      });
    });
  }
}
