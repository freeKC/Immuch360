// The worker isolate (lot A4b): a job run there with FakeBackendSpec and the Dart codec, its progress heard on the
// root isolate, a cancel from the root isolate seen in the middle of the job, the model's session kept between jobs
// and given back after keepSession, a worker that dies.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/ai_worker.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

import '../fakes/fake_engine_tools.dart';
import '../fakes/fake_thread_priority.dart';
import 'engine_test_support.dart';

void main() {
  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('ai_worker_test_'));
  tearDown(() => folder.deleteSync(recursive: true));

  AiWorkerSetup setupWith({FakeBackendSpec backend = const FakeBackendSpec(), Duration keep = aiSessionKeep}) =>
      AiWorkerSetup(
        backend: backend,
        codec: SbsCodecChoice.dart,
        keepSession: keep,
        memory: const FixedMemoryProbe(),
        priority: FakeThreadPriority(threads: {1: 'main'}),
      );

  AiWorkerJob workerJob(ImmersiveJob job, NativeCancelFlag cancel, {SbsDecoded? decoded}) => AiWorkerJob(
    job: job,
    bytes: File(job.source.path!).readAsBytesSync(),
    decoded: decoded,
    cancelAddress: cancel.address,
  );

  test('a job runs in the worker; its progress is heard on the root isolate, its file written', () async {
    final worker = await AiWorker.spawn(setupWith());
    addTearDown(worker.close);
    final cancel = NativeCancelFlag();
    addTearDown(cancel.free);
    final part = partIn(folder, 'orientation_1.jpg');
    final job = jobFor(codecFixturePath('orientation_1.jpg'), partPath: part);
    final progress = <ImmersiveProgress>[];

    final outcome = await worker.run(workerJob(job, cancel), onProgress: progress.add);

    expect(outcome.result.isDone, isTrue, reason: '${outcome.result.error}: ${outcome.result.message}');
    expect((outcome.decoder, outcome.encoder), ('dart', 'dart'));
    expect(progress.first.stage, ImmersiveStage.reading);
    expect(progress.last, const ImmersiveProgress(ImmersiveStage.writing, 1000));
    expect(StereoPhotoXmp.findIn(File(part).readAsBytesSync())!.sourceSha1, job.source.sha1);
    final status = await worker.status();
    expect((status.jobs, status.sessionOpen), (1, true));
  });

  test('a cancel from the root isolate while the worker runs the model: the run ends, its map is dropped', () async {
    final worker = await AiWorker.spawn(setupWith(backend: const FakeBackendSpec(delay: Duration(milliseconds: 400))));
    addTearDown(worker.close);
    final cancel = NativeCancelFlag();
    addTearDown(cancel.free);
    final part = partIn(folder, 'orientation_1.jpg');
    final stages = <ImmersiveStage>[];

    final outcome = await worker.run(
      workerJob(jobFor(codecFixturePath('orientation_1.jpg'), partPath: part), cancel),
      onProgress: (progress) {
        stages.add(progress.stage);
        // Heard while the worker is busy with the model: the flag is read without a message
        if (progress.stage == ImmersiveStage.depth) {
          cancel.cancel();
        }
      },
    );

    expect(outcome.result.error, ImmersiveErrorCode.cancelled);
    expect(stages, isNot(contains(ImmersiveStage.encoding)));
    expect(File(part).existsSync(), isFalse);
  });

  test('the session is kept between jobs, given back after keepSession without one, opened again after', () async {
    final worker = await AiWorker.spawn(setupWith(keep: const Duration(milliseconds: 300)));
    addTearDown(worker.close);
    final cancel = NativeCancelFlag();
    addTearDown(cancel.free);
    Future<void> oneJob(String name) async {
      final outcome = await worker.run(
        workerJob(jobFor(codecFixturePath('orientation_1.jpg'), partPath: partIn(folder, name)), cancel),
      );
      expect(outcome.result.isDone, isTrue);
    }

    await oneJob('a.jpg');
    await oneJob('b.jpg');
    var status = await worker.status();
    expect((status.jobs, status.sessionOpen, status.sessionCloses), (2, true, 0));

    await Future<void>.delayed(const Duration(milliseconds: 700));
    status = await worker.status();
    expect((status.sessionOpen, status.sessionCloses), (false, 1));

    await oneJob('c.jpg');
    status = await worker.status();
    expect((status.jobs, status.sessionOpen, status.sessionCloses), (3, true, 1));
  });

  test('a session that failed to open is not kept', () async {
    final worker = await AiWorker.spawn(setupWith(backend: const FakeBackendSpec(failure: 'no library')));
    addTearDown(worker.close);
    final cancel = NativeCancelFlag();
    addTearDown(cancel.free);
    final outcome = await worker.run(
      workerJob(jobFor(codecFixturePath('orientation_1.jpg'), partPath: partIn(folder, 'a.jpg')), cancel),
    );
    expect((outcome.result.error, outcome.result.message), (ImmersiveErrorCode.modelFailed, 'no library'));
    expect((await worker.status()).sessionOpen, isFalse);
  });

  test('a worker that dies in a job fails it with AiWorkerStopped, and answers nothing after', () async {
    final worker = await AiWorker.spawn(setupWith(backend: const FakeBackendSpec(endIsolateInRun: true)));
    final cancel = NativeCancelFlag();
    addTearDown(cancel.free);
    await expectLater(
      worker.run(workerJob(jobFor(codecFixturePath('orientation_1.jpg'), partPath: partIn(folder, 'a.jpg')), cancel)),
      throwsA(isA<AiWorkerStopped>()),
    );
    expect(worker.isAlive, isFalse);
    await expectLater(worker.status(), throwsA(isA<AiWorkerStopped>()));
    await worker.close();
  });

  test('close gives the session back and ends the isolate', () async {
    final worker = await AiWorker.spawn(setupWith());
    final cancel = NativeCancelFlag();
    addTearDown(cancel.free);
    await worker.run(
      workerJob(jobFor(codecFixturePath('orientation_1.jpg'), partPath: partIn(folder, 'a.jpg')), cancel),
    );
    await worker.close();
    // The exit is heard soon after
    for (var i = 0; i < 50 && worker.isAlive; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(worker.isAlive, isFalse);
    await worker.close();
  });
}
