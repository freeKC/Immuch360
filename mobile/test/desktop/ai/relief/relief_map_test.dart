// The map step of relief-v1: the model's map cut to the photo, the percentiles by nearest rank, the normalisation and
// its flat cases, the dilation of the foreground.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_input.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';

void main() {
  group('the cut to the photo', () {
    test('keeps the whole map of a stretched photo, in double precision', () {
      final frame = reliefInputFrameFor(4000, 3000, inputWidth: 8, inputHeight: 6);
      expect(frame.framing, ReliefFraming.stretched);
      final map = DepthMap(8, 6, Float32List.fromList([for (var index = 0; index < 48; index++) index + 0.1]));
      final cut = cropToPhoto(map, frame);
      expect([cut.width, cut.height], [8, 6]);
      expect(cut.values, [
        for (var index = 0; index < 48; index++) Float32List.fromList([index + 0.1]).first,
      ]);
    });

    test('keeps only the rectangle a centered photo filled', () {
      // A 3:1 panorama in an input of 12 x 8: 12 x 4, rows 2 to 5
      final frame = reliefInputFrameFor(3000, 1000, inputWidth: 12, inputHeight: 8);
      expect(frame.framing, ReliefFraming.centered);
      expect([frame.left, frame.top, frame.width, frame.height], [0, 2, 12, 4]);
      final map = DepthMap(12, 8, Float32List.fromList([for (var index = 0; index < 96; index++) index.toDouble()]));
      final cut = cropToPhoto(map, frame);
      expect([cut.width, cut.height], [12, 4]);
      expect(cut.values.first, 24);
      expect(cut.values.last, 71);
    });

    test('keeps only the columns a centered portrait filled', () {
      // A 1:3 portrait in an input of 12 x 8: 3 x 8, columns 4 to 6
      final frame = reliefInputFrameFor(10, 30, inputWidth: 12, inputHeight: 8);
      expect(frame.framing, ReliefFraming.centered);
      expect([frame.left, frame.top, frame.width, frame.height], [4, 0, 3, 8]);
      final map = DepthMap(12, 8, Float32List.fromList([for (var index = 0; index < 96; index++) index.toDouble()]));
      final cut = cropToPhoto(map, frame);
      expect([cut.width, cut.height], [3, 8]);
      expect(cut.values.sublist(0, 3), [4, 5, 6]);
      expect(cut.values.sublist(3, 6), [16, 17, 18]);
      expect(cut.values.last, 90);
    });

    test('refuses a map of another size than the input', () {
      final frame = reliefInputFrameFor(100, 100, inputWidth: 8, inputHeight: 6);
      expect(() => cropToPhoto(DepthMap(6, 8, Float32List(48)), frame), throwsArgumentError);
    });
  });

  group('the percentiles', () {
    test('take the nearest rank, counted from 1', () {
      final sorted = Float64List.fromList([for (var index = 1; index <= 200; index++) index.toDouble()]);
      // rank max(1, (P * N + 99) ~/ 100): 4 and 196 for N = 200
      expect(reliefPercentile(sorted, 2), 4);
      expect(reliefPercentile(sorted, 98), 196);
      final few = Float64List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      expect(reliefPercentile(few, 2), 1);
      expect(reliefPercentile(few, 98), 10);
    });
  });

  group('the normalisation', () {
    test('maps p2 to 0 and p98 to 1, and clamps the outliers', () {
      final values = Float64List.fromList([for (var index = 0; index < 100; index++) index.toDouble()]);
      values[0] = -1000;
      values[99] = 1000;
      final normalised = normaliseDepth(ReliefDepth(10, 10, values));
      expect(normalised.p2, 1);
      expect(normalised.p98, 97);
      expect(normalised.depth.values.first, 0);
      expect(normalised.depth.values.last, 1);
      expect(normalised.depth.values[49], (49 - 1) / 96);
      expect(normalised.lowRelief, isFalse);
    });

    test('of a constant map is 0.5 everywhere, with little relief', () {
      final normalised = normaliseDepth(ReliefDepth(3, 2, Float64List(6)..fillRange(0, 6, 7.5)));
      expect(normalised.depth.values, everyElement(0.5));
      expect(normalised.lowRelief, isTrue);
    });

    test('says little relief when the spread is under a tenth of p98', () {
      expect(normaliseDepth(ReliefDepth(2, 1, Float64List.fromList([10, 10.9]))).lowRelief, isTrue);
      expect(normaliseDepth(ReliefDepth(2, 1, Float64List.fromList([10, 11.2]))).lowRelief, isFalse);
      // A tenth of p98, not of p2: 1.05 is over a tenth of 10 but under a tenth of 11.05
      expect(normaliseDepth(ReliefDepth(2, 1, Float64List.fromList([10, 11.05]))).lowRelief, isTrue);
      // |p98|: a map of negative values is judged on its magnitude
      expect(normaliseDepth(ReliefDepth(2, 1, Float64List.fromList([-11, -10.5]))).lowRelief, isTrue);
    });

    test('never lets a value that is not a number through', () {
      final values = Float64List.fromList([for (var index = 0; index < 100; index++) index.toDouble()]);
      values[40] = double.nan;
      values[41] = double.infinity;
      values[42] = double.negativeInfinity;
      final normalised = normaliseDepth(ReliefDepth(10, 10, values));
      expect(normalised.depth.values.every((value) => value >= 0 && value <= 1), isTrue);
      expect(normalised.depth.values[40], 0.5);
      expect(normalised.depth.values[41], 1);
      expect(normalised.depth.values[42], 0);
      expect(normalised.p2.isFinite && normalised.p98.isFinite, isTrue);
      // Ranks 2 and 96 of the 97 finite values: an infinity counted in would give 0 and 99
      expect(normalised.p2, 1);
      expect(normalised.p98, 98);

      final broken = normaliseDepth(ReliefDepth(2, 2, Float64List.fromList([double.nan, double.nan, double.nan, 1])));
      expect(broken.depth.values, everyElement(0.5));
      expect(broken.lowRelief, isTrue);
    });

    test('keeps p98 finite when more than 2 % of the map is infinite', () {
      // 10 % of +infinity: counted in the percentiles, p98 would be infinite and those values NaN
      final values = Float64List.fromList([for (var index = 0; index < 100; index++) index.toDouble()]);
      values.fillRange(90, 100, double.infinity);
      final normalised = normaliseDepth(ReliefDepth(10, 10, values));
      expect(normalised.p2, 1);
      expect(normalised.p98, 88);
      expect(normalised.depth.values.every((value) => value >= 0 && value <= 1), isTrue);
      expect(normalised.depth.values.sublist(90), everyElement(1));
    });
  });

  group('the dilation of the foreground', () {
    test('spreads the nearest value over the 5 x 5 window around it, cut at the edges', () {
      final values = Float64List(9 * 7);
      values[3 * 9 + 4] = 1;
      values[0] = 0.5;
      final dilated = dilateForeground(ReliefDepth(9, 7, values)).values;
      double wanted(int x, int y) {
        if ((x - 4).abs() <= 2 && (y - 3).abs() <= 2) {
          return 1;
        }
        return x <= 2 && y <= 2 ? 0.5 : 0;
      }

      for (var y = 0; y < 7; y++) {
        for (var x = 0; x < 9; x++) {
          expect(dilated[y * 9 + x], wanted(x, y), reason: '($x, $y)');
        }
      }
    });

    test('leaves a map of one value as it is', () {
      expect(dilateForeground(ReliefDepth(1, 1, Float64List.fromList([0.3]))).values, [0.3]);
    });
  });
}
