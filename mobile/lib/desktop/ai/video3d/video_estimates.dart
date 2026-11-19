// What the dialog of a 3D video says before Convert (store/m2/release-49/lots/video3d-plan.md, section 4.3, and the
// study's sections 2, 4.1 and 4.2): the time of the work as a range marked "first guess" (this computer's last video
// job at that quality when there was one, else an estimate scaled from the ai1 measures by the logical processors and
// held to the study's 2.0 to 2.8 times for a large processor), the free space it needs (2.2 times the estimated
// output: about 135 MB a minute for H.264 at 1080p side by side, 50 for AV1, 0.6 times for Half SBS, plus two states
// of the window loop), and the qualities the memory allows (Fine with 16 GB or more only, Fast only under 8 GB). The real
// time left replaces the guess after two windows of the job, from its own pace, never from the photos' timings.
//
// Pure Dart.

import 'dart:math' as math;

import 'package:immich_mobile/desktop/ai/video3d/video_job_file.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';

/// Seconds a new frame took on ai1 (i5-1145G7, 8 logical processors, ONNX Runtime with 6 threads), the depth with its
/// windows, plus the 36 ms of decode, right eye and hardware encode besides (study sections 2 and 4.1)
const videoAi1SecondsPerFrame = {
  VideoDepthQuality.fast: 0.41 + 0.036,
  VideoDepthQuality.standard: 0.95 + 0.036,
  VideoDepthQuality.fine: 2.03 + 0.036,
};

/// The logical processors of ai1
const _ai1Processors = 8;

/// The most a computer is taken to be faster than ai1 on the depth: the study's FreeKC i9-13980HX (32 logical
/// processors) at 2.0 to 2.8 times, from the photo model on two ONNX Runtime versions (not measured with the video
/// model, whose 32 frame window may be held by the memory rather than the cores)
const videoSpeedUpOverAi1 = (low: 2.0, high: 2.8);

/// The range of the time a job of [frames] frames at [quality] takes on a computer of [logicalProcessors]: from this
/// computer's last video job at that quality ([keptMillisPerFrame]) within 15 %, else an estimate scaled from ai1: by
/// the threads ONNX Runtime gets (processors minus 2) against ai1's 6, the speed-up held to [videoSpeedUpOverAi1]
/// (the threads alone would give the i9 5 times ai1), the range from the fast end to the slow end of that speed-up,
/// widened by 25 % each way
({Duration low, Duration high}) videoTimeRange({
  required int frames,
  required VideoDepthQuality quality,
  required int logicalProcessors,
  int? keptMillisPerFrame,
}) {
  if (keptMillisPerFrame != null && keptMillisPerFrame > 0) {
    final total = keptMillisPerFrame / 1000 * frames;
    return (low: Duration(seconds: (total * 0.85).round()), high: Duration(seconds: (total * 1.15).round()));
  }
  final threads = math.max(1, logicalProcessors - 2);
  final byThreads = threads / (_ai1Processors - 2);
  final fastest = math.min(byThreads, videoSpeedUpOverAi1.high);
  final slowest = math.min(byThreads, videoSpeedUpOverAi1.low);
  final ai1 = videoAi1SecondsPerFrame[quality]! * frames;
  return (
    low: Duration(seconds: (ai1 / fastest * 0.75).round()),
    high: Duration(seconds: (ai1 / slowest * 1.25).round()),
  );
}

/// Bytes a minute of the output: H.264 at 1080p side by side 135 MB, AV1 50 MB (study 4.2), for the pixels of a
/// 3840 x 1080 frame; Half SBS 0.6 times
int videoBytesPerMinute({required bool av1, required bool half, int outWidth = 3840, int outHeight = 1080}) {
  final base = (av1 ? 50 : 135) * 1000 * 1000 * (outWidth * outHeight) / (3840 * 1080);
  return (base * (half ? 0.6 : 1)).round();
}

/// The free space a job needs on the drive of its destination: 2.2 times the estimated output (the segments and the
/// MP4 exist together at the final mux), plus two states of the window loop for a model input of [modelWidth] x
/// [modelHeight] (the last one and the next, for the moment both exist; about 110 MB at 700 x 392)
int videoDiskNeed({
  required double durationSeconds,
  required bool av1,
  required bool half,
  required int modelWidth,
  required int modelHeight,
  int outWidth = 3840,
  int outHeight = 1080,
}) =>
    (2.2 * videoBytesPerMinute(av1: av1, half: half, outWidth: outWidth, outHeight: outHeight) * durationSeconds / 60)
        .round() +
    2 * videoStateBytes(modelWidth, modelHeight);

/// The qualities a computer with [physicalMemory] bytes is offered: Fast only under 8 GB, Fine only with 16 GB or more
List<VideoDepthQuality> videoQualitiesFor(int physicalMemory) {
  const gib = 1024 * 1024 * 1024;
  if (physicalMemory < 8 * gib) {
    return const [VideoDepthQuality.fast];
  }
  if (physicalMemory < 16 * gib) {
    return const [VideoDepthQuality.fast, VideoDepthQuality.standard];
  }
  return VideoDepthQuality.values;
}

/// The quality a dialog starts with: [kept] (the last one chosen) when offered, else Standard, else the best offered
VideoDepthQuality videoDefaultQuality(List<VideoDepthQuality> offered, String? kept) {
  for (final quality in offered) {
    if (quality.name == kept) {
      return quality;
    }
  }
  return offered.contains(VideoDepthQuality.standard) ? VideoDepthQuality.standard : offered.last;
}

/// The frames a job of [source] works on: its frame count, else its duration at the grid's rate (30 for slow motion)
int videoFramesOf(VideoSource source, VideoGrid grid) {
  final count = source.frameCount;
  if (count != null && !grid.slowMotion) {
    return count;
  }
  return ((source.duration ?? 0) * grid.rate.value).round();
}
