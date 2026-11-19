import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_estimates.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_job_file.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';
import 'package:immich_mobile/domain/models/ai_immersive/relief_strength.dart';

void main() {
  test('the first guess: an estimate scaled from ai1, held to the study\'s 2.0 to 2.8 times', () {
    // ai1 itself: a minute at 30 fps and Standard is about 30 minutes (study 4.1), 26 measured on ped
    final ai1 = videoTimeRange(frames: 1800, quality: VideoDepthQuality.standard, logicalProcessors: 8);
    expect(ai1.low.inMinutes, inInclusiveRange(21, 23));
    expect(ai1.high.inMinutes, inInclusiveRange(36, 38));
    expect(ai1.low.inMinutes, lessThanOrEqualTo(26));
    // FreeKC's i9-13980HX, 32 logical processors: the study's 11 to 15 minutes a minute at Standard fall inside,
    // never the 6 minutes that 30 threads against 6 would say
    final i9 = videoTimeRange(frames: 1800, quality: VideoDepthQuality.standard, logicalProcessors: 32);
    expect(i9.low.inSeconds, lessThanOrEqualTo(11 * 60));
    expect(i9.high.inSeconds, greaterThanOrEqualTo(15 * 60));
    expect(i9.low.inSeconds, greaterThan(ai1.low.inSeconds / 3));
    expect(i9.high.inMinutes, lessThanOrEqualTo(20));
    // A 64 thread workstation gets no more than the i9
    final big = videoTimeRange(frames: 1800, quality: VideoDepthQuality.standard, logicalProcessors: 64);
    expect((big.low, big.high), (i9.low, i9.high));
    // 16 logical processors: 14 threads, 2.33 times ai1 at best, 2 at worst
    final mid = videoTimeRange(frames: 1800, quality: VideoDepthQuality.standard, logicalProcessors: 16);
    expect(mid.low.inSeconds, closeTo(0.986 * 1800 / (14 / 6) * 0.75, 1));
    expect(mid.high.inSeconds, closeTo(0.986 * 1800 / 2 * 1.25, 1));
  });

  test('this computer\'s last job at that quality wins, within 15 %', () {
    final kept = videoTimeRange(
      frames: 1000,
      quality: VideoDepthQuality.fast,
      logicalProcessors: 8,
      keptMillisPerFrame: 400,
    );
    expect((kept.low.inSeconds, kept.high.inSeconds), (340, 460));
  });

  test('the disk: 2.2 times the output, H.264 135 MB a minute at 1080p side by side, AV1 50, Half 0.6 times', () {
    // Two states of the loop besides: 55 MB each at 700 x 392 (the 8 held maps, ref and the 10 key inputs)
    final states = 2 * videoStateBytes(700, 392);
    expect(videoStateBytes(700, 392), 54880000);
    expect(
      videoDiskNeed(durationSeconds: 60, av1: false, half: false, modelWidth: 700, modelHeight: 392),
      297000000 + states,
    );
    expect(
      videoDiskNeed(durationSeconds: 60, av1: true, half: false, modelWidth: 700, modelHeight: 392),
      110000000 + states,
    );
    expect(
      videoDiskNeed(durationSeconds: 60, av1: false, half: true, modelWidth: 700, modelHeight: 392),
      178200000 + states,
    );
    // A portrait 2160 x 1920 frame has about the pixels of 3840 x 1080
    expect(videoBytesPerMinute(av1: false, half: false, outWidth: 2160, outHeight: 1920), closeTo(135e6, 1e6));
  });

  test('the qualities the memory allows, and the one a dialog starts with', () {
    const gib = 1024 * 1024 * 1024;
    expect(videoQualitiesFor(6 * gib), [VideoDepthQuality.fast]);
    expect(videoQualitiesFor(12 * gib), [VideoDepthQuality.fast, VideoDepthQuality.standard]);
    expect(videoQualitiesFor(32 * gib), VideoDepthQuality.values);
    expect(videoDefaultQuality(VideoDepthQuality.values, null), VideoDepthQuality.standard);
    expect(videoDefaultQuality(VideoDepthQuality.values, 'fine'), VideoDepthQuality.fine);
    expect(videoDefaultQuality([VideoDepthQuality.fast], 'fine'), VideoDepthQuality.fast);
  });

  test('the settings of the 3D videos: Subtle by default, kept by name, timings per quality', () {
    const defaults = DesktopAiSettings();
    expect(defaults.videoReliefStrength, ReliefStrength.subtle);
    expect(defaults.videoQuality, 'standard');
    expect(defaults.videoHalfSbs, isFalse);
    final chosen = defaults.copyWith(
      videoReliefStrength: ReliefStrength.strong,
      videoQuality: 'fine',
      videoHalfSbs: true,
      videoFrameMillis: {'standard': 930},
    );
    final back = DesktopAiSettings.fromJson(chosen.toJson());
    expect(back, chosen);
    expect(back.videoFrameMillis, {'standard': 930});
    final odd = DesktopAiSettings.fromJson({
      'videoQuality': 'ultra',
      'videoFrameMillis': {'fast': -1, 'fine': 'x'},
    });
    expect(odd.videoQuality, 'standard');
    expect(odd.videoFrameMillis, isEmpty);
    expect(odd.videoReliefStrength, ReliefStrength.subtle);
  });
}
