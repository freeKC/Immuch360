// The worker isolate (lot A4b): a job run there with FakeBackendSpec and the Dart codec, its progress heard on the
// root isolate, a cancel from the root isolate seen in the middle of the job, the model's session kept between jobs
// and given back after keepSession, a worker that dies. Lot C1: the keeper of the sessions (at most two, each given
// back after keepSession without use), tasks of other kinds run in the worker with their progress, their result or
// their failure, and the session of the 3D photo kept with theirs. The stop of a run of ONNX Runtime, which needs the
// library: ort/ort_stop_test.dart.

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

  group('the keeper of the sessions', () {
    late List<String> closed;
    setUp(() => closed = []);

    String Function() opener(String name) =>
        () => name;
    void close(String session) => closed.add(session);

    test('keeps a session open between uses and opens it once', () {
      final keeper = AiSessionKeeper(keep: const Duration(minutes: 1));
      var opened = 0;
      String open() {
        opened++;
        return 'moge';
      }

      expect(keeper.open('moge', open, close), 'moge');
      keeper.endJob();
      expect(keeper.open('moge', open, close), 'moge');
      keeper.endJob();
      expect((opened, keeper.openNames.join(' '), closed.join(' ')), (1, 'moge', ''));
      keeper.closeAll();
      expect((keeper.openNames.join(' '), closed.join(' '), keeper.closes), ('', 'moge', 1));
    });

    test('keeps two at most: a third gives back the one used least recently', () {
      final keeper = AiSessionKeeper(keep: const Duration(minutes: 1));
      keeper.open('moge', opener('moge'), close);
      keeper.open('lama', opener('lama'), close);
      keeper.open('moge', opener('moge'), close);
      keeper.endJob();
      expect(keeper.openNames, ['lama', 'moge']);

      keeper.open('migan', opener('migan'), close);

      expect((keeper.openNames.join(' '), closed.join(' '), keeper.closes), ('moge migan', 'lama', 1));
      keeper.closeAll();
    });

    test('a session its owner opens: room made before, adopted after, forgotten when the owner closed it', () {
      final keeper = AiSessionKeeper(keep: const Duration(minutes: 1));
      keeper.open('moge', opener('moge'), close);
      keeper.open('lama', opener('lama'), close);
      keeper.endJob();

      keeper.makeRoom(aiDepthSession);
      expect((keeper.openNames.join(' '), closed.join(' ')), ('lama', 'moge'));
      keeper.adopt(aiDepthSession, () => closed.add('depth'));
      keeper.endJob();
      expect(keeper.openNames, ['lama', aiDepthSession]);

      keeper.makeRoom(aiDepthSession);
      expect(keeper.openNames, ['lama', aiDepthSession], reason: 'open already: nothing to give back');
      keeper.forget(aiDepthSession);
      expect((keeper.openNames.join(' '), closed.join(' ')), ('lama', 'moge'), reason: 'forgotten, not closed again');
      keeper.closeAll();
    });

    test('gives a session back after keep without use, counted from the end of the job that used it', () async {
      final keeper = AiSessionKeeper(keep: const Duration(milliseconds: 200));
      keeper.open('moge', opener('moge'), close);
      keeper.open('lama', opener('lama'), close);
      keeper.endJob();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      keeper.open('lama', opener('lama'), close);
      keeper.endJob();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect((keeper.openNames.join(' '), closed.join(' ')), ('lama', 'moge'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect((keeper.openNames.join(' '), closed.join(' '), keeper.closes), ('', 'moge lama', 2));
    });

    test('a session that fails to open is not kept, and a session of another type is refused', () {
      final keeper = AiSessionKeeper(keep: const Duration(minutes: 1));
      expect(() => keeper.open<String>('moge', () => throw StateError('no model'), close), throwsStateError);
      expect(keeper.openNames, isEmpty);
      keeper.open('moge', opener('moge'), close);
      expect(() => keeper.open<List<int>>('moge', () => [1], (_) {}), throwsStateError);
      keeper.closeAll();
    });
  });

  group('tasks', () {
    test('a task runs in the worker: its progress heard, its result given back, counted as a job', () async {
      final worker = await AiWorker.spawn(setupWith());
      addTearDown(worker.close);
      final cancel = NativeCancelFlag();
      addTearDown(cancel.free);
      final progress = <ImmersiveProgress>[];

      final result = await worker.runTask(
        const _CountingTask('moge'),
        cancelAddress: cancel.address,
        onProgress: progress.add,
      );

      expect(result, 'moge opened 1 time, cancelled: false');
      expect(progress, const [ImmersiveProgress(ImmersiveStage.geometry, 400)]);
      final status = await worker.status();
      expect((status.jobs, status.openSessions.join(' '), status.runOptionsHeld), (1, 'moge', 0));
    });

    test('a task reads the cancel flag of its job', () async {
      final worker = await AiWorker.spawn(setupWith());
      addTearDown(worker.close);
      final cancel = NativeCancelFlag()..cancel();
      addTearDown(cancel.free);
      expect(
        await worker.runTask(const _CountingTask('moge'), cancelAddress: cancel.address),
        'moge opened 1 time, cancelled: true',
      );
    });

    test('a task that throws fails its call with its message, and the worker goes on', () async {
      final worker = await AiWorker.spawn(setupWith());
      addTearDown(worker.close);
      final cancel = NativeCancelFlag();
      addTearDown(cancel.free);
      await expectLater(
        worker.runTask(const _CountingTask('broken'), cancelAddress: cancel.address),
        throwsA(isA<AiWorkerTaskFailed>().having((e) => e.message, 'message', 'Bad state: no model for broken')),
      );
      expect(await worker.runTask(const _CountingTask('lama'), cancelAddress: cancel.address), startsWith('lama'));
    });

    test('the session of the 3D photo is one of the two: tasks that open two more give it back', () async {
      final worker = await AiWorker.spawn(setupWith());
      addTearDown(worker.close);
      final cancel = NativeCancelFlag();
      addTearDown(cancel.free);
      final outcome = await worker.run(
        workerJob(jobFor(codecFixturePath('orientation_1.jpg'), partPath: partIn(folder, 'a.jpg')), cancel),
      );
      expect(outcome.result.isDone, isTrue);
      expect((await worker.status()).openSessions, [aiDepthSession]);

      await worker.runTask(const _CountingTask('moge'), cancelAddress: cancel.address);
      expect((await worker.status()).openSessions, [aiDepthSession, 'moge']);
      await worker.runTask(const _CountingTask('lama'), cancelAddress: cancel.address);
      var status = await worker.status();
      expect((status.openSessions.join(' '), status.sessionOpen, status.sessionCloses), ('moge lama', false, 1));

      // The next 3D photo opens it again, and gives back the one used least recently
      await worker.run(
        workerJob(jobFor(codecFixturePath('orientation_1.jpg'), partPath: partIn(folder, 'b.jpg')), cancel),
      );
      status = await worker.status();
      expect((status.openSessions.join(' '), status.sessionOpen, status.sessionCloses), ('lama depth', true, 2));
    });
  });
}

/// Opens the session [name] (a string) through the keeper, says how often it was opened and whether the job was
/// cancelled; "broken" fails to open
class _CountingTask implements AiWorkerTask<String> {
  const _CountingTask(this.name);

  final String name;

  static final _opened = <String, int>{};

  @override
  String run(AiWorkerContext context) {
    context.progress(const ImmersiveProgress(ImmersiveStage.geometry, 400));
    context.sessions.open(name, () {
      if (name == 'broken') {
        throw StateError('no model for $name');
      }
      _opened[name] = (_opened[name] ?? 0) + 1;
      return name;
    }, (_) {});
    return '$name opened ${_opened[name]} time, cancelled: ${context.isCancelled}';
  }
}
