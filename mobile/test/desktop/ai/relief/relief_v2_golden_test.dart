// The Dart of relief-v2 without MI-GAN against its golden fixture, made by .github/desktop/ai/make_relief_v2_golden.py:
// d at each pixel of the eye within 1e-9, the right eye within one unit per channel, the same mask of filled pixels and
// the same flags, on the four cases of relief-v1 and the case of a sharp edge under a soft ramp of the model.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_v2.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

void main() {
  final golden =
      jsonDecode(File('test/fixtures/ai_immersive/relief_golden_v2.json').readAsStringSync()) as Map<String, dynamic>;
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

  test('the fixture is that of relief-v2, with its five cases and the settings of the app', () {
    expect(golden['pipeline'], ReliefV2.pipeline);
    expect(cases.map((entry) => entry['name']), ['production', 'strong', 'flat', 'dark', 'edge']);
    expect([eyeWidth, eyeHeight, mapWidth, mapHeight], [32, 8, 16, 4]);
    expect(golden['rangeSigma'], ReliefV2.rangeSigma);
    expect(golden['spatialSigma'], ReliefV2.spatialSigma);
  });

  for (final entry in cases) {
    final name = entry['name'] as String;
    group('case $name', () {
      final parallax = (entry['parallax'] as num).toDouble();
      final convergence = (entry['convergence'] as num).toDouble();
      final raw = ReliefDepth(mapWidth, mapHeight, Float64List.fromList(flat(entry['depth'])));
      final left = rgbaOf(entry['image']);

      test('reads the same depth at every pixel of the eye, guided by the photo', () {
        final normalised = normaliseDepth(raw);
        expect(normalised.depth.values, flat(entry['normalized']));
        final rows = GuidedEyeDepth(normalised.depth, eye: left, eyeWidth: eyeWidth, eyeHeight: eyeHeight);
        final row = Float64List(eyeWidth);
        final expected = flat(entry['eyeDepth']);
        for (var y = 0; y < eyeHeight; y++) {
          rows.sampleRow(y, row);
          for (var x = 0; x < eyeWidth; x++) {
            expect(row[x], closeTo(expected[y * eyeWidth + x], 1e-9), reason: 'pixel ($x, $y)');
          }
        }
      });

      test('builds the right eye within one unit, with the same holes and the same flags', () {
        final right = Uint8List(eyeWidth * eyeHeight * 4);
        final holes = Uint8List(eyeWidth * eyeHeight);
        final result = reliefV2RightEye(
          left: left,
          width: eyeWidth,
          height: eyeHeight,
          depth: raw,
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
        expect(result.filledPixels, entry['filledPixels']);
        expect(result.meanLuma, entry['meanLuma']);
        expect(result.flags.map((flag) => flag.xmp), (entry['flags'] as List).cast<String>());
        expect(result.inpaint.pixels, 0);
      });
    });
  }

  test('the edge case: the jump of the depth falls on the edge of the photo, at column 13', () {
    final entry = cases.last;
    final depth = flat(entry['eyeDepth']);
    for (var y = 0; y < eyeHeight; y++) {
      expect(depth[y * eyeWidth + 12], greaterThan(0.9));
      expect(depth[y * eyeWidth + 13], lessThan(0.35));
    }
  });
}
