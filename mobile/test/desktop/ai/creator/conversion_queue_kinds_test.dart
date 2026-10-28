// The queue of phases 2 and 3 (design-final 2026-10-27, sections 2.5, 4.5 and 10.1 point 5), run with the fakes of
// lot C0: an engine per kind, two lanes (the processor, the graphics card) with one job each, the second one waiting
// when the memory free cannot hold both, the 360° 3D panorama chained after its panorama and skipped with its reason
// when the panorama was not made, a disk full that pauses both lanes, the same settings per kind, a new seed for "Make
// a new version", and the time left of a job.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_conversion_engines.dart';
import '../fakes/fake_conversion_output.dart';
import '../fakes/fake_immersive_engine.dart';
import '../fakes/fake_panorama_engine.dart';
import '../fakes/fake_scene_engine.dart';
import '../fakes/fake_stereo_panorama_engine.dart';

const _gib = 1024 * 1024 * 1024;

String _sumOf(List<int> bytes) => base64.encode(crypto.sha1.convert(bytes).bytes);

/// The sum of the file at [path] in Dart, without an isolate per job
Future<String> _dartSum(String path, NativeCancelFlag cancel) async => _sumOf(File(path).readAsBytesSync());

/// The memory of the computer, changed by the tests
class _Memory implements MemoryProbe {
  int? available = 16 * _gib;

  @override
  MemoryFacts read() => MemoryFacts(physical: 16 * _gib, available: available);
}

/// Every run, by kind, and how many ran at once on each lane and on both
class _Runs {
  final kinds = <ConversionKind>[];
  final _running = <ConversionLane, int>{};
  final mostOnLane = <ConversionLane, int>{};
  var mostAtOnce = 0;

  void start(ConversionKind kind) {
    kinds.add(kind);
    _running[kind.lane] = (_running[kind.lane] ?? 0) + 1;
    mostOnLane[kind.lane] = math.max(mostOnLane[kind.lane] ?? 0, _running[kind.lane]!);
    mostAtOnce = math.max(mostAtOnce, _running.values.fold(0, (sum, count) => sum + count));
  }

  void end(ConversionKind kind) => _running[kind.lane] = _running[kind.lane]! - 1;
}

/// [inner] counted by [runs]
class _Counted implements ImmersiveEngine {
  _Counted(this.kind, this.inner, this.runs);

  final ConversionKind kind;
  final ImmersiveEngine inner;
  final _Runs runs;

  @override
  Future<ImmersiveResult> run(
    covariant ImmersiveJobSpec job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    runs.start(kind);
    try {
      return await inner.run(job, cancel: cancel, onProgress: onProgress);
    } finally {
      runs.end(kind);
    }
  }

  @override
  Future<void> dispose() => inner.dispose();
}

/// An engine that tells [events], then what the test tells it, until [release]; it ends cancelled
class _Scripted implements ImmersiveEngine {
  _Scripted(this.events);

  final List<ImmersiveProgress> events;
  final _hold = Completer<void>();
  final told = Completer<void>();
  void Function(ImmersiveProgress progress)? _onProgress;

  void tell(ImmersiveProgress progress) => _onProgress?.call(progress);

  void release() => _hold.complete();

  @override
  Future<ImmersiveResult> run(
    covariant ImmersiveJobSpec job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    _onProgress = onProgress;
    events.forEach(tell);
    told.complete();
    await _hold.future;
    return const ImmersiveResult.failed(ImmersiveErrorCode.cancelled);
  }

  @override
  Future<void> dispose() async {}
}

/// The writer, held at the rename of the first job of [kind] until [hold] completes
class _HeldFinish extends FakeConversionOutput {
  _HeldFinish(this.kind);

  final ConversionKind kind;
  final reached = Completer<void>();
  final hold = Completer<void>();

  @override
  Future<ConversionSaved> finish(
    ConversionJob job,
    String partPath, {
    required ImmersiveSource original,
    required AiWhenExists whenExists,
    String? replaceName,
  }) async {
    if (job.kind == kind && !reached.isCompleted) {
      reached.complete();
      await hold.future;
    }
    return super.finish(job, partPath, original: original, whenExists: whenExists, replaceName: replaceName);
  }
}

