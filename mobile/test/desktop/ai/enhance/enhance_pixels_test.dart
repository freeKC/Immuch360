import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_pixels.dart';

/// A picture of [width] x [height] whose every pixel is [r], [g], [b]
Uint8List _plain(int width, int height, int r, int g, int b) {
  final rgba = Uint8List(width * height * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = r;
    rgba[i + 1] = g;
    rgba[i + 2] = b;
    rgba[i + 3] = 255;
  }
  return rgba;
}

int _red(Uint8List rgba, int width, int x, int y) => rgba[4 * (y * width + x)];

void main() {
  group('tiles', () {
    test('the starts of the probe: a step of tile less overlap, the last tile against the edge', () {
      expect(tileStarts(1000, 512, 64), [0, 448, 488]);
      expect(tileStarts(512, 512, 64), [0]);
      expect(tileStarts(300, 512, 64), [0]);
    });

    test('a 12 MP photo gives the 63 tiles of the probe, a 3 MP one its 20', () {
      expect(planTiles(4000, 3000), hasLength(63));
      expect(planTiles(2000, 1500), hasLength(20));
      final small = planTiles(500, 375);
      expect(small, hasLength(1));
      expect(small.single, (x: 0, y: 0, width: 500, height: 375));
    });

    test('every tile has the same size and stays inside the picture', () {
      for (final tile in planTiles(1234, 777, tile: 256, overlap: 32)) {
        expect((tile.width, tile.height), (256, 256));
        expect(tile.x + tile.width, lessThanOrEqualTo(1234));
        expect(tile.y + tile.height, lessThanOrEqualTo(777));
      }
    });

    test('the feather rises over the overlap from both sides', () {
      final ramp = featherRamp(512, 64);
      expect(ramp.first, closeTo(1 / 64, 1e-6));
      expect(ramp[63], 1);
      expect(ramp[256], 1);
      expect(ramp.last, closeTo(1 / 64, 1e-6));
      expect(featherRamp(10, 0), everyElement(1));
    });
  });

  group('blending the tiles', () {
    test('tiles of one colour give that colour everywhere', () {
      final blender = TileBlender(1000, 600);
      for (final tile in planTiles(1000, 600)) {
        blender.add(tile, _plain(tile.width, tile.height, 10, 120, 250), overlap: 64);
      }
      final out = blender.toRgba();
      for (final (x, y) in [(0, 0), (470, 300), (999, 599), (500, 100)]) {
        expect(out.sublist(4 * (y * 1000 + x), 4 * (y * 1000 + x) + 4), [10, 120, 250, 255]);
      }
    });

    test('two tiles of different colours meet with a ramp in their overlap, never a step', () {
      final blender = TileBlender(1000, 4);
      final tiles = planTiles(1000, 4, tile: 512, overlap: 64);
      for (final (index, tile) in tiles.indexed) {
        final value = index == 0 ? 0 : 200;
        blender.add(tile, _plain(tile.width, tile.height, value, value, value), overlap: 64);
      }
      final out = blender.toRgba();
      // The first tile alone before the overlap, the last alone after it
      expect(_red(out, 1000, 10, 1), 0);
      expect(_red(out, 1000, 990, 1), 200);
      var previous = -1;
      for (var x = 0; x < 1000; x++) {
        final value = _red(out, 1000, x, 1);
        expect(value, greaterThanOrEqualTo(previous));
        expect(value - (previous < 0 ? value : previous), lessThanOrEqualTo(10));
        previous = value;
      }
    });

    test('a picture no tile covered fails rather than gives black', () {
      final blender = TileBlender(10, 10);
      expect(blender.toRgba, throwsStateError);
    });
  });

  group('resizing', () {
    test('half size averages each block of four pixels', () {
      final rgba = Uint8List(4 * 4 * 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final i = 4 * (y * 4 + x);
          rgba[i] = (x + y).isEven ? 100 : 200;
          rgba[i + 3] = 255;
        }
      }
      final half = resizeRgba(rgba, 4, 4, 2, 2);
      expect([for (var i = 0; i < half.length; i += 4) half[i]], [150, 150, 150, 150]);
      expect([for (var i = 3; i < half.length; i += 4) half[i]], everyElement(255));
    });

    test('the same size gives the same pixels, an odd size is resampled', () {
      final rgba = _plain(7, 5, 30, 60, 90);
      expect(resizeRgba(rgba, 7, 5, 7, 5), rgba);
      final grown = resizeRgba(rgba, 7, 5, 9, 6);
      expect(grown.length, 9 * 6 * 4);
      expect(grown.sublist(0, 4), [30, 60, 90, 255]);
      final shrunk = resizeRgba(rgba, 7, 5, 3, 2);
      expect(shrunk.sublist(0, 4), [30, 60, 90, 255]);
    });

    test('reflect padding mirrors without repeating the edge, and the crop takes it back', () {
      final rgba = Uint8List(3 * 1 * 4);
      for (var x = 0; x < 3; x++) {
        rgba[4 * x] = 10 * (x + 1);
        rgba[4 * x + 3] = 255;
      }
      final padded = reflectPad(rgba, 3, 1, 5, 2);
      expect([for (var x = 0; x < 5; x++) _red(padded, 5, x, 0)], [10, 20, 30, 20, 10]);
      expect([for (var x = 0; x < 5; x++) _red(padded, 5, x, 1)], [10, 20, 30, 20, 10]);
      expect(cropRgba(padded, 5, 2, 3, 1), rgba);
    });
  });

  group('colour fix and strength', () {
    test('a result equal to the photo stays as it is', () {
      final photo = _plain(40, 30, 90, 100, 110);
      final result = Uint8List.fromList(photo);
      colourFix(result, photo, 40, 30);
      expect(result, photo);
    });

    test('a shift of the whole tone goes, the fine detail of the result stays', () {
      const width = 64;
      const height = 64;
      final photo = _plain(width, height, 100, 100, 100);
      final result = Uint8List(width * height * 4);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final i = 4 * (y * width + x);
          // Darker by 30, with a checker of plus and minus 20 the model invented
          final detail = (x + y).isEven ? 20 : -20;
          result[i] = 70 + detail;
          result[i + 1] = 70 + detail;
          result[i + 2] = 70 + detail;
          result[i + 3] = 255;
        }
      }
      colourFix(result, photo, width, height);
      var sum = 0;
      for (var i = 0; i < result.length; i += 4) {
        sum += result[i];
      }
      // The mean tone is the photo's again
      expect(sum / (width * height), closeTo(100, 1.5));
      // The checker is still there
      const centre = 4 * (32 * width + 32);
      const next = 4 * (32 * width + 33);
      expect((result[centre] - result[next]).abs(), greaterThan(25));
    });

    test('the strength blends the result with the photo', () {
      final photo = _plain(2, 2, 100, 0, 200);
      final result = _plain(2, 2, 200, 100, 0);
      blendStrength(result, photo, 0.6);
      expect(result.sublist(0, 4), [160, 60, 80, 255]);
      final none = _plain(2, 2, 200, 100, 0);
      blendStrength(none, photo, 0);
      expect(none, photo);
      final all = _plain(2, 2, 200, 100, 0);
      blendStrength(all, photo, 1);
      expect(all.sublist(0, 4), [200, 100, 0, 255]);
    });
  });
}
