// How sharp an image of a splat scene is (lot SP5, sharpness.dart), the rule of tools/pick_sharp.py of the measure of
// 1 November 2026: the variance of the Laplacian of a grey copy of 512 pixels, and an image left out as blurred when it
// stays under half the median of its neighbours (two before, two after).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/splat/sharpness.dart';

import 'splat_input_support.dart';

void main() {
  group('the grey copy', () {
    test('is the luma of Pillow\'s "L", fitted in 512 pixels by area average, from RGBA or from BGR0 rows', () {
      const width = 2000;
      const height = 1000;
      final rgba = Uint8List(width * height * 4);
      final bgr0 = Uint8List((width + 8) * height * 4);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final at = (y * width + x) * 4;
          rgba
            ..[at] = 200
            ..[at + 1] = 100
            ..[at + 2] = 50
            ..[at + 3] = 255;
          final row = (y * (width + 8) + x) * 4;
          bgr0
            ..[row] = 50
            ..[row + 1] = 100
            ..[row + 2] = 200;
        }
      }
      final grey = greyFitted(rgba, width: width, height: height);
      expect((grey.width, grey.height), (512, 256));
      // 0.299 x 200 + 0.587 x 100 + 0.114 x 50 = 124.2
      expect(grey.pixels.toSet(), {124});
      final fromMpv = greyFitted(bgr0, width: width, height: height, stride: (width + 8) * 4, order: PixelOrder.bgr0);
      expect((fromMpv.width, fromMpv.height), (512, 256));
      expect(fromMpv.pixels, grey.pixels);
    });

    test('keeps a picture that already fits', () {
      final grey = greyFitted(texturedRgba(300, 200), width: 300, height: 200);
      expect((grey.width, grey.height), (300, 200));
      expect(fittedIn(4272, 2848, 512), (512, 341));
      expect(fittedIn(1080, 1920, 512), (288, 512));
    });
  });

  group('the variance of the Laplacian', () {
    test('is 0 for a flat picture and drops for a blurred copy of a textured one', () {
      final flat = GreyPicture(width: 64, height: 48, pixels: Uint8List(64 * 48)..fillRange(0, 64 * 48, 90));
      expect(laplacianVariance(flat), 0);

      final sharp = sharpnessOf(texturedRgba(320, 240), width: 320, height: 240);
      final soft = sharpnessOf(texturedRgba(320, 240, blur: 1), width: 320, height: 240);
      final blurred = sharpnessOf(texturedRgba(320, 240, blur: 3), width: 320, height: 240);
      expect(sharp, greaterThan(1000));
      expect(soft, lessThan(sharp / 4));
      expect(blurred, lessThan(soft));
    });

    test('matches the formula of pick_sharp.py on a small picture', () {
      // Rows 0 to 3 of a 4 x 4 picture: the inner pixels (1,1), (2,1), (1,2), (2,2)
      final grey = GreyPicture(
        width: 4,
        height: 4,
        pixels: Uint8List.fromList([0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 255, 150]),
      );
      // Laplacians: 10 + 90 + 40 + 60 - 200 = 0; 20 + 100 + 50 + 70 - 240 = 0; 50 + 130 + 80 + 100 - 360 = 0;
      // 60 + 255 + 90 + 110 - 400 = 115: mean 28.75, variance 115² / 4 - 28.75² = 2479.6875 (numpy's var)
      expect(laplacianVariance(grey), closeTo(2479.6875, 1e-9));
    });
  });

  group('the blurred ones', () {
    test('are those under half the median of two neighbours on each side', () {
      expect(blurredAmong([100, 100, 30, 100, 100, 100, 20, 100]), {2, 6});
      // The first and the last have their neighbours on one side only
      expect(blurredAmong([40, 100, 100, 100, 100, 45]), {0, 5});
      expect(blurredAmong([100, 100, 49, 100]), {2});
      expect(blurredAmong([100, 100, 50, 100]), isEmpty, reason: 'half the median is not under it');
    });

    test('are none in a video blurred all along, nor for an image alone', () {
      expect(blurredAmong([12, 11, 13, 12, 11, 12]), isEmpty);
      expect(blurredAmong([3]), isEmpty);
      expect(blurredAmong([]), isEmpty);
    });

    test('in a synthetic walk, the blurred photos are found', () {
      final sharpness = [
        for (var step = 0; step < 12; step++)
          sharpnessOf(
            texturedRgba(240, 180, shift: step * 6, blur: step == 3 || step == 8 ? 2 : 0),
            width: 240,
            height: 180,
          ),
      ];
      expect(blurredAmong(sharpness), {3, 8});
    });
  });
}
