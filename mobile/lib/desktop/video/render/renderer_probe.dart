// The renderer probe of the 360° player of the computers (design 2.3 "Selection", DP1 section 4.3 "Sonde"): whether
// renderer C keeps up with the video at its tier on this computer, measured on the playback itself rather than on a
// test clip, since the cost depends on the video (5.7K H.264 decoded in software, 8K HEVC without copy) as much as on
// the GPU.
//
// What it measures: the frames the plugin drew with a new frame of mpv, against the frame rate of the video, over
// the first [RendererProbeLimits.window] of playback (time paused or buffering left out), with the time each draw
// took; and the memory of the process over that window and then while the view moves (DP1: the first five seconds and
// the drags), since a renderer that kept memory per view change brought the owner's PC down on 2026-10-09 (spike 3).
// A drag is measured from its own start: a demuxer cache that fills over a minute, or the rest of the app, is not the
// renderer's growth. What it decides: keep the tier, go a tier down, or give up (flat, with the message); and, when
// renderer C attached but draws nothing (a pass the driver does not compile, an intermediate texture it refuses),
// that it is refused.
//
// A shortfall is not always the renderer's: a video the processor decodes, or one whose frames come late while the
// plugin draws each in a fraction of a frame's time, is limited by its decoding (decodeLimited), and the page then
// plays the server's transcoded stream when there is one rather than taking the renderer down.
//
// The thresholds are assumptions [A], set from the measures of the skeleton (V-C, 2026-10-09): the Intel UHD of the
// owner's PC draws a 5.7K video at the 2880 tier at 27.3 frames a second of 30 at rest (kept: above 0.9 of the rate),
// and the RTX 4060 holds 30 at the full tier. Below 0.6 of the rate at the lowest tier the view is too jerky to be
// worth it, and the video plays flat with the message.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// The thresholds of the probe, see the top of this file
abstract final class RendererProbeLimits {
  /// Playback measured before the first verdict
  static const window = Duration(seconds: 5);

  /// How often the probe reads the plugin's counts and the memory
  static const interval = Duration(seconds: 1);

  /// Drawn frames over the video's rate at or above which the tier is kept
  static const keepRatio = 0.9;

  /// At the lowest tier, the ratio below which the video plays flat instead
  static const lowestTierFloor = 0.6;

  /// Growth of the process's memory over its level when the renderer attached, in MiB, that takes a tier down
  static const memoryGrowthMB = 512;

  /// The rate a video is measured against at most: the plugin draws no faster than the screen
  static const maxTargetFramesPerSecond = 60.0;

  /// Intervals in a row of playback with draws that failed and none that succeeded before renderer C is refused
  static const refuseAfter = 3;

  /// A shortfall whose draws took less than this share of a frame's time on average (the median) is the decoder's:
  /// the plugin waits for frames rather than the other way round
  static const decodeDrawShare = 0.5;
}

/// What the probe measured over its window
@immutable
class ProbeSample {
  const ProbeSample({
    required this.seconds,
    required this.frames,
    this.targetFramesPerSecond,
    this.memoryGrowthMB,
    this.failed = 0,
    this.error,
    this.drawMs,
  });

  /// Playback measured, in seconds
  final double seconds;

  /// Draws of the plugin with a new frame of mpv over [seconds]
  final int frames;

  /// The video's frame rate, at most [RendererProbeLimits.maxTargetFramesPerSecond]; null when mpv does not know it
  final double? targetFramesPerSecond;
  final int? memoryGrowthMB;

  /// Draws that could not happen over [seconds], and the plugin's last error ("shader: ...", "intermediate FBO
  /// incomplete ...")
  final int failed;
  final String? error;

  /// The median time of a draw with a new frame of mpv, in milliseconds (mpv's frame, then the view); null when none
  /// was timed
  final double? drawMs;

  double get framesPerSecond => seconds > 0 ? frames / seconds : 0;

  /// Drawn frames over the video's rate, null when the rate is not known
  double? get ratio {
    final target = targetFramesPerSecond;
    return target == null || target <= 0 ? null : framesPerSecond / target;
  }

