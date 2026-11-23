import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/desktop/ai/video3d/vda_window_loop.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_frame_ops.dart';

import '../ort/ort_for_tests.dart';

final _expected =
    jsonDecode(File('test/fixtures/ai_immersive/tiny_vda_expected.json').readAsStringSync()) as Map<String, dynamic>;

/// Frame ops that carry the index of a frame through the loop: the input of a frame is its index everywhere
class _IndexOps extends DartVideoFrameOps {
  const _IndexOps();

  @override
  void vdaInput(Uint8List rgb, int width, int height, Float32List out, int outWidth, int outHeight) =>
      out.fillRange(0, out.length, (rgb[0] + 256 * rgb[1]).toDouble());
}

Uint8List _indexFrame(int index) => Uint8List(12)
  ..[0] = index % 256
  ..[1] = index ~/ 256;

/// vda_video_frame of make_tiny_models.py
Uint8List _syntheticFrame(int index) {
  const eye = 28;
  final cut = _expected['cutAt'] as int;
  final rgb = Uint8List(eye * eye * 3);
  var at = 0;
  for (var y = 0; y < eye; y++) {
    for (var x = 0; x < eye; x++) {
      if (index < cut) {
        rgb[at++] = (8 * x + 3 * index) % 90;
        rgb[at++] = (5 * y + index) % 70 + 10;
        rgb[at++] = (x * y + 2 * index) % 60;
      } else {
        rgb[at++] = 150 + (7 * y + 2 * index) % 100;
        rgb[at++] = 120 + (3 * x + y + index) % 120;
        rgb[at++] = 200 + (x + index) % 50;
      }
    }
  }
  return rgb;
}

/// tiny_vda.onnx in double precision, as make_tiny_models.py computes it
Float32List _tinyVda(Float32List input, int width, int height) {
  final plane = width * height;
  var total = 0.0;
  for (final value in input) {
    total += value;
  }
  final g = total / input.length;
  final out = Float32List(vdaWindowLength * plane);
  for (var slot = 0; slot < vdaWindowLength; slot++) {
    final base = slot * 3 * plane;
    for (var i = 0; i < plane; i++) {
      final m = (input[base + i] + input[base + plane + i] + input[base + 2 * plane + i]) / 3;
      out[slot * plane + i] = (m * 0.5 + 2) * (1 + g / 8) + g / 4;
    }
  }
  return out;
}

List<VdaFinalFrame> _run(VdaWindowLoop loop, int frames, Uint8List Function(int) frameOf) => [
  for (var i = 0; i < frames; i++) ...loop.add(frameOf(i)),
  ...loop.finish(),
];

