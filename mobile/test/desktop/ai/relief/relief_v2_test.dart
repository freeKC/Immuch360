import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_v2.dart';
import 'package:immich_mobile/desktop/ai/relief/right_eye.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// An RGBA eye of [width] x [height] whose pixel (x, y) has the colour [colour] gives
Uint8List _eye(int width, int height, List<int> Function(int x, int y) colour) {
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final c = colour(x, y);
      final at = (y * width + x) * 4;
      rgba[at] = c[0];
      rgba[at + 1] = c[1];
      rgba[at + 2] = c[2];
      rgba[at + 3] = 255;
    }
  }
  return rgba;
}

ReliefDepth _map(int width, int height, double Function(int x, int y) depth) => ReliefDepth(
  width,
  height,
  Float64List.fromList([
    for (var y = 0; y < height; y++)
      for (var x = 0; x < width; x++) depth(x, y),
  ]),
);

/// The first x of [row] where d falls under one half, coming from the left
int _crossing(Float64List row) {
  for (var x = 0; x < row.length; x++) {
    if (row[x] < 0.5) {
      return x;
    }
  }
  return row.length;
}

/// Paints every hole with magenta, and keeps the regions it was given
class _MarkerInpaint implements InpaintBackend {
  final regions = <InpaintRegion>[];

  @override
  int get regionMax => 512;

  @override
  String get modelSha256 => 'marker';

  @override
  Uint8List fill(InpaintRegion region) {
    regions.add(region);
    final out = Uint8List.fromList(region.rgb);
    for (var i = 0; i < region.width * region.height; i++) {
      if (region.mask[i] == 0) {
        out[3 * i] = 255;
        out[3 * i + 1] = 0;
        out[3 * i + 2] = 255;
      }
    }
    return out;
  }

  @override
  void close() {}
}

