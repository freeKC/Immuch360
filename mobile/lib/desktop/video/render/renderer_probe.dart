// The renderer probe of the 360° player of the computers (design 2.3 "Selection", DP1 section 4.3 "Sonde"): whether
// renderer C keeps up with the video at its tier on this computer, measured on the playback itself rather than on a
// test clip, since the cost depends on the video (5.7K H.264 decoded in software, 8K HEVC without copy) as much as on
// the GPU.
//
// What it measures: the frames the plugin drew with a new frame of mpv, against the frame rate of the video, over
// the first [RendererProbeLimits.window] of playback (time paused or buffering left out); and the memory of the
// process for as long as the player is open, since a renderer that keeps memory per view change brought the owner's
// PC down on 2026-10-09 (spike 3). What it decides: keep the tier, go a tier down, or give up (flat, with the message).
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
}

/// What the probe measured over its window
@immutable
class ProbeSample {
  const ProbeSample({required this.seconds, required this.frames, this.targetFramesPerSecond, this.memoryGrowthMB});

  /// Playback measured, in seconds
  final double seconds;

  /// Draws of the plugin with a new frame of mpv over [seconds]
  final int frames;

  /// The video's frame rate, at most [RendererProbeLimits.maxTargetFramesPerSecond]; null when mpv does not know it
  final double? targetFramesPerSecond;
  final int? memoryGrowthMB;

  double get framesPerSecond => seconds > 0 ? frames / seconds : 0;

  /// Drawn frames over the video's rate, null when the rate is not known
  double? get ratio {
    final target = targetFramesPerSecond;
    return target == null || target <= 0 ? null : framesPerSecond / target;
  }

  @override
  String toString() =>
      'ProbeSample(${framesPerSecond.toStringAsFixed(1)} of ${targetFramesPerSecond?.toStringAsFixed(1)} fps over '
      '${seconds.toStringAsFixed(1)} s, memory +${memoryGrowthMB ?? '?'} MiB)';
}

enum ProbeVerdict {
  /// The tier keeps up
  keep,

  /// A tier down
  stepDown,

  /// Nothing keeps up: flat, with the message
  fail,
}

/// The verdict on [sample] at a tier, [lowestTier] when no tier is below it
ProbeVerdict judgeProbe(ProbeSample sample, {required bool lowestTier}) {
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

/// Runs the probe on one player, see the top of this file. [stats] reads the plugin's counts since its previous call
/// (the probe is their only reader), [targetFramesPerSecond] the video's rate, [memoryMB] the process's memory,
/// [measuring] whether the video plays now (neither paused nor buffering).
class RendererProbe {
  RendererProbe({
    required this.stats,
    required this.targetFramesPerSecond,
    required this.memoryMB,
    required this.measuring,
    this.window = RendererProbeLimits.window,
    this.interval = RendererProbeLimits.interval,
  });

  final Future<ProjectionStats?> Function() stats;
  final Future<double?> Function() targetFramesPerSecond;
  final int? Function() memoryMB;
  final bool Function() measuring;
  final Duration window;
  final Duration interval;

  Timer? _timer;
  bool _reading = false;
  int? _baseMB;
  double _seconds = 0;
  int _frames = 0;
  bool _judged = false;
  bool _sawFrame = false;
  late bool _lowestTier;
  void Function(ProbeVerdict verdict, ProbeSample sample)? _onResult;

  bool get running => _timer != null;

  /// Measures from now on at a tier ([lowestTier] when none is below it); [onResult] gets the first verdict after the
  /// window, then any later memory verdict that is not keep. A new start (after a tier change) measures again.
  void start({required bool lowestTier, required void Function(ProbeVerdict verdict, ProbeSample sample) onResult}) {
    stop();
    _lowestTier = lowestTier;
    _onResult = onResult;
    // Taken at the first frame drawn: the decoder's surfaces and mpv's textures, made by the open, are no growth
    _baseMB = null;
    _seconds = 0;
    _frames = 0;
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
      final base = _baseMB;
      final now = memoryMB();
      final growth = base == null || now == null ? null : math.max(0, now - base);
      if (_judged) {
        // The memory only from now on: the plugin's counts are left to the troubleshooting and the harness
        if (growth != null && growth > RendererProbeLimits.memoryGrowthMB) {
          _report(ProbeSample(seconds: _seconds, frames: _frames, memoryGrowthMB: growth));
        }
        return;
      }
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
        }
        return;
      }
      if (!measuring()) {
        return;
      }
      _seconds += interval.inMicroseconds / 1e6;
      _frames += frames;
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
        ),
        always: true,
      );
    } finally {
      _reading = false;
    }
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
