// The geometry of the panoramas and the depth of a whole sphere for relief-360-v1 (lot P1, design-final 2026-10-27,
// section 4.4, point 1): the convention of make_pano_golden.py for the direction of a pixel, the icosahedron and its
// tangent views (every direction seen, each view level), the input of the depth model read around the sphere, then the
// maps of the views of a synthetic room, each with a scale and a shift of its own as Depth Anything gives them,
// aligned and merged back into the disparity of the room; a view the model read inverted is left out, and what no
// view kept sees is counted; a flat world stays flat, and the seam is no edge.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/panorama/erp_math.dart';
import 'package:immich_mobile/desktop/ai/panorama/pano_depth.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_input.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

double _degrees(double radians) => radians * 180 / math.pi;

/// The distance to a room of 6 x 3.2 x 8 m around the eye, with a ball of 0.5 m at 1.7 m ahead and to the right when
/// [ball]
double _roomDistance(SphereVector d, {bool ball = true}) {
  var distance = double.infinity;
  for (final (component, half) in [(d.x, 3.0), (d.y, 1.6), (d.z, 4.0)]) {
    if (component.abs() > 1e-12) {
      distance = math.min(distance, half / component.abs());
    }
  }
  if (ball) {
    const cx = 0.8;
    const cy = -0.2;
    const cz = 1.5;
    const radius = 0.5;
    final along = d.x * cx + d.y * cy + d.z * cz;
    final disc = along * along - (cx * cx + cy * cy + cz * cz - radius * radius);
    if (disc >= 0) {
      final hit = along - math.sqrt(disc);
      if (hit > 0) {
        distance = math.min(distance, hit);
      }
    }
  }
  return distance;
}

/// What a depth model gives for [view] of the room: s / z + t, z the depth along the axis of the view, with a scale
/// and a shift of its own for each view, as a relative disparity is
DepthMap _modelMap(TangentView view, int index, {bool ball = true}) {
  final scale = 1 + 0.5 * math.sin(1.7 * index);
  final shift = 0.3 * math.cos(2.3 * index);
  final values = Float32List(view.width * view.height);
  for (var j = 0; j < view.height; j++) {
    for (var i = 0; i < view.width; i++) {
      final direction = view.directionOf(i.toDouble(), j.toDouble());
      final z = _roomDistance(direction, ball: ball) * direction.dot(view.forward);
      values[j * view.width + i] = scale / z + shift;
    }
  }
  return DepthMap(view.width, view.height, values);
}

/// The true disparity of the room, 1 / distance, at each pixel of a map of [width] x [height]
Float64List _roomDisparity(int width, int height, {bool ball = true}) => Float64List.fromList([
  for (var y = 0; y < height; y++)
    for (var x = 0; x < width; x++) 1 / _roomDistance(erpDirection(x, y, width, height), ball: ball),
]);

/// [actual] against [expected] up to one factor: the relative errors once the best factor is applied, sorted
List<double> _relativeErrors(Float64List actual, Float64List expected) {
  var cross = 0.0;
  var square = 0.0;
  for (var i = 0; i < actual.length; i++) {
    cross += actual[i] * expected[i];
    square += expected[i] * expected[i];
  }
  final factor = cross / square;
  return [for (var i = 0; i < actual.length; i++) (actual[i] - factor * expected[i]).abs() / (factor * expected[i])]
    ..sort();
}

