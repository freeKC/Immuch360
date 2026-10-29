// An engine of 360° 3D panoramas (relief-360-v1) without a depth model, for the tests of the queue (the job chained
// after its panorama, the 3D version of a 360° photo) and of the screens (lots C3, P1, U3): it plays the steps of a 3D
// panorama, refuses a flat one when asked (notEnoughRelief), and writes a real small square JPEG, top and bottom with
// the left eye on top, with GPano and our XMP, which the 360° rules of the app and StereoPanoramaXmp read back.

import 'dart:io';

import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';

import 'fake_scene_engine.dart';

class FakeStereoPanoramaEngine extends FakeStagedEngine<StereoPanoramaJob> {
  FakeStereoPanoramaEngine({
    super.failAt,
    super.failure = ImmersiveErrorCode.notEnoughRelief,
    super.stepDelay,
    super.slowStage,
    super.slowDelay,
    super.holdStage,
    super.qualityFlags,
    this.side = 32,
    this.filledFraction = 0.03,
  });

  /// The side of the square frame written (each eye side x side / 2)
  final int side;
  final double filledFraction;

  @override
  List<ImmersiveStage> get stages => ImmersiveStage.stereoPanorama;

  /// The XMP the real engine writes for [job]: a version of the photo the panorama was generated from, or of the 360°
  /// photo itself
  StereoPanoramaXmp xmpOf(StereoPanoramaJob job) => StereoPanoramaXmp.estimated(
    width: side,
    height: side,
    depthModelSha256: depthModelOnnxSha256,
    sourceName: job.original.name,
    sourceSize: job.original.size,
    sourceSha1: job.original.sha1,
    sourceQuarterTurns: job.quarterTurns,
    created: job.created,
    creatorTool: job.creatorTool,
    parent: job.parent,
    derivativeId: job.derivativeId,
    qualityFlags: qualityFlags,
  );

  @override
  Future<int> write(StereoPanoramaJob job) async {
    final bytes = fakeJpegWithXmp(xmpOf(job).toXml(), width: side, height: side);
    await File(job.partPath).writeAsBytes(bytes, flush: true);
    return bytes.length;
  }

  @override
  ImmersiveResultDetails detailsOf(StereoPanoramaJob job) =>
      StereoPanoramaResultDetails(width: side, height: side, filledFraction: filledFraction);
}
