// The right eye of a 360° panorama, relief-360-v1 (lot P1, design-final 2026-10-27, section 4.4): the golden fixture
// of .github/desktop/ai/make_pano_golden.py (each byte within one unit, the mask of the filled pixels exactly, the
// numbers within 1e-9), then what a fixture of 48 x 24 cannot show: nothing moves at the poles, the nearest moves by
// 1° at the equator, the seam is no edge (the eye of a panorama turned by half a turn is that eye turned), a flat map
// gives the panorama back, and the cancel and the progress of the rows.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/panorama/relief_360.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/desktop/ai/relief/right_eye.dart' show ReliefCancelledException;
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

Map<String, dynamic> _golden() =>
    jsonDecode(File('test/fixtures/ai_immersive/pano_golden_v1.json').readAsStringSync()) as Map<String, dynamic>;

/// RGBA from rows of R, G, B bytes
Uint8List _rgbaOf(List<List<int>> rows) => Uint8List.fromList([
  for (final row in rows)
    for (var x = 0; x < row.length; x += 3) ...[row[x], row[x + 1], row[x + 2], 255],
]);

/// A panorama of [width] x [height] that changes slowly everywhere and wraps across the seam
Uint8List _smoothPanorama(int width, int height) {
  final rgba = Uint8List(4 * width * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final angle = 2 * math.pi * x / width;
      final at = 4 * (y * width + x);
      rgba[at] = (128 + 100 * math.sin(angle)).round();
      rgba[at + 1] = (128 + 100 * math.cos(2 * angle)).round();
      rgba[at + 2] = (40 + 160 * y / height).round();
      rgba[at + 3] = 255;
    }
  }
  return rgba;
}

/// A far room (0) with a near box (1) across the seam, columns within [half] of it, rows [top] to [bottom]
ReliefDepth _boxAcrossSeam(int width, int height, {required int half, required int top, required int bottom}) {
  final values = Float64List(width * height);
  for (var y = top; y <= bottom; y++) {
    for (var x = 0; x < width; x++) {
      if (x < half || x >= width - half) {
        values[y * width + x] = 1;
      }
    }
  }
  return ReliefDepth(width, height, values);
}

/// [rgba] of [width] x [height] rolled by [by] columns: the column x of the result is the column (x + by) mod width
Uint8List _roll(Uint8List cells, int width, int height, int by, {int bytes = 4}) {
  final out = Uint8List(cells.length);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final from = (y * width + (x + by) % width) * bytes;
      out.setRange((y * width + x) * bytes, (y * width + x + 1) * bytes, cells, from);
    }
  }
  return out;
}

ReliefDepth _rollDepth(ReliefDepth map, int by) {
  final values = Float64List(map.values.length);
  for (var y = 0; y < map.height; y++) {
    for (var x = 0; x < map.width; x++) {
      values[y * map.width + x] = map.values[y * map.width + (x + by) % map.width];
    }
  }
  return ReliefDepth(map.width, map.height, values);
}

