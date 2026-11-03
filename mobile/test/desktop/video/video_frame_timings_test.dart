// The frame times of Flutter in the log while a video plays (lib/desktop/video/video_frame_timings.dart; lot AD3 of the
// AV2 videos, M1 of its review): a summary every few seconds of the build and raster durations, by kind of video,
// nothing while no video plays or the log is above the fine level.

import 'dart:ui' show FrameTiming;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/video_frame_timings.dart';

/// A frame whose build took [buildMs] and raster [rasterMs], one after the other from its vsync
FrameTiming _frame(double buildMs, double rasterMs) {
  final build = (buildMs * 1000).round();
  final raster = (rasterMs * 1000).round();
  return FrameTiming(
    vsyncStart: 0,
    buildStart: 100,
    buildFinish: 100 + build,
    rasterStart: 200 + build,
    rasterFinish: 200 + build + raster,
    rasterFinishWallTime: 200 + build + raster,
  );
}

void main() {
  test('the quantiles and the line of a span', () {
    final times = VideoFrameTimes('ivf');
    for (var i = 1; i <= 100; i++) {
      times.add(_frame(i / 10, i / 2));
    }
    expect(VideoFrameTimes.quantile([5, 1, 3, 2, 4], 0.5), 3);
    expect(VideoFrameTimes.quantile(const [], 0.99), 0);
    expect(
      times.summary(const Duration(seconds: 5)),
      'ivf: 100 frames in 5.0 s, build p50/p90/p99/max 5.1/9.1/10.0/10.0 ms, '
      'raster 25.5/45.5/50.0/50.0 ms, total 30.8/54.8/60.2/60.2 ms, over 16.7 ms 73, over 33.4 ms 45',
    );
  });

  test('a summary every few seconds while a video plays, one when the kind changes, none while nothing plays', () {
    final lines = <String>[];
    String? playing;
    var enabled = true;
    final clock = _FakeClock();
    final watch = VideoFrameTimingsWatch(
      playing: () => playing,
      enabled: () => enabled,
      write: lines.add,
      clock: clock,
    );
    watch.onTimings([_frame(1, 2)]);
    expect(lines, isEmpty, reason: 'no video plays');
    playing = 'ivf';
    watch.onTimings([_frame(1, 2), _frame(1, 3)]);
    clock.now += const Duration(seconds: 2);
    watch.onTimings([_frame(1, 12)]);
    expect(lines, isEmpty, reason: 'two seconds of a span of five');
    clock.now += const Duration(seconds: 3);
    watch.onTimings([_frame(1, 40)]);
    expect(lines, hasLength(1));
    expect(lines.single, startsWith('Frame times while a video plays, ivf: 4 frames in 5.0 s, build p50'));
    // Another kind of video: the span of the first ends there
    watch.onTimings([_frame(1, 2)]);
    playing = 'mp4';
    clock.now += const Duration(seconds: 1);
    watch.onTimings([_frame(2, 2)]);
    expect(lines, hasLength(2));
    expect(lines.last, contains('ivf: 1 frames in 1.0 s'));
    // The video stops: what it gathered is written
    playing = null;
    watch.onTimings([_frame(2, 2)]);
    expect(lines, hasLength(3));
    expect(lines.last, contains('mp4: 1 frames'));
    // The log above the fine level: nothing gathered
    playing = 'ivf';
    enabled = false;
    clock.now += const Duration(seconds: 10);
    watch.onTimings([_frame(1, 2)]);
    watch.onTimings([_frame(1, 2)]);
    expect(lines, hasLength(3));
  });
}

/// A stopwatch whose time the test sets
class _FakeClock implements Stopwatch {
  Duration now = Duration.zero;

  @override
  Duration get elapsed => now;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
