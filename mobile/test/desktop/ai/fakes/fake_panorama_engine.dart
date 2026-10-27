// An engine of 360° panoramas without a generator, for the tests of the queue (the lane of the graphics card, the
// chained 3D version) and of the screens (lots C3, U3): it plays the steps of a panorama, says "step k of n" through
// the progress of the generation, fails at a chosen step with a named failure (gpuOutOfMemory, generatorStalled,
// outputRejected...), and writes a real small equirectangular JPEG, 2:1, with GPano and our XMP, which the 360° rules
// of the app and PanoramaXmp read back.

import 'dart:io';

import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';

import 'fake_scene_engine.dart';

class FakePanoramaEngine extends FakeStagedEngine<PanoramaJob> {
  FakePanoramaEngine({
    super.failAt,
    super.failure = ImmersiveErrorCode.generatorFailed,
    super.stepDelay,
    super.slowStage,
    super.slowDelay,
    super.holdStage,
    super.qualityFlags,
    this.width = 32,
    this.height = 16,
    this.sourceCoverage = 0.08,
    this.region = const PhotoRegion(yaw: 0, pitch: 0, hfov: 65.4, vfov: 50.6),
    this.secondsPerStep = 12,
  });

  /// The pace the fake generation tells, one progress per step of the job
  final int secondsPerStep;

  /// The size of the panorama written, 2:1
  final int width;
  final int height;
  final double sourceCoverage;
  final PhotoRegion region;

  @override
  List<ImmersiveStage> get stages => ImmersiveStage.panorama;

  /// The steps of the generation of the job run, "step k of n" with the time left at [secondsPerStep]
  @override
  List<ImmersiveProgress> inside(ImmersiveStage stage, int from, int to) {
    if (stage != ImmersiveStage.generating || jobs.isEmpty) {
      return const [];
    }
    final steps = jobs.last.steps;
    return [
      for (var step = 1; step <= steps; step++)
        ImmersiveProgress(
          stage,
          from + (to - from) * step ~/ steps,
          step: step,
          steps: steps,
          remaining: Duration(seconds: (steps - step) * secondsPerStep),
        ),
    ];
  }

  /// The XMP the real engine writes for [job]
  PanoramaXmp xmpOf(PanoramaJob job) => PanoramaXmp.generated(
    width: width,
    height: height,
    region: region,
    sourceCoverage: sourceCoverage,
    generator: job.generator,
    generatorSha256: fakeGeneratorSha256,
    generatorLora: 'flux2-klein-4b-360-erp-lora-v1',
    generatorLoraSha256: fakeLoraSha256,
    seed: job.seed,
    steps: job.steps,
    upscaler: 'realesrgan-x4plus',
    sourceName: job.original.name,
    sourceSize: job.original.size,
    sourceSha1: job.original.sha1,
    sourceQuarterTurns: job.quarterTurns,
    created: job.created,
    creatorTool: job.creatorTool,
    derivativeId: job.derivativeId,
    qualityFlags: qualityFlags,
  );

  @override
  Future<int> write(PanoramaJob job) async {
    final bytes = fakeJpegWithXmp(xmpOf(job).toXml(), width: width, height: height);
    await File(job.partPath).writeAsBytes(bytes, flush: true);
    return bytes.length;
  }

  @override
  ImmersiveResultDetails detailsOf(PanoramaJob job) => PanoramaResultDetails(
    width: width,
    height: height,
    seed: job.seed,
    steps: job.steps,
    sourceCoverage: sourceCoverage,
  );
}

/// The sums the fake panoramas write for the transformer and the LoRA
const fakeGeneratorSha256 = '1111111111111111111111111111111111111111111111111111111111111111';
const fakeLoraSha256 = '2222222222222222222222222222222222222222222222222222222222222222';
