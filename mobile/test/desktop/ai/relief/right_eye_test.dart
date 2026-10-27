// The right eye of relief-v1 on rows built by hand: what the golden fixture cannot hold with eyes of 32 pixels (the
// link threshold, the tie of two backgrounds, a row with nothing written), and the properties every photo must keep
// (a flat map gives the left eye back, no hole is left, the left eye is never touched). The expected bytes of the
// three hand rows come from right_eye_row of .github/desktop/ai/make_relief_golden.py on the same inputs.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/desktop/ai/relief/right_eye.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// An RGBA eye of [width] x [height] whose pixels all differ, never black
Uint8List patternEye(int width, int height) {
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final at = (y * width + x) * 4;
      rgba[at] = 20 + (7 * x + 3 * y) % 200;
      rgba[at + 1] = 30 + (5 * x + 11 * y) % 200;
      rgba[at + 2] = 40 + (13 * x + y) % 200;
      rgba[at + 3] = 255;
    }
  }
  return rgba;
}

/// One row of RGBA from rows of R, G, B
Uint8List rowOf(List<List<int>> pixels) => Uint8List.fromList([
  for (final pixel in pixels) ...[...pixel, 255],
]);

List<List<int>> rgbOf(Uint8List rgba, {int offset = 0, required int width}) => [
  for (var x = 0; x < width; x++) [rgba[offset + x * 4], rgba[offset + x * 4 + 1], rgba[offset + x * 4 + 2]],
];

/// A map at the size of the eye: the enlargement then reads each value exactly, so [d] is the depth of each pixel
ReliefDepth rowDepth(List<double> d) => ReliefDepth(d.length, 1, Float64List.fromList(d));