void main() {
  group('the guided depth of relief-v2', () {
    // A dark object on the left of x = 29, a light background on its right; the model's map, 8 samples across 64
    // pixels, gives the soft ramp Depth Anything draws around an edge
    const width = 64;
    const height = 24;
    const edge = 29;
    final eye = _eye(width, height, (x, y) => x < edge ? const [30, 30, 30] : const [220, 220, 220]);
    const ramp = [1.0, 1.0, 0.9, 0.6, 0.25, 0.05, 0.0, 0.0];
    final map = _map(8, 3, (x, y) => ramp[x]);

    test('keeps the edge of the photo within one pixel, on every row', () {
      final guided = GuidedEyeDepth(map, eye: eye, eyeWidth: width, eyeHeight: height);
      final row = Float64List(width);
      for (var y = 0; y < height; y++) {
        guided.sampleRow(y, row);
        expect((_crossing(row) - edge).abs(), lessThanOrEqualTo(1), reason: 'row $y: $row');
        // A sharp jump: the object on one side, the background on the other, nothing halfway
        expect(row[edge - 2], greaterThan(0.85));
        expect(row[edge + 1], lessThan(0.3));
      }
    });

    test('where the bilinear reading of relief-v1 spreads it over many pixels', () {
      final bilinear = EyeDepthSampler(map, width, height);
      final row = Float64List(width);
      bilinear.sampleRow(0, row);
      final spread = row.where((d) => d > 0.1 && d < 0.85).length;
      expect(spread, greaterThan(8));
    });

    test('gives the depth itself on a photo of one colour', () {
      final plain = _eye(16, 8, (x, y) => const [100, 120, 140]);
      final flat = _map(4, 2, (x, y) => 0.25);
      final row = Float64List(16);
      GuidedEyeDepth(flat, eye: plain, eyeWidth: 16, eyeHeight: 8).sampleRow(3, row);
      for (final d in row) {
        expect(d, closeTo(0.25, 1e-12));
      }
    });

    test('works for an eye smaller than the map', () {
      final small = _eye(3, 2, (x, y) => [x * 80, 0, 0]);
      final row = Float64List(3);
      GuidedEyeDepth(_map(8, 4, (x, y) => x / 7), eye: small, eyeWidth: 3, eyeHeight: 2).sampleRow(1, row);
      expect(row.every((d) => d >= 0 && d <= 1), isTrue);
    });
  });

  group('the right eye of relief-v2', () {
    // A yellow disc, near, on a plain blue background, far; the parallax wide enough for holes of about 10 pixels
    const width = 96;
    const height = 64;
    bool inDisc(int x, int y) => (x - 48) * (x - 48) + (y - 32) * (y - 32) <= 16 * 16;
    const disc = [230, 200, 40];
    const blue = [40, 90, 160];
    final left = _eye(width, height, (x, y) => inDisc(x, y) ? disc : blue);
    final depth = _map(24, 16, (x, y) => inDisc(4 * x + 2, 4 * y + 2) ? 1.0 : 0.0);

    test('without MI-GAN: every hole takes the fill of relief-v1, nothing stays empty', () {
      final target = Uint8List(width * height * 4);
      final holes = Uint8List(width * height);
      final result = reliefV2RightEye(
        left: left,
        width: width,
        height: height,
        depth: depth,
        parallax: 0.1,
        target: target,
        holes: holes,
      );
      expect(result.filledPixels, greaterThan(50));
      expect(result.inpaint.pixels, 0);
      for (var i = 0; i < width * height; i++) {
        expect(target[i * 4 + 3], 255);
        // Inside a hole, past the blur of its edges: the background beside the hole, never the disc
        if (holes[i] == 1 && i % width > 0 && i % width < width - 1 && holes[i - 1] == 1 && holes[i + 1] == 1) {
          expect(target.sublist(i * 4, i * 4 + 3), blue, reason: 'pixel $i');
        }
      }
    });

    test('with MI-GAN: every hole is filled by it, from the background only, the rest untouched', () {
      final plainTarget = Uint8List(width * height * 4);
      reliefV2RightEye(left: left, width: width, height: height, depth: depth, parallax: 0.1, target: plainTarget);
      final target = Uint8List(width * height * 4);
      final holes = Uint8List(width * height);
      final inpaint = _MarkerInpaint();
      final result = reliefV2RightEye(
        left: left,
        width: width,
        height: height,
        depth: depth,
        parallax: 0.1,
        target: target,
        holes: holes,
        inpaint: inpaint,
      );
      expect(result.inpaint.cells, 1);
      expect(result.inpaint.pixels, result.filledPixels);
      expect(inpaint.regions, hasLength(1));
      final region = inpaint.regions.single;
      for (var i = 0; i < region.width * region.height; i++) {
        if (region.mask[i] != 0) {
          // The disc is hidden from MI-GAN along with the holes
          expect(region.rgb.sublist(3 * i, 3 * i + 3), isNot(disc), reason: 'known pixel $i');
        }
      }
      for (var i = 0; i < width * height; i++) {
        final pixel = target.sublist(i * 4, i * 4 + 4);
        if (holes[i] == 1) {
          expect(pixel, [255, 0, 255, 255], reason: 'hole $i');
        } else {
          expect(pixel, plainTarget.sublist(i * 4, i * 4 + 4), reason: 'pixel $i');
        }
      }
    });

    test('thin holes keep the fill of relief-v1', () {
      final target = Uint8List(width * height * 4);
      final inpaint = _MarkerInpaint();
      // A parallax that opens holes of 2 pixels at most
      final result = reliefV2RightEye(
        left: left,
        width: width,
        height: height,
        depth: depth,
        parallax: 0.02,
        target: target,
        inpaint: inpaint,
      );
      expect(result.filledPixels, greaterThan(0));
      expect(inpaint.regions, isEmpty);
      expect(result.inpaint.pixels, 0);
    });

    test('a cancel before a cell stops the fill', () {
      final target = Uint8List(width * height * 4);
      var rows = 0;
      expect(
        () => reliefV2RightEye(
          left: left,
          width: width,
          height: height,
          depth: depth,
          parallax: 0.1,
          target: target,
          inpaint: _MarkerInpaint(),
          onRows: (done) => rows = done,
          // The rows are read at 0 and 64; the first cell after them
          isCancelled: () => rows == height,
        ),
        throwsA(isA<ReliefCancelledException>()),
      );
    });

    test('writes the depth of each pixel, a hole that of its background', () {
      final target = Uint8List(width * height * 4);
      final holes = Uint8List(width * height);
      final eyeDepth = Uint8List(width * height);
      writeRightEye(
        left: left,
        width: width,
        height: height,
        map: depth,
        rows: GuidedEyeDepth(normaliseDepth(depth).depth, eye: left, eyeWidth: width, eyeHeight: height),
        parallax: 0.1,
        convergence: 0.5,
        target: target,
        holes: holes,
        eyeDepth: eyeDepth,
      );
      expect(holes.contains(1), isTrue);
      for (var i = 0; i < width * height; i++) {
        if (holes[i] == 1) {
          // The background side of the jump, never the disc
          expect(eyeDepth[i], lessThan(32), reason: 'hole $i');
        }
      }
      expect(eyeDepth.contains(255), isTrue);
    });
  });

  test('the cells of the holes: a run under the minimum is left out', () {
    const width = 1000;
    const height = 10;
    final holes = Uint8List(width * height);
    holes.fillRange(5 * width + 10, 5 * width + 13, 1); // 3 pixels, cell 0
    holes.fillRange(2 * width + 500, 2 * width + 504, 1); // 4 pixels, cell 1
    holes.fillRange(7 * width + 760, 7 * width + 800, 1); // 40 pixels across cells 1 and 2
    expect(inpaintCellsOf(holes, width, height), [1, 2]);
  });

  test('the pipeline of relief-v2 is its own', () {
    expect(ReliefV2.pipeline, 'relief-v2');
    expect(ReliefV2.pipeline, isNot(ReliefV1.pipeline));
    expect(ReliefV2.inpaintCell + 2 * ReliefV2.inpaintMargin, lessThanOrEqualTo(512));
  });
}
