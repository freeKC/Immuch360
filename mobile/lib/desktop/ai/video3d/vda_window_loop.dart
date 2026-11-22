// The depth of a video by Video Depth Anything (store/m2/release-49/lots/video3d-plan.md, sections 2.3 and 4.4): the
// window loop of upstream's infer_video_depth (github.com/DepthAnything/Video-Depth-Anything, video_depth.py at
// 4f5ae23172), as the probe's depth.py runs it, frame after frame instead of on a whole clip in memory.
//
// Windows of 32 frames, one every 22: the first 10 slots of a window are the previous window's prepared inputs at its
// key frames [0, 12, 24..31] (so slot 0 stays the scene's first frame and slot 1 the previous window's frame 12), the
// last 22 are new frames, the tail of the scene padded with its last frame. The maps of a new window are fitted to the
// earlier ones by a scale and a shift (least squares of slots 0 and 1 against ref: the scene's first map and the last
// window's frame 12, both as aligned), clipped at 0; the 8 maps after them are blended with the 8 last maps of the
// previous window (weights i / 7), which therefore stay held back until the next window has run. The remedy of the
// check of 18 November (VideoDepthAlignment.tenFrame) fits on all 10 overlap slots, the 8 held maps as targets of slots
// 2 to 9, and blends with cosine weights.
//
// Each scene runs its own loop: at a cut (the luma histogram detector of the probe, cut_probe.py) the scene's last
// window is padded with its last frame and the next scene starts fresh, so the output equals the scenes run alone; a
// cut less than 22 frames after the scene's start only resets the normalisation (a music video cutting every second
// would cost a window per shot). The percentiles p2 and p98 of each final map (nearest rank) are smoothed over time,
// decay 0.9 a frame, and reset at each cut.
//
// Pure Dart and synchronous: the job's isolate feeds it the eye frames, the model runs through [VdaModel], the frame
// work through VideoFrameOps. Its state between two windows ([VdaLoopState]) is what a paused job keeps.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/video3d/video_frame_ops.dart';

/// Frames a window of the model takes
const vdaWindowLength = 32;

/// Frames a window shares with the one before it
const vdaOverlap = 10;

/// Frames of the overlap blended between two windows
const vdaBlended = 8;

/// New frames a window brings: 22
const vdaStep = vdaWindowLength - vdaOverlap;

/// The slots of a window the next one takes as its first 10
const vdaKeyFrames = [0, 12, 24, 25, 26, 27, 28, 29, 30, 31];

/// How the percentiles of the maps are smoothed: lo = 0.9 lo + 0.1 p2 a frame
const vdaPercentileDecay = 0.9;

/// The cut detector: a half L1 distance between two frames' histograms over this, and over [cutRatio] times the
/// median of the last [cutHistory] distances (at least [cutMedianFloor])
const cutFloor = 0.15;
const cutRatio = 4.0;
const cutHistory = 15;
const cutMedianFloor = 0.01;

/// How a window is fitted to the one before it
enum VideoDepthAlignment {
  /// Upstream's: slots 0 and 1, linear blend
  upstream,

  /// The remedy: all 10 overlap slots, cosine blend
  tenFrame,
}

/// Runs the model on one window: [input] holds 32 prepared frames of 3 x [width] x [height] (channels first), the
/// answer 32 maps of [width] x [height]
typedef VdaModel = Float32List Function(Float32List input, int width, int height);

/// The scale and the shift that bring [predicted] nearest to [target] by least squares, every pair of maps of the two
/// lists taken together; (1, 0) when the system has no single answer. In double precision, summed in order.
(double, double) vdaScaleShift(List<Float64List> predicted, List<Float64List> target) {
  var a00 = 0.0;
  var a01 = 0.0;
  var a11 = 0.0;
  var b0 = 0.0;
  var b1 = 0.0;
  for (var m = 0; m < predicted.length; m++) {
    final p = predicted[m];
    final t = target[m];
    for (var i = 0; i < p.length; i++) {
      a00 += p[i] * p[i];
      a01 += p[i];
      b0 += p[i] * t[i];
      b1 += t[i];
    }
    a11 += p.length;
  }
  final det = a00 * a11 - a01 * a01;
  if (det == 0) {
    return (1.0, 0.0);
  }
  return ((a11 * b0 - a01 * b1) / det, (-a01 * b0 + a00 * b1) / det);
}

/// [map] * [scale] + [shift], clipped at 0
Float64List vdaAligned(Float64List map, double scale, double shift) {
  final out = Float64List(map.length);
  for (var i = 0; i < map.length; i++) {
    final value = map[i] * scale + shift;
    out[i] = value > 0 ? value : 0;
  }
  return out;
}

