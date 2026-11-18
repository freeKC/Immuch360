import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_estimates.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';
import 'package:immich_mobile/domain/models/ai_immersive/relief_strength.dart';

void main() {
  test('the first guess: ai1 scaled by the threads of ONNX Runtime, within 35 %', () {
    // ai1 itself: a minute at 30 fps and Standard is about 30 minutes (study 4.1)
    final ai1 = videoTimeRange(frames: 1800, quality: VideoDepthQuality.standard, logicalProcessors: 8);
    expect(ai1.low.inMinutes, inInclusiveRange(18, 20));
    expect(ai1.high.inMinutes, inInclusiveRange(38, 40));
    // 32 logical processors: 30 threads against 6
    final i9 = videoTimeRange(frames: 1800, quality: VideoDepthQuality.standard, logicalProcessors: 32);
    expect(i9.high.inSeconds, closeTo(ai1.high.inSeconds / 5, 2));
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
    expect(videoDiskNeed(durationSeconds: 60, av1: false, half: false), 297000000);
    expect(videoDiskNeed(durationSeconds: 60, av1: true, half: false), 110000000);
    expect(videoDiskNeed(durationSeconds: 60, av1: false, half: true), 178200000);
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