void main() {
  group('the windows of upstream, from the Python port of depth.py', () {
    final windows = (_expected['windows'] as Map<String, dynamic>).map(
      (n, list) => MapEntry(int.parse(n), (list as List).map((w) => (w as List).cast<int>()).toList()),
    );

    for (final MapEntry(key: n, value: expected) in windows.entries) {
      test('a scene of $n frames', () {
        final seen = <List<int>>[];
        final loop = VdaWindowLoop(
          ops: const _IndexOps(),
          model: (input, width, height) {
            final plane = width * height;
            seen.add([for (var slot = 0; slot < vdaWindowLength; slot++) input[slot * 3 * plane].round()]);
            return Float32List(vdaWindowLength * plane);
          },
          eyeWidth: 2,
          eyeHeight: 2,
          modelWidth: 2,
          modelHeight: 2,
          detectCuts: false,
        );
        final given = _run(loop, n, _indexFrame);
        expect(seen, expected);
        expect(given.map((frame) => frame.index), List.generate(n, (i) => i));
        expect(given.map((frame) => frame.rgb[0] + 256 * frame.rgb[1]), List.generate(n, (i) => i));
      });
    }
  });

  group('the synthetic video with a cut, against make_tiny_models.py', () {
    final maps = (_expected['maps'] as List).map((m) => (m as List).cast<num>()).toList();
    final percentiles = (_expected['percentiles'] as List).map((p) => (p as List).cast<num>()).toList();

    void check(List<VdaFinalFrame> given, VdaWindowLoop loop, double tolerance) {
      expect(loop.cuts, _expected['cuts']);
      expect(given.map((frame) => frame.index), List.generate(_expected['frames'] as int, (i) => i));
      for (final frame in given) {
        final expected = maps[frame.index];
        for (var i = 0; i < expected.length; i++) {
          expect(frame.map[i], closeTo(expected[i], tolerance), reason: 'frame ${frame.index} value $i');
        }
        expect(frame.p2, closeTo(percentiles[frame.index][0], tolerance), reason: 'p2 of ${frame.index}');
        expect(frame.p98, closeTo(percentiles[frame.index][1], tolerance), reason: 'p98 of ${frame.index}');
      }
    }

    VdaWindowLoop loopWith(VdaModel model) => VdaWindowLoop(
      ops: const DartVideoFrameOps(),
      model: model,
      eyeWidth: 28,
      eyeHeight: 28,
      modelWidth: 14,
      modelHeight: 14,
    );

    test('the loop restarts at the cut, and gives the maps and the smoothed percentiles of the reference', () {
      final loop = loopWith(_tinyVda);
      final given = _run(loop, _expected['frames'] as int, _syntheticFrame);
      // float32 between the model and the loop: within a few units of the last place
      check(given, loop, 2e-5);
      expect(loop.windowsRun, 2 + 2);
      expect(loop.normalisationResets, isEmpty);
    });

    final ort = ortForTests();
    test('the same with tiny_vda.onnx in ONNX Runtime', skip: ort.skip, () {
      final runtime = OrtRuntime.load(ort.library!);
      final session = runtime.openSession(File('test/fixtures/ai_immersive/tiny_vda.onnx').absolute.path);
      addTearDown(session.close);
      expect(session.inputs.single.name, 'frames');
      expect(session.inputs.single.shape, [1, 32, 3, -1, -1]);
      expect(session.outputs.single.shape, [1, 32, -1, -1]);
      final loop = loopWith((input, width, height) {
        final output = session
            .runNamed({
              'frames': OrtTensor([1, vdaWindowLength, 3, height, width], input),
            })
            .values
            .single;
        expect(output.shape, [1, vdaWindowLength, height, width]);
        return output.values;
      });
      check(_run(loop, _expected['frames'] as int, _syntheticFrame), loop, 1e-4);
    });
  });

  group('alignment', () {
    test('least squares find the scale and the shift of an exact line, and (1, 0) without an answer', () {
      final p = Float64List.fromList([1, 2, 3, 4]);
      final t = Float64List.fromList([5, 7, 9, 11]);
      final (scale, shift) = vdaScaleShift([p], [t]);
      expect(scale, closeTo(2, 1e-12));
      expect(shift, closeTo(3, 1e-12));
      expect(
        vdaScaleShift(
          [
            Float64List.fromList([2, 2]),
          ],
          [
            Float64List.fromList([1, 3]),
          ],
        ),
        (1.0, 0.0),
      );
      expect(vdaAligned(Float64List.fromList([-1, 1]), 2, 0.5), [0, 2.5]);
    });

    test('blend weights: linear upstream, cosine for the ten frame remedy', () {
      expect(
        [for (var i = 0; i < 8; i++) vdaBlendWeight(VideoDepthAlignment.upstream, i)],
        [for (var i = 0; i < 8; i++) i / 7],
      );
      final cosine = [for (var i = 0; i < 8; i++) vdaBlendWeight(VideoDepthAlignment.tenFrame, i)];
      expect(cosine.first, closeTo(0, 1e-12));
      expect(cosine.last, closeTo(1, 1e-12));
      expect(cosine[1], lessThan(1 / 7));
      expect(cosine[6], greaterThan(6 / 7));
    });

    test('the ten frame remedy runs the same windows and gives other maps in the blend zones only', () {
      List<VdaFinalFrame> run(VideoDepthAlignment mode) => _run(
        VdaWindowLoop(
          ops: const DartVideoFrameOps(),
          model: _tinyVda,
          eyeWidth: 28,
          eyeHeight: 28,
          modelWidth: 14,
          modelHeight: 14,
          alignment: mode,
          detectCuts: false,
        ),
        36,
        _syntheticFrame,
      );
      final upstream = run(VideoDepthAlignment.upstream);
      final remedy = run(VideoDepthAlignment.tenFrame);
      expect(remedy.length, upstream.length);
      // The first window is never fitted
      for (var i = 0; i < 24; i++) {
        expect(remedy[i].map, upstream[i].map);
      }
      expect(remedy[26].map, isNot(upstream[26].map));
    });
  });

  group('the cut detector', () {
    test('the distances of the study: 0.33 flagged, 0.048 not', () {
      final golden =
          jsonDecode(File('test/fixtures/ai_immersive/relief_video_golden_v1.json').readAsStringSync())
              as Map<String, dynamic>;
      final detector = CutDetector();
      final distances = ((golden['detector'] as Map)['distances'] as List).cast<num>();
      final flagged = [
        for (final (i, distance) in distances.indexed)
          if (detector.addDistance(distance.toDouble())) i,
      ];
      expect(flagged, (golden['detector'] as Map)['cuts']);
      expect(flagged, contains(distances.indexOf(0.33)));
      expect(flagged, isNot(contains(distances.indexOf(0.048))));
      expect(detector.history.length, cutHistory);
    });

    test('a cut less than 22 frames after the scene\'s start only resets the normalisation', () {
      // Flashes: dark frames, a bright one at 10, dark again
      Uint8List frame(int index) =>
          Uint8List(28 * 28 * 3)..fillRange(0, 28 * 28 * 3, index == 10 ? 240 : 20 + index % 3);
      final loop = VdaWindowLoop(
        ops: const DartVideoFrameOps(),
        model: _tinyVda,
        eyeWidth: 28,
        eyeHeight: 28,
        modelWidth: 14,
        modelHeight: 14,
      );
      final given = _run(loop, 40, frame);
      expect(loop.cuts, isEmpty);
      expect(loop.normalisationResets, [10, 11]);
      expect(given.length, 40);
      // The percentiles start again from the map of frame 10
      final (p2, p98) = vdaPercentiles(given[10].map);
      expect((given[10].p2, given[10].p98), (p2, p98));
    });
  });

  group('pause and resume', () {
    test('a loop restored from its state after a window gives what an uninterrupted one gives', () {
      VdaWindowLoop make() => VdaWindowLoop(
        ops: const DartVideoFrameOps(),
        model: _tinyVda,
        eyeWidth: 28,
        eyeHeight: 28,
        modelWidth: 14,
        modelHeight: 14,
        detectCuts: false,
      );
      final whole = _run(make(), 100, (i) => _syntheticFrame(i % 36));
      final first = make();
      final before = <VdaFinalFrame>[];
      VdaLoopState? state;
      for (var i = 0; state == null; i++) {
        before.addAll(first.add(_syntheticFrame(i % 36)));
        state = first.loopStateIfWindowAfter(53);
      }
      expect(state.firstHeld, 54 - 8);
      expect(before.length, 46);
      final resumed = make()
        ..restore(state, [for (var i = state.firstHeld; i < state.firstHeld + 8; i++) _syntheticFrame(i % 36)]);
      final after = [
        for (var i = state.nextIndex; i < 100; i++) ...resumed.add(_syntheticFrame(i % 36)),
        ...resumed.finish(),
      ];
      final both = [...before, ...after];
      expect(both.map((f) => f.index), List.generate(100, (i) => i));
      for (var i = 0; i < 100; i++) {
        expect(both[i].map, whole[i].map, reason: 'frame $i');
        expect((both[i].p2, both[i].p98), (whole[i].p2, whole[i].p98), reason: 'frame $i');
        expect(both[i].rgb, whole[i].rgb);
      }
    });
  });

  test('percentiles by nearest rank', () {
    final map = Float64List.fromList(List.generate(100, (i) => (99 - i).toDouble()));
    expect(vdaPercentiles(map), (1.0, 97.0));
    expect(vdaPercentiles(Float64List.fromList([5])), (5.0, 5.0));
    // Selected rather than sorted (lot ai-360-3d-51): the ranks of a sort, on maps of every kind
    final random = math.Random(7);
    for (final (length, levels) in [(2, 3), (17, 2), (1000, 5), (153664, 1 << 30), (274400, 40)]) {
      final values = Float64List.fromList([for (var i = 0; i < length; i++) random.nextInt(levels) / 7]);
      final sorted = Float64List.fromList(values)..sort();
      int rank(int percent) => math.max(1, (percent * length + 99) ~/ 100) - 1;
      expect(vdaPercentiles(values), (sorted[rank(2)], sorted[rank(98)]), reason: '$length values of $levels levels');
    }
    final ascending = Float64List.fromList([for (var i = 0; i < 5000; i++) i.toDouble()]);
    expect(vdaPercentiles(ascending), (99.0, 4899.0));
    expect(vdaPercentiles(Float64List.fromList(ascending.reversed.toList())), (99.0, 4899.0));
    expect(vdaPercentiles(Float64List.fromList([3, double.nan, 1, 2])).$1, 1.0);
  });
}

extension on VdaWindowLoop {
  /// The state once the frame [index] was taken and its window ran
  VdaLoopState? loopStateIfWindowAfter(int index) => nextIndex == index + 1 ? stateAfterWindow() : null;
}
