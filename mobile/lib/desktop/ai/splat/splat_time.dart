// The time of a splat scene (plan 2026-11-01, sections 2.2 and 2.4, lot SP6; design engineering-first of 1 November
// 2026, section 4.5): its engine tells the time left of the whole job (ConversionKind.tellsWholeTimeLeft), since it
// follows the images, the pairs and the steps of the job rather than a time per step.
//
// The times of the steps a computer keeps (AiTimings, desktop_ai.json, under "splatScene" and "splatSceneVideo") are
// those of a job of [splatReferenceImages] images, 150 photos or 150 frames, at 20 000 steps: the defaults of the plan
// until this computer finished one, then the mean of what it measured. A job of other counts scales them: the photos
// or frames prepared, the points of the images and the mapping with its images; the matching with the pairs it tries
// (colmapPairsOf: n (n - 1) / 2 for every pair, the photos and a video of up to 200 frames; the list of pairs of a
// longer video, 7 322 for 250 frames); the training with its steps (one image a step, at the definition of the
// settings); the rest not at all. The times a job measured go back to the reference the same way before they are kept
// ([SplatTimeModel.normalized]). Until lot SPF1 a video was matched by sequential_matcher, its time by its images: a
// time of a video kept then would tell the matching far too short (only the test build T1 could have kept one).
//
// Before a computer finished a scene, the defaults of the steps of COLMAP follow its threads (lot SPF2,
// [splatProcessorFactor]): measured on 24 processors, they told a laptop of 4 cores its first scene far too short.
//
// The counts a job starts from are those it will take ([splatPlannedImages]): the 150 frames of a video (its one member
// is not an image), 200 of more photos. The step of the photos or of the frames follows what the preparation reads
// ([SplatTimeModel.read]: the photos taken, the windows of the video, as soon as it says how many), the steps after it
// the images it kept ([SplatTimeModel.images]); each is measured and kept by its own count.
//
// The quality (lot Q1): the training of Detailed takes [SplatV1.detailedTrainingFactor] times that of Headset (4.3 to
// 5.8 in the measure of 5 November, its 30 000 steps included), Maximum as much again times its pixels over those of
// 1 920 ([splatTrainingFactorOf]); the times kept stay those of Headset, a training of Detailed divided by its factor
// before it is kept, so that the next scene of either quality is told right. The training of Maximum is told by that
// factor but never kept ([splatKeepsTrainingOf], review of lot Q1): its scaling by the pixels was never measured, and
// one scene of it would shift the time every later scene of Headset and Detailed is told from.
//
// While a step runs, what is left of it is told by what it went through: the pace of its images (done of total) once a
// tenth of them is done, blended with what was expected before; for the training, the pace of its last 1 000 steps
// ([SplatTrainingPace]: M1 measured 19 to 20 s per 1 000 steps from the 5 000th to the end, the cap of 150 000 gaussians
// reached by then). The time left of the job adds what is expected of the steps after it.

import 'dart:math' as math;

import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/splat/colmap_runner.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The images the times of the steps of a splat scene are kept for
const splatReferenceImages = 150;

/// The milliseconds of each step of a splat scene of 150 photos before this computer finished one, as the plan of 1
/// November estimates them from its measure (aiDefaultTimings of desktop_ai_settings.dart, "splatScene"): some 13 min
const splatSceneDefaultTimings = <String, int>{
  'reading': 5000,
  'photos': 45000,
  'features': 15000,
  'matching': 195000,
  'mapping': 50000,
  'training': 450000,
  'splatCopy': 10000,
  'writing': 1000,
};

/// The same for a splat scene of a video of two minutes ("splatSceneVideo"): some 12 min. The matching and the mapping
/// of lot SPF1, measured on 3 November on the 22 threads of the PC: every pair of the 150 frames of the lighthouse,
/// rich in points (2 455 an image), 285.7 s, and its mapper at 15 inliers, 36.3 s (FreeKC's object, poor in points: 11
/// and 10 s); sequential_matcher took 58 to 81 s there
const splatSceneVideoDefaultTimings = <String, int>{
  'reading': 5000,
  'frames': 60000,
  'features': 15000,
  'matching': 286000,
  'mapping': 36000,
  'training': 306000,
  'splatCopy': 10000,
  'writing': 1000,
};

/// The steps of COLMAP, whose defaults follow the threads of the computer ([splatProcessorFactor])
const splatProcessorStages = {'features', 'matching', 'mapping'};

