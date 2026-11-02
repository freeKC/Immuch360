// The time of a splat scene (plan 2026-11-01, sections 2.2 and 2.4, lot SP6; design engineering-first of 1 November
// 2026, section 4.5): its engine tells the time left of the whole job (ConversionKind.tellsWholeTimeLeft), since it
// follows the images, the pairs and the steps of the job rather than a time per step.
//
// The times of the steps a computer keeps (AiTimings, desktop_ai.json, under "splatScene" and "splatSceneVideo") are
// those of a job of [splatReferenceImages] images, 150 photos or 150 frames, at 20 000 steps: the defaults of the plan
// until this computer finished one, then the mean of what it measured. A job of other counts scales them: the photos
// or frames prepared, the points of the images and the mapping with its images; the exhaustive matching of photos with
// its pairs (n (n - 1) / 2), the sequential one of a video with its images; the training with its steps (one image a
// step, at the definition of the settings); the rest not at all. The times a job measured go back to the reference
// the same way before they are kept ([SplatTimeModel.normalized]).
//
// While a step runs, what is left of it is told by what it went through: the pace of its images (done of total) once a
// tenth of them is done, blended with what was expected before; for the training, the pace of its last 1 000 steps
// ([SplatTrainingPace]: M1 measured 19 to 20 s per 1 000 steps from the 5 000th to the end, the cap of 150 000 gaussians
// reached by then). The time left of the job adds what is expected of the steps after it.

import 'dart:math' as math;

import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
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

/// The same for a splat scene of a video of two minutes ("splatSceneVideo"): some 8.5 min
const splatSceneVideoDefaultTimings = <String, int>{
  'reading': 5000,
  'frames': 60000,
  'features': 15000,
  'matching': 81000,
  'mapping': 30000,
  'training': 306000,
  'splatCopy': 10000,
  'writing': 1000,
};

/// The times of [milliseconds] (by the names of the steps) as the engine reads them; a name of no step is left out
Map<ImmersiveStage, Duration> splatTimingsOf(Map<String, int> milliseconds) => {
  for (final MapEntry(key: name, value: millis) in milliseconds.entries)
    ?ImmersiveStage.values.asNameMap()[name]: Duration(milliseconds: millis),
};

/// How many times longer than for the reference job a step of a job of [images] images (photos, or frames of a
/// [video]) and [steps] steps of training takes (see the top of this file)
double splatStageScale(ImmersiveStage stage, {required int images, required bool video, int steps = SplatV1.steps}) {
  final n = math.max(1, images);
  const reference = splatReferenceImages;
  return switch (stage) {
    ImmersiveStage.photos ||
    ImmersiveStage.frames ||
    ImmersiveStage.features ||
    ImmersiveStage.mapping => n / reference,
    ImmersiveStage.matching => video ? n / reference : (n * (n - 1)) / (reference * (reference - 1)),
    ImmersiveStage.training => steps / SplatV1.steps,
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
  }) : _images = math.max(1, images);

  /// What each step takes for the reference job on this computer (the times kept)
  final Map<ImmersiveStage, Duration> reference;

  /// The steps of the job, in their order
  final List<ImmersiveStage> stages;
  final bool video;

  /// The steps of the training
  final int steps;
  int _images;

  /// The images of the job: the members until they are prepared, then the images kept
  int get images => _images;

  set images(int count) => _images = math.max(1, count);

  /// What [stage] is expected to take for this job
  Duration expected(ImmersiveStage stage) {
    final base = reference[stage];
    if (base == null) {
      return Duration.zero;
    }
    return base * splatStageScale(stage, images: _images, video: video, steps: steps);
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

  /// What [stage] would have taken for the reference job, having taken [took] for this one: what is kept on this
  /// computer
  Duration normalized(ImmersiveStage stage, Duration took) {
    final scale = splatStageScale(stage, images: _images, video: video, steps: steps);
    return scale <= 0 ? took : took * (1 / scale);
  }
}
