// The frame times of Flutter in the log, at the fine level, while a video plays on the computers (lot AD3 of the AV2
// videos, M1 of its review): PresentMon tells how often the window presents, not which side is late, so the build and
// raster durations Flutter gives for each of its frames (FrameTiming) are summed up every few seconds, with the kind
// of video playing (its extension), for the measures of a test copy (the app's log read from a copy of its base).
// Nothing is gathered while no video plays or while the log is above the fine level; the engine hands the timings over
// in batches (about once a second), so the watch costs nothing between them.

import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:logging/logging.dart';
import 'package:native_video_player/native_video_player.dart';

final _log = Logger('DesktopFrameTimings');

/// The frames of one span of playback: how many, and the build and raster durations of each, in microseconds
class VideoFrameTimes {
  VideoFrameTimes(this.kind);

  /// The kind of video (its extension: "ivf", "mp4"), which tells the runs of a measure apart in the log
  final String kind;

  final _build = <int>[];
  final _raster = <int>[];
  final _total = <int>[];

  int get frames => _build.length;

  void add(FrameTiming timing) {
    _build.add(timing.buildDuration.inMicroseconds);
    _raster.add(timing.rasterDuration.inMicroseconds);
    _total.add(timing.totalSpan.inMicroseconds);
  }

  /// The [share] quantile of [values] (0.5 the median), the value at that rank of the sorted list
  static int quantile(List<int> values, double share) {
    if (values.isEmpty) {
      return 0;
    }
    final sorted = [...values]..sort();
    return sorted[math.min(sorted.length - 1, (share * sorted.length).floor())];
  }

  static String _ms(int micros) => (micros / 1000).toStringAsFixed(1);

  String _line(List<int> values) =>
      '${_ms(quantile(values, 0.5))}/${_ms(quantile(values, 0.9))}/${_ms(quantile(values, 0.99))}/'
      '${_ms(values.isEmpty ? 0 : values.reduce(math.max))}';

  /// The line of the log: "ivf: 150 frames in 5.0 s, build p50/p90/p99/max 0.4/0.9/2.1/3.0 ms, raster ..., over 16.7
  /// ms 3, over 33.4 ms 1"
  String summary(Duration span) {
    final seconds = span.inMilliseconds / 1000;
    final over16 = _total.where((micros) => micros > 16700).length;
    final over33 = _total.where((micros) => micros > 33400).length;
    return '$kind: $frames frames in ${seconds.toStringAsFixed(1)} s, build p50/p90/p99/max ${_line(_build)} ms, '
        'raster ${_line(_raster)} ms, total ${_line(_total)} ms, over 16.7 ms $over16, over 33.4 ms $over33';
  }
}

/// Gathers the frame times while [playing] gives the kind of the video that plays (null when none does) and the log
/// takes the fine level ([enabled]), and writes a summary every [every] (see the top of this file)
class VideoFrameTimingsWatch {
  VideoFrameTimingsWatch({
    required this.playing,
    this.every = const Duration(seconds: 5),
    bool Function()? enabled,
    void Function(String line)? write,
    Stopwatch? clock,
  }) : _enabled = enabled ?? (() => _log.isLoggable(Level.FINE)),
       _write = write ?? _log.fine,
       _clock = clock ?? (Stopwatch()..start());

  final String? Function() playing;
  final Duration every;
  final bool Function() _enabled;
  final void Function(String line) _write;
  final Stopwatch _clock;

  VideoFrameTimes? _times;
  Duration _since = Duration.zero;

  /// The timings the engine hands over: kept while a video plays, a summary written once [every] passed, and when the
  /// kind of video changes or none plays any more
  void onTimings(List<FrameTiming> timings) {
    final kind = _enabled() ? playing() : null;
    final times = _times;
    if (times != null && times.kind != kind) {
      _flush();
    }
    if (kind == null) {
      return;
    }
    final current = _times ??= VideoFrameTimes(kind);
    if (current.frames == 0) {
      _since = _clock.elapsed;
    }
    timings.forEach(current.add);
    if (_clock.elapsed - _since >= every) {
      _flush();
    }
  }

  void _flush() {
    final times = _times;
    _times = null;
    if (times != null && times.frames > 0) {
      _write('Frame times while a video plays, ${times.summary(_clock.elapsed - _since)}');
    }
  }
}

/// The kind of the video the app's player plays now (activeDesktopVideo), null when none plays
String? playingVideoKind() {
  final video = activeDesktopVideo.value;
  if (video == null || video.onPlaybackStatusChanged.value != PlaybackStatus.playing) {
    return null;
  }
  final path = video.videoSource?.path ?? '';
  final name = path.split(RegExp(r'[/\\?]')).lastWhere((part) => part.isNotEmpty, orElse: () => '');
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(dot + 1).toLowerCase() : 'video';
}

/// Watches the frame times of the app's window for its whole life (DesktopShell); returns what stops it
void Function() watchVideoFrameTimings() {
  final watch = VideoFrameTimingsWatch(playing: playingVideoKind);
  SchedulerBinding.instance.addTimingsCallback(watch.onTimings);
  return () => SchedulerBinding.instance.removeTimingsCallback(watch.onTimings);
}
