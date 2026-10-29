// The input of the depth model: the two framings (stretched between 1.0 and 1.9, centered on the mean colour
// otherwise), the reduction by area average, the normalisation of ImageNet and the NCHW layout.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_input.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// An RGBA photo whose pixel (x, y) is [colour] (x, y)
Uint8List photo(int width, int height, List<int> Function(int x, int y) colour) {
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final rgb = colour(x, y);
      rgba.setRange((y * width + x) * 4, (y * width + x) * 4 + 4, [...rgb, 255]);
    }
  }
  return rgba;
}

/// What the model gets for the value [v] (0 to 255, the area average) of [channel]
double normalised(double v, int channel) =>
    Float32List.fromList([(v / 255 - reliefInputMean[channel]) / reliefInputStd[channel]]).first;

void main() {
  group('the framing', () {
    test('stretches a photo from 1.0 to 1.9 wide for 1 high over the whole input', () {
      for (final (width, height) in [(1000, 1000), (4000, 3000), (1920, 1080), (1900, 1000), (1, 1)]) {
        final frame = reliefInputFrameFor(width, height);
        expect(frame.framing, ReliefFraming.stretched, reason: '$width x $height');
        expect([frame.left, frame.top, frame.width, frame.height], [0, 0, 686, 518], reason: '$width x $height');
        expect([frame.inputWidth, frame.inputHeight], [depthModelInputWidth, depthModelInputHeight]);
      }
    });

    test('centers a portrait, a square crop just under 1.0 and a flat panorama, keeping their proportions', () {
      final cases = {
        // A phone portrait: 518 high, 3000 * 518 / 4000 = 388.5, rounded half up
        (3000, 4000): [148, 0, 389, 518],
        (999, 1000): [84, 0, 517, 518],
        // Just over 1.9: 686 wide, 1000 * 686 / 1901 = 360.9
        (1901, 1000): [0, 78, 686, 361],
        // A 3:1 panorama
        (6000, 2000): [0, 144, 686, 229],
        // Never narrower than a pixel
        (1, 100000): [342, 0, 1, 518],
        (100000, 1): [0, 258, 686, 1],
      };
      cases.forEach((size, rectangle) {
        final frame = reliefInputFrameFor(size.$1, size.$2);
        expect(frame.framing, ReliefFraming.centered, reason: '$size');
        expect([frame.left, frame.top, frame.width, frame.height], rectangle, reason: '$size');
      });
    });

    test('refuses an empty photo', () {
      expect(() => reliefInputFrameFor(0, 10), throwsArgumentError);
      expect(() => reliefInputFrameFor(10, 0), throwsArgumentError);
    });
  });

  group('the input', () {
    test('is [1, 3, 518, 686] float32, planes R, G and B, normalised with the means and deviations of ImageNet', () {
      final input = reliefInputOf(photo(40, 30, (x, y) => [128, 64, 200]), width: 40, height: 30);
      expect(input.nchw, hasLength(3 * 518 * 686));
      const plane = 518 * 686;
      for (final index in [0, 1234, plane - 1]) {
        expect(input.nchw[index], closeTo(normalised(128, 0), 1e-6));
        expect(input.nchw[plane + index], closeTo(normalised(64, 1), 1e-6));
        expect(input.nchw[2 * plane + index], closeTo(normalised(200, 2), 1e-6));
      }
      expect(normalised(0, 0), closeTo(-0.485 / 0.229, 1e-6));
      expect(normalised(255, 2), closeTo((1 - 0.406) / 0.225, 1e-6));
    });

    test('averages the area each input pixel covers, pixels cut in part counting in part', () {
      // 3 x 3 into 2 x 2: each input pixel covers 1.5 x 1.5 photo pixels, a quarter of the middle one
      final input = reliefInputOf(
        photo(3, 3, (x, y) => x == 1 && y == 1 ? [255, 0, 90] : [0, 0, 0]),
        width: 3,
        height: 3,
        inputWidth: 2,
        inputHeight: 2,
      );
      for (var index = 0; index < 4; index++) {
        expect(input.nchw[index], normalised(255 / 9, 0));
        expect(input.nchw[4 + index], normalised(0, 1));
        expect(input.nchw[8 + index], normalised(90 / 9, 2));
      }
    });

    test('reduces a photo by blocks, row after row, and enlarges a small one pixel by pixel', () {
      final reduced = reliefInputOf(
        photo(4, 4, (x, y) => [10 * x + 40 * y, 0, 0]),
        width: 4,
        height: 4,
        inputWidth: 2,
        inputHeight: 2,
      );
      // The four 2 x 2 blocks: (0 + 10 + 40 + 50) / 4, ...
      expect(reduced.nchw.sublist(0, 4), [
        normalised(25, 0),
        normalised(45, 0),
        normalised(105, 0),
        normalised(125, 0),
      ]);
      final enlarged = reliefInputOf(
        photo(2, 2, (x, y) => [0, 100 * x + 50 * y, 0]),
        width: 2,
        height: 2,
        inputWidth: 4,
        inputHeight: 4,
      );
      expect(enlarged.nchw.sublist(16, 32), [
        for (final value in [0, 0, 100, 100, 0, 0, 100, 100, 50, 50, 150, 150, 50, 50, 150, 150])
          normalised(value.toDouble(), 1),
      ]);
    });

    test('of a centered photo lies on a background of its mean colour', () {
      // A 3:1 photo in an input of 12 x 8: 12 x 4 on rows 2 to 5; red on its left half, blue on its right half
      final input = reliefInputOf(
        photo(30, 10, (x, y) => x < 15 ? [255, 0, 0] : [0, 0, 255]),
        width: 30,
        height: 10,
        inputWidth: 12,
        inputHeight: 8,
      );
      expect(input.frame.framing, ReliefFraming.centered);
      expect([input.frame.left, input.frame.top, input.frame.width, input.frame.height], [0, 2, 12, 4]);
      const plane = 12 * 8;
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 12; x++) {
          final inside = y >= 2 && y < 6;
          final red = inside ? (x < 6 ? 255.0 : 0.0) : 127.5;
          final blue = inside ? (x < 6 ? 0.0 : 255.0) : 127.5;
          expect(input.nchw[y * 12 + x], normalised(red, 0), reason: 'R ($x, $y)');
          expect(input.nchw[plane + y * 12 + x], normalised(0, 1), reason: 'G ($x, $y)');
          expect(input.nchw[2 * plane + y * 12 + x], normalised(blue, 2), reason: 'B ($x, $y)');
        }
      }
    });

    test('of a centered portrait lies between two sides of its mean colour', () {
      // A 1:3 photo in an input of 12 x 8: 3 x 8 on columns 4 to 6; red on its top half, blue on its bottom half
      final input = reliefInputOf(
        photo(10, 30, (x, y) => y < 15 ? [255, 0, 0] : [0, 0, 255]),
        width: 10,
        height: 30,
        inputWidth: 12,
        inputHeight: 8,
      );
      expect(input.frame.framing, ReliefFraming.centered);
      expect([input.frame.left, input.frame.top, input.frame.width, input.frame.height], [4, 0, 3, 8]);
      const plane = 12 * 8;
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 12; x++) {
          final inside = x >= 4 && x < 7;
          final red = inside ? (y < 4 ? 255.0 : 0.0) : 127.5;
          final blue = inside ? (y < 4 ? 0.0 : 255.0) : 127.5;
          expect(input.nchw[y * 12 + x], normalised(red, 0), reason: 'R ($x, $y)');
          expect(input.nchw[plane + y * 12 + x], normalised(0, 1), reason: 'G ($x, $y)');
          expect(input.nchw[2 * plane + y * 12 + x], normalised(blue, 2), reason: 'B ($x, $y)');
        }
      }
    });

    test('reads a photo inside a wider buffer, and never its alpha', () {
      // The left eye of a pair: rows of 2 x 3 pixels, the eye on the left 3
      final pair = photo(6, 3, (x, y) => x < 3 ? [30, 60, 90] : [255, 255, 255]);
      for (var pixel = 0; pixel < 18; pixel++) {
        pair[pixel * 4 + 3] = pixel;
      }
      final input = reliefInputOf(pair, width: 3, height: 3, stride: 6 * 4, inputWidth: 3, inputHeight: 3);
      expect(input.nchw.sublist(0, 9), everyElement(normalised(30, 0)));
      expect(input.nchw.sublist(9, 18), everyElement(normalised(60, 1)));
      expect(input.nchw.sublist(18, 27), everyElement(normalised(90, 2)));
    });

    test('refuses pixels that do not fill the photo', () {
      expect(() => reliefInputOf(Uint8List(10), width: 2, height: 2), throwsArgumentError);
    });
  });
}
