import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_frame_ops.dart';
import 'package:immuch_sbs_codec/immuch_sbs_codec.dart' as native;

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/ai_immersive/$name').readAsStringSync()) as Map<String, dynamic>;

/// pattern() of make_relief_video_golden.py
Uint8List _pattern(int width, int height, int seed) {
  final rgb = Uint8List(width * height * 3);
  var at = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      rgb[at++] = (17 * x + 3 * y * y + seed) % 256;
      rgb[at++] = (5 * x * y + 40 + seed) % 256;
      rgb[at++] = (255 - 7 * x - 11 * y + 3 * seed) % 256;
    }
  }
  return rgb;
}

/// The image of a relief case in the left half of a 2L x H frame
(Uint8List, int, int) _frameOf(List<dynamic> image) {
  final height = image.length;
  final width = (image.first as List).length ~/ 3;
  final sbs = Uint8List(width * height * 6);
  for (var y = 0; y < height; y++) {
    sbs.setAll(y * width * 6, (image[y] as List).cast<int>());
  }
  return (sbs, width, height);
}

Float64List _flat(List<dynamic> rows) =>
    Float64List.fromList([for (final row in rows) ...(row as List).map((v) => (v as num).toDouble())]);

List<String> _holeRows(Uint8List holes, int width) => [
  for (var y = 0; y < holes.length ~/ width; y++) holes.sublist(y * width, (y + 1) * width).map((h) => '$h').join(),
];

void _goldenChecks(VideoFrameOps Function() make) {
  final photo = _fixture('relief_golden_v1.json');
  final video = _fixture('relief_video_golden_v1.json');
  final image = ((photo['cases'] as List).first as Map)['image'] as List;

  test('every case of the photo golden: the right eye of a frame at relief-v1 is that of the 3D photo', () {
    final ops = make();
    for (final c in (photo['cases'] as List).cast<Map<String, dynamic>>()) {
      final (sbs, width, height) = _frameOf(c['image'] as List);
      final depth = _flat(c['depth'] as List);
      final rows = c['depth'] as List;
      final sorted = Float64List.fromList(depth)..sort();
      final holes = Uint8List(width * height);
      final filled = ops.reliefEye(
        sbs,
        width,
        height,
        depth,
        (rows.first as List).length,
        rows.length,
        p2: reliefPercentile(sorted, 2),
        p98: reliefPercentile(sorted, 98),
        parallax: (c['parallax'] as num).toDouble(),
        convergence: (c['convergence'] as num).toDouble(),
        holes: holes,
      );
      final expected = (c['rightEye'] as List).map((row) => (row as List).cast<int>()).toList();
      for (var y = 0; y < height; y++) {
        expect(sbs.sublist(y * width * 6 + width * 3, (y + 1) * width * 6), expected[y], reason: '${c['name']} row $y');
      }
      expect(_holeRows(holes, width), c['holes'], reason: c['name'] as String);
      expect(filled, c['filledPixels']);
    }
    ops.dispose();
  });

  test('every relief case of the video golden, its floating window and its half frame', () {
    final ops = make();
    for (final c in (video['relief'] as List).cast<Map<String, dynamic>>()) {
      final (sbs, width, height) = _frameOf(image);
      final rows = c['depth'] as List;
      final holes = Uint8List(width * height);
      final filled = ops.reliefEye(
        sbs,
        width,
        height,
        _flat(rows),
        (rows.first as List).length,
        rows.length,
        p2: (c['p2'] as num).toDouble(),
        p98: (c['p98'] as num).toDouble(),
        parallax: (c['parallax'] as num).toDouble(),
        convergence: (c['convergence'] as num).toDouble(),
        holes: holes,
      );
      ops.edgeFade(sbs, width, height, c['edgeBand'] as int);
      expect(sbs, [for (final row in c['sbs'] as List) ...(row as List).cast<int>()], reason: c['name'] as String);
      expect(_holeRows(holes, width), c['holes']);
      expect(filled, c['filledPixels']);
      final half = Uint8List(width * height * 3);
      ops.halfSbs(sbs, width, height, half);
      expect(half, [for (final row in c['halfSbs'] as List) ...(row as List).cast<int>()], reason: c['name'] as String);
    }
    ops.dispose();
  });

  test('the input of the model and the histogram of the cut detector', () {
    final ops = make();
    for (final c in (video['vdaInput'] as List).cast<Map<String, dynamic>>()) {
      final [w, h, seed] = (c['source'] as List).cast<int>();
      final [width, height] = (c['size'] as List).cast<int>();
      final out = Float32List(3 * width * height);
      ops.vdaInput(_pattern(w, h, seed), w, h, out, width, height);
      expect(
        out,
        Float32List.fromList((c['values'] as List).map((v) => (v as num).toDouble()).toList()),
        reason: c['name'] as String,
      );
    }
    for (final c in (video['lumaHistogram'] as List).cast<Map<String, dynamic>>()) {
      final [w, h, seed] = (c['source'] as List).cast<int>();
      expect(
        ops.lumaHistogram(_pattern(w, h, seed), w, h),
        (c['histogram'] as List).cast<num>(),
        reason: c['name'] as String,
      );
    }
    ops.dispose();
  });
}