void main() {
  late Directory root;
  late String photos;
  late FakeConversionOutput output;
  late _Memory memory;
  late _Runs runs;
  late FakeSceneEngine scene;
  late FakePanoramaEngine panorama;
  late FakeStereoPanoramaEngine stereo;
  late FakeImmersiveEngine sbs;
  late Map<ConversionKind, ConversionEngine> Function() engines;
  late DesktopAiSettingsStore settings;
  late DateTime clock;
  late List<int> seeds;
  late ProviderContainer container;

  ProviderContainer containerWith() {
    final made = ProviderContainer(
      overrides: [
        conversionToolsProvider.overrideWith(
          (ref) => ConversionTools(
            engine: _Counted(ConversionKind.sbsFromPhoto, sbs, runs),
            engines: {
              for (final MapEntry(key: kind, value: entry) in engines().entries)
                kind: ConversionEngine(
                  engine: _Counted(kind, entry.engine, runs),
                  settingsKey: entry.settingsKey,
                  generator: entry.generator,
                  steps: entry.steps,
                ),
            },
            output: output,
            finder: ExistingVersionFinder(),
            creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
            software: 'Immuch360 Desktop 3.3.0',
            memory: memory,
            memoryRecheck: const Duration(milliseconds: 20),
            settings: settings,
            now: () => clock,
            newSeed: () => seeds.removeAt(0),
          ),
        ),
      ],
    );
    addTearDown(made.dispose);
    return made;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('conversion_queue_kinds');
    // Before the containers, so that it runs after them: Windows deletes no folder with a file still open
    addTearDown(() => root.deleteSync(recursive: true));
    photos = p.join(root.path, 'photos');
    Directory(photos).createSync();
    final support = Directory(p.join(root.path, 'support'))..createSync();
    output = FakeConversionOutput();
    memory = _Memory();
    runs = _Runs();
    scene = FakeSceneEngine();
    panorama = FakePanoramaEngine();
    stereo = FakeStereoPanoramaEngine();
    sbs = FakeImmersiveEngine();
    engines = () => fakeConversionEngines(scene: scene, panorama: panorama, stereoPanorama: stereo);
    settings = DesktopAiSettingsStore(settingsDirectory: () async => support);
    clock = DateTime(2026, 10, 27, 22, 30);
    seeds = [11, 12, 13, 14];
    container = containerWith();
  });

  ConversionQueueNotifier queue() => container.read(conversionQueueProvider.notifier);
  ConversionQueueState current() => container.read(conversionQueueProvider);
  ConversionJob job(String id) => current().byId(id)!;

  /// An original in the photos folder, its version of [kind] planned next to it
  ConversionRequest photo(String name, {ConversionKind kind = ConversionKind.sceneFromPhoto, int turns = 0}) {
    final bytes = Uint8List.fromList(List.generate(64, (i) => (i * 7 + name.length) & 0xff));
    final path = p.join(photos, name);
    File(path).writeAsBytesSync(bytes);
    return ConversionRequest(
      source: LocalFileSource(path, hash: _dartSum),
      target: ConversionTarget.nextTo(path, kind: kind),
      quarterTurns: turns,
    );
  }

  /// Completes once [test] holds for the state of the queue
  Future<void> until(bool Function(ConversionQueueState state) test) async {
    if (test(current())) {
      return;
    }
    final reached = Completer<void>();
    final subscription = container.listen(conversionQueueProvider, (_, next) {
      if (!reached.isCompleted && test(next)) {
        reached.complete();
      }
    });
    try {
      await reached.future.timeout(const Duration(seconds: 10));
    } finally {
      subscription.close();
    }
  }

  Future<void> allEnded() => until((state) => state.jobs.every((job) => job.state.isEnded));

  List<String> folder() => [for (final entry in Directory(photos).listSync()) p.basename(entry.path)]..sort();

  test('the name planned for each kind', () {
    final original = p.join(photos, 'salon.jpg');
    expect(ConversionTarget.nextTo(original).fileName, 'salon_3D_LRF_Full_SBS.jpg');
    expect(ConversionTarget.nextTo(original, kind: ConversionKind.sceneFromPhoto).fileName, 'salon_scene3D.jpg');
    expect(ConversionTarget.nextTo(original, kind: ConversionKind.panoramaFromPhoto).fileName, 'salon_360.jpg');
    expect(
      ConversionTarget.nextTo(
        p.join(photos, 'PANO_0001.jpg'),
        kind: ConversionKind.stereoPanoramaFromPanorama,
      ).fileName,
      'PANO_0001_3D.jpg',
    );
  });

  group('an engine per kind', () {
    test('a scene runs through the engine of its kind, its steps in order, and lands next to the original', () async {
      final request = photo('salon.jpg', turns: 1);
      final original = File(p.join(photos, 'salon.jpg'));
      final before = original.readAsBytesSync();
      final states = <ConversionState>[];
      container.listen(conversionQueueProvider, (_, next) {
        final state = next.jobs.firstOrNull?.state;
        if (state != null && (states.isEmpty || states.last != state)) {
          states.add(state);
        }
      });

      final id = queue().add([request], kind: ConversionKind.sceneFromPhoto).single;
      await allEnded();

      expect(states, [
        ConversionState.waiting,
        ConversionState.reading,
        ConversionState.decoding,
        ConversionState.geometry,
        ConversionState.layers,
        ConversionState.inpaint,
        ConversionState.mesh,
        ConversionState.textures,
        ConversionState.writing,
        ConversionState.done,
      ]);
      final done = job(id);
      expect(done.kind, ConversionKind.sceneFromPhoto);
      expect(done.writtenPath, p.join(photos, 'salon_scene3D.jpg'));
      expect(done.details, isA<SceneResultDetails>());
      final spec = scene.jobs.single;
      expect(spec.sources.single.name, 'salon.jpg');
      expect(spec.sources.single.sha1, _sumOf(before));
      expect(spec.quarterTurns, 1);
      expect(spec.exif.software, 'Immuch360 Desktop 3.3.0');
      final xmp = ImmersiveXmp.findIn(File(done.writtenPath!).readAsBytesSync())! as SceneXmp;
      expect(xmp.sourceSha1, _sumOf(before));
      expect(xmp.settingsKey, fakeSceneSettingsKey(1));
      expect(runs.kinds, [ConversionKind.sceneFromPhoto]);
      expect(sbs.jobs, isEmpty);
      expect(original.readAsBytesSync(), before);
      expect(folder(), ['salon.jpg', 'salon_scene3D.jpg']);
    });

    test('a kind without an engine in this build fails with its reason, and the other photos go on', () async {
      engines = () => fakeConversionEngines(scene: scene);
      container = containerWith();

      final panoramaId = queue().add([
        photo('a.jpg', kind: ConversionKind.panoramaFromPhoto),
      ], kind: ConversionKind.panoramaFromPhoto).single;
      final sceneId = queue().add([photo('b.jpg')], kind: ConversionKind.sceneFromPhoto).single;
      await allEnded();

      expect(job(panoramaId).state, ConversionState.failed);
      expect(job(panoramaId).error, ImmersiveErrorCode.modelFailed);
      expect(job(panoramaId).message, contains('panoramaFromPhoto'));
      expect(job(sceneId).state, ConversionState.done);
      expect(container.read(conversionToolsProvider).supports(ConversionKind.panoramaFromPhoto), isFalse);
      expect(container.read(conversionToolsProvider).supports(ConversionKind.sceneFromPhoto), isTrue);
      expect(container.read(conversionToolsProvider).supports(ConversionKind.sbsFromPhoto), isTrue);
    });

    test('a spec only reaches the engine of its kind: one registered for another kind fails the job', () async {
      engines = () => {
        ConversionKind.sceneFromPhoto: ConversionEngine(engine: FakeImmersiveEngine(), settingsKey: (_, _) => null),
      };
      container = containerWith();

      final id = queue().add([photo('salon.jpg')], kind: ConversionKind.sceneFromPhoto).single;
      await allEnded();

      expect(job(id).state, ConversionState.failed);
      expect(job(id).error, ImmersiveErrorCode.modelFailed);
      expect(output.discarded, output.begun);
      expect(folder(), ['salon.jpg']);
    });

    test('the same settings are those of the kind: a scene skips its scene, never the 3D photo', () async {
      final first = queue().add([photo('salon.jpg')], kind: ConversionKind.sceneFromPhoto).single;
      await allEnded();
      final made = job(first).writtenPath;

      final again = queue().add([photo('salon.jpg')], kind: ConversionKind.sceneFromPhoto).single;
      final turned = queue().add([photo('salon.jpg', turns: 2)], kind: ConversionKind.sceneFromPhoto).single;
      final sbsId = queue().add([photo('salon.jpg', kind: ConversionKind.sbsFromPhoto)]).single;
      await allEnded();

      expect(job(again).state, ConversionState.skipped);
      expect(job(again).skipReason, ConversionSkipReason.sameSettingsExists);
      expect(job(again).existingVersionPath, made);
      expect(job(turned).state, ConversionState.done);
      expect(job(turned).writtenPath, p.join(photos, 'salon_scene3D (1).jpg'));
      expect(job(sbsId).state, ConversionState.done);
      expect(job(sbsId).writtenPath, p.join(photos, 'salon_3D_LRF_Full_SBS.jpg'));
      expect(scene.jobs, hasLength(2));
    });

    test('a key the engine cannot tell before the run looks for no version: the photo is converted', () async {
      engines = () => {ConversionKind.sceneFromPhoto: ConversionEngine(engine: scene, settingsKey: (_, _) => null)};
      container = containerWith();
      queue().add([photo('salon.jpg')], kind: ConversionKind.sceneFromPhoto);
      await allEnded();

      final again = queue().add([photo('salon.jpg')], kind: ConversionKind.sceneFromPhoto).single;
      await allEnded();

      expect(job(again).state, ConversionState.done);
      expect(job(again).writtenPath, p.join(photos, 'salon_scene3D (1).jpg'));
    });
  });

  group('two lanes', () {
    test('a panorama on the graphics card does not hold the scenes back; one job at a time on each lane', () async {
      panorama = FakePanoramaEngine(holdStage: ImmersiveStage.upscale);
      final held = panorama.reachedHold.stream.first;

      final panoramas = queue().add([
        photo('a.jpg', kind: ConversionKind.panoramaFromPhoto),
        photo('b.jpg', kind: ConversionKind.panoramaFromPhoto),
      ], kind: ConversionKind.panoramaFromPhoto);
      await held;
      final scenes = queue().add([photo('c.jpg'), photo('d.jpg')], kind: ConversionKind.sceneFromPhoto);
      await until((state) => scenes.every((id) => state.byId(id)!.state == ConversionState.done));

      expect(job(panoramas[0]).state, ConversionState.upscale);
      expect(job(panoramas[1]).state, ConversionState.waiting);
      expect(current().onLane(ConversionLane.gpu)?.id, panoramas[0]);
      expect(current().onLane(ConversionLane.cpu), isNull);
      expect(current().running.map((job) => job.id), [panoramas[0]]);

      final next = panorama.reachedHold.stream.first;
      panorama.release();
      await next;
      expect(job(panoramas[0]).state, ConversionState.done);
      panorama.release();
      await allEnded();

      expect(runs.mostOnLane, {ConversionLane.gpu: 1, ConversionLane.cpu: 1});
      expect(runs.mostAtOnce, 2);
      expect([
        for (final id in [...panoramas, ...scenes]) job(id).state,
      ], everyElement(ConversionState.done));
      expect(folder(), containsAll(['a_360.jpg', 'b_360.jpg', 'c_scene3D.jpg', 'd_scene3D.jpg']));
    });

    test(
      'a job of the other lane waits while the memory free cannot hold both, and runs once the first ends',
      () async {
        panorama = FakePanoramaEngine(holdStage: ImmersiveStage.generating);
        final held = panorama.reachedHold.stream.first;
        memory.available = 3 * _gib - 1;

        final generated = queue().add([
          photo('a.jpg', kind: ConversionKind.panoramaFromPhoto),
        ], kind: ConversionKind.panoramaFromPhoto).single;
        await held;
        final waiting = queue().add([photo('b.jpg')], kind: ConversionKind.sceneFromPhoto).single;
        // Time enough for a few checks of the memory
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(job(waiting).state, ConversionState.waiting);
        expect(job(waiting).waitingFor, ConversionWait.memory);
        expect(scene.jobs, isEmpty);

        panorama.release();
        await allEnded();
        expect(job(generated).state, ConversionState.done);
        expect(job(waiting).state, ConversionState.done);
        expect(job(waiting).waitingFor, isNull);
        expect(runs.mostAtOnce, 1);
      },
    );

    test(
      'a scene waits beside a panorama that has not loaded its models yet: the memory free counts none of them',
      () async {
        panorama = FakePanoramaEngine(holdStage: ImmersiveStage.fieldOfView);
        final held = panorama.reachedHold.stream.first;
        // Enough for a scene beside a generation (3 GiB), not for a scene and the 6 GiB the panorama has still to take
        memory.available = 4 * _gib;

        final generated = queue().add([
          photo('a.jpg', kind: ConversionKind.panoramaFromPhoto),
        ], kind: ConversionKind.panoramaFromPhoto).single;
        // At once, the panorama reading its photo
        final waiting = queue().add([photo('b.jpg')], kind: ConversionKind.sceneFromPhoto).single;
        await held;
        // Time enough for a few checks of the memory
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(job(generated).state, ConversionState.fieldOfView);
        expect(job(waiting).state, ConversionState.waiting);
        expect(job(waiting).waitingFor, ConversionWait.memory);
        expect(scene.jobs, isEmpty);

        // The generation takes its memory (M3 saw 0.9 to 1.7 GiB free then): the scene runs once the panorama ends
        memory.available = _gib;
        panorama.release();
        await allEnded();
        expect([job(generated).state, job(waiting).state], everyElement(ConversionState.done));
        expect(runs.kinds, [ConversionKind.panoramaFromPhoto, ConversionKind.sceneFromPhoto]);
        expect(runs.mostAtOnce, 1);
      },
    );

    test(
      'once the panorama generates, the memory free counts it: a scene starts beside when it holds the scene',
      () async {
        final engine = _Scripted([
          const ImmersiveProgress(ImmersiveStage.reading, 0),
          const ImmersiveProgress(ImmersiveStage.fieldOfView, 50),
          const ImmersiveProgress(ImmersiveStage.loadingModels, 100),
        ]);
        engines = () => {
          ...fakeConversionEngines(scene: scene),
          ConversionKind.panoramaFromPhoto: ConversionEngine(
            engine: engine,
            settingsKey: (_, _) => null,
            generator: fakePanoramaGenerator,
            steps: fakePanoramaSteps,
          ),
        };
        container = containerWith();
        memory.available = 4 * _gib;

        final generated = queue().add([
          photo('a.jpg', kind: ConversionKind.panoramaFromPhoto),
        ], kind: ConversionKind.panoramaFromPhoto).single;
        await engine.told.future;
        final waiting = queue().add([photo('b.jpg')], kind: ConversionKind.sceneFromPhoto).single;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(job(generated).state, ConversionState.loadingModels);
        expect(job(waiting).waitingFor, ConversionWait.memory);
        expect(scene.jobs, isEmpty);

        // Its models loaded, the generation runs; the 4 GiB read now are what is left beside it
        engine.tell(const ImmersiveProgress(ImmersiveStage.generating, 200, step: 1, steps: fakePanoramaSteps));
        await until((state) => state.byId(waiting)!.state == ConversionState.done);
        expect(job(generated).state, ConversionState.generating);
        expect(runs.mostAtOnce, 2);

        queue().cancel(generated);
        engine.release();
        await allEnded();
      },
    );

    test(
      'a panorama waits beside a scene that has not run its models yet, and starts beside it once they run',
      () async {
        final engine = _Scripted([
          const ImmersiveProgress(ImmersiveStage.reading, 0),
          const ImmersiveProgress(ImmersiveStage.decoding, 100),
        ]);
        engines = () => {
          ...fakeConversionEngines(panorama: panorama),
          ConversionKind.sceneFromPhoto: ConversionEngine(engine: engine, settingsKey: (_, _) => null),
        };
        container = containerWith();
        // A panorama beside a scene asks for 6.5 GiB and the reserve: enough beside the scene once it holds its 2 GiB
        memory.available = 8 * _gib;

        final decoding = queue().add([photo('a.jpg')], kind: ConversionKind.sceneFromPhoto).single;
        await engine.told.future;
        final waiting = queue().add([
          photo('b.jpg', kind: ConversionKind.panoramaFromPhoto),
        ], kind: ConversionKind.panoramaFromPhoto).single;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(job(waiting).waitingFor, ConversionWait.memory);
        expect(panorama.jobs, isEmpty);

        engine.tell(const ImmersiveProgress(ImmersiveStage.geometry, 200));
        await until((state) => state.byId(waiting)!.state == ConversionState.done);
        expect(job(decoding).state, ConversionState.geometry);

        queue().cancel(decoding);
        engine.release();
        await allEnded();
      },
    );

    test('a computer with memory for both starts a scene beside a panorama still reading its photo', () async {
      panorama = FakePanoramaEngine(holdStage: ImmersiveStage.fieldOfView);
      final held = panorama.reachedHold.stream.first;
      memory.available = 12 * _gib;

      final generated = queue().add([
        photo('a.jpg', kind: ConversionKind.panoramaFromPhoto),
      ], kind: ConversionKind.panoramaFromPhoto).single;
      final beside = queue().add([photo('b.jpg')], kind: ConversionKind.sceneFromPhoto).single;
      await held;
      await until((state) => state.byId(beside)!.state == ConversionState.done);

      expect(job(generated).state, ConversionState.fieldOfView);
      expect(runs.mostAtOnce, 2);
      panorama.release();
      await allEnded();
    });

    test('memory freed while the other lane runs lets the waiting job start beside it', () async {
      panorama = FakePanoramaEngine(holdStage: ImmersiveStage.generating);
      final held = panorama.reachedHold.stream.first;
      memory.available = _gib;

      queue().add([photo('a.jpg', kind: ConversionKind.panoramaFromPhoto)], kind: ConversionKind.panoramaFromPhoto);
      await held;
      final waiting = queue().add([photo('b.jpg')], kind: ConversionKind.sceneFromPhoto).single;
      await until((state) => state.byId(waiting)!.waitingFor == ConversionWait.memory);

      // The user closed a game
      memory.available = 3 * _gib;
      await until((state) => state.byId(waiting)!.state == ConversionState.done);

      expect(current().onLane(ConversionLane.gpu)?.state, ConversionState.generating);
      expect(runs.mostAtOnce, 2);
      panorama.release();
      await allEnded();
    });

    test('when both lanes free up, the job that came first starts first, the other one waits for memory', () async {
      panorama = FakePanoramaEngine(holdStage: ImmersiveStage.generating);
      memory.available = 2 * _gib;
      var held = panorama.reachedHold.stream.first;

      final first = queue().add([
        photo('a.jpg', kind: ConversionKind.panoramaFromPhoto),
      ], kind: ConversionKind.panoramaFromPhoto).single;
      await held;
      final second = queue().add([
        photo('b.jpg', kind: ConversionKind.panoramaFromPhoto),
      ], kind: ConversionKind.panoramaFromPhoto).single;
      final waiting = queue().add([photo('c.jpg')], kind: ConversionKind.sceneFromPhoto).single;
      await until((state) => state.byId(waiting)!.waitingFor == ConversionWait.memory);

      held = panorama.reachedHold.stream.first;
      panorama.release();
      await held;

      expect(job(first).state, ConversionState.done);
      expect(job(second).state, ConversionState.generating);
      expect(job(waiting).state, ConversionState.waiting);
      expect(job(waiting).waitingFor, ConversionWait.memory);
      panorama.release();
      await allEnded();
      expect(job(waiting).state, ConversionState.done);
      expect(runs.kinds, [
        ConversionKind.panoramaFromPhoto,
        ConversionKind.panoramaFromPhoto,
        ConversionKind.sceneFromPhoto,
      ]);
    });

    test('alone on its lane, a job never waits for memory: its engine checks its own photo', () async {
      memory.available = 100 * 1024 * 1024;

      final id = queue().add([photo('salon.jpg')], kind: ConversionKind.sceneFromPhoto).single;
      await allEnded();

      expect(job(id).state, ConversionState.done);
    });

    test('a disk full on one lane pauses both: nothing new starts until Resume', () async {
      panorama = FakePanoramaEngine(holdStage: ImmersiveStage.upscale);
      final held = panorama.reachedHold.stream.first;
      output.failFinishOf['x.jpg'] = ImmersiveErrorCode.diskFull;

      final generated = queue().add([
        photo('a.jpg', kind: ConversionKind.panoramaFromPhoto),
        photo('b.jpg', kind: ConversionKind.panoramaFromPhoto),
      ], kind: ConversionKind.panoramaFromPhoto);
      await held;
      final scenes = queue().add([photo('x.jpg'), photo('y.jpg')], kind: ConversionKind.sceneFromPhoto);
      await until((state) => state.isPaused);

      expect(job(scenes[0]).error, ImmersiveErrorCode.diskFull);
      // The panorama under way goes to its end, the next one waits with the scene
      panorama.release();
      await until((state) => state.byId(generated[0])!.state.isEnded);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(job(generated[0]).state, ConversionState.done);
      expect(job(generated[1]).state, ConversionState.waiting);
      expect(job(scenes[1]).state, ConversionState.waiting);
      expect(current().hasWork, isTrue);

      final next = panorama.reachedHold.stream.first;
      queue().resume();
      await next;
      panorama.release();
      await allEnded();
      expect([
        for (final id in [...generated, ...scenes]) job(id).state,
      ], everyElement(ConversionState.done));
    });
  });

  group('the 3D version chained after its panorama', () {
    test('runs after the panorama, from the file it wrote, as a version of the photo', () async {
      final request = photo('salon.jpg', kind: ConversionKind.panoramaFromPhoto, turns: 1);
      final bytes = File(p.join(photos, 'salon.jpg')).readAsBytesSync();

      final ids = queue().add([request], kind: ConversionKind.panoramaFromPhoto, alsoStereo: true);
      expect(ids, hasLength(2));
      expect(job(ids[1]).kind, ConversionKind.stereoPanoramaFromPanorama);
      expect(job(ids[1]).parentId, ids[0]);
      expect(job(ids[1]).target?.fileName, 'salon_360_3D.jpg');
      expect([job(ids[1]).batchIndex, job(ids[1]).batchSize], [1, 1]);
      await allEnded();

      final generated = job(ids[0]);
      final relief = job(ids[1]);
      expect([generated.state, relief.state], everyElement(ConversionState.done));
      expect(generated.writtenPath, p.join(photos, 'salon_360.jpg'));
      expect(relief.writtenPath, p.join(photos, 'salon_360_3D.jpg'));
      expect(runs.kinds, [ConversionKind.panoramaFromPhoto, ConversionKind.stereoPanoramaFromPanorama]);
      final spec = stereo.jobs.single;
      expect(spec.source.path, generated.writtenPath);
      expect(spec.photo?.name, 'salon.jpg');
      expect(spec.photo?.sha1, _sumOf(bytes));
      expect(spec.original.sha1, _sumOf(bytes));
      expect(spec.quarterTurns, 1);
      final panoramaXmp = ImmersiveXmp.findIn(File(generated.writtenPath!).readAsBytesSync())! as PanoramaXmp;
      expect(spec.parent?.derivativeId, panoramaXmp.derivativeId);
      final written = ImmersiveXmp.findIn(File(relief.writtenPath!).readAsBytesSync())! as StereoPanoramaXmp;
      expect(written.sourceSha1, _sumOf(bytes));
      expect(written.sourceName, 'salon.jpg');
      expect(written.parentDerivativeId, panoramaXmp.derivativeId);
      expect(output.originals.last.sha1, _sumOf(bytes), reason: 'the writer tells the photo, not the panorama');
      expect(folder(), ['salon.jpg', 'salon_360.jpg', 'salon_360_3D.jpg']);
    });

    test(
      'asked by itself later ("Make the 3D version"), it is a version of the photo too, from that panorama',
      () async {
        final request = photo('salon.jpg', kind: ConversionKind.panoramaFromPhoto);
        final bytes = File(p.join(photos, 'salon.jpg')).readAsBytesSync();
        final made = queue().add([request], kind: ConversionKind.panoramaFromPhoto).single;
        await allEnded();
        final panoramaPath = job(made).writtenPath!;
        final panoramaXmp = ImmersiveXmp.findIn(File(panoramaPath).readAsBytesSync())! as PanoramaXmp;

        // The panorama chosen as the source, as the dialog hands it to the queue
        final id = queue().add([
          ConversionRequest(
            source: LocalFileSource(panoramaPath, hash: _dartSum),
            target: ConversionTarget.nextTo(panoramaPath, kind: ConversionKind.stereoPanoramaFromPanorama),
          ),
        ], kind: ConversionKind.stereoPanoramaFromPanorama).single;
        await allEnded();

        final relief = job(id);
        expect(relief.state, ConversionState.done);
        expect(relief.writtenPath, p.join(photos, 'salon_360_3D.jpg'));
        final spec = stereo.jobs.single;
        expect(spec.source.path, panoramaPath);
        expect(spec.photo?.name, 'salon.jpg');
        expect(spec.original.sha1, _sumOf(bytes));
        expect(spec.parent?.derivativeId, panoramaXmp.derivativeId);
        final written = ImmersiveXmp.findIn(File(relief.writtenPath!).readAsBytesSync())! as StereoPanoramaXmp;
        expect(written.sourceName, 'salon.jpg');
        expect(written.sourceSha1, _sumOf(bytes));
        expect(written.parentDerivativeId, panoramaXmp.derivativeId);
        expect(output.originals.last.sha1, _sumOf(bytes), reason: 'the writer tells the photo, not the panorama');
      },
    );

    test('a 360° photo of the user asked by itself stays its own original', () async {
      final request = photo('PANO_0001.jpg', kind: ConversionKind.stereoPanoramaFromPanorama);
      final bytes = File(p.join(photos, 'PANO_0001.jpg')).readAsBytesSync();
      final id = queue().add([request], kind: ConversionKind.stereoPanoramaFromPanorama).single;
      await allEnded();

      expect(job(id).state, ConversionState.done);
      final spec = stereo.jobs.single;
      expect(spec.photo, isNull);
      expect(spec.parent, isNull);
      expect(spec.original.sha1, _sumOf(bytes));
    });

    test('a panorama that failed skips its 3D version with that reason; Retry of the panorama runs both', () async {
      panorama = FakePanoramaEngine(failAt: ImmersiveStage.generating, failure: ImmersiveErrorCode.gpuOutOfMemory);

      final ids = queue().add(
        [photo('salon.jpg', kind: ConversionKind.panoramaFromPhoto)],
        kind: ConversionKind.panoramaFromPhoto,
        alsoStereo: true,
      );
      await allEnded();

      expect(job(ids[0]).error, ImmersiveErrorCode.gpuOutOfMemory);
      expect(job(ids[1]).state, ConversionState.skipped);
      expect(job(ids[1]).skipReason, ConversionSkipReason.parentNotMade);
      expect(current().hasWork, isFalse);
      expect(stereo.jobs, isEmpty);

      panorama = FakePanoramaEngine();
      container.invalidate(conversionToolsProvider);
      queue().retry(ids[0]);
      await allEnded();
      expect([job(ids[0]).state, job(ids[1]).state], everyElement(ConversionState.done));
      expect(job(ids[1]).skipReason, isNull);
    });

    test('a panorama cancelled while it waits skips its 3D version at once: nothing is left to wait for', () async {
      panorama = FakePanoramaEngine(holdStage: ImmersiveStage.generating);
      final held = panorama.reachedHold.stream.first;
      queue().add([photo('a.jpg', kind: ConversionKind.panoramaFromPhoto)], kind: ConversionKind.panoramaFromPhoto);
      await held;

      final ids = queue().add(
        [photo('salon.jpg', kind: ConversionKind.panoramaFromPhoto)],
        kind: ConversionKind.panoramaFromPhoto,
        alsoStereo: true,
      );
      queue().cancel(ids[0]);
      await until((state) => state.byId(ids[1])!.state.isEnded);

      expect(job(ids[0]).state, ConversionState.cancelled);
      expect(job(ids[1]).skipReason, ConversionSkipReason.parentNotMade);
      panorama.release();
      await allEnded();
      expect(current().hasWork, isFalse);
    });

    test('Cancel all skips the 3D versions with their reason; Retry of a panorama runs its 3D version again', () async {
      panorama = FakePanoramaEngine(holdStage: ImmersiveStage.generating);
      final held = panorama.reachedHold.stream.first;
      final ids = queue().add(
        [
          photo('a.jpg', kind: ConversionKind.panoramaFromPhoto),
          photo('b.jpg', kind: ConversionKind.panoramaFromPhoto),
        ],
        kind: ConversionKind.panoramaFromPhoto,
        alsoStereo: true,
      );
      await held;

      queue().cancelAll();
      // The panorama that waited, and its 3D version, at once
      expect(job(ids[2]).state, ConversionState.cancelled);
      expect(job(ids[3]).skipReason, ConversionSkipReason.parentNotMade);
      // The one being generated stops at its next check
      panorama.release();
      await allEnded();
      expect(job(ids[0]).state, ConversionState.cancelled);
      expect(job(ids[1]).state, ConversionState.skipped);
      expect(job(ids[1]).skipReason, ConversionSkipReason.parentNotMade);
      expect(stereo.jobs, isEmpty);

      panorama = FakePanoramaEngine();
      container.invalidate(conversionToolsProvider);
      queue().retry(ids[0]);
      await allEnded();
      expect([job(ids[0]).state, job(ids[1]).state], everyElement(ConversionState.done));
      expect(job(ids[1]).writtenPath, p.join(photos, 'a_360_3D.jpg'));
      expect([job(ids[2]).state, job(ids[3]).state], [ConversionState.cancelled, ConversionState.skipped]);
    });

    test('Cancel all while the panorama is renamed: it is kept, its 3D version is cancelled, never started', () async {
      final renaming = _HeldFinish(ConversionKind.panoramaFromPhoto);
      output = renaming;
      container = containerWith();
      final ids = queue().add(
        [photo('salon.jpg', kind: ConversionKind.panoramaFromPhoto)],
        kind: ConversionKind.panoramaFromPhoto,
        alsoStereo: true,
      );
      await renaming.reached.future;

      queue().cancelAll();
      renaming.hold.complete();
      await allEnded();

      expect(job(ids[0]).state, ConversionState.done);
      expect(job(ids[1]).state, ConversionState.cancelled);
      expect(stereo.jobs, isEmpty);
      expect(folder(), ['salon.jpg', 'salon_360.jpg']);

      // Its own Retry makes it from that panorama
      queue().retry(ids[1]);
      await allEnded();
      expect(job(ids[1]).state, ConversionState.done);
      expect(stereo.jobs.single.source.path, job(ids[0]).writtenPath);
    });

    test('a panorama skipped for the same settings gives its file to the 3D version', () async {
      final first = queue().add([
        photo('salon.jpg', kind: ConversionKind.panoramaFromPhoto),
      ], kind: ConversionKind.panoramaFromPhoto).single;
      await allEnded();

      final ids = queue().add(
        [photo('salon.jpg', kind: ConversionKind.panoramaFromPhoto)],
        kind: ConversionKind.panoramaFromPhoto,
        alsoStereo: true,
      );
      await allEnded();

      expect(job(ids[0]).skipReason, ConversionSkipReason.sameSettingsExists);
      expect(job(ids[1]).state, ConversionState.done);
      expect(stereo.jobs.single.source.path, job(first).writtenPath);
      expect(panorama.jobs, hasLength(1));
      expect(folder(), ['salon.jpg', 'salon_360.jpg', 'salon_360_3D.jpg']);
    });

    group('the same settings of a 3D version are those of its own panorama', () {
      /// "360° 3D panorama" of salon.jpg with [existing], the panorama made with [steps]
      Future<List<String>> panoramaAnd3D({
        ExistingVersionChoice existing = ExistingVersionChoice.skip,
        int steps = fakePanoramaSteps,
      }) async {
        engines = () => {
          ...fakeConversionEngines(scene: scene, stereoPanorama: stereo),
          ConversionKind.panoramaFromPhoto: ConversionEngine(
            engine: panorama,
            settingsKey: (_, turns) => fakePanoramaSettingsKey(turns, steps: steps),
            generator: fakePanoramaGenerator,
            steps: steps,
          ),
        };
        container.invalidate(conversionToolsProvider);
        final ids = queue().add(
          [photo('salon.jpg', kind: ConversionKind.panoramaFromPhoto)],
          kind: ConversionKind.panoramaFromPhoto,
          existing: existing,
          alsoStereo: true,
        );
        await allEnded();
        return ids;
      }

      StereoPanoramaXmp stereoAt(String name) =>
          ImmersiveXmp.findIn(File(p.join(photos, name)).readAsBytesSync())! as StereoPanoramaXmp;
      PanoramaXmp panoramaAt(String path) => ImmersiveXmp.findIn(File(path).readAsBytesSync())! as PanoramaXmp;

      test('Skip: a new panorama of the photo gets its own 3D version, the older one stays', () async {
        await panoramaAnd3D();
        final older = File(p.join(photos, 'salon_360_3D.jpg')).readAsBytesSync();

        // The settings of the panorama changed (another variant of the generator, a component updated)
        final ids = await panoramaAnd3D(steps: 28);

        final generated = job(ids[0]);
        final relief = job(ids[1]);
        expect(generated.writtenPath, p.join(photos, 'salon_360 (1).jpg'));
        expect(relief.state, ConversionState.done);
        expect(relief.skipReason, isNull);
        expect(relief.writtenPath, p.join(photos, 'salon_360_3D (1).jpg'));
        expect(stereoAt('salon_360_3D (1).jpg').parentDerivativeId, panoramaAt(generated.writtenPath!).derivativeId);
        expect(File(p.join(photos, 'salon_360_3D.jpg')).readAsBytesSync(), older);
        expect(stereo.jobs, hasLength(2));
      });

      test('Replace: the 3D version of the older panorama is kept, never taken by the new one', () async {
        await panoramaAnd3D();
        final olderPanorama = panoramaAt(p.join(photos, 'salon_360.jpg')).derivativeId;
        final older = File(p.join(photos, 'salon_360_3D.jpg')).readAsBytesSync();

        final ids = await panoramaAnd3D(steps: 28, existing: ExistingVersionChoice.replace);

        final relief = job(ids[1]);
        expect(relief.state, ConversionState.done);
        expect(relief.replaced, isFalse);
        expect(relief.writtenPath, p.join(photos, 'salon_360_3D (1).jpg'));
        expect(File(p.join(photos, 'salon_360_3D.jpg')).readAsBytesSync(), older);
        expect(stereoAt('salon_360_3D.jpg').parentDerivativeId, olderPanorama);
      });

      test(
        'a panorama skipped for a second one of the same settings gives that one, whose 3D version is made',
        () async {
          await panoramaAnd3D();
          // A second panorama of the same settings, without its 3D version
          final second = queue()
              .add(
                [photo('salon.jpg', kind: ConversionKind.panoramaFromPhoto)],
                kind: ConversionKind.panoramaFromPhoto,
                existing: ExistingVersionChoice.newVersion,
              )
              .single;
          await allEnded();
          final secondPath = job(second).writtenPath!;
          expect(secondPath, p.join(photos, 'salon_360 (1).jpg'));

          final ids = await panoramaAnd3D();

          // The neighbours are read in the order of their names: "salon_360 (1).jpg" first
          expect(job(ids[0]).skipReason, ConversionSkipReason.sameSettingsExists);
          expect(job(ids[0]).existingVersionPath, secondPath);
          final relief = job(ids[1]);
          expect(relief.state, ConversionState.done);
          expect(relief.writtenPath, p.join(photos, 'salon_360_3D (1).jpg'));
          expect(stereo.jobs.last.source.path, secondPath);
          expect(stereoAt('salon_360_3D (1).jpg').parentDerivativeId, panoramaAt(secondPath).derivativeId);
        },
      );
    });

    test('the 3D version of a 360° photo of the user runs alone, a version of that photo', () async {
      final request = photo('PANO_0001.jpg', kind: ConversionKind.stereoPanoramaFromPanorama);
      final bytes = File(p.join(photos, 'PANO_0001.jpg')).readAsBytesSync();

      final id = queue().add([request], kind: ConversionKind.stereoPanoramaFromPanorama).single;
      await allEnded();

      expect(job(id).writtenPath, p.join(photos, 'PANO_0001_3D.jpg'));
      expect(stereo.jobs.single.photo, isNull);
      expect(stereo.jobs.single.parent, isNull);
      expect(stereo.jobs.single.original.sha1, _sumOf(bytes));
    });
  });

  test('Make a new version of a panorama draws a new seed; the seed is never part of the same settings', () async {
    queue().add([photo('salon.jpg', kind: ConversionKind.panoramaFromPhoto)], kind: ConversionKind.panoramaFromPhoto);
    await allEnded();

    final skipped = queue().add([
      photo('salon.jpg', kind: ConversionKind.panoramaFromPhoto),
    ], kind: ConversionKind.panoramaFromPhoto).single;
    final made = queue()
        .add(
          [photo('salon.jpg', kind: ConversionKind.panoramaFromPhoto)],
          kind: ConversionKind.panoramaFromPhoto,
          existing: ExistingVersionChoice.newVersion,
        )
        .single;
    await allEnded();

    expect(job(skipped).skipReason, ConversionSkipReason.sameSettingsExists);
    expect(panorama.jobs.map((job) => job.seed), [11, 12]);
    expect(
      panorama.jobs.map((job) => (job.generator, job.steps)),
      everyElement((fakePanoramaGenerator, fakePanoramaSteps)),
    );
    final first = ImmersiveXmp.findIn(File(p.join(photos, 'salon_360.jpg')).readAsBytesSync())! as PanoramaXmp;
    final second = ImmersiveXmp.findIn(File(job(made).writtenPath!).readAsBytesSync())! as PanoramaXmp;
    expect([first.seed, second.seed], [11, 12]);
    expect(second.settingsKey, first.settingsKey);
    expect(second.derivativeId, isNot(first.derivativeId));
  });

  group('the time left', () {
    test('a generation tells step k of n and its own time left, the steps after it come from the timings', () async {
      final engine = _Scripted([
        const ImmersiveProgress(ImmersiveStage.reading, 0),
        const ImmersiveProgress(ImmersiveStage.loadingModels, 50),
        const ImmersiveProgress(ImmersiveStage.generating, 300, step: 12, steps: 20, remaining: Duration(seconds: 96)),
      ]);
      engines = () => {
        ConversionKind.panoramaFromPhoto: ConversionEngine(
          engine: engine,
          settingsKey: (_, _) => null,
          generator: fakePanoramaGenerator,
          steps: fakePanoramaSteps,
        ),
      };
      container = containerWith();

      final id = queue().add([
        photo('salon.jpg', kind: ConversionKind.panoramaFromPhoto),
      ], kind: ConversionKind.panoramaFromPhoto).single;
      await engine.told.future;
      await until((state) => state.byId(id)!.step == 12);

      final after = [
        ImmersiveStage.seam,
        ImmersiveStage.upscale,
        ImmersiveStage.pasteBack,
        ImmersiveStage.encoding,
        ImmersiveStage.writing,
      ].map((stage) => aiDefaultTimings['panoramaFromPhoto']![stage.name]!).fold(0, (sum, millis) => sum + millis);
      final running = job(id);
      expect(running.state, ConversionState.generating);
      expect((running.step, running.steps), (12, 20));
      expect(running.remaining, const Duration(seconds: 96) + Duration(milliseconds: after));
      expect(current().generating?.id, id);

      queue().cancel(id);
      engine.release();
      await allEnded();
      expect(current().generating, isNull);
    });

    test('a step that tells no time is estimated from the timings and the time it has taken so far', () async {
      final engine = _Scripted([
        const ImmersiveProgress(ImmersiveStage.reading, 0),
        const ImmersiveProgress(ImmersiveStage.geometry, 100),
      ]);
      engines = () => {ConversionKind.sceneFromPhoto: ConversionEngine(engine: engine, settingsKey: (_, _) => null)};
      await settings.update(
        (kept) => kept.copyWith(
          timings: {
            'sceneFromPhoto': {
              'geometry': 4000,
              'layers': 1000,
              'inpaint': 6000,
              'mesh': 500,
              'textures': 1500,
              'writing': 200,
            },
          },
        ),
      );
      container = containerWith();

      final id = queue().add([photo('salon.jpg')], kind: ConversionKind.sceneFromPhoto).single;
      await engine.told.future;
      await until((state) => state.byId(id)!.state == ConversionState.geometry);
      expect(job(id).remaining, const Duration(milliseconds: 4000 + 1000 + 6000 + 500 + 1500 + 200));

      // 3 s later the geometry tells its progress
      clock = clock.add(const Duration(seconds: 3));
      engine.tell(const ImmersiveProgress(ImmersiveStage.geometry, 200));
      expect(job(id).remaining, const Duration(milliseconds: 1000 + 1000 + 6000 + 500 + 1500 + 200));
      // Longer than its timing: that step counts for nothing more
      clock = clock.add(const Duration(seconds: 10));
      engine.tell(const ImmersiveProgress(ImmersiveStage.geometry, 300));
      expect(job(id).remaining, const Duration(milliseconds: 1000 + 6000 + 500 + 1500 + 200));
      // The next step starts its own count
      engine.tell(const ImmersiveProgress(ImmersiveStage.layers, 400));
      clock = clock.add(const Duration(milliseconds: 400));
      engine.tell(const ImmersiveProgress(ImmersiveStage.layers, 450));
      expect(job(id).remaining, const Duration(milliseconds: 600 + 6000 + 500 + 1500 + 200));
      expect((job(id).step, job(id).steps), (null, null));

      queue().cancel(id);
      engine.release();
      await allEnded();
    });

    test('the times of a job done are kept for the next ones, not those of a job that failed', () async {
      final id = queue().add([photo('salon.jpg')], kind: ConversionKind.sceneFromPhoto).single;
      await allEnded();
      for (var wait = 0; wait < 100 && (await settings.read()).timings.isEmpty; wait++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(job(id).state, ConversionState.done);
      final kept = (await settings.read()).timings['sceneFromPhoto']!;
      expect(kept.keys, containsAll(['reading', 'geometry', 'inpaint', 'writing']));
      // The fake takes no time: the mean with the timing of the design
      expect(kept['geometry'], lessThan(aiDefaultTimings['sceneFromPhoto']!['geometry']!));

      panorama = FakePanoramaEngine(failAt: ImmersiveStage.upscale);
      container.invalidate(conversionToolsProvider);
      queue().add([photo('b.jpg', kind: ConversionKind.panoramaFromPhoto)], kind: ConversionKind.panoramaFromPhoto);
      await allEnded();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((await settings.read()).timings.keys, ['sceneFromPhoto']);
    });

    test('the time a job of each kind takes, before any measure', () {
      for (final kind in ConversionKind.values) {
        expect(kind.expectedDuration(const AiTimings()), greaterThan(Duration.zero), reason: '$kind');
      }
      expect(ConversionKind.sceneFromPhoto.expectedDuration(const AiTimings()), lessThan(const Duration(seconds: 30)));
      expect(
        ConversionKind.panoramaFromPhoto.expectedDuration(const AiTimings()),
        lessThan(const Duration(minutes: 5)),
      );
    });
  });
}