  @override
  String toString() =>
      'ProbeSample(${framesPerSecond.toStringAsFixed(1)} of ${targetFramesPerSecond?.toStringAsFixed(1)} fps over '
      '${seconds.toStringAsFixed(1)} s, draw ${drawMs?.toStringAsFixed(1) ?? '?'} ms, memory '
      '+${memoryGrowthMB ?? '?'} MiB${failed > 0 ? ', $failed failed${error == null ? '' : ': $error'}' : ''})';
}

enum ProbeVerdict {
  /// The tier keeps up
  keep,

  /// A tier down
  stepDown,

  /// Nothing keeps up: flat, with the message
  fail,

  /// Renderer C attached but draws nothing while the video plays: flat with the message, or a tier down when the
  /// intermediate texture is what the driver refused
  refused,
}

/// The verdict on [sample] at a tier, [lowestTier] when no tier is below it
ProbeVerdict judgeProbe(ProbeSample sample, {required bool lowestTier}) {
  if (sample.frames == 0 && sample.failed > 0) {
    return ProbeVerdict.refused;
  }
  final growth = sample.memoryGrowthMB;
  if (growth != null && growth > RendererProbeLimits.memoryGrowthMB) {
    return lowestTier ? ProbeVerdict.fail : ProbeVerdict.stepDown;
  }
  final ratio = sample.ratio;
  if (ratio == null || ratio >= RendererProbeLimits.keepRatio) {
    return ProbeVerdict.keep;
  }
  if (!lowestTier) {
    return ProbeVerdict.stepDown;
  }
  return ratio < RendererProbeLimits.lowestTierFloor ? ProbeVerdict.fail : ProbeVerdict.keep;
}

/// Whether [sample], kept at the lowest tier, is below the rate all the same: the view plays, not smoothly, and the
/// user is told that a dedicated graphics card helps (DP1: the Intel UHD of the owner's PC draws a 5.7K H.264 video,
/// decoded in software, at 20 to 27 frames a second of 30 at the 2880 tier)
bool slowAtLowestTier(ProbeSample sample, {required bool lowestTier}) {
  final ratio = sample.ratio;
  return lowestTier && ratio != null && ratio < RendererProbeLimits.keepRatio;
}

/// Whether the shortfall of [sample] (below [RendererProbeLimits.keepRatio] of the rate) comes from the decoding
/// rather than from the drawing: the processor decodes ([hwdec], mpv's hwdec-current, is "no"), or the plugin drew
/// each frame in less than [RendererProbeLimits.decodeDrawShare] of a frame's time and still got too few. A smaller
/// tier does not help such a video; the server's transcoded stream does.
bool decodeLimited(ProbeSample sample, {String? hwdec}) {
  final ratio = sample.ratio;
  final target = sample.targetFramesPerSecond;
  if (ratio == null || target == null || ratio >= RendererProbeLimits.keepRatio) {
    return false;
  }
  if (hwdec?.trim() == 'no') {
    return true;
  }
  final draw = sample.drawMs;
  return draw != null && draw * target < 1000 * RendererProbeLimits.decodeDrawShare;
}

/// Runs the probe on one player, see the top of this file. [stats] reads the plugin's counts since its previous call
/// (the probe is their only reader), [targetFramesPerSecond] the video's rate, [memoryMB] the process's memory,
/// [measuring] whether the video plays now (shown, neither paused nor buffering), [moving] whether the view moves now
/// (a drag, the wheel, a held key).
class RendererProbe {
  RendererProbe({
    required this.stats,
    required this.targetFramesPerSecond,
    required this.memoryMB,
    required this.measuring,
    bool Function()? moving,
    this.window = RendererProbeLimits.window,
    this.interval = RendererProbeLimits.interval,
  }) : moving = moving ?? _still;

  static bool _still() => false;

  final Future<ProjectionStats?> Function() stats;
  final Future<double?> Function() targetFramesPerSecond;
  final int? Function() memoryMB;
  final bool Function() measuring;
  final bool Function() moving;
  final Duration window;
  final Duration interval;

  Timer? _timer;
  bool _reading = false;
  int? _baseMB;
  int? _dragBaseMB;
  double _seconds = 0;
  int _frames = 0;
  final _drawMs = <double>[];
  int _failingIntervals = 0;
  int _failed = 0;
  bool _judged = false;
  bool _sawFrame = false;
  late bool _lowestTier;
  void Function(ProbeVerdict verdict, ProbeSample sample)? _onResult;