void main() {
  test('the bands of the floating window', () {
    for (final c in (_fixture('relief_video_golden_v1.json')['edgeBands'] as List).cast<Map<String, dynamic>>()) {
      expect(
        videoEdgeBand((c['parallax'] as num).toDouble(), c['width'] as int, (c['convergence'] as num).toDouble()),
        c['band'],
      );
    }
    expect(videoEdgeBand(0.015, 1920, 0.5), 17);
    expect(videoEdgeBand(0.02, 1920, 0.5), 22);
    expect(videoEdgeBand(0.03, 1920, 0.5), 31);
  });

  test('normaliseWith: the percentiles of the job, 0.5 for a flat spread and for not a number', () {
    final raw = ReliefDepth(4, 1, Float64List.fromList([0, 1, 2, double.nan]));
    expect(normaliseWith(raw, 0, 2).values, [0, 0.5, 1, 0.5]);
    expect(normaliseWith(raw, 1, 1).values, [0.5, 0.5, 0.5, 0.5]);
    expect(normaliseWith(raw, 0.5, 1.5).values, [0, 0.5, 1, 0.5]);
  });

  group('the pure Dart reference', () => _goldenChecks(() => const DartVideoFrameOps()));

  final reason = native.nativeCodecUnavailableReason;
  group('the Rust of immuch_sbs_codec', skip: reason, () {
    _goldenChecks(() => nativeVideoFrameOps(threads: 3)!);

    test('gives the bytes of the Dart reference on a larger frame, threads or not', () {
      const width = 191;
      const height = 67;
      final random = math.Random(7);
      final frame = Uint8List.fromList(List.generate(width * height * 3, (_) => random.nextInt(256)));
      final depth = Float64List.fromList(List.generate(42 * 14, (i) => 3 + 2 * math.sin(i / 9) + random.nextDouble()));
      Uint8List run(VideoFrameOps ops) {
        final sbs = Uint8List(width * height * 6);
        for (var y = 0; y < height; y++) {
          sbs.setRange(y * width * 6, y * width * 6 + width * 3, frame, y * width * 3);
        }
        ops.reliefEye(sbs, width, height, depth, 42, 14, p2: 2.2, p98: 5.1, parallax: 0.03, convergence: 0.5);
        ops.edgeFade(sbs, width, height, videoEdgeBand(0.03, width, 0.5));
        return sbs;
      }

      final dart = run(const DartVideoFrameOps());
      for (final threads in [1, 4]) {
        final ops = nativeVideoFrameOps(threads: threads)!;
        expect(run(ops), dart, reason: '$threads threads');
        final input = Float32List(3 * 70 * 28);
        final reference = Float32List(3 * 70 * 28);
        ops.vdaInput(frame, width, height, input, 70, 28);
        const DartVideoFrameOps().vdaInput(frame, width, height, reference, 70, 28);
        expect(input, reference);
        expect(ops.lumaHistogram(frame, width, height), const DartVideoFrameOps().lumaHistogram(frame, width, height));
        ops.dispose();
      }
    });

    test('a call after dispose, and a frame too short, are refused', () {
      final ops = nativeVideoFrameOps()!;
      expect(
        () => ops.reliefEye(Uint8List(10), 8, 4, Float64List(4), 2, 2, p2: 0, p98: 1, parallax: 0.02, convergence: 0.5),
        throwsA(isA<native.NativeCodecException>()),
      );
      ops.dispose();
      expect(() => ops.halfSbs(Uint8List(48), 2, 2, Uint8List(12)), throwsStateError);
    });
  });
}