/// The weight of the new window for the blended frame [i] (0 to 7)
double vdaBlendWeight(VideoDepthAlignment mode, int i) => switch (mode) {
  VideoDepthAlignment.upstream => i / (vdaBlended - 1),
  VideoDepthAlignment.tenFrame => 0.5 - 0.5 * math.cos(math.pi * i / (vdaBlended - 1)),
};

/// The percentiles 2 and 98 of [map] by nearest rank
(double, double) vdaPercentiles(Float64List map) {
  final sorted = Float64List.fromList(map)..sort();
  int rank(int percent) => math.max(1, (percent * sorted.length + 99) ~/ 100) - 1;
  return (sorted[rank(2)], sorted[rank(98)]);
}

/// The median of [values], the mean of the two middle ones for an even count
double _median(List<double> values) {
  final sorted = [...values]..sort();
  final n = sorted.length;
  return n.isOdd ? sorted[n ~/ 2] : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
}

/// The luma histogram cut detector of the probe: [add] takes the histogram of each frame and says whether a cut
/// comes right before it
class CutDetector {
  CutDetector();

  Float64List? _previous;
  final _history = <double>[];

  /// The distances seen, the last [cutHistory] of them (for the job's state)
  List<double> get history => List.unmodifiable(_history);
  Float64List? get previous => _previous;

  /// Whether [histogram] starts a new scene
  bool add(Float64List histogram) {
    final previous = _previous;
    _previous = histogram;
    if (previous == null) {
      return false;
    }
    var l1 = 0.0;
    for (var i = 0; i < histogram.length; i++) {
      l1 += (histogram[i] - previous[i]).abs();
    }
    return addDistance(0.5 * l1);
  }

  /// The rule on a distance alone (detect.log of the study: 0.33 flagged, at most 0.048 not)
  bool addDistance(double distance) {
    final recent = _history.isEmpty ? const [0.0] : _history;
    final cut = distance > cutFloor && distance > cutRatio * math.max(_median(recent), cutMedianFloor);
    _history.add(distance);
    if (_history.length > cutHistory) {
      _history.removeAt(0);
    }
    return cut;
  }

  void restore(Float64List? previous, List<double> history) {
    _previous = previous;
    _history
      ..clear()
      ..addAll(history.length > cutHistory ? history.sublist(history.length - cutHistory) : history);
  }
}

/// A frame whose map no later window changes: its index in the video, its eye frame, its aligned map and the smoothed
/// percentiles to normalise it with
class VdaFinalFrame {
  const VdaFinalFrame({required this.index, required this.rgb, required this.map, required this.p2, required this.p98});

  final int index;
  final Uint8List rgb;
  final Float64List map;
  final double p2;
  final double p98;
}

/// What the loop holds between two windows of a scene: what a paused job writes, and a resumed one reads back
class VdaLoopState {
  const VdaLoopState({
    required this.nextIndex,
    required this.sceneStart,
    required this.sceneFrames,
    required this.windows,
    required this.held,
    required this.ref,
    required this.keyInputs,
    required this.lo,
    required this.hi,
    required this.previousHistogram,
    required this.distances,
    required this.firstHeld,
    this.resets = const {},
    this.views = const [],
    this.alignment,
  });

  /// The index of the next frame the loop takes
  final int nextIndex;

  /// The first frame of the scene, and the frames of the scene taken so far
  final int sceneStart;
  final int sceneFrames;

  /// Windows of the scene run so far
  final int windows;

  /// The last 8 aligned maps, not final yet, and ref
  final List<Float64List> held;
  final List<Float64List> ref;

  /// The prepared inputs of the last window at its key frames
  final List<Float32List> keyInputs;

  /// The smoothed percentiles, null at the start of a scene
  final double? lo;
  final double? hi;
  final Float64List? previousHistogram;
  final List<double> distances;

  /// The video index of the first held map: its eye frame and the 7 after it are what a resumed job decodes again
  final int firstHeld;

  /// Frames not given out yet whose normalisation starts again (a cut too close to the scene's start)
  final Set<int> resets;

  /// For a 360° video (sphere_video_worker.dart): the state of the loop of each face of the cube, this state holding
  /// the cut detector of the whole frame, the smoothed percentiles of the map of the sphere ([lo], [hi]) and the
  /// frames whose smoothing starts again ([resets]); empty for a flat video
  final List<VdaLoopState> views;

  /// For a 360° video: the smoothed scale and shift of each face, two values a face (NaN for a face left out); null
  /// before the first frame or for a flat video
  final Float64List? alignment;
}

/// The window loop over a whole video, scene after scene
class VdaWindowLoop {
  VdaWindowLoop({
    required this.ops,
    required this.model,
    required this.eyeWidth,
    required this.eyeHeight,
    required this.modelWidth,
    required this.modelHeight,
    this.alignment = VideoDepthAlignment.upstream,
    this.detectCuts = true,
  }) : _inputLength = 3 * modelWidth * modelHeight;