  bool get running => _timer != null;

  /// Measures from now on at a tier ([lowestTier] when none is below it); [onResult] gets the first verdict after the
  /// window (or refused, when nothing is drawn), then any later memory verdict of a drag that is not keep. A new start
  /// (after a tier change) measures again.
  void start({required bool lowestTier, required void Function(ProbeVerdict verdict, ProbeSample sample) onResult}) {
    stop();
    _lowestTier = lowestTier;
    _onResult = onResult;
    // Taken at the first frame drawn: the decoder's surfaces and mpv's textures, made by the open, are no growth
    _baseMB = null;
    _dragBaseMB = null;
    _seconds = 0;
    _frames = 0;
    _drawMs.clear();
    _failingIntervals = 0;
    _failed = 0;
    _judged = false;
    _sawFrame = false;
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_reading) {
      return;
    }
    _reading = true;
    try {
      if (_judged) {
        _checkDrag();
        return;
      }
      final base = _baseMB;
      final now = memoryMB();
      final growth = base == null || now == null ? null : math.max(0, now - base);
      // Read even while not measuring: the counts start again from here
      final counts = await stats();
      if (_timer == null) {
        return;
      }
      final frames = counts?.frames ?? 0;
      // From the interval after the first frame drawn: the open and the first decode are not the renderer's cost
      if (!_sawFrame) {
        _sawFrame = frames > 0;
        if (_sawFrame) {
          _baseMB = memoryMB();
          _failed = 0;
          return;
        }
        // Draws that fail while the video plays, and none that succeeds: renderer C attached but cannot draw. Before
        // the video plays, a failed draw is a view asked before the first frame.
        final failed = counts?.failed ?? 0;
        if (failed > 0 && measuring()) {
          _failed += failed;
          _failingIntervals++;
          if (_failingIntervals >= RendererProbeLimits.refuseAfter) {
            _judged = true;
            _report(
              ProbeSample(
                seconds: _failingIntervals * interval.inMicroseconds / 1e6,
                frames: 0,
                failed: _failed,
                error: counts?.error,
              ),
            );
          }
        } else {
          _failingIntervals = 0;
          _failed = 0;
        }
        return;
      }
      if (!measuring()) {
        return;
      }
      _seconds += interval.inMicroseconds / 1e6;
      _frames += frames;
      _failed += counts?.failed ?? 0;
      _drawMs.addAll(counts?.frameMs ?? const []);
      if (_seconds * 1e6 < window.inMicroseconds && !(growth != null && growth > RendererProbeLimits.memoryGrowthMB)) {
        return;
      }
      final rate = await targetFramesPerSecond();
      if (_timer == null) {
        return;
      }
      _judged = true;
      _report(
        ProbeSample(
          seconds: _seconds,
          frames: _frames,
          targetFramesPerSecond: rate == null || rate <= 0
              ? null
              : math.min(rate, RendererProbeLimits.maxTargetFramesPerSecond),
          memoryGrowthMB: growth,
          failed: _failed,
          error: counts?.error,
          drawMs: _median(_drawMs),
        ),
        always: true,
      );
    } finally {
      _reading = false;
    }
  }

  /// After the first verdict, the memory only, and only while the view moves, from where it was when the move began
  /// (the plugin's counts are left to the troubleshooting and the harness)
  void _checkDrag() {
    if (!moving()) {
      _dragBaseMB = null;
      return;
    }
    final now = memoryMB();
    final base = _dragBaseMB;
    if (now == null) {
      return;
    }
    if (base == null) {
      _dragBaseMB = now;
      return;
    }
    final growth = math.max(0, now - base);
    if (growth > RendererProbeLimits.memoryGrowthMB) {
      _report(ProbeSample(seconds: _seconds, frames: _frames, memoryGrowthMB: growth));
    }
  }

  static double? _median(List<double> values) {
    if (values.isEmpty) {
      return null;
    }
    final sorted = [...values]..sort();
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
  }

  void _report(ProbeSample sample, {bool always = false}) {
    final verdict = judgeProbe(sample, lowestTier: _lowestTier);
    if (verdict != ProbeVerdict.keep) {
      stop();
    }
    if (always || verdict != ProbeVerdict.keep) {
      _onResult?.call(verdict, sample);
    }
  }
}
