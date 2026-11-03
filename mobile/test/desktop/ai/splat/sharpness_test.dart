// How sharp an image of a splat scene is (lot SP5, sharpness.dart), the rule of tools/pick_sharp.py of the measure of
// 1 November 2026: the variance of the Laplacian of a grey copy of 512 pixels, and an image left out as blurred when it
// stays under half the median of its neighbours (two before, two after).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/splat/sharpness.dart';

import 'splat_input_support.dart';

/// The windows of FreeKC's video the neighbours left out on 3 November (frames.csv of the diagnosis, from 0)
const _byNeighbours = {17, 21, 42, 70, 71, 90, 103, 121, 132, 142, 147};

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

    test('a run of blurred ones, which the neighbours keep, under a quarter of the median of all (lot SPF2)', () {
      // Four blurred in a row: each has blurred neighbours, the median of all (100) leaves them under its quarter
      expect(blurredAmong([100, 100, 100, 10, 10, 10, 10, 100, 100, 100]), {3, 4, 5, 6});
      // The floor alone (no rule of the neighbours): a quarter of the median of all
      expect(blurredAmong([100, 100, 100, 26, 26, 26, 100, 100, 100], ratio: 0), isEmpty, reason: 'a quarter is 25');
      expect(blurredAmong([100, 100, 100, 24, 24, 24, 100, 100, 100], ratio: 0), {3, 4, 5});
      expect(blurredAmong([100, 100, 100, 24, 24, 24, 100, 100, 100], ratio: 0, floor: 0), isEmpty);
    });

    test('FreeKC\'s video of 3 November: the 11 windows the neighbours leave out, and the run of close-ups out of '
        'focus, the frames 125 to 133 the app kept that morning (diag-2026-11-03.md, section 3.2)', () {
      // The sharpest candidate of each of the 150 windows, in the order of time, as the diagnosis took them again
      const sharpness = <double>[
        219.05,
        232.56,
        228.58,
        204.75,
        194.53,
        193.25,
        187.06,
        218.66,
        262.56,
        233.33,
        199.07,
        204.96,
        296.60,
        222.38,
        331.60,
        314.81,
        185.20,
        35.93,
        55.31,
        43.55,
        108.17,
        42.04,
        92.70,
        151.74,
        182.52,
        249.03,
        226.07,
        209.23,
        192.27,
        144.10,
        112.62,
        121.18,
        122.59,
        115.09,
        155.90,
        225.71,
        109.46,
        155.56,
        186.15,
        141.41,
        135.36,
        205.43,
        81.68,
        152.58,
        198.12,
        191.74,
        223.96,
        224.43,
        244.34,
        201.10,
        212.80,
        201.47,
        125.04,
        207.22,
        166.79,
        143.94,
        211.03,
        217.75,
        170.60,
        164.15,
        185.69,
        209.69,
        193.56,
        184.16,
        78.07,
        83.87,
        62.96,
        39.86,
        43.49,
        43.24,
        9.59,
        12.46,
        52.42,
        182.48,
        123.57,
        144.49,
        116.29,
        115.59,
        126.08,
        94.68,
        164.01,
        174.85,
        96.68,
        64.09,
        67.41,
        43.84,
        71.37,
        116.91,
        136.94,
        153.07,
        82.93,
        187.17,
        193.03,
        238.70,
        199.53,
        115.42,
        163.35,
        122.31,
        129.11,
        214.24,
        170.14,
        197.14,
        197.07,
        84.90,
        130.77,
        173.90,
        287.76,
        287.33,
        112.02,
        103.17,
        147.85,
        122.04,
        82.20,
        74.96,
        63.24,
        53.70,
        74.51,
        92.03,
        70.26,
        58.16,
        58.43,
        25.92,
        98.35,
        64.92,
        217.59,
        139.07,
        70.28,
        67.88,
        41.40,
        34.27,
        57.76,
        69.92,
        18.59,
        27.49,
        28.64,
        11.23,
        16.37,
        6.54,
        9.62,
        7.75,
        4.89,
        8.71,
        10.50,
        62.92,
        79.17,
        41.55,
        114.56,
        54.52,
        136.21,
        155.03,
      ];
      final blurred = blurredAmong(sharpness);
      expect(blurred.difference(_byNeighbours), {133, 134, 135, 136, 137, 138, 139, 140, 141});
      expect(blurred, containsAll(_byNeighbours));
      expect(150 - blurred.length, 130, reason: '129 of them placed by COLMAP in the diagnosis, 10 of 139 before');
      // The floor: a quarter of the median of the 150 (129.94), 32.5; the next frame kept is at 34.27
      expect(blurred, isNot(contains(129)));
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