/// How many times longer than the defaults the steps of COLMAP take on a computer of [processors] processors, before
/// it finished a scene (lot SPF2, m1 of the review of lot SPF1): the defaults were measured on the 22 threads of the
/// PC of the measure (24 processors less two, colmapCommonThreadsFor), some 31.4 s a block of 1 225 pairs in the 286 s
/// of the 11 175 pairs of 150 frames. The same blocks of the lighthouse took 68.5 s on 2 threads and 47.2 s on 6 of the
/// same processor (review of lot SPF1): 2.19 and 1.51 times as long. Between two measures, by the logarithm of the
/// threads; 1 from 22 threads on, never faster than measured; the cores of an older laptop are slower still, which the
/// first scene of the computer then says (AiTimings keeps what it measured)
double splatProcessorFactor(int processors) {
  final threads = colmapCommonThreadsFor(processors);
  const measured = [(2, 68.5 * 11175 / 1225 / 286), (6, 47.2 * 11175 / 1225 / 286), (22, 1.0)];
  if (threads <= measured.first.$1) {
    return measured.first.$2;
  }
  for (var k = 1; k < measured.length; k++) {
    final (low, slow) = measured[k - 1];
    final (high, fast) = measured[k];
    if (threads <= high) {
      final at = (math.log(threads) - math.log(low)) / (math.log(high) - math.log(low));
      return slow + (fast - slow) * at;
    }
  }
  return 1.0;
}

/// The default of [stage] of a splat scene ([kind] "splatScene" or "splatSceneVideo") on a computer of [processors]
/// processors: the steps of COLMAP times [splatProcessorFactor], the others as they are; any other kind as it is
int splatDefaultOn(String kind, String stage, int milliseconds, {required int processors}) =>
    (kind == 'splatScene' || kind == 'splatSceneVideo') && splatProcessorStages.contains(stage)
    ? (milliseconds * splatProcessorFactor(processors)).round()
    : milliseconds;

/// The times of [milliseconds] (by the names of the steps) as the engine reads them; a name of no step is left out
Map<ImmersiveStage, Duration> splatTimingsOf(Map<String, int> milliseconds) => {
  for (final MapEntry(key: name, value: millis) in milliseconds.entries)
    ?ImmersiveStage.values.asNameMap()[name]: Duration(milliseconds: millis),
};

/// The images a job of [members] (photos, or the one video when [video]) plans before its preparation says more: the
/// SplatV1.videoFrames frames of a video of up to two minutes (a longer one tells its own count once open), the photos
/// up to SplatV1.maxPhotos (more are spread evenly in time, planSplatPhotos)
int splatPlannedImages(int members, {required bool video}) =>
    video ? SplatV1.videoFrames : math.min(members, SplatV1.maxPhotos);

/// How many times longer than the training of Headset (20 000 steps at 1 024 pixels) that of [settings] takes (see the
/// top of this file): its steps for Headset, [SplatV1.detailedTrainingFactor] for Detailed, and for Maximum that times
/// the pixels of its definition over those of 1 920, told only ([splatKeepsTrainingOf])
double splatTrainingFactorOf(SplatSettings settings) => switch (settings.quality) {
  SplatQuality.headset => settings.steps / SplatV1.steps,
  SplatQuality.detailed => SplatV1.detailedTrainingFactor,
  SplatQuality.maximum =>
    SplatV1.detailedTrainingFactor *
        math.pow(math.max(settings.trainingResolution, SplatV1.detailedResolution) / SplatV1.detailedResolution, 2),
};

/// Whether the training of [settings], divided by [splatTrainingFactorOf], is kept as that of Headset: for Headset and
/// Detailed, whose factors were measured; not for Maximum, whose scaling by the pixels was not (see the top of this
/// file), the time kept staying what it was
bool splatKeepsTrainingOf(SplatSettings settings) => settings.quality != SplatQuality.maximum;

/// How many times longer than for the reference job a step of a job of [images] images (photos, or frames of a
/// [video]) and [steps] steps of training takes (see the top of this file); the training [trainingFactor] times as
/// long when given (the quality, [splatTrainingFactorOf]), else by its steps
double splatStageScale(
  ImmersiveStage stage, {
  required int images,
  required bool video,
  int steps = SplatV1.steps,
  double? trainingFactor,
}) {
  final n = math.max(1, images);
  const reference = splatReferenceImages;
  return switch (stage) {
    ImmersiveStage.photos ||
    ImmersiveStage.frames ||
    ImmersiveStage.features ||
    ImmersiveStage.mapping => n / reference,
    ImmersiveStage.matching => colmapPairsOf(n, video: video) / colmapPairsOf(reference, video: video),
    ImmersiveStage.training => trainingFactor ?? steps / SplatV1.steps,
    _ => 1,
  };
}

/// The pace of a training: the steps and when each count came (BrushProgress.elapsed), the time left told by the last
/// [window] steps
class SplatTrainingPace {
  SplatTrainingPace({this.window = 1000});

  final int window;
  final _marks = <(int, Duration)>[];

  /// [step] reached [elapsed] after the training started
  void add(int step, Duration elapsed) {
    if (_marks.isNotEmpty && step <= _marks.last.$1) {
      return;
    }
    _marks.add((step, elapsed));
    // Only what the window needs, and the mark just before it
    while (_marks.length > 2 && _marks[1].$1 <= step - window) {
      _marks.removeAt(0);
    }
  }

  /// The time left to reach [steps] at the pace of the last [window] steps (of all of them before the first window);
  /// null before two counts
  Duration? left(int steps) {
    if (_marks.length < 2) {
      return null;
    }
    final (lastStep, lastTime) = _marks.last;
    final (firstStep, firstTime) = _marks.first;
    final went = lastStep - firstStep;
    if (went <= 0) {
      return null;
    }
    final perStep = (lastTime - firstTime).inMicroseconds / went;
    return Duration(microseconds: (perStep * math.max(0, steps - lastStep)).round());
  }
}

