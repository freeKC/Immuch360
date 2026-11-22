// The heavy work of a 360° video made 360° 3D (lot ai-360-3d-51): for each equirectangular frame, its six faces
// (sphere_depth.dart), each fed to a window loop of Video Depth Anything of its own, the cuts found once on the whole
// frame and given to every loop, so that the faces keep their windows together; once every face has the final map of
// a frame, the maps merged into the depth of the sphere and the right eye drawn around it by relief-360 (the 3D
// versions of the 360° photos, relief_360.dart), with the shift of the nearest point at the equator set by the
// strength (0.75°, 1° or 1.5°) and fading as cos(latitude) to nothing at the poles; the holes filled from the
// background beside them, wrapped across the seam. The output frame is top and bottom, the left eye (the frame as it
// came) on top: eyeWidth x 2 eyeHeight.
//
// Its state after a window is a VdaLoopState holding the six states of the faces (views), the cut detector of the
// frame, the smoothed percentiles of the map and the smoothed alignment of the faces: Pause, a quit, a restart of the
// computer go on from the last segment as for a flat video.

import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/panorama/erp_math.dart' show TangentView;
import 'package:immich_mobile/desktop/ai/panorama/pano_depth.dart' show ViewAlignment;
import 'package:immich_mobile/desktop/ai/panorama/relief_360.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart' show ReliefDepth;
import 'package:immich_mobile/desktop/ai/video3d/sphere_depth.dart';
import 'package:immich_mobile/desktop/ai/video3d/vda_window_loop.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_engine.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_frame_ops.dart';

/// The worker of a 360° video in the caller's isolate
class LocalSphereVideoFrameWorker implements VideoFrameWorker {
  LocalSphereVideoFrameWorker({
    required this.ops,
    required VdaModel model,
    required this.eyeWidth,
    required this.eyeHeight,
    required this.side,
    required this.shiftDegrees,
    VideoDepthAlignment alignment = VideoDepthAlignment.upstream,
    this.onSphere,
  }) : views = sphereVideoViews(side) {
    if (eyeWidth != 2 * eyeHeight) {
      throw ArgumentError('An equirectangular eye of $eyeWidth x $eyeHeight is not 2:1');
    }
    _sampler = SphereViewSampler(eyeWidth: eyeWidth, eyeHeight: eyeHeight, views: views);
    final map = sphereMapSize(side);
    _merger = SphereDepthMerger(views: views, mapWidth: map.width, mapHeight: map.height);
    _loops = [
      for (var k = 0; k < views.length; k++)
        VdaWindowLoop(
          ops: ops,
          model: model,
          eyeWidth: side,
          eyeHeight: side,
          modelWidth: side,
          modelHeight: side,
          alignment: alignment,
          detectCuts: false,
        ),
    ];
  }

  final VideoFrameOps ops;
  final int eyeWidth;
  final int eyeHeight;

  /// The side of a face, the model's input: the short side of the quality (280, 392 or 518)
  final int side;

  /// The shift of the nearest point at the equator
  final double shiftDegrees;
  final List<TangentView> views;

  /// Hears the map of the sphere of each final frame, between 0 (far) and 1 (near), and the alignment of the faces
  final void Function(int index, ReliefDepth map, List<ViewAlignment> alignment)? onSphere;

  late final SphereViewSampler _sampler;
  late final SphereDepthMerger _merger;
  late final List<VdaWindowLoop> _loops;
  final _detector = CutDetector();

  /// The frames of the sphere not final yet, by index
  final _frames = <int, Uint8List>{};
  var _next = 0;
  List<ViewAlignment>? _alignment;
  double? _lo;
  double? _hi;

  /// The final frames whose smoothing starts again: the first after a cut
  final _resets = <int>{};
  final cuts = <int>[];

  int get windowsRun => _loops.first.windowsRun;

  List<VideoSbsFrame> _gather(List<List<VdaFinalFrame>> perView) {
    final count = perView.first.length;
    for (final finals in perView) {
      if (finals.length != count) {
        throw StateError('The faces gave ${perView.map((f) => f.length).toList()} final frames');
      }
    }
    return [
      for (var i = 0; i < count; i++) _drawOne([for (final finals in perView) finals[i]]),
    ];
  }

