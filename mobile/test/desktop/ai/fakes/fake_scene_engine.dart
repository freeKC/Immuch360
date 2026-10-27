// An engine of 3D scenes without a model, for the tests of the queue and the screens of phases 2 and 3 (lots C3, C5,
// S4): it plays the steps of a scene one after the other, fails at a chosen step, drags, waits at a step until the
// test lets it go, and sees the cancel flag between two steps as the real one does. Its last step writes a real small
// photo that carries a scene: a JPEG preview with our XMP, then the glb of test/fixtures/ai_immersive/tiny_scene3D.jpg,
// which SceneXmp, scene_container.dart and the readers of the scene read back.
//
// FakeStagedEngine, the loop of the steps, is shared with the fakes of the panoramas.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// Pure Dart, already in the lock through maplibre_gl, as in lib/desktop/library/local_image_codec.dart
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/services/ai_immersive/scene_container.dart';

import 'fake_immersive_engine.dart' show insertJpegSegment;

/// The steps of a job of one kind played without a model: what the fakes of the scene and the panoramas share
abstract class FakeStagedEngine<J extends ImmersiveJobSpec> implements ImmersiveEngine {
  FakeStagedEngine({
    this.failAt,
    this.failure = ImmersiveErrorCode.modelFailed,
    this.stepDelay = Duration.zero,
    this.slowStage,
    this.slowDelay = const Duration(milliseconds: 200),
    this.holdStage,
    this.qualityFlags = const [],
  });

  /// The step that fails, with [failure]; null for a job that ends well
  final ImmersiveStage? failAt;
  final ImmersiveErrorCode failure;

  /// How long each step takes, and the one step that takes [slowDelay] instead
  final Duration stepDelay;
  final ImmersiveStage? slowStage;
  final Duration slowDelay;

  /// The step where the job waits until [release]
  final ImmersiveStage? holdStage;
  Completer<void> _hold = Completer<void>();
  final List<ReliefQualityFlag> qualityFlags;

  /// Every job run, in order, and every progress reported
  final jobs = <J>[];
  final progress = <ImmersiveProgress>[];

  /// Tells each job that reaches [holdStage]
  final reachedHold = StreamController<J>.broadcast(sync: true);
  bool disposed = false;

  /// The steps of the kind
  List<ImmersiveStage> get stages;

  /// Writes the file of [job] to its .part; the bytes written
  Future<int> write(J job);

  /// The details of the file written for [job]
  ImmersiveResultDetails detailsOf(J job);

  /// What a step reports inside it, between [from] and [to] thousandths: nothing but for the long steps of a fake
  List<ImmersiveProgress> inside(ImmersiveStage stage, int from, int to) => const [];

  /// Lets the job held at [holdStage] go on
  void release() {
    if (!_hold.isCompleted) {
      _hold.complete();
    }
  }

  @override
  Future<ImmersiveResult> run(
    covariant J job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    if (disposed) {
      throw StateError('The engine was disposed');
    }
    jobs.add(job);
    final times = <ImmersiveStage, Duration>{};
    var written = 0;
    for (final (index, stage) in stages.indexed) {
      if (cancel.isCancelled) {
        return ImmersiveResult.failed(ImmersiveErrorCode.cancelled, stageTimes: times);
      }
      final step = ImmersiveProgress(stage, 1000 * index ~/ stages.length);
      progress.add(step);
      onProgress?.call(step);
      final watch = Stopwatch()..start();
      if (stage == holdStage) {
        reachedHold.add(job);
        await _hold.future;
        _hold = Completer<void>();
      }
      final delay = stage == slowStage ? slowDelay : stepDelay;
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      if (cancel.isCancelled) {
        return ImmersiveResult.failed(ImmersiveErrorCode.cancelled, stageTimes: times);
      }
      for (final inner in inside(stage, step.perMille, 1000 * (index + 1) ~/ stages.length)) {
        progress.add(inner);
        onProgress?.call(inner);
      }
      if (stage == failAt) {
        return ImmersiveResult.failed(failure, message: 'Scripted failure at ${stage.name}', stageTimes: times);
      }
      if (stage == ImmersiveStage.writing) {
        written = await write(job);
      }
      times[stage] = watch.elapsed;
    }
    const last = ImmersiveProgress(ImmersiveStage.writing, 1000);
    progress.add(last);
    onProgress?.call(last);
    return ImmersiveResult.made(
      details: detailsOf(job),
      bytesWritten: written,
      qualityFlags: qualityFlags,
      stageTimes: times,
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await reachedHold.close();
  }
}

/// A JPEG of [width] x [height] (a gradient) that carries [packet] in an APP1 segment right after the JFIF header
Uint8List fakeJpegWithXmp(String packet, {required int width, required int height}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, (x * 255) ~/ width, (y * 255) ~/ height, 96);
    }
  }
  return insertJpegSegment(img.encodeJpg(image, quality: 90), xmpApp1Segment(packet));
}

