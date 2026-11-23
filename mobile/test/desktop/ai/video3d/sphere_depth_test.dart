// The projection maths of the 360° 3D videos (lot ai-360-3d-51): the six faces of the cube and their round trip, the
// whole sphere covered, the depth of a known sphere read back through the faces (seams of the cube and of the frame
// continuous, the poles included), the faces brought to each other when each has a scale and a shift of its own, the
// smoothing over time, the equal area percentiles, and the right eye of relief-360 on RGB frames: no shift at the
// poles, the shift of the equator wrapped across the seam.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/panorama/erp_math.dart';
import 'package:immich_mobile/desktop/ai/panorama/pano_depth.dart' show ViewAlignment;
import 'package:immich_mobile/desktop/ai/panorama/relief_360.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/desktop/ai/video3d/sphere_depth.dart';

/// The disparity of a smooth made up scene, 1 / r, r the distance in the direction ([x], [y], [z])
double _disparity(double x, double y, double z) => 1 / (2 + 0.6 * x + 0.4 * y - 0.3 * z * x);

/// The map of each face as the model would give it for that scene: 1 / z, z the depth along the axis of the face,
/// brought by [alpha] and [beta] of each face (x = (1 / z - beta) / alpha)
List<Float64List> _faceMaps(List<TangentView> views, {List<double>? alpha, List<double>? beta}) => [
  for (final (k, view) in views.indexed)
    Float64List.fromList([
      for (var j = 0; j < view.height; j++)
        for (var i = 0; i < view.width; i++)
          () {
            final d = view.directionOf(i.toDouble(), j.toDouble());
            final cosine = d.dot(view.forward);
            final inverseZ = _disparity(d.x, d.y, d.z) / cosine;
            return (inverseZ - (beta?[k] ?? 0)) / (alpha?[k] ?? 1);
          }(),
    ]),
];

