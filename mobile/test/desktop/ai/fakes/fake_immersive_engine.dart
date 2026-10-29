// An engine without a model, for the tests of the queue and the screens: it plays the steps of a job one after the
// other, fails at a chosen step, drags, waits at a step until the test lets it go, and sees the cancel flag between
// two steps as the real one does. Its last step writes a real small side by side JPEG with our XMP to the .part, which
// package:image and StereoPhotoXmp read back.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// Pure Dart, already in the lock through maplibre_gl, as in lib/desktop/library/local_image_codec.dart
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

class FakeImmersiveEngine implements ImmersiveEngine {
  FakeImmersiveEngine({
    this.failAt,
    this.failure = ImmersiveErrorCode.decodeFailed,
    this.stepDelay = Duration.zero,
    this.slowStage,
    this.slowDelay = const Duration(milliseconds: 200),
    this.holdStage,
    this.eyeWidth = 8,
    this.eyeHeight = 6,
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

  /// The size of one eye of the JPEG written
  final int eyeWidth;
  final int eyeHeight;
  final List<ReliefQualityFlag> qualityFlags;

  /// Every job run, in order, and every progress reported
  final jobs = <ImmersiveJob>[];
  final progress = <ImmersiveProgress>[];

  /// Tells each job that reaches [holdStage]
  final reachedHold = StreamController<ImmersiveJob>.broadcast(sync: true);
  bool disposed = false;

  /// Lets the job held at [holdStage] go on
  void release() {
    if (!_hold.isCompleted) {
      _hold.complete();
    }
  }

  @override
  Future<ImmersiveResult> run(
    ImmersiveJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    if (disposed) {
      throw StateError('The engine was disposed');
    }
    jobs.add(job);
    final times = <ImmersiveStage, Duration>{};
    var written = 0;
    for (final (index, stage) in ImmersiveStage.sbs.indexed) {
      if (cancel.isCancelled) {
        return ImmersiveResult.failed(ImmersiveErrorCode.cancelled, stageTimes: times);
      }
      final step = ImmersiveProgress(stage, 1000 * index ~/ ImmersiveStage.sbs.length);
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
      if (stage == failAt) {
        return ImmersiveResult.failed(failure, message: 'Scripted failure at ${stage.name}', stageTimes: times);
      }
      if (stage == ImmersiveStage.writing) {
        final bytes = fakeSbsJpeg(xmp: xmpOf(job), eyeWidth: eyeWidth, eyeHeight: eyeHeight);
        await File(job.partPath).writeAsBytes(bytes, flush: true);
        written = bytes.length;
      }
      times[stage] = watch.elapsed;
    }
    const last = ImmersiveProgress(ImmersiveStage.writing, 1000);
    progress.add(last);
    onProgress?.call(last);
    return ImmersiveResult.done(
      eyeWidth: eyeWidth,
      eyeHeight: eyeHeight,
      bytesWritten: written,
      qualityFlags: qualityFlags,
      stageTimes: times,
    );
  }

  /// The XMP the real engine writes for [job]
  StereoPhotoXmp xmpOf(ImmersiveJob job) => StereoPhotoXmp.estimated(
    eyeWidth: eyeWidth,
    eyeHeight: eyeHeight,
    depthModelSha256: depthModelOnnxSha256,
    sourceName: job.source.name,
    sourceSize: job.source.size,
    sourceSha1: job.source.sha1,
    sourceQuarterTurns: job.quarterTurns,
    created: job.created,
    creatorTool: job.creatorTool,
    derivativeId: job.derivativeId,
    parallax: job.parallax,
    convergence: job.convergence,
    qualityFlags: qualityFlags,
  );

  @override
  Future<void> dispose() async {
    disposed = true;
    release();
    await reachedHold.close();
  }
}

/// A full side by side JPEG of two eyes of [eyeWidth] x [eyeHeight] (a gradient on the left, the same moved by one
/// pixel on the right) that carries [xmp] in an APP1 segment right after the JFIF header
Uint8List fakeSbsJpeg({required StereoPhotoXmp xmp, int eyeWidth = 8, int eyeHeight = 6}) {
  final image = img.Image(width: 2 * eyeWidth, height: eyeHeight);
  for (var y = 0; y < eyeHeight; y++) {
    for (var x = 0; x < 2 * eyeWidth; x++) {
      final column = x < eyeWidth ? x : x - eyeWidth + 1;
      image.setPixelRgb(x, y, (column * 255) ~/ eyeWidth, (y * 255) ~/ eyeHeight, 128);
    }
  }
  return insertJpegSegment(img.encodeJpg(image, quality: 90), xmpApp1Segment(xmp.toXml()));
}

/// [jpeg] with [segment] inserted after its SOI and its JFIF APP0 when it has one
Uint8List insertJpegSegment(Uint8List jpeg, Uint8List segment) {
  if (jpeg.length < 4 || jpeg[0] != 0xff || jpeg[1] != 0xd8) {
    throw ArgumentError('Not a JPEG');
  }
  var at = 2;
  if (jpeg[2] == 0xff && jpeg[3] == 0xe0) {
    at += 2 + (jpeg[4] << 8 | jpeg[5]);
  }
  return Uint8List.fromList([...jpeg.sublist(0, at), ...segment, ...jpeg.sublist(at)]);
}