  VideoSbsFrame _drawOne(List<VdaFinalFrame> faces) {
    final index = faces.first.index;
    for (final face in faces) {
      if (face.index != index) {
        throw StateError('Faces at frames ${faces.map((f) => f.index).toList()}');
      }
    }
    final left = _frames.remove(index);
    if (left == null) {
      throw StateError('No frame $index of the sphere');
    }
    final reset = _resets.remove(index) || _alignment == null;
    final x = [for (final face in faces) sphereFaceNormalised(face.map, face.p2, face.p98)];
    final solved = _merger.align(x);
    final alignment = _alignment = smoothAlignments(reset ? null : _alignment, solved);
    final values = _merger.merge(x, alignment);
    final (p2, p98) = spherePercentiles(values, _merger.mapWidth, _merger.mapHeight);
    if (reset || _lo == null) {
      _lo = p2;
      _hi = p98;
    } else {
      _lo = sphereSmoothingDecay * _lo! + (1 - sphereSmoothingDecay) * p2;
      _hi = sphereSmoothingDecay * _hi! + (1 - sphereSmoothingDecay) * p98;
    }
    final map = sphereRelief(values, _merger.mapWidth, _merger.mapHeight, _lo!, _hi!);
    onSphere?.call(index, map, alignment);
    final eyeBytes = eyeWidth * eyeHeight * 3;
    final frame = Uint8List(2 * eyeBytes)..setRange(0, eyeBytes, left);
    final eye = writeRelief360RightEye(
      left: left,
      width: eyeWidth,
      height: eyeHeight,
      map: map,
      lowRelief: false,
      maxShiftDegrees: shiftDegrees,
      target: frame,
      targetOffset: eyeBytes,
      channels: 3,
    );
    return VideoSbsFrame(index: index, bytes: frame, holes: eye.filledPixels);
  }

  @override
  Future<List<VideoSbsFrame>> add(Uint8List rgb) async {
    final index = _next++;
    final cut = _detector.add(ops.lumaHistogram(rgb, eyeWidth, eyeHeight)) && index > 0;
    if (cut) {
      cuts.add(index);
      _resets.add(index);
    }
    _frames[index] = rgb;
    final faces = _sampler.sample(rgb);
    return _gather([for (var k = 0; k < _loops.length; k++) _loops[k].add(faces[k], cut: cut)]);
  }

  @override
  Future<List<VideoSbsFrame>> finish() async => _gather([for (final loop in _loops) loop.finish()]);

  @override
  Future<VdaLoopState?> stateAfterWindow() async {
    final faces = <VdaLoopState>[];
    for (final loop in _loops) {
      final state = loop.stateAfterWindow();
      if (state == null) {
        return null;
      }
      faces.add(state);
    }
    final first = faces.first;
    final alignment = _alignment;
    return VdaLoopState(
      nextIndex: first.nextIndex,
      sceneStart: first.sceneStart,
      sceneFrames: first.sceneFrames,
      windows: first.windows,
      held: const [],
      ref: const [],
      keyInputs: const [],
      lo: _lo,
      hi: _hi,
      previousHistogram: _detector.previous,
      distances: _detector.history,
      firstHeld: first.firstHeld,
      resets: {..._resets},
      views: faces,
      alignment: alignment == null
          ? null
          : Float64List.fromList([
              for (final face in alignment) ...(face.isUsed ? [face.scale, face.shift] : [double.nan, double.nan]),
            ]),
    );
  }

  @override
  Future<void> restore(VdaLoopState state, List<Uint8List> heldFrames) async {
    if (state.views.length != _loops.length) {
      throw ArgumentError('A state of ${state.views.length} faces for ${_loops.length}');
    }
    final faces = [for (final frame in heldFrames) _sampler.sample(frame)];
    for (var k = 0; k < _loops.length; k++) {
      _loops[k].restore(state.views[k], [for (final frame in faces) frame[k]]);
    }
    _next = state.nextIndex;
    _frames.clear();
    for (final (i, frame) in heldFrames.indexed) {
      _frames[state.firstHeld + i] = frame;
    }
    _lo = state.lo;
    _hi = state.hi;
    _resets
      ..clear()
      ..addAll(state.resets);
    _detector.restore(state.previousHistogram, state.distances);
    final alignment = state.alignment;
    _alignment = alignment == null
        ? null
        : [
            for (var k = 0; k < alignment.length ~/ 2; k++)
              alignment[2 * k].isNaN ? ViewAlignment.unused : ViewAlignment(alignment[2 * k], alignment[2 * k + 1]),
          ];
  }

  @override
  Future<({int windows, List<int> cuts})> counts() async => (windows: windowsRun, cuts: [...cuts]);

  @override
  Future<void> close() async => ops.dispose();
}