void main() {
  test('six faces, each its own axis, a pixel back where it came from', () {
    final views = sphereVideoViews(56);
    expect(views.length, sphereViewCount);
    for (final view in views) {
      expect(view.tanX, closeTo(sphereFaceTan, 1e-12));
      for (final (i, j) in [(0.0, 0.0), (27.5, 27.5), (55.0, 3.0), (10.0, 55.0)]) {
        final d = view.directionOf(i, j);
        final (u, v) = view.pixelOf(d.x, d.y, d.z)!;
        expect(u, closeTo(i, 1e-9));
        expect(v, closeTo(j, 1e-9));
      }
    }
    // Two neighbours share 12.7° across their common edge
    final across = 2 * (math.atan(sphereFaceTan) - math.pi / 4) * 180 / math.pi;
    expect(across, closeTo(12.68, 0.01));
  });

  test('every pixel of the map is seen by a face, a direction near an edge or a corner by several', () {
    final views = sphereVideoViews(28);
    final map = sphereMapSize(28);
    final merger = SphereDepthMerger(views: views, mapWidth: map.width, mapHeight: map.height);
    expect(merger.uncovered, 0);
    expect(merger.alignmentPoints, greaterThan(100));
    // A corner of the cube: three faces see it with a weight above zero
    const corner = SphereVector(0.5773502691896258, 0.5773502691896258, 0.5773502691896258);
    final seeing = views.where((view) {
      final at = view.pixelOf(corner.x, corner.y, corner.z);
      return at != null && view.weightAt(at.$1, at.$2) > 0;
    });
    expect(seeing.length, 3);
  });

  test('the depth of a known sphere comes back through the faces: the edges of the cube, the seam of the frame and '
      'the poles continuous', () {
    final views = sphereVideoViews(56);
    final size = sphereMapSize(56);
    final merger = SphereDepthMerger(views: views, mapWidth: size.width, mapHeight: size.height);
    final x = _faceMaps(views);
    final alignment = merger.align(x);
    for (final face in alignment) {
      expect(face.scale, closeTo(1, 1e-3));
      expect(face.shift, closeTo(0, 1e-3));
    }
    final merged = merger.merge(x, alignment);
    var worst = 0.0;
    for (var y = 0; y < size.height; y++) {
      for (var xx = 0; xx < size.width; xx++) {
        final d = erpDirection(xx, y, size.width, size.height);
        final expected = _disparity(d.x, d.y, d.z);
        worst = math.max(worst, (merged[y * size.width + xx] - expected).abs() / expected);
      }
    }
    expect(worst, lessThan(2e-3));
    // Across the seam of the frame: the last column and the first one differ no more than two neighbours inside
    for (var y = 0; y < size.height; y++) {
      final row = y * size.width;
      var step = 0.0;
      for (var xx = 0; xx + 1 < size.width; xx++) {
        step = math.max(step, (merged[row + xx + 1] - merged[row + xx]).abs());
      }
      expect(
        (merged[row] - merged[row + size.width - 1]).abs(),
        lessThanOrEqualTo(step * 1.5 + 1e-12),
        reason: 'row $y',
      );
    }
    // The rows at the poles: one direction each, the same value along the row within the interpolation
    for (final y in [0, size.height - 1]) {
      final row = merged.sublist(y * size.width, (y + 1) * size.width);
      expect(row.reduce(math.max) - row.reduce(math.min), lessThan(0.01));
    }
  });

  test(
    'faces with a scale and a shift of their own are brought to each other: the sphere up to one scale and shift',
    () {
      final views = sphereVideoViews(56);
      final size = sphereMapSize(56);
      final merger = SphereDepthMerger(views: views, mapWidth: size.width, mapHeight: size.height);
      final x = _faceMaps(views, alpha: [1.0, 0.6, 1.7, 1.2, 0.8, 1.4], beta: [0.0, 0.1, -0.2, 0.05, 0.15, -0.1]);
      final merged = merger.merge(x, merger.align(x));
      // A fit of merged = a / r + b over the sphere leaves almost nothing
      var sxx = 0.0;
      var sx = 0.0;
      var sy = 0.0;
      var sxy = 0.0;
      var n = 0.0;
      final truth = Float64List(merged.length);
      for (var y = 0; y < size.height; y++) {
        for (var xx = 0; xx < size.width; xx++) {
          final d = erpDirection(xx, y, size.width, size.height);
          final value = truth[y * size.width + xx] = _disparity(d.x, d.y, d.z);
          final got = merged[y * size.width + xx];
          sxx += value * value;
          sx += value;
          sy += got;
          sxy += value * got;
          n++;
        }
      }
      final a = (n * sxy - sx * sy) / (n * sxx - sx * sx);
      final b = (sy - a * sx) / n;
      expect(a, greaterThan(0));
      var worst = 0.0;
      var spread = 0.0;
      for (var i = 0; i < merged.length; i++) {
        worst = math.max(worst, (merged[i] - (a * truth[i] + b)).abs());
        spread = math.max(spread, (a * truth[i] + b).abs());
      }
      expect(worst / spread, lessThan(0.02));
    },
  );

  test('the alignment of a face is smoothed over the frames; a face left out keeps its last one', () {
    const previous = [ViewAlignment(1, 0), ViewAlignment(2, 1), ViewAlignment.unused];
    const solved = [ViewAlignment(2, 1), ViewAlignment.unused, ViewAlignment(3, 0.5)];
    final smoothed = smoothAlignments(previous, solved);
    expect(smoothed[0].scale, closeTo(1.1, 1e-12));
    expect(smoothed[0].shift, closeTo(0.1, 1e-12));
    expect(smoothed[1].scale, 2);
    expect(smoothed[2].scale, 3);
    expect(smoothAlignments(null, solved), same(solved));
  });

  test('the percentiles of the map count the sphere, not the rows: a hot band at a pole barely moves them', () {
    const width = 256;
    const height = 128;
    final values = Float64List(width * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        values[y * width + x] = y < 8 ? 100 : (x % 10) / 10;
      }
    }
    final (p2, p98) = spherePercentiles(values, width, height);
    expect(p2, 0);
    expect(p98, lessThan(1));
    final map = sphereRelief(values, width, height, p2, p98);
    expect(map.values.reduce(math.max), 1);
    expect(map.values.reduce(math.min), 0);
  });

  test('a frame brought down by area and read on the faces: the face ahead sees the middle of the frame', () {
    const width = 64;
    const height = 32;
    final rgb = Uint8List(width * height * 3);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        rgb[3 * (y * width + x)] = x * 4;
        rgb[3 * (y * width + x) + 1] = y * 8;
        rgb[3 * (y * width + x) + 2] = 128;
      }
    }
    final halved = rgbAreaResample(rgb, width, height, 32, 16);
    expect(halved[0], 2); // (0 + 4) / 2
    expect(halved[1], 4); // (0 + 8) / 2
    final sampler = SphereViewSampler(eyeWidth: width, eyeHeight: height, views: sphereVideoViews(8));
    expect((sampler.sourceWidth, sampler.sourceHeight), (32, 16));
    final faces = sampler.sample(rgb);
    expect(faces.length, 6);
    // The pixel (3, 3) of the face ahead looks 8.9° left of longitude 0: column 14.7 of the halved frame, whose red
    // is 8 x + 2
    final ahead = faces.first;
    const centre = 3 * (3 * 8 + 3);
    expect(ahead[centre], closeTo(119.7, 1.5));
    expect(ahead[centre + 2], 128);
  });

  test('the right eye of an RGB frame: nothing moves at the poles, the equator moves by the shift and wraps across the '
      'seam', () {
    const width = 360;
    const height = 180;
    final left = Uint8List(width * height * 3);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        left[3 * (y * width + x)] = (x * 7) % 256;
        left[3 * (y * width + x) + 1] = (x * 3 + y) % 256;
        left[3 * (y * width + x) + 2] = y;
      }
    }
    // Everything at the nearest: a shift of the whole sphere of 1° at the equator, 1 pixel of this frame
    final map = ReliefDepth(90, 45, Float64List(90 * 45)..fillRange(0, 90 * 45, 1));
    final frame = Uint8List(2 * width * height * 3)..setRange(0, width * height * 3, left);
    final eye = writeRelief360RightEye(
      left: left,
      width: width,
      height: height,
      map: map,
      lowRelief: false,
      maxShiftDegrees: 1,
      target: frame,
      targetOffset: width * height * 3,
      channels: 3,
    );
    expect(eye.filledPixels, lessThan(width * height ~/ 100));
    Uint8List rightRow(int y) => Uint8List.sublistView(frame, (height + y) * width * 3, (height + y + 1) * width * 3);
    Uint8List leftRow(int y) => Uint8List.sublistView(left, y * width * 3, (y + 1) * width * 3);
    // The poles: the same row in both eyes
    expect(rightRow(0), leftRow(0));
    expect(rightRow(height - 1), leftRow(height - 1));
    // The equator: the right eye sees each column one to the right, the last one the first of the frame
    const equator = height ~/ 2;
    final right = rightRow(equator);
    final source = leftRow(equator);
    for (var x = 0; x < width; x++) {
      expect(right[3 * x], source[3 * ((x + 1) % width)], reason: 'column $x');
    }
    // The strengths: 0.75°, 1° and 1.5° at the equator
    expect(sphereShiftDegreesOf(0.02), 1);
    expect(sphereShiftDegreesOf(0.015), 0.75);
    expect(sphereShiftDegreesOf(0.03), closeTo(1.5, 1e-12));
  });
}