void main() {
  group('a flat map', () {
    test('gives a right eye equal to the left eye at the settings of the app', () {
      final left = patternEye(40, 6);
      final right = Uint8List(left.length);
      final holes = Uint8List(40 * 6);
      final map = reliefMapOf(ReliefDepth(10, 3, Float64List(30)..fillRange(0, 30, 4.2)));
      expect(map.lowRelief, isTrue);
      expect(map.depth.values, everyElement(0.5));
      final eye = writeRightEye(
        left: left,
        width: 40,
        height: 6,
        map: map.depth,
        parallax: ReliefV1.parallax,
        convergence: ReliefV1.convergence,
        target: right,
        holes: holes,
      );
      expect(right, left);
      expect(eye.filledPixels, 0);
      expect(holes, everyElement(0));
    });

    test('moves the whole eye when the convergence is off the middle, and fills the column it leaves', () {
      final left = patternEye(16, 2);
      final right = Uint8List(left.length);
      final holes = Uint8List(16 * 2);
      // d = 0.5 everywhere, c = 0.25: s = 0.5 * 16 * -0.25 = -2 pixels, two hole columns at the right edge
      final eye = writeRightEye(
        left: left,
        width: 16,
        height: 2,
        map: ReliefDepth(4, 2, Float64List(8)..fillRange(0, 8, 0.5)),
        parallax: 0.5,
        convergence: 0.25,
        target: right,
        holes: holes,
      );
      expect(eye.filledPixels, 4);
      for (var y = 0; y < 2; y++) {
        expect(holes.sublist(y * 16, y * 16 + 16), [...List.filled(14, 0), 1, 1]);
        for (var x = 0; x < 14; x++) {
          expect(
            right.sublist((y * 16 + x) * 4, (y * 16 + x) * 4 + 4),
            left.sublist((y * 16 + x + 2) * 4, (y * 16 + x + 3) * 4),
          );
        }
      }
    });
  });

  group('holes', () {
    test('are all filled: no pixel of the right eye is left unwritten', () {
      // A near square in the middle of a far ground, under a strong parallax: holes open beside it
      final depth = Float64List(16 * 8);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 16; x++) {
          depth[y * 16 + x] = x >= 6 && x < 10 && y >= 2 && y < 6 ? 9.0 : 1.0 + 0.01 * x;
        }
      }
      final left = patternEye(64, 32);
      final right = Uint8List(left.length)..fillRange(0, left.length, 1);
      final holes = Uint8List(64 * 32);
      final eye = writeRightEye(
        left: left,
        width: 64,
        height: 32,
        map: reliefMapOf(ReliefDepth(16, 8, depth)).depth,
        parallax: 0.2,
        convergence: 0.5,
        target: right,
        holes: holes,
      );
      expect(eye.filledPixels, greaterThan(0));
      expect(holes.where((hole) => hole == 1).length, eye.filledPixels);
      for (var pixel = 0; pixel < 64 * 32; pixel++) {
        expect(right[pixel * 4 + 3], 255, reason: 'pixel $pixel written');
        // The photo has no channel under 20: a filled pixel takes the colours of written neighbours, never black
        expect(right.sublist(pixel * 4, pixel * 4 + 3), everyElement(greaterThanOrEqualTo(20)), reason: 'pixel $pixel');
      }
    });

    test('link two neighbours whose depths differ by 0.04 or less, and open beyond', () {
      // 100 near pixels then 100 far ones, c = 0: the near ones move left by 100 * d, the far ones stay
      final left = rowOf([
        for (var x = 0; x < 200; x++) [x % 256, 3 * x % 256, 255 - x % 256],
      ]);
      for (final (near, holesWanted) in [(0.04, 0), (0.0375, 0), (0.0425, 4), (0.0401, 4)]) {
        final right = Uint8List(left.length);
        final holes = Uint8List(200);
        final eye = writeRightEye(
          left: left,
          width: 200,
          height: 1,
          map: rowDepth([...List.filled(100, near), ...List.filled(100, 0.0)]),
          parallax: 0.5,
          convergence: 0,
          target: right,
          holes: holes,
        );
        expect(eye.filledPixels, holesWanted, reason: 'near at $near');
        if (holesWanted > 0) {
          expect(holes.sublist(95, 101), [0, 1, 1, 1, 1, 0], reason: 'near at $near');
          // The holes take the background, the far pixel 100, then the blur of 3 mixes in the near edge at 95
          expect(rgbOf(right, offset: 96 * 4, width: 5), [
            [100, 43, 155],
            [100, 44, 155],
            [100, 44, 155],
            [100, 44, 155],
            [100, 44, 155],
          ]);
        } else {
          expect(rgbOf(right, offset: 96 * 4, width: 5).first, [99, near == 0.04 ? 42 : 41, 156]);
        }
      }
    });

    test('between two backgrounds of the same depth take the left one', () {
      final left = rowOf([
        for (var x = 0; x < 8; x++) [10 * x + 5, 200 - 10 * x, 7 * x],
      ]);
      final right = Uint8List(left.length);
      final holes = Uint8List(8);
      // The near pixel 3 moves left by 2 and leaves column 3 between the far columns 2 and 4
      writeRightEye(
        left: left,
        width: 8,
        height: 1,
        map: rowDepth([0, 0, 0, 1, 0, 0, 0, 0]),
        parallax: 0.25,
        convergence: 0,
        target: right,
        holes: holes,
      );
      expect(holes, [0, 0, 0, 1, 0, 0, 0, 0]);
      expect(rgbOf(right, width: 8), [
        [5, 200, 0],
        [35, 170, 21],
        [25, 180, 14],
        [32, 173, 19],
        [45, 160, 28],
        [55, 150, 35],
        [65, 140, 42],
        [75, 130, 49],
      ]);
    });

    test('of a row where nothing was written are black', () {
      final left = rowOf([
        for (var x = 0; x < 8; x++) [10 * x + 5, 200 - 10 * x, 7 * x],
      ]);
      final right = Uint8List(left.length);
      final holes = Uint8List(8);
      final eye = writeRightEye(
        left: left,
        width: 8,
        height: 1,
        map: rowDepth(List.filled(8, 1.0)),
        parallax: 1,
        convergence: 0,
        target: right,
        holes: holes,
      );
      expect(eye.filledPixels, 8);
      expect(holes, everyElement(1));
      expect(rgbOf(right, width: 8), everyElement([0, 0, 0]));
    });
  });

  group('the left eye', () {
    test('is never changed, when the right eye is written beside it in the pair', () {
      const width = 48;
      const height = 20;
      final pair = Uint8List(2 * width * height * 4);
      final eye = patternEye(width, height);
      for (var y = 0; y < height; y++) {
        pair.setRange(y * 2 * width * 4, y * 2 * width * 4 + width * 4, eye, y * width * 4);
      }
      final before = Uint8List.fromList(pair);
      final depth = Float64List(12 * 5);
      for (var index = 0; index < depth.length; index++) {
        depth[index] = index % 12 < 6 ? 2.0 : 8.0 + index % 5;
      }
      final result = reliefV1RightEye(
        left: pair,
        width: width,
        height: height,
        leftStride: 2 * width * 4,
        depth: ReliefDepth(12, 5, depth),
        parallax: 0.1,
        convergence: 0.5,
        target: pair,
        targetOffset: width * 4,
        targetStride: 2 * width * 4,
      );
      expect(result.filledPixels, greaterThan(0));
      for (var y = 0; y < height; y++) {
        final row = y * 2 * width * 4;
        expect(pair.sublist(row, row + width * 4), before.sublist(row, row + width * 4), reason: 'left row $y');
      }
      // The right half was written: alpha 255 everywhere, and it is not the left eye copied
      var differs = false;
      for (var y = 0; y < height; y++) {
        final row = y * 2 * width * 4;
        final right = pair.sublist(row + width * 4, row + 2 * width * 4);
        expect([for (var x = 0; x < width; x++) right[x * 4 + 3]], everyElement(255));
        differs = differs || !_same(right, before.sublist(row, row + width * 4));
      }
      expect(differs, isTrue);
    });

    test('given apart is left as it was, and gives the same right eye as in the pair', () {
      const width = 30;
      const height = 9;
      final left = patternEye(width, height);
      final copy = Uint8List.fromList(left);
      final depth = ReliefDepth(6, 3, Float64List.fromList([1, 2, 3, 9, 9, 1, 1, 2, 3, 9, 9, 1, 1, 2, 3, 9, 9, 1]));
      final alone = Uint8List(width * height * 4);
      final aloneResult = reliefV1RightEye(
        left: left,
        width: width,
        height: height,
        depth: depth,
        parallax: 0.1,
        convergence: 0.5,
        target: alone,
      );
      expect(left, copy);

      final pair = Uint8List(2 * width * height * 4);
      for (var y = 0; y < height; y++) {
        pair.setRange(y * 2 * width * 4, y * 2 * width * 4 + width * 4, left, y * width * 4);
      }
      final inPair = reliefV1RightEye(
        left: pair,
        width: width,
        height: height,
        leftStride: 2 * width * 4,
        depth: depth,
        parallax: 0.1,
        convergence: 0.5,
        target: pair,
        targetOffset: width * 4,
        targetStride: 2 * width * 4,
      );
      for (var y = 0; y < height; y++) {
        final row = y * 2 * width * 4;
        expect(pair.sublist(row + width * 4, row + 2 * width * 4), alone.sublist(y * width * 4, (y + 1) * width * 4));
      }
      // The luma and the flags of the eye, read with its stride in the pair whose right half was black at the start
      expect(inPair.meanLuma, aloneResult.meanLuma);
      expect(inPair.flags, aloneResult.flags);
      expect(inPair.filledPixels, aloneResult.filledPixels);
    });
  });

  group('a constant map', () {
    test('is low relief and keeps the eye as it is at the convergence of the app', () {
      final left = patternEye(20, 10);
      final right = Uint8List(left.length);
      final result = reliefV1RightEye(
        left: left,
        width: 20,
        height: 10,
        depth: ReliefDepth(5, 5, Float64List(25)..fillRange(0, 25, 3)),
        parallax: ReliefV1.parallax,
        convergence: ReliefV1.convergence,
        target: right,
      );
      expect(right, left);
      expect(result.flags, [ReliefQualityFlag.lowRelief]);
      expect(result.filledPixels, 0);
    });
  });

  group('the run', () {
    test('reports its rows every 64 and at the end, and stops when asked', () {
      final left = patternEye(10, 150);
      final map = ReliefDepth(2, 2, Float64List.fromList([1, 2, 3, 4]));
      final seen = <int>[];
      writeRightEye(
        left: left,
        width: 10,
        height: 150,
        map: map,
        parallax: 0.02,
        convergence: 0.5,
        target: Uint8List(left.length),
        onRows: seen.add,
      );
      expect(seen, [64, 128, 150]);

      // Read before rows 0 and 64: the second read stops the run once 64 rows are done
      var asked = 0;
      seen.clear();
      expect(
        () => writeRightEye(
          left: left,
          width: 10,
          height: 150,
          map: map,
          parallax: 0.02,
          convergence: 0.5,
          target: Uint8List(left.length),
          isCancelled: () => ++asked == 2,
          onRows: seen.add,
        ),
        throwsA(isA<ReliefCancelledException>()),
      );
      expect(asked, 2);
      expect(seen, [64]);
    });

    test('refuses settings out of range and buffers too small', () {
      final left = patternEye(4, 2);
      final map = ReliefDepth(2, 1, Float64List.fromList([0, 1]));
      void run({double parallax = 0.02, double convergence = 0.5, Uint8List? target, Uint8List? holes}) =>
          writeRightEye(
            left: left,
            width: 4,
            height: 2,
            map: map,
            parallax: parallax,
            convergence: convergence,
            target: target ?? Uint8List(left.length),
            holes: holes,
          );
      expect(() => run(parallax: double.nan), throwsArgumentError);
      expect(() => run(parallax: 1.5), throwsArgumentError);
      expect(() => run(convergence: -0.1), throwsArgumentError);
      expect(() => run(target: Uint8List(left.length - 1)), throwsArgumentError);
      expect(() => run(holes: Uint8List(7)), throwsArgumentError);
      run();
    });
  });
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    return false;
  }
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) {
      return false;
    }
  }
  return true;
}