  final VideoFrameOps ops;
  final VdaModel model;
  final int eyeWidth;
  final int eyeHeight;
  final int modelWidth;
  final int modelHeight;
  final VideoDepthAlignment alignment;
  final bool detectCuts;
  final int _inputLength;

  final _detector = CutDetector();
  var _next = 0;
  var _sceneStart = 0;

  /// Prepared inputs and eye frames of the scene not used by a window yet, by index in the scene
  final _inputs = <int, Float32List>{};
  final _frames = <int, Uint8List>{};
  var _sceneFrames = 0;
  var _windows = 0;
  List<Float64List> _held = [];
  List<Float64List> _ref = [];
  List<Float32List> _keyInputs = [];

  /// Maps of the scene aligned and final, by index in the scene, waiting to be given out in order
  double? _lo;
  double? _hi;
  final _resets = <int>{};
  var _given = 0;

  /// The cuts found, by video index of their first frame, and those that only reset the normalisation
  final cuts = <int>[];
  final normalisationResets = <int>[];

  /// Windows run so far over the whole video
  var windowsRun = 0;

  /// The index of the next frame [add] takes
  int get nextIndex => _next;

  /// The frames given out so far
  int get given => _given;

  /// Takes the eye frame [rgb] of the next index; gives the frames that became final, in order. [cut], when given,
  /// says whether a cut comes right before this frame instead of the loop's own detector: the faces of a 360° video
  /// each run a loop, and the cuts are found once on the whole frame (sphere_video_worker.dart)
  List<VdaFinalFrame> add(Uint8List rgb, {bool? cut}) {
    final out = <VdaFinalFrame>[];
    final index = _next++;
    final isCut = cut ?? (detectCuts && _detector.add(ops.lumaHistogram(rgb, eyeWidth, eyeHeight)));
    if (isCut && index > 0) {
      if (index - _sceneStart < vdaStep) {
        normalisationResets.add(index);
        _resets.add(index);
      } else {
        cuts.add(index);
        out.addAll(_endScene());
        _sceneStart = index;
        _resets.add(index);
      }
    }
    final input = Float32List(_inputLength);
    ops.vdaInput(rgb, eyeWidth, eyeHeight, input, modelWidth, modelHeight);
    final local = _sceneFrames++;
    _inputs[local] = input;
    _frames[local] = rgb;
    // Window k takes the frames 22 k to 22 k + 31 of the scene
    if (local == _windows * vdaStep + vdaWindowLength - 1) {
      out.addAll(_runWindow(last: false));
    }
    return out;
  }

  /// The end of the video: the scene's last windows, padded, and every frame left
  List<VdaFinalFrame> finish() => _endScene();

  /// The state between two windows, valid right after a window ran with nothing else added since (the job writes it
  /// at the end of a segment); null when the loop is not at such a point
  VdaLoopState? stateAfterWindow() {
    if (_windows == 0 || _sceneFrames != (_windows - 1) * vdaStep + vdaWindowLength) {
      return null;
    }
    return VdaLoopState(
      nextIndex: _next,
      sceneStart: _sceneStart,
      sceneFrames: _sceneFrames,
      windows: _windows,
      held: _held,
      ref: _ref,
      keyInputs: _keyInputs,
      lo: _lo,
      hi: _hi,
      previousHistogram: _detector.previous,
      distances: _detector.history,
      firstHeld: _sceneStart + _sceneFrames - vdaBlended,
      resets: {..._resets},
    );
  }

  /// Takes back [state]; the eye frames of its held maps ([heldFrames], 8 frames from VdaLoopState.firstHeld) come
  /// from the decoder again
  void restore(VdaLoopState state, List<Uint8List> heldFrames) {
    if (heldFrames.length != state.held.length) {
      throw ArgumentError('${heldFrames.length} frames for ${state.held.length} held maps');
    }
    _next = state.nextIndex;
    _sceneStart = state.sceneStart;
    _sceneFrames = state.sceneFrames;
    _windows = state.windows;
    _held = [...state.held];
    _ref = [...state.ref];
    _keyInputs = [...state.keyInputs];
    _lo = state.lo;
    _hi = state.hi;
    _given = state.firstHeld;
    _inputs.clear();
    _frames.clear();
    for (final (i, frame) in heldFrames.indexed) {
      _frames[state.firstHeld - _sceneStart + i] = frame;
    }
    // The last frame of the window, for the padding of a scene that ends right away: the last key input
    _inputs[_sceneFrames - 1] = _keyInputs.last;
    _resets
      ..clear()
      ..addAll(state.resets);
    _detector.restore(state.previousHistogram, state.distances);
  }