/// The scene of the fixture tiny_scene3D.jpg and the packet that names it, read once
final class FakeSceneTail {
  FakeSceneTail._(this.xmp, this.glb);

  static FakeSceneTail? _read;

  /// Read from test/fixtures/ai_immersive (the tests run in mobile/)
  static FakeSceneTail get fixture => _read ??= () {
    final file = File('test/fixtures/ai_immersive/tiny_scene3D.jpg').readAsBytesSync();
    final xmp = ImmersiveXmp.findIn(file)! as SceneXmp;
    return FakeSceneTail._(xmp, sceneBytesOf(file, xmp)!);
  }();

  final SceneXmp xmp;
  final Uint8List glb;
}

class FakeSceneEngine extends FakeStagedEngine<SceneJob> {
  FakeSceneEngine({
    super.failAt,
    super.failure,
    super.stepDelay,
    super.slowStage,
    super.slowDelay,
    super.holdStage,
    super.qualityFlags,
    this.previewWidth = 16,
    this.previewHeight = 12,
  });

  /// The size of the preview written
  final int previewWidth;
  final int previewHeight;

  @override
  List<ImmersiveStage> get stages => ImmersiveStage.scene;

  /// The XMP the real engine writes for [job], around the scene of the fixture
  SceneXmp xmpOf(SceneJob job) {
    final tail = FakeSceneTail.fixture;
    final scene = tail.xmp;
    return SceneXmp.reconstructed(
      sceneLength: tail.glb.length,
      sceneSha256: scene.sceneSha256!,
      sceneMeshes: scene.sceneMeshes!,
      sceneVertices: scene.sceneVertices!,
      sceneTriangles: scene.sceneTriangles!,
      sceneTextureMax: scene.sceneTextureMax!,
      sceneScale: scene.sceneScale!,
      gridStep: scene.gridStep!,
      safe: scene.safe!,
      fieldOfView: scene.fieldOfView!,
      fieldOfViewSource: FieldOfViewSource.model,
      geometryModel: scene.geometryModel!,
      geometryModelSha256: scene.geometryModelSha256!,
      inpaintModel: scene.inpaintModel!,
      inpaintModelSha256: scene.inpaintModelSha256!,
      hiddenFraction: scene.hiddenFraction!,
      sourceName: job.original.name,
      sourceSize: job.original.size,
      sourceSha1: job.original.sha1,
      sourceQuarterTurns: job.quarterTurns,
      created: job.created,
      creatorTool: job.creatorTool,
      derivativeId: job.derivativeId,
      qualityFlags: qualityFlags,
    );
  }

  @override
  Future<int> write(SceneJob job) async {
    final glb = FakeSceneTail.fixture.glb;
    final bytes = Uint8List.fromList([
      ...fakeJpegWithXmp(xmpOf(job).toXml(), width: previewWidth, height: previewHeight),
      ...glb,
    ]);
    await File(job.partPath).writeAsBytes(bytes, flush: true);
    final glbPath = job.glbPartPath;
    if (glbPath != null) {
      await File(glbPath).writeAsBytes(glb, flush: true);
    }
    return bytes.length;
  }

  @override
  ImmersiveResultDetails detailsOf(SceneJob job) {
    final scene = FakeSceneTail.fixture.xmp;
    return SceneResultDetails(
      meshes: scene.sceneMeshes!,
      vertices: scene.sceneVertices!,
      triangles: scene.sceneTriangles!,
      safe: scene.safe!,
      scale: scene.sceneScale!,
      hiddenFraction: scene.hiddenFraction!,
      fieldOfView: scene.fieldOfView!,
    );
  }
}