/// The times of the steps of one splat scene (see the top of this file)
class SplatTimeModel {
  SplatTimeModel({
    required this.reference,
    required this.stages,
    required int images,
    required this.video,
    this.steps = SplatV1.steps,
    this.trainingFactor,
    this.keepsTraining = true,
    int? read,
  }) : _images = math.max(1, images),
       _read = math.max(1, read ?? images);

  /// What each step takes for the reference job on this computer (the times kept)
  final Map<ImmersiveStage, Duration> reference;

  /// The steps of the job, in their order
  final List<ImmersiveStage> stages;
  final bool video;

  /// The steps of the training
  final int steps;

  /// How many times longer than that of Headset the training takes ([splatTrainingFactorOf]); by [steps] when null
  final double? trainingFactor;

  /// Whether the time of the training of this job is kept on this computer ([splatKeepsTrainingOf], [kept])
  final bool keepsTraining;
  int _images;
  int _read;

  /// The images of the job, which the steps after the preparation follow: those planned ([splatPlannedImages]) until
  /// they are prepared, then the images kept
  int get images => _images;

  set images(int count) => _images = math.max(1, count);

  /// The photos or the frames the preparation reads, which its step follows: those planned until it says how many
  int get read => _read;

  set read(int count) => _read = math.max(1, count);

  /// The scale of [stage] for this job: the preparation by what it reads, the other steps by the images kept
  double _scaleOf(ImmersiveStage stage) => splatStageScale(
    stage,
    images: stage == ImmersiveStage.photos || stage == ImmersiveStage.frames ? _read : _images,
    video: video,
    steps: steps,
    trainingFactor: trainingFactor,
  );

  /// What [stage] is expected to take for this job
  Duration expected(ImmersiveStage stage) {
    final base = reference[stage];
    if (base == null) {
      return Duration.zero;
    }
    return base * _scaleOf(stage);
  }

  /// What the whole job is expected to take
  Duration get total => stages.fold(Duration.zero, (sum, stage) => sum + expected(stage));

  /// What is expected of the steps after [stage]
  Duration after(ImmersiveStage stage) {
    final at = stages.indexOf(stage);
    return stages.skip(at + 1).fold(Duration.zero, (sum, later) => sum + expected(later));
  }

  /// What is left of [stage] after [inStage]: [stageLeft] when the step tells it (the pace of a training), else the
  /// pace of its images once a tenth of [total] is [done], blended with what was expected; what was expected less what
  /// went otherwise, never less than nothing
  Duration leftOf(ImmersiveStage stage, {required Duration inStage, int? done, int? total, Duration? stageLeft}) {
    if (stageLeft != null) {
      return stageLeft;
    }
    final byExpectation = expected(stage) - inStage;
    final expectedLeft = byExpectation.isNegative ? Duration.zero : byExpectation;
    if (done == null || total == null || total <= 0 || done <= 0) {
      return expectedLeft;
    }
    final share = (done / total).clamp(0.0, 1.0);
    if (share < 0.1) {
      return expectedLeft;
    }
    final byPace = Duration(microseconds: (inStage.inMicroseconds * (total - done) / done).round());
    return byPace * share + expectedLeft * (1 - share);
  }

  /// The time left of the whole job at [stage] (see [leftOf])
  Duration left(ImmersiveStage stage, {required Duration inStage, int? done, int? total, Duration? stageLeft}) =>
      leftOf(stage, inStage: inStage, done: done, total: total, stageLeft: stageLeft) + after(stage);

  /// Where the job is, in thousandths, once [fraction] of [stage] is done: each step weighs what it is expected to take
  int perMille(ImmersiveStage stage, double fraction) {
    final all = total.inMicroseconds;
    if (all <= 0) {
      final at = stages.indexOf(stage);
      return at < 0 ? 0 : ((at + fraction.clamp(0.0, 1.0)) * 1000 ~/ stages.length);
    }
    var before = Duration.zero;
    for (final earlier in stages) {
      if (earlier == stage) {
        break;
      }
      before += expected(earlier);
    }
    final now = before.inMicroseconds + expected(stage).inMicroseconds * fraction.clamp(0.0, 1.0);
    return (now * 1000 / all).round().clamp(0, 1000);
  }

  /// What [stage] would have taken for the reference job, having taken [took] for this one
  Duration normalized(ImmersiveStage stage, Duration took) {
    final scale = _scaleOf(stage);
    return scale <= 0 ? took : took * (1 / scale);
  }

  /// What is kept on this computer of [stage], having taken [took] for this job: [normalized]; null for a training
  /// whose time is not kept ([keepsTraining]), which leaves the time kept before as it was
  Duration? kept(ImmersiveStage stage, Duration took) =>
      stage == ImmersiveStage.training && !keepsTraining ? null : normalized(stage, took);
}