void main() {
  group('pano_golden_v1.json', () {
    final golden = _golden();
    final width = golden['frameWidth'] as int;
    final height = golden['frameHeight'] as int;
    final tolerance = (golden['tolerance'] as num).toDouble();

    for (final entry in (golden['reliefs'] as List).cast<Map<String, dynamic>>()) {
      final name = entry['name'] as String;
      test('$name: ${entry['description']}', () {
        final left = _rgbaOf((entry['image'] as List).map((row) => (row as List).cast<int>()).toList());
        final disparity = Float64List.fromList([
          for (final row in entry['disparity'] as List)
            for (final value in row as List) (value as num).toDouble(),
        ]);
        final normalised = normaliseDepth(ReliefDepth(width, height, disparity));
        expect(normalised.p2, closeTo((entry['p2'] as num).toDouble(), tolerance));
        expect(normalised.p98, closeTo((entry['p98'] as num).toDouble(), tolerance));
        final expectedD = [
          for (final row in entry['normalized'] as List)
            for (final value in row as List) (value as num).toDouble(),
        ];
        for (var i = 0; i < expectedD.length; i++) {
          expect(normalised.depth.values[i], closeTo(expectedD[i], tolerance), reason: 'd at $i');
        }

        final before = Uint8List.fromList(left);
        final right = Uint8List(left.length);
        final holes = Uint8List(width * height);
        final eye = writeRelief360RightEye(
          left: left,
          width: width,
          height: height,
          map: normalised.depth,
          lowRelief: normalised.lowRelief,
          maxShiftDegrees: (entry['maxShiftDegrees'] as num).toDouble(),
          target: right,
          holes: holes,
        );

        expect(left, before, reason: 'the left eye is only read');
        final expectedRows = (entry['rightEye'] as List).map((row) => (row as List).cast<int>()).toList();
        final expectedHoles = (entry['holes'] as List).cast<String>();
        for (var y = 0; y < height; y++) {
          expect(
            [for (var x = 0; x < width; x++) holes[y * width + x]].join(),
            expectedHoles[y],
            reason: 'the holes of the row $y',
          );
          for (var x = 0; x < width; x++) {
            for (var channel = 0; channel < 3; channel++) {
              final actual = right[4 * (y * width + x) + channel];
              final expected = expectedRows[y][3 * x + channel];
              expect((actual - expected).abs(), lessThanOrEqualTo(1), reason: 'row $y, column $x, channel $channel');
            }
            expect(right[4 * (y * width + x) + 3], 255);
          }
        }
        expect(eye.filledPixels, entry['filledPixels']);
        expect(eye.filledFraction, closeTo((entry['filledFraction'] as num).toDouble(), tolerance));
        expect([for (final flag in eye.flags) flag.xmp], entry['flags']);
        expect(eye.refused, entry['refused']);
      });
    }
  });

  group('around the sphere', () {
    test('nothing moves at the poles, the nearest moves by 1° at the equator', () {
      const width = 720;
      const height = 360;
      final left = _smoothPanorama(width, height);
      // Near everywhere: every pixel shifts by its row's share of 1°, 2 pixels at the equator for 720 columns
      final near = ReliefDepth(width, height, Float64List(width * height)..fillRange(0, width * height, 1));
      final right = Uint8List(left.length);
      final holes = Uint8List(width * height);
      final eye = writeRelief360RightEye(
        left: left,
        width: width,
        height: height,
        map: near,
        lowRelief: false,
        target: right,
        holes: holes,
      );
      expect(eye.filledPixels, 0, reason: 'a whole row moving together opens nothing around the sphere');
      for (final y in [0, 1, height - 2, height - 1]) {
        expect(
          right.sublist(4 * y * width, 4 * (y + 1) * width),
          left.sublist(4 * y * width, 4 * (y + 1) * width),
          reason: 'the row $y at the pole is the panorama itself',
        );
      }
      // At the equator the whole row moved left by 2 columns: the right eye at x is the panorama at x + 2
      for (final y in [height ~/ 2 - 1, height ~/ 2]) {
        final shift = width / 360 * math.cos(math.pi * (0.5 - (y + 0.5) / height));
        expect(shift, closeTo(2, 1e-4));
        for (var x = 0; x < width; x++) {
          for (var channel = 0; channel < 3; channel++) {
            final from = left[4 * (y * width + (x + 2) % width) + channel];
            expect(
              (right[4 * (y * width + x) + channel] - from).abs(),
              lessThanOrEqualTo(1),
              reason: 'row $y, column $x',
            );
          }
        }
      }
    });

    test('the far stays put: a map of zeros gives the panorama back', () {
      const width = 96;
      const height = 48;
      final left = _smoothPanorama(width, height);
      final right = Uint8List(left.length);
      final eye = writeRelief360RightEye(
        left: left,
        width: width,
        height: height,
        map: ReliefDepth(4, 2, Float64List(8)),
        lowRelief: false,
        target: right,
      );
      expect(right, left);
      expect(eye.filledPixels, 0);
      expect(eye.refused, isFalse);
    });

    test('the seam is no edge: the eye of the panorama turned by half a turn is its eye turned', () {
      const width = 360;
      const height = 180;
      final left = _smoothPanorama(width, height);
      // A near box across the seam at a strong shift opens holes on both sides of the seam
      final map = _boxAcrossSeam(width, height, half: 20, top: 60, bottom: 120);
      Uint8List holesOf(Uint8List image, ReliefDepth depth, Uint8List into) {
        final holes = Uint8List(width * height);
        writeRelief360RightEye(
          left: image,
          width: width,
          height: height,
          map: depth,
          lowRelief: false,
          maxShiftDegrees: 12,
          target: into,
          holes: holes,
        );
        return holes;
      }

      final right = Uint8List(left.length);
      final holes = holesOf(left, map, right);
      expect(holes.contains(1), isTrue, reason: 'the box opens holes beside it');
      expect(
        [for (var y = 60; y <= 120; y++) holes[y * width + width - 1] + holes[y * width]].any((count) => count > 0),
        isFalse,
        reason: 'inside the box, across the seam, nothing is a hole',
      );

      const half = width ~/ 2;
      final turnedRight = Uint8List(left.length);
      final turnedHoles = holesOf(_roll(left, width, height, half), _rollDepth(map, half), turnedRight);
      expect(turnedHoles, _roll(holes, width, height, half, bytes: 1), reason: 'the same holes, wherever the seam is');
      // Two writes of the same depth keep the first one: the order of the columns, which starts at the seam, may pick
      // the other of two neighbours there, never more than one step of the panorama away
      var step = 0;
      for (var y = 0; y < height; y++) {
        for (var x = 1; x < width; x++) {
          for (var channel = 0; channel < 3; channel++) {
            step = math.max(
              step,
              (left[4 * (y * width + x) + channel] - left[4 * (y * width + x - 1) + channel]).abs(),
            );
          }
        }
      }
      final rolled = _roll(right, width, height, half);
      var largest = 0;
      for (var i = 0; i < rolled.length; i++) {
        largest = math.max(largest, (rolled[i] - turnedRight[i]).abs());
      }
      expect(largest, lessThanOrEqualTo(step + 1), reason: 'the same colours but for the order of two equal writes');

      // The columns on each side of the seam differ no more than two neighbours elsewhere in the row
      for (var y = 0; y < height; y++) {
        var neighbours = 0;
        for (var x = 1; x < width; x++) {
          for (var channel = 0; channel < 3; channel++) {
            neighbours = math.max(
              neighbours,
              (right[4 * (y * width + x) + channel] - right[4 * (y * width + x - 1) + channel]).abs(),
            );
          }
        }
        for (var channel = 0; channel < 3; channel++) {
          final across = (right[4 * y * width + channel] - right[4 * (y * width + width - 1) + channel]).abs();
          expect(across, lessThanOrEqualTo(neighbours + 1), reason: 'the seam of the row $y');
        }
      }
    });

    test('a slope that falls across the seam is stretched whole: the last column is linked to the first', () {
      const width = 360;
      const height = 2;
      final left = _smoothPanorama(width, height);
      // From 0.6 left of the seam down to 0 right of it over 20 columns, every two neighbours linked (0.03 apart): at
      // 120° the nearer moves 2.5 columns more than its right neighbour, and only the segments between them, the one
      // across the seam too, leave no hole
      final values = Float64List(width * height);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final across = x < width ~/ 2 ? x + 0.5 : x + 0.5 - width;
          values[y * width + x] = (0.3 - 0.03 * across).clamp(0.0, 0.6);
        }
      }
      final eye = writeRelief360RightEye(
        left: left,
        width: width,
        height: height,
        map: ReliefDepth(width, height, values),
        lowRelief: false,
        maxShiftDegrees: 120,
        target: Uint8List(left.length),
      );
      expect(eye.filledPixels, 0);
    });

    test('refused when the map is flat, or past 8 % filled; hiddenAreas past 5 %', () {
      expect(const Relief360Eye(filledPixels: 0, width: 10, height: 10, lowRelief: true).refused, isTrue);
      expect(const Relief360Eye(filledPixels: 8, width: 10, height: 10, lowRelief: false).refused, isFalse);
      expect(const Relief360Eye(filledPixels: 9, width: 10, height: 10, lowRelief: false).refused, isTrue);
      expect(const Relief360Eye(filledPixels: 5, width: 10, height: 10, lowRelief: false).flags, isEmpty);
      expect(const Relief360Eye(filledPixels: 6, width: 10, height: 10, lowRelief: false).flags, [
        ReliefQualityFlag.hiddenAreas,
      ]);
    });

    test('reads the map around the sphere at the size of the eye, across the seam', () {
      // A map of 4 x 2 whose last column is near: the first columns of an eye of 16 read it across the seam
      final map = ReliefDepth(4, 2, Float64List.fromList([0, 0, 0, 1, 0, 0, 0, 1]));
      final sampler = SphereDepthSampler(map, 16, 2);
      final row = Float64List(16);
      sampler.sampleRow(0, row);
      // u = (x + 0.5) / 4 - 0.5: the column 0 of the eye is at u = -0.375, between the last column and the first
      expect(row[0], closeTo(0.375, 1e-12));
      expect(row[15], closeTo(0.625, 1e-12));
      expect(row[8], 0);
    });

    test('hears the cancel every 64 rows and tells the rows done', () {
      const width = 32;
      const height = 130;
      final left = _smoothPanorama(width, height);
      final rows = <int>[];
      writeRelief360RightEye(
        left: left,
        width: width,
        height: height,
        map: ReliefDepth(2, 2, Float64List(4)),
        lowRelief: false,
        target: Uint8List(left.length),
        onRows: rows.add,
      );
      expect(rows, [64, 128, 130]);
      var asked = 0;
      expect(
        () => writeRelief360RightEye(
          left: left,
          width: width,
          height: height,
          map: ReliefDepth(2, 2, Float64List(4)),
          lowRelief: false,
          target: Uint8List(left.length),
          isCancelled: () => ++asked == 2,
        ),
        throwsA(isA<ReliefCancelledException>()),
      );
      expect(asked, 2);
    });

    test('writes into the lower half of a frame of both eyes, the upper one only read', () {
      const width = 48;
      const height = 24;
      final eye = _smoothPanorama(width, height);
      final frame = Uint8List(2 * eye.length)..setAll(0, eye);
      writeRelief360RightEye(
        left: frame,
        width: width,
        height: height,
        map: _boxAcrossSeam(width, height, half: 4, top: 8, bottom: 16),
        lowRelief: false,
        target: frame,
        targetOffset: eye.length,
      );
      expect(frame.sublist(0, eye.length), eye);
      expect(frame.sublist(eye.length), isNot(everyElement(0)));
    });
  });
}