void main() {
  group('the frame', () {
    test('the convention of make_pano_golden.py: the centre column ahead, the right to the right, the top up', () {
      const width = 400;
      const height = 200;
      final ahead = erpDirection(width ~/ 2, height ~/ 2, width, height);
      expect(ahead.z, closeTo(1, 1e-3));
      // The column three quarters across looks right, x positive
      final right = erpDirection(3 * width ~/ 4, height ~/ 2, width, height);
      expect(right.x, closeTo(1, 1e-3));
      expect(erpDirection(0, 0, width, height).y, closeTo(1, 1e-3));
      expect(erpLatitude(height - 1, height), closeTo(-math.pi / 2 + math.pi / (2 * height), 1e-12));
    });

    test('a pixel goes to its direction and back', () {
      const width = 64;
      const height = 32;
      for (final (x, y) in [(0, 0), (63, 31), (17, 9), (32, 16), (63, 16), (0, 16)]) {
        final d = erpDirection(x, y, width, height);
        final (u, v) = erpPixelOf(d.x, d.y, d.z, width, height);
        expect(u, closeTo(x, 1e-9), reason: 'column of ($x, $y)');
        expect(v, closeTo(y, 1e-9), reason: 'row of ($x, $y)');
      }
    });

    test('a read around the sphere wraps the columns and repeats the poles', () {
      final sphere = SphereBilinear(4, 2);
      final values = [0.0, 1.0, 2.0, 3.0, 10.0, 11.0, 12.0, 13.0];
      // Half a pixel left of the first column: between the last and the first
      expect(sphere.read(values, -0.5, 0), closeTo(1.5, 1e-12));
      expect(sphere.read(values, 3.5, 1), closeTo(11.5, 1e-12));
      // Above the top row: the top row itself
      expect(sphere.read(values, 1, -0.7), closeTo(1, 1e-12));
      expect(sphere.read(values, 1, 5), closeTo(11, 1e-12));
    });

    test('a frame resampled by area to an exact 2:1, larger or smaller, its profile kept', () {
      final rgba = Uint8List(4 * 6 * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba.setAll(i, [i ~/ 4 * 10, 100, 200, 255]);
      }
      final profile = Uint8List.fromList([1, 2, 3]);
      final picture = SbsDecoded(width: 6, height: 4, rgba: rgba, iccProfile: profile);
      expect(identical(resampleArea(picture, 6, 4), picture), isTrue);
      final half = resampleArea(picture, 3, 2);
      expect(half.iccProfile, profile);
      // The first pixel averages the pixels 0, 1, 6 and 7: red 0, 10, 60 and 70
      expect(half.rgba.sublist(0, 4), [35, 100, 200, 255]);
      final larger = resampleArea(picture, 12, 6);
      expect(larger.width, 12);
      expect(larger.height, 6);
      expect(larger.rgba.sublist(0, 4), [0, 100, 200, 255]);
    });
  });

  group('the icosahedron and its views', () {
    final centres = icosahedronFaceCentres();
    final views = relief360Views();

    test('20 faces, each 41.8° from its three neighbours, every direction within 37.4° of one', () {
      expect(centres, hasLength(Relief360V1.tangentViews));
      for (final centre in centres) {
        expect(centre.dot(centre), closeTo(1, 1e-12));
        final angles = [
          for (final other in centres)
            if (!identical(other, centre)) _degrees(centre.angleTo(other)),
        ]..sort();
        expect(angles.take(3), everyElement(closeTo(41.81, 0.01)));
        expect(angles[3], greaterThan(60));
      }
      var farthest = 0.0;
      for (var y = 0; y < 90; y++) {
        for (var x = 0; x < 180; x++) {
          final d = erpDirection(x, y, 180, 90);
          farthest = math.max(farthest, centres.map((centre) => _degrees(d.angleTo(centre))).reduce(math.min));
        }
      }
      expect(farthest, lessThan(37.38 + 0.01));
    });

    test('each view is level, the input of the depth model, 45° up and 52.9° to each side', () {
      for (final view in views) {
        expect(view.width, depthModelInputWidth);
        expect(view.height, depthModelInputHeight);
        expect(view.right.y, closeTo(0, 1e-12), reason: 'the horizon is level');
        expect(view.up.y, greaterThan(0));
        expect(view.right.dot(view.forward), closeTo(0, 1e-12));
        expect(view.up.dot(view.forward), closeTo(0, 1e-12));
      }
      expect(_degrees(math.atan(views.first.tanY)), closeTo(45, 1e-9));
      expect(_degrees(math.atan(views.first.tanX)), closeTo(52.94, 0.01));
    });

    test('a pixel of a view goes to its direction and back, its weight 1 at the centre and 0 at the edge', () {
      final view = TangentView(const SphereVector(0.6, 0.48, 0.64), width: 40, height: 30);
      for (final (i, j) in [(0.0, 0.0), (39.0, 29.0), (12.0, 20.0), (19.5, 14.5)]) {
        final d = view.directionOf(i, j);
        final (u, v) = view.pixelOf(d.x, d.y, d.z)!;
        expect(u, closeTo(i, 1e-9));
        expect(v, closeTo(j, 1e-9));
      }
      expect(view.weightAt(19.5, 14.5), 1);
      expect(view.weightAt(-0.5, 14.5), 0);
      expect(view.weightAt(19.5, 29.5), 0);
      expect(view.weightAt(9.5, 14.5), closeTo(0.25, 1e-12));
      final behind = view.forward;
      expect(view.pixelOf(-behind.x, -behind.y, -behind.z), isNull);
    });

    test('every direction of the sphere is seen by a view, away from its edge', () {
      final small = relief360Views(inputWidth: 64, inputHeight: 48);
      final flat = [
        for (var k = 0; k < small.length; k++) DepthMap(64, 48, Float32List(64 * 48)..fillRange(0, 64 * 48, 1)),
      ];
      final merged = mergeViewDepths(small, flat, width: 180, height: 90);
      expect(merged.uncovered, 0);
    });

    test('the input of a view is the panorama read around the sphere, normalised as the 3D photo does', () {
      const width = 360;
      const height = 180;
      final rgba = Uint8List(4 * width * height);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final lon = erpLongitude(x, width);
          final lat = erpLatitude(y, height);
          rgba.setAll(4 * (y * width + x), [
            (128 + 100 * math.sin(lon)).round(),
            (128 + 100 * math.cos(lon)).round(),
            (128 + 120 * lat / math.pi).round(),
            255,
          ]);
        }
      }
      final panorama = SbsDecoded(width: width, height: height, rgba: rgba);
      // A view looking behind, across the seam, and one looking up
      for (final forward in [const SphereVector(0, 0, -1), SphereVector.unit(0.3, 0.8, 0.2)]) {
        final view = TangentView(forward, width: 31, height: 23);
        final nchw = tangentViewInput(panorama, view);
        const plane = 31 * 23;
        double byte(int channel, int at) =>
            (nchw[channel * plane + at] * reliefInputStd[channel] + reliefInputMean[channel]) * 255;
        for (final (i, j) in [(15, 11), (0, 0), (30, 22), (3, 17)]) {
          final d = view.directionOf(i.toDouble(), j.toDouble());
          final lon = math.atan2(d.x, d.z);
          final lat = math.asin(d.y);
          final at = j * 31 + i;
          expect(byte(0, at), closeTo(128 + 100 * math.sin(lon), 2), reason: 'red at ($i, $j) of $forward');
          expect(byte(1, at), closeTo(128 + 100 * math.cos(lon), 2), reason: 'green at ($i, $j) of $forward');
          expect(byte(2, at), closeTo(128 + 120 * lat / math.pi, 2), reason: 'blue at ($i, $j) of $forward');
        }
      }
    });
  });

  group('the views merged', () {
    const width = 256;
    const height = 128;
    final views = relief360Views(inputWidth: 128, inputHeight: 96);

    test('the maps of a room, each with its own scale and shift, merge back into the disparity of the room', () {
      final merged = mergeViewDepths(
        views,
        [for (var k = 0; k < views.length; k++) _modelMap(views[k], k)],
        width: width,
        height: height,
      );
      expect(merged.uncovered, 0);
      final errors = _relativeErrors(merged.map.values, _roomDisparity(width, height));
      // 0.27 % and 0.67 % on ai1; a merge without cos(theta), or without the alignment, is off by 25 % in the median
      expect(errors[errors.length ~/ 2], lessThan(0.005));
      expect(errors[errors.length * 99 ~/ 100], lessThan(0.02), reason: 'only the edge of the ball is off');
      expect(merged.alignments.every((alignment) => alignment.scale > 0), isTrue);
    });

    test('without the ball, a smooth room: every pixel within 2 % of the truth', () {
      final merged = mergeViewDepths(
        views,
        [for (var k = 0; k < views.length; k++) _modelMap(views[k], k, ball: false)],
        width: width,
        height: height,
      );
      final errors = _relativeErrors(merged.map.values, _roomDisparity(width, height, ball: false));
      // 0.007 % and 1.3 % on ai1, the largest where a corner of the room is read in bilinear
      expect(errors[errors.length ~/ 2], lessThan(0.001));
      expect(errors.last, lessThan(0.02));
    });

    test('a view the model read inverted is left out, the others solved again: the room stays within 1 %', () {
      // Each view is brought between its own percentiles: had the whole alignment been given up for this one view,
      // the twenty would be merged at twenty scales, 25 % off in the median
      final maps = [for (var k = 0; k < views.length; k++) _modelMap(views[k], k)];
      final inverted = maps[2];
      maps[2] = DepthMap(inverted.width, inverted.height, Float32List.fromList([for (final v in inverted.values) -v]));
      final merged = mergeViewDepths(views, maps, width: width, height: height);

      expect(merged.uncovered, 0, reason: 'its neighbours see what it saw');
      expect(merged.alignments[2].isUsed, isFalse);
      expect(merged.alignments[2].scale, 0);
      for (final (k, alignment) in merged.alignments.indexed) {
        if (k != 2) {
          expect(alignment.isUsed, isTrue, reason: 'view $k');
        }
      }
      final errors = _relativeErrors(merged.map.values, _roomDisparity(width, height));
      expect(errors[errors.length ~/ 2], lessThan(0.01));
      expect(errors[errors.length * 9 ~/ 10], lessThan(0.03));
    });

    test('the five views around the north pole read inverted: left out, the pole seen by no view is counted', () {
      final maps = [for (var k = 0; k < views.length; k++) _modelMap(views[k], k)];
      for (var k = 0; k < 5; k++) {
        maps[k] = DepthMap(maps[k].width, maps[k].height, Float32List.fromList([for (final v in maps[k].values) -v]));
      }
      final merged = mergeViewDepths(views, maps, width: width, height: height);

      expect(
        [for (final alignment in merged.alignments) alignment.isUsed],
        [for (var k = 0; k < views.length; k++) k >= 5],
      );
      expect(merged.uncovered, greaterThan(0));
      // The pixels no view saw are left at 0, and only around the pole, past the reach of the ring of the equator
      var unseen = 0;
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          if (merged.map.values[y * width + x] == 0) {
            unseen++;
            expect(_degrees(erpLatitude(y, height)), greaterThan(50), reason: 'row $y, column $x');
          }
        }
      }
      expect(unseen, merged.uncovered);
    });

    test('the seam is no edge: the columns on each side of it differ as little as two neighbours elsewhere', () {
      final merged = mergeViewDepths(
        views,
        [for (var k = 0; k < views.length; k++) _modelMap(views[k], k)],
        width: width,
        height: height,
      );
      final map = merged.map.values;
      for (var y = 0; y < height; y++) {
        var neighbours = 0.0;
        for (var x = 1; x < width; x++) {
          neighbours = math.max(neighbours, (map[y * width + x] - map[y * width + x - 1]).abs());
        }
        final across = (map[y * width] - map[y * width + width - 1]).abs();
        expect(across, lessThanOrEqualTo(neighbours + 1e-9), reason: 'row $y');
      }
    });

    test('a world without relief stays flat: the relief of relief-v1 says lowRelief', () {
      final flat = [
        for (final view in views)
          DepthMap(
            view.width,
            view.height,
            Float32List(view.width * view.height)..fillRange(0, view.width * view.height, 7),
          ),
      ];
      final merged = mergeViewDepths(views, flat, width: width, height: height);
      expect(normaliseDepth(merged.map).lowRelief, isTrue);
    });

    test('refuses views and maps that do not pair', () {
      expect(() => mergeViewDepths(views, const [], width: 8, height: 4), throwsArgumentError);
    });
  });
}
