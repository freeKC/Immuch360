// The warnings relief-v1 raises on a photo: little relief, large hidden areas, a dark photo, in the order of the XMP.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_flags.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

void main() {
  group('the mean luma', () {
    test('weighs R, G and B by Rec. 709 over the whole photo', () {
      final rgba = Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 0, 0, 0, 0]);
      expect(meanLuma(rgba, width: 2, height: 2), closeTo((0.2126 + 0.7152 + 0.0722) * 255 / 4, 1e-9));
    });

    test('reads the eye inside a wider buffer, never the pixels beside it', () {
      // Rows of 4 pixels, the eye on the first 2, white beside it
      final rgba = Uint8List(4 * 2 * 4)..fillRange(0, 32, 255);
      for (final pixel in [0, 1, 4, 5]) {
        rgba.setRange(pixel * 4, pixel * 4 + 3, [10, 10, 10]);
      }
      expect(meanLuma(rgba, width: 2, height: 2, stride: 16), closeTo(10, 1e-9));
    });
  });

  group('the flags', () {
    List<ReliefQualityFlag> flags({bool lowRelief = false, int filled = 0, double luma = 100}) =>
        reliefFlags(lowRelief: lowRelief, filledPixels: filled, width: 100, height: 20, meanLuma: luma);

    test('say nothing of a good photo', () {
      expect(flags(), isEmpty);
    });

    test('say large hidden areas past 5 % of the pixels filled, not at 5 %', () {
      expect(flags(filled: 100), isEmpty);
      expect(flags(filled: 101), [ReliefQualityFlag.hiddenAreas]);
    });

    test('say dark under a mean luma of 20, not at 20', () {
      expect(flags(luma: 20), isEmpty);
      expect(flags(luma: 19.99), [ReliefQualityFlag.dark]);
    });

    test('come in the order lowRelief, hiddenAreas, dark', () {
      expect(flags(lowRelief: true, filled: 2000, luma: 3), [
        ReliefQualityFlag.lowRelief,
        ReliefQualityFlag.hiddenAreas,
        ReliefQualityFlag.dark,
      ]);
    });
  });
}
