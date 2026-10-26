import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:path/path.dart' as p;

import 'fakes/fake_depth_backend.dart';
import 'fakes/fake_immersive_engine.dart';

void main() {
  late Directory folder;
  late NativeCancelFlag cancel;

  ImmersiveJob job({String name = 'salon.jpg', int turns = 0}) => ImmersiveJob(
    id: 'job-$name',
    source: ImmersiveSource(name: name, size: 4182311, sha1: 'X8tYgvibyzHDDN2yXGU/ft1XxeM=', path: '/photos/$name'),
    partPath: p.join(folder.path, '.${sbsFileNameFor(name)}.1-1.immuch360.part'),
    derivativeId: 'urn:uuid:6f1c2e0a-0000-4000-8000-000000000000',
    creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
    created: '2026-10-27T10:12:00+01:00',
    quarterTurns: turns,
  );

  setUp(() {
    folder = Directory.systemTemp.createTempSync('fake_immersive_engine');
    cancel = NativeCancelFlag();
  });

  tearDown(() {
    cancel.free();
    folder.deleteSync(recursive: true);
  });

  group('FakeImmersiveEngine', () {
    test('plays every step in order and writes a JPEG that package:image and our XMP reader read back', () async {
      final engine = FakeImmersiveEngine(qualityFlags: const [ReliefQualityFlag.hiddenAreas]);
      final heard = <ImmersiveProgress>[];

      final result = await engine.run(job(turns: 1), cancel: cancel, onProgress: heard.add);

      expect(result.isDone, isTrue);
      expect(result.eyeWidth, 8);
      expect(heard.map((step) => step.stage).toSet().toList(), ImmersiveStage.values);
      expect(heard.last, const ImmersiveProgress(ImmersiveStage.writing, 1000));
      final bytes = File(job().partPath).readAsBytesSync();
      expect(result.bytesWritten, bytes.length);
      final decoded = img.decodeJpg(bytes)!;
      expect([decoded.width, decoded.height], [16, 6]);
      final xmp = StereoPhotoXmp.findIn(bytes)!;
      expect(xmp.isReadableStereoPhoto, isTrue);
      expect(xmp.eyes, StereoEyes.full);
      expect(xmp.eyeOrder, EyeOrder.leftRight);
      expect(xmp.origin, ImmersiveOrigin.estimatedDepth);
      expect(xmp.leftEye, LeftEyeSource.original);
      expect([xmp.eyeWidth, xmp.eyeHeight], [8, 6]);
      expect(xmp.sourceName, 'salon.jpg');
      expect(xmp.sourceSha1, 'X8tYgvibyzHDDN2yXGU/ft1XxeM=');
      expect(xmp.sourceQuarterTurns, 1);
      expect(xmp.derivativeId, 'urn:uuid:6f1c2e0a-0000-4000-8000-000000000000');
      expect(xmp.qualityFlags, [ReliefQualityFlag.hiddenAreas]);
      expect(xmp.depthModelSha256, depthModelOnnxSha256);
    });

    test('fails at the chosen step with its code, and writes nothing', () async {
      final engine = FakeImmersiveEngine(failAt: ImmersiveStage.depth, failure: ImmersiveErrorCode.modelFailed);

      final result = await engine.run(job(), cancel: cancel);

      expect(result.error, ImmersiveErrorCode.modelFailed);
      expect(result.message, contains('depth'));
      expect(engine.progress.last.stage, ImmersiveStage.depth);
      expect(File(job().partPath).existsSync(), isFalse);
    });

    test('a job held at a step and cancelled there ends cancelled, without a file', () async {
      final engine = FakeImmersiveEngine(holdStage: ImmersiveStage.rightEye);
      final held = engine.reachedHold.stream.first;

      final running = engine.run(job(), cancel: cancel);
      await held;
      cancel.cancel();
      engine.release();

      expect((await running).error, ImmersiveErrorCode.cancelled);
      expect(File(job().partPath).existsSync(), isFalse);
    });

    test('a slow step takes its time', () async {
      final engine = FakeImmersiveEngine(
        slowStage: ImmersiveStage.encoding,
        slowDelay: const Duration(milliseconds: 50),
      );
      final watch = Stopwatch()..start();

      final result = await engine.run(job(), cancel: cancel);

      expect(result.isDone, isTrue);
      expect(watch.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 50)));
      expect(result.stageTimes[ImmersiveStage.encoding], greaterThanOrEqualTo(const Duration(milliseconds: 50)));
    });

    test('a disposed engine runs nothing more', () async {
      final engine = FakeImmersiveEngine();
      await engine.dispose();

      await expectLater(engine.run(job(), cancel: cancel), throwsStateError);
    });
  });

  group('FakeDepthBackend', () {
    Float32List input(FakeDepthBackend backend) => Float32List(3 * backend.inputWidth * backend.inputHeight);

    test('gives the map of its shape at the size of the model', () {
      final gradient = FakeDepthBackend();
      final map = gradient.estimate(input(gradient));

      expect([map.width, map.height], [depthModelInputWidth, depthModelInputHeight]);
      expect(map.at(0, 0), 1);
      expect(map.at(0, map.height - 1), 10);
      final step = FakeDepthBackend(shape: FakeDepthShape.step, inputWidth: 4, inputHeight: 2);
      expect(step.estimate(input(step)).values, [1, 1, 10, 10, 1, 1, 10, 10]);
      final flat = FakeDepthBackend(shape: FakeDepthShape.constant, inputWidth: 2, inputHeight: 2);
      expect(flat.estimate(input(flat)).values, [5, 5, 5, 5]);
      expect(gradient.calls, 1);
    });

    test('refuses an input of the wrong size and fails on demand', () {
      final backend = FakeDepthBackend(inputWidth: 2, inputHeight: 2);

      expect(() => backend.estimate(Float32List(3)), throwsArgumentError);
      backend.failure = 'The model could not be loaded';
      expect(() => backend.estimate(input(backend)), throwsA(isA<DepthBackendException>()));
      backend.close();
      expect(backend.closed, isTrue);
    });
  });
}