  List<VdaFinalFrame> _endScene() {
    final out = <VdaFinalFrame>[];
    if (_sceneFrames == 0) {
      return out;
    }
    // The windows still to run, as upstream: every k with 22 k < n, the last one where 22 (k + 1) >= n
    while (_windows * vdaStep < _sceneFrames) {
      out.addAll(_runWindow(last: (_windows + 1) * vdaStep >= _sceneFrames));
    }
    out.addAll(_giveHeld());
    _sceneFrames = 0;
    _windows = 0;
    _held = [];
    _ref = [];
    _keyInputs = [];
    _inputs.clear();
    _frames.clear();
    return out;
  }

  Float32List _inputAt(int local) {
    // The tail of the scene is padded with its last frame
    final at = math.min(local, _sceneFrames - 1);
    return _inputs[at]!;
  }

  List<VdaFinalFrame> _runWindow({required bool last}) {
    final k = _windows;
    final start = k * vdaStep;
    final window = Float32List(vdaWindowLength * _inputLength);
    final slots = <Float32List>[];
    for (var slot = 0; slot < vdaWindowLength; slot++) {
      final input = k > 0 && slot < vdaOverlap ? _keyInputs[slot] : _inputAt(start + slot);
      slots.add(input);
      window.setAll(slot * _inputLength, input);
    }
    final output = model(window, modelWidth, modelHeight);
    final plane = modelWidth * modelHeight;
    if (output.length != vdaWindowLength * plane) {
      throw StateError('The model gave ${output.length} values for a window of ${vdaWindowLength * plane}');
    }
    final maps = [
      for (var slot = 0; slot < vdaWindowLength; slot++)
        Float64List.fromList(output.sublist(slot * plane, (slot + 1) * plane)),
    ];
    windowsRun++;
    _windows++;
    _keyInputs = [for (final slot in vdaKeyFrames) slots[slot]];
    // The inputs no later window takes: those of the frames before the next window's slot 10
    _inputs.removeWhere((local, _) => local < start + vdaStep + vdaOverlap && local < _sceneFrames - 1);
    final List<Float64List> fresh;
    if (k == 0) {
      fresh = maps;
      _ref = [maps[0], maps[12]];
    } else {
      final List<Float64List> predicted;
      final List<Float64List> target;
      if (alignment == VideoDepthAlignment.tenFrame) {
        predicted = maps.sublist(0, vdaOverlap);
        target = [..._ref, ..._held];
      } else {
        predicted = maps.sublist(0, vdaOverlap - vdaBlended);
        target = _ref;
      }
      final (scale, shift) = vdaScaleShift(predicted, target);
      for (var i = 0; i < vdaBlended; i++) {
        final post = vdaAligned(maps[vdaOverlap - vdaBlended + i], scale, shift);
        final pre = _held[i];
        final w = vdaBlendWeight(alignment, i);
        final blended = Float64List(plane);
        for (var j = 0; j < plane; j++) {
          blended[j] = pre[j] * (1 - w) + post[j] * w;
        }
        _held[i] = blended;
      }
      fresh = [
        ..._held,
        for (var slot = vdaOverlap; slot < vdaWindowLength; slot++) vdaAligned(maps[slot], scale, shift),
      ];
      _ref = [_ref[0], vdaAligned(maps[12], scale, shift)];
    }
    // fresh: the maps of the frames from the previous held ones (or the scene's first) to the end of this window
    final firstLocal = k == 0 ? 0 : start + vdaOverlap - vdaBlended;
    final out = <VdaFinalFrame>[];
    final keep = last ? 0 : vdaBlended;
    for (var i = 0; i < fresh.length - keep; i++) {
      final local = firstLocal + i;
      if (local < _sceneFrames) {
        out.add(_give(local, fresh[i]));
      }
    }
    _held = fresh.sublist(fresh.length - vdaBlended);
    if (last) {
      _held = [];
    }
    return out;
  }

  List<VdaFinalFrame> _giveHeld() {
    final out = <VdaFinalFrame>[];
    final firstLocal = _sceneFrames - _held.length;
    for (final (i, map) in _held.indexed) {
      final local = firstLocal + i;
      if (local < _sceneFrames && _frames.containsKey(local)) {
        out.add(_give(local, map));
      }
    }
    _held = [];
    return out;
  }

  VdaFinalFrame _give(int local, Float64List map) {
    final index = _sceneStart + local;
    if (index != _given) {
      throw StateError('Frame $index given out of order, $_given expected');
    }
    _given++;
    final (p2, p98) = vdaPercentiles(map);
    if (_lo == null || _resets.remove(index)) {
      _lo = p2;
      _hi = p98;
    } else {
      _lo = vdaPercentileDecay * _lo! + (1 - vdaPercentileDecay) * p2;
      _hi = vdaPercentileDecay * _hi! + (1 - vdaPercentileDecay) * p98;
    }
    final rgb = _frames.remove(local)!;
    return VdaFinalFrame(index: index, rgb: rgb, map: map, p2: _lo!, p98: _hi!);
  }
}
