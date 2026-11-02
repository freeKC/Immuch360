// The splat scenes in the queue (lot SP6): one job for a whole selection on the lane of the graphics card, its spec
// given its photos or its video, its settings, its .ply and the times of its steps on this computer; the card asked
// with the need of a splat scene; the time left the engine tells taken as it is; the .ply put beside the .spz under the
// same name; both .part files dropped when the scene is not made; the times kept under "splatSceneVideo" for a video;
// Retry. Then end to end on the fakes: the engine of the app (SplatEngine) with the preparation of the app (the photos
// of lot SP5, the frames from a synthetic source) and the fake COLMAP and Brush compiled as programs, through the
// queue: the .spz written next to the photos and accepted by the probe of the app, Cancel at every step within a
// second, Retry from the poses after a training that failed.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/splat_members.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/gpu/gpu_budget.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/splat/brush_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/colmap_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_engine.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_images.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_work_folder.dart';
import 'package:immich_mobile/desktop/ai/splat/video_frames.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_conversion_output.dart';
import '../fakes/fake_gpu_probe.dart';
import '../fakes/fake_immersive_engine.dart';
import '../fakes/fake_panorama_engine.dart';
import '../splat/splat_input_support.dart';

const _gib = 1024 * 1024 * 1024;
const _mib = 1024 * 1024;

final _colmap = Platform.environment['IMMUCH360_FAKE_COLMAP'] ?? '';
final _brush = Platform.environment['IMMUCH360_FAKE_BRUSH'] ?? '';
final _launcher = Platform.environment['IMMUCH360_RUN_LAUNCHER'];

Object _skipFakes() => _colmap.isEmpty || _brush.isEmpty
    ? 'IMMUCH360_FAKE_COLMAP and IMMUCH360_FAKE_BRUSH name no programs'
    : (!Platform.isWindows && (_launcher == null || _launcher!.isEmpty)
          ? 'IMMUCH360_RUN_LAUNCHER names no launcher'
          : false);

class _Roomy implements MemoryProbe {
  const _Roomy();

  @override
  MemoryFacts read() => const MemoryFacts(physical: 16 * 1024 * _mib, available: 12 * 1024 * _mib);
}

/// The RTX 4060 with [free] bytes free
GpuReport _rtxWith(int free) => GpuReport(
  adapters: [
    GpuAdapter(
      name: 'NVIDIA GeForce RTX 4060 Laptop GPU',
      kind: GpuKind.discrete,
      localMemory: 8188 * _mib,
      vendorId: 0x10de,
      deviceId: 0x28a0,
      budget: 7800 * _mib,
      usage: 7800 * _mib - free,
      apiVersion: '1.4.312',
    ),
  ],
);

/// An engine of the splat scenes that records the spec it is given and tells what the test says
class _ScriptedSplat implements ImmersiveEngine {
  final specs = <SplatJob>[];
  final _gate = <Completer<void>>[];
  ImmersiveResult Function(SplatJob job) result = _made;

  /// Holds the next job in its training until [release]
  var hold = false;

  static ImmersiveResult _made(SplatJob job) {
    File(job.partPath).writeAsBytesSync(Uint8List.fromList([1, 2, 3]));
    final ply = job.plyPartPath;
    if (ply != null) {
      File(ply).writeAsBytesSync(Uint8List.fromList([4, 5]));
    }
    return ImmersiveResult.made(
      details: SplatResultDetails(
        gaussians: 150000,
        images: 150,
        placed: 150,
        subject: job.settings.subject,
        scale: 0.45,
        fromVideo: job.isVideo,
        plyBytes: ply == null ? null : 2,
      ),
      bytesWritten: 3,
      stageTimes: const {
        ImmersiveStage.features: Duration(seconds: 16),
        ImmersiveStage.training: Duration(seconds: 400),
      },
    );
  }

  void release() {
    for (final gate in _gate) {
      if (!gate.isCompleted) {
        gate.complete();
      }
    }
  }

  @override
  Future<ImmersiveResult> run(
    covariant SplatJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    specs.add(job);
    onProgress?.call(const ImmersiveProgress(ImmersiveStage.features, 120, step: 87, steps: 150));
    onProgress?.call(
      const ImmersiveProgress(
        ImmersiveStage.training,
        500,
        step: 12400,
        steps: 20000,
        remaining: Duration(minutes: 3, seconds: 7),
      ),
    );
    if (hold) {
      final gate = Completer<void>();
      _gate.add(gate);
      while (!gate.isCompleted && !cancel.isCancelled) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (cancel.isCancelled) {
        return const ImmersiveResult.failed(ImmersiveErrorCode.cancelled);
      }
    }
    return result(job);
  }

  @override
  Future<void> dispose() async {}
}

/// A video of 30 s, every frame sharp, its JPEG [jpeg]
class _Video implements SplatFrameSource {
  _Video(this.jpeg, {this.decoding = Duration.zero});

  final Uint8List jpeg;

  /// How long a frame takes to come, as a decoder
  final Duration decoding;

  @override
  Future<SplatVideoFacts> open(String resource) async =>
      const SplatVideoFacts(duration: Duration(seconds: 30), fps: 30);

  @override
  Future<SplatFrame?> frameAt(Duration time) async {
    await Future<void>.delayed(decoding);
    return _VideoFrame(time, jpeg);
  }

  @override
  Future<void> close() async {}
}

class _VideoFrame implements SplatFrame {
  _VideoFrame(this.time, this.jpeg);

  @override
  final Duration time;
  final Uint8List jpeg;

  @override
  int get width => 64;
  @override
  int get height => 48;
  @override
  double get sharpness => 100;

  @override
  Future<({int width, int height})> writeJpeg(String path) async {
    await File(path).writeAsBytes(jpeg);
    return (width: 64, height: 48);
  }
}

void main() {
  late Directory folder;
  late ProviderContainer container;
  late FakeConversionOutput output;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('conversion_queue_splat_test_');
    output = FakeConversionOutput();
  });
  tearDown(() {
    for (var k = 0; k < 20; k++) {
      try {
        folder.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        sleep(const Duration(milliseconds: 100));
      }
    }
  });

  ProviderContainer containerWith(
    ImmersiveEngine splat, {
    GpuBudget? budget,
    DesktopAiSettingsStore? settings,
    FakePanoramaEngine? panorama,
  }) {
    final made = ProviderContainer(
      overrides: [
        conversionToolsProvider.overrideWith(
          (ref) => ConversionTools(
            engine: FakeImmersiveEngine(),
            engines: {
              ConversionKind.splatScene: ConversionEngine(engine: splat, settingsKey: (source, turns) => null),
              if (panorama != null)
                ConversionKind.panoramaFromPhoto: ConversionEngine(
                  engine: panorama,
                  settingsKey: (source, turns) => null,
                  generator: 'flux2-klein-base-4b-q4_0',
                  steps: 20,
                ),
            },
            output: output,
            finder: ExistingVersionFinder(),
            creatorTool: 'Immuch360 Desktop 3.3.0 (windows)',
            memory: const _Roomy(),
            gpuBudget: budget,
            gpuRecheck: const Duration(milliseconds: 30),
            settings: settings,
          ),
        ),
      ],
    );
    addTearDown(made.dispose);
    return made;
  }

  ConversionQueueNotifier queue() => container.read(conversionQueueProvider.notifier);
  ConversionJob job(String id) => container.read(conversionQueueProvider).byId(id)!;

  Future<void> until(
    bool Function(ConversionQueueState state) test, {
    Duration within = const Duration(seconds: 30),
  }) async {
    if (test(container.read(conversionQueueProvider))) {
      return;
    }
    final reached = Completer<void>();
    final subscription = container.listen(conversionQueueProvider, (_, next) {
      if (!reached.isCompleted && test(next)) {
        reached.complete();
      }
    });
    try {
      await reached.future.timeout(within);
    } finally {
      subscription.close();
    }
  }

  /// [count] photos of the room, each a step further, as a camera writes them, taken a second apart
  List<String> photos(int count, {int width = 96, int height = 72}) {
    final room = Directory(p.join(folder.path, 'Salon'))..createSync(recursive: true);
    return [
      for (var k = 0; k < count; k++)
        (File(
          p.join(room.path, 'IMG_${2000 + k}.jpg'),
        )..writeAsBytesSync(testJpeg(texturedRgba(width, height, shift: k * 2), width, height))).path,
    ];
  }

  /// A splat scene of [paths], named "salon", next to them
  String addSplat(List<String> paths, {bool video = false, SplatSettings settings = const SplatSettings()}) =>
      queue().addSplat(
        lead: LocalFileSource(paths.first),
        selection: SplatSelection(
          members: [
            for (final (index, path) in paths.indexed)
              SourceSplatMember(LocalFileSource(path), taken: DateTime.utc(2026, 11, 1, 10, 0, index)),
          ],
          settings: settings,
        ),
        target: ConversionTarget(folder: p.dirname(paths.first), fileName: splatFileNameFor('salon')),
        video: video,
      );

  group('the queue', () {
    test('one job on the lane of the graphics card, its spec given its photos, settings, .ply and timings', () async {
      final engine = _ScriptedSplat();
      container = containerWith(engine);
      final paths = photos(3);
      final id = addSplat(paths, settings: const SplatSettings(subject: SplatSubject.object, keepPly: true));
      await until((state) => job(id).state.isEnded);

      expect(job(id).state, ConversionState.done, reason: '${job(id).error} ${job(id).message}');
      expect((job(id).kind, job(id).kind.lane, job(id).batchSize), (ConversionKind.splatScene, ConversionLane.gpu, 1));
      final spec = engine.specs.single;
      expect(spec.members.map((member) => member.name), ['IMG_2000.jpg', 'IMG_2001.jpg', 'IMG_2002.jpg']);
      expect((spec.isVideo, spec.settings.subject, spec.settings.keepPly), (false, SplatSubject.object, true));
      expect(spec.lead.name, 'IMG_2000.jpg');
      expect(spec.plyPartPath, isNotNull);
      // The times of the steps of a job of photos, the defaults of this computer
      expect(spec.timings[ImmersiveStage.training], const Duration(milliseconds: 450000));
      expect(spec.timings.keys, containsAll(ImmersiveStage.splatOf(video: false)));
      expect(job(id).writtenPath, p.join(p.dirname(paths.first), 'salon_splat.spz'));
      expect(File(p.join(p.dirname(paths.first), 'salon_splat.ply')).readAsBytesSync(), [4, 5]);
      expect((job(id).details! as SplatResultDetails).plyBytes, 2);
      expect(output.discarded, isEmpty);
    });

    test('the time left is the one the engine tells, as it is; the step and its count with it', () async {
      final engine = _ScriptedSplat()..hold = true;
      container = containerWith(engine);
      final id = addSplat(photos(3));
      await until((state) => job(id).state == ConversionState.training);

      expect(job(id).remaining, const Duration(minutes: 3, seconds: 7));
      expect((job(id).step, job(id).steps), (12400, 20000));
      expect(container.read(conversionQueueProvider).splatting?.id, id);
      engine.release();
      await until((state) => job(id).state.isEnded);
      expect(container.read(conversionQueueProvider).splatting, isNull);
    });

    test('the .ply of a scene saved as "name (1)" goes beside it under the same name', () async {
      container = containerWith(_ScriptedSplat());
      final paths = photos(3);
      File(p.join(p.dirname(paths.first), 'salon_splat.spz')).writeAsBytesSync([9]);
      final id = addSplat(paths, settings: const SplatSettings(keepPly: true));
      await until((state) => job(id).state.isEnded);

      expect(job(id).writtenPath, p.join(p.dirname(paths.first), 'salon_splat (1).spz'));
      expect(File(p.join(p.dirname(paths.first), 'salon_splat (1).ply')).existsSync(), isTrue);
    });

    test('a .ply that cannot be saved: the scene is done all the same, the .ply said missing', () async {
      container = containerWith(_ScriptedSplat());
      output.failCompanion = ImmersiveErrorCode.diskFull;
      final id = addSplat(photos(3), settings: const SplatSettings(keepPly: true));
      await until((state) => job(id).state.isEnded);

      expect(job(id).state, ConversionState.done);
      expect(job(id).message, contains('.ply could not be saved'));
      expect((job(id).details! as SplatResultDetails).plyBytes, isNull);
      expect(output.discarded, hasLength(1), reason: 'the .part of the .ply');
    });

    test('a scene not made drops its .spz and its .ply', () async {
      final engine = _ScriptedSplat()
        ..result = (job) => const ImmersiveResult.failed(ImmersiveErrorCode.trainingFailed, message: 'panic');
      container = containerWith(engine);
      final id = addSplat(photos(3), settings: const SplatSettings(keepPly: true));
      await until((state) => job(id).state.isEnded);

      expect((job(id).state, job(id).error), (ConversionState.failed, ImmersiveErrorCode.trainingFailed));
      // The job shows failed before its .part files are deleted, one after the other
      for (var k = 0; k < 100 && output.discarded.length < 2; k++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(output.discarded, hasLength(2));
      expect(output.discarded.every((path) => !File(path).existsSync()), isTrue);
    });

    test('Retry runs the same selection again', () async {
      var runs = 0;
      final engine = _ScriptedSplat()
        ..result = (job) => ++runs == 1
            ? const ImmersiveResult.failed(ImmersiveErrorCode.trainingFailed, message: 'panic')
            : _ScriptedSplat._made(job);
      container = containerWith(engine);
      final id = addSplat(photos(3));
      await until((state) => job(id).state.isEnded);
      queue().retry(id);
      await until((state) => job(id).state == ConversionState.done);

      expect(engine.specs, hasLength(2));
      expect(identical(engine.specs[0].members, engine.specs[1].members), isTrue);
    });

    test('a video: its times kept under splatSceneVideo, those of the photos untouched', () async {
      final store = DesktopAiSettingsStore(settingsDirectory: () async => folder);
      final engine = _ScriptedSplat();
      container = containerWith(engine, settings: store);
      final id = addSplat(photos(1), video: true);
      await until((state) => job(id).state.isEnded);

      expect(job(id).fromVideo, isTrue);
      expect(engine.specs.single.isVideo, isTrue);
      expect(engine.specs.single.timings[ImmersiveStage.training], const Duration(milliseconds: 306000));
      final timings = (await store.read()).timings;
      expect(timings['splatSceneVideo']?['training'], 400000);
      expect(timings['splatScene'], isNull);
    });

    test('the card asked with the need of a splat scene: 3 GiB free let it start where a panorama waits', () async {
      final engine = _ScriptedSplat();
      final panorama = FakePanoramaEngine();
      container = containerWith(
        engine,
        panorama: panorama,
        budget: GpuBudget(probe: () async => _rtxWith(3 * 1024 * _mib)),
      );
      final pano = File(p.join(folder.path, 'beach.jpg'))..writeAsBytesSync(List.filled(64, 7));
      final panoId = queue().add([
        ConversionRequest(source: LocalFileSource(pano.path), target: ConversionTarget.nextTo(pano.path)),
      ], kind: ConversionKind.panoramaFromPhoto).single;
      await until((state) => job(panoId).waitingFor == ConversionWait.graphicsMemory);
      queue().cancel(panoId);
      final id = addSplat(photos(3));
      await until((state) => job(id).state.isEnded);

      expect(job(id).state, ConversionState.done, reason: '${job(id).error} ${job(id).message}');
    });

    test('integrated graphics alone: the scene fails, said with the reason of the splat scenes', () async {
      container = containerWith(
        _ScriptedSplat(),
        budget: GpuBudget(probe: () async => FakeGpuReports.integratedOnly, integratedAllowed: () async => true),
      );
      final id = addSplat(photos(3));
      await until((state) => job(id).state.isEnded);

      expect(
        (job(id).error, job(id).message),
        (ImmersiveErrorCode.gpuUnavailable, AiGateReason.splatGpuIntegrated.name),
      );
    });
  });

  group('end to end on the fakes, through the queue', () {
    late Directory work;
    late Map<String, String> colmapEnvironment;
    late Map<String, String> brushEnvironment;

    setUp(() {
      work = Directory(p.join(folder.path, 'work'));
      colmapEnvironment = {'IMMUCH360_FAKE_COLMAP_MODE': 'ok', 'IMMUCH360_FAKE_COLMAP_STEP_MS': '0'};
      brushEnvironment = {'IMMUCH360_FAKE_BRUSH_MODE': 'ok', 'IMMUCH360_FAKE_BRUSH_STEP_MS': '0'};
    });

    const rtx = GpuAdapter(
      name: 'NVIDIA GeForce RTX 4060 Laptop GPU',
      kind: GpuKind.discrete,
      localMemory: 8 * _gib,
      vendorId: 0x10DE,
      deviceId: 0x28A0,
      driverVersion: '616.56',
      vulkanIndex: 0,
    );

    ProviderContainer realContainer({DesktopAiSettingsStore? settings, Duration decoding = Duration.zero}) {
      final runner = ManagedProcessRunner(linuxLauncher: _launcher);
      final engine = SplatEngine(
        images: appSplatImages(frameSource: () => _Video(testJpeg(texturedRgba(64, 48), 64, 48), decoding: decoding)),
        colmap: ColmapRunner(
          runner: runner,
          colmap: _colmap,
          memory: const _Roomy(),
          processors: 8,
          environment: colmapEnvironment,
        ),
        brush: BrushRunner(
          runner: runner,
          brush: _brush,
          cardCheck: () async => const BrushCardReady(rtx, GpuReport(adapters: [rtx])),
          cacheRoot: Directory(p.join(folder.path, 'brush-cache')),
          environment: brushEnvironment,
        ),
        roots: [SplatWorkRoot(work)],
      );
      return containerWith(
        engine,
        budget: GpuBudget(probe: () async => _rtxWith(6 * _gib)),
        settings: settings,
      );
    }

    const quick = SplatSettings(steps: 1000, maxGaussians: 3000, keepPly: true);

    test(
      '24 photos: the .spz next to them, accepted by the probe of the app, its .ply beside, its times kept',
      () async {
        final store = DesktopAiSettingsStore(settingsDirectory: () async => Directory(p.join(folder.path, 'settings')));
        container = realContainer(settings: store);
        final paths = photos(24);
        final id = addSplat(paths, settings: quick);
        final states = <ConversionState>[];
        container.listen(conversionQueueProvider, (_, next) {
          final state = next.byId(id)?.state;
          if (state != null && (states.isEmpty || states.last != state)) {
            states.add(state);
          }
        });
        await until((state) => job(id).state.isEnded, within: const Duration(minutes: 2));

        expect(job(id).state, ConversionState.done, reason: '${job(id).error} ${job(id).message}');
        final spz = File(job(id).writtenPath!);
        expect(p.basename(spz.path), 'salon_splat.spz');
        final bytes = spz.readAsBytesSync();
        final head = probeSplatHead(
          Uint8List.sublistView(bytes, 0, bytes.length.clamp(0, splatHeadBytes)),
          bytes.length,
        );
        expect(head, isA<SplatHead>().having((head) => head.formatVersion, 'version', 2));
        expect(File(p.join(p.dirname(spz.path), 'salon_splat.ply')).existsSync(), isTrue);
        final details = job(id).details! as SplatResultDetails;
        expect((details.gaussians, details.images, details.placed), (2000, 24, 24));
        expect(
          states,
          containsAllInOrder([
            ConversionState.photos,
            ConversionState.features,
            ConversionState.matching,
            ConversionState.mapping,
            ConversionState.training,
            ConversionState.writing,
            ConversionState.done,
          ]),
        );
        final timings = (await store.read()).timings['splatScene']!;
        expect(timings.keys, containsAll(['photos', 'features', 'matching', 'mapping', 'training', 'splatCopy']));
        expect(work.listSync(), isEmpty, reason: 'the work folder goes with the scene made');
      },
      skip: _skipFakes(),
    );

    test('a video: its frames from the source of the app, one camera, the scene made', () async {
      container = realContainer();
      final video = File(p.join(folder.path, 'walk.mp4'))..writeAsBytesSync(List.filled(1024, 1));
      final id = queue().addSplat(
        lead: LocalFileSource(video.path),
        selection: SplatSelection(members: [SourceSplatMember(LocalFileSource(video.path))], settings: quick),
        target: ConversionTarget(folder: folder.path, fileName: splatFileNameFor('walk')),
        video: true,
      );
      await until((state) => job(id).state.isEnded, within: const Duration(minutes: 2));

      expect(job(id).state, ConversionState.done, reason: '${job(id).error} ${job(id).message}');
      expect((job(id).details! as SplatResultDetails).fromVideo, isTrue);
      expect((job(id).details! as SplatResultDetails).images, 150);
    }, skip: _skipFakes());

    test('a video of one member: the time of its frames kept under splatSceneVideo as they went', () async {
      final store = DesktopAiSettingsStore(settingsDirectory: () async => Directory(p.join(folder.path, 'settings')));
      // 600 candidates of 3 ms each to decode
      container = realContainer(settings: store, decoding: const Duration(milliseconds: 3));
      final video = File(p.join(folder.path, 'walk.mp4'))..writeAsBytesSync(List.filled(1024, 1));
      final watch = Stopwatch()..start();
      final id = queue().addSplat(
        lead: LocalFileSource(video.path),
        selection: SplatSelection(members: [SourceSplatMember(LocalFileSource(video.path))], settings: quick),
        target: ConversionTarget(folder: folder.path, fileName: splatFileNameFor('walk')),
        video: true,
      );
      await until((state) => job(id).state.isEnded, within: const Duration(minutes: 2));
      watch.stop();

      expect(job(id).state, ConversionState.done, reason: '${job(id).error} ${job(id).message}');
      // 150 frames taken, the 150 the times are kept for: what they took, within the time of the whole job
      final frames = (await store.read()).timings['splatSceneVideo']!['frames']!;
      expect(frames, inInclusiveRange(1, watch.elapsedMilliseconds));
    }, skip: _skipFakes());

    group('Cancel from the queue within a second', () {
      for (final at in [
        ConversionState.photos,
        ConversionState.features,
        ConversionState.matching,
        ConversionState.mapping,
        ConversionState.training,
      ]) {
        test(at.name, () async {
          colmapEnvironment['IMMUCH360_FAKE_COLMAP_MODE'] = 'slow';
          colmapEnvironment['IMMUCH360_FAKE_COLMAP_STEP_MS'] = '100';
          brushEnvironment['IMMUCH360_FAKE_BRUSH_MODE'] = 'slow';
          brushEnvironment['IMMUCH360_FAKE_BRUSH_STEP_MS'] = '300';
          container = realContainer();
          // Larger photos for the preparation to last; 60 for the matching to count 4 blocks
          final paths = at == ConversionState.photos
              ? photos(60, width: 800, height: 600)
              : photos(at == ConversionState.matching ? 60 : 24);
          final id = addSplat(paths, settings: const SplatSettings(steps: 4000, maxGaussians: 3000));
          await until((state) => job(id).state == at && (job(id).step ?? 0) >= 2, within: const Duration(minutes: 2));
          final watch = Stopwatch()..start();
          queue().cancel(id);
          await until((state) => job(id).state.isEnded);
          watch.stop();

          expect(job(id).state, ConversionState.cancelled, reason: '${job(id).error} ${job(id).message}');
          expect(watch.elapsed, lessThan(const Duration(seconds: 1)), reason: '${at.name}: ${watch.elapsed}');
          expect(output.discarded, hasLength(1), reason: 'the .part of the .spz');
        }, skip: _skipFakes());
      }

      test('frames', () async {
        // 600 candidates of a video of 30 s, 20 ms each to decode: some 12 s of frames
        container = realContainer(decoding: const Duration(milliseconds: 20));
        final video = File(p.join(folder.path, 'walk.mp4'))..writeAsBytesSync(List.filled(1024, 1));
        final id = queue().addSplat(
          lead: LocalFileSource(video.path),
          selection: SplatSelection(members: [SourceSplatMember(LocalFileSource(video.path))], settings: quick),
          target: ConversionTarget(folder: folder.path, fileName: splatFileNameFor('walk')),
          video: true,
        );
        await until(
          (state) => job(id).state == ConversionState.frames && (job(id).step ?? 0) >= 2,
          within: const Duration(minutes: 2),
        );
        final watch = Stopwatch()..start();
        queue().cancel(id);
        await until((state) => job(id).state.isEnded);
        watch.stop();

        expect(job(id).state, ConversionState.cancelled, reason: '${job(id).error} ${job(id).message}');
        expect(watch.elapsed, lessThan(const Duration(seconds: 1)), reason: 'frames: ${watch.elapsed}');
        expect(work.listSync(), isEmpty, reason: 'nothing kept before the poses');
      }, skip: _skipFakes());
    });

    test('a scene made whose file cannot be saved keeps its poses: Retry trains again without COLMAP', () async {
      final pid = File(p.join(folder.path, 'colmap.pid'));
      container = realContainer();
      final paths = photos(24);
      // The destination refuses the file once, as a disk full or a share gone
      output.failFinishOf[p.basename(paths.first)] = ImmersiveErrorCode.diskFull;
      final id = addSplat(paths, settings: quick);
      await until((state) => job(id).state.isEnded, within: const Duration(minutes: 2));
      expect(job(id).error, ImmersiveErrorCode.diskFull);
      expect(work.listSync().whereType<Directory>(), hasLength(1), reason: 'the poses and the training kept');

      colmapEnvironment['IMMUCH360_FAKE_COLMAP_PID'] = pid.path;
      final states = <ConversionState>{};
      container.listen(conversionQueueProvider, (_, next) => states.add(next.byId(id)!.state));
      queue().retry(id);
      await until((state) => job(id).state.isEnded, within: const Duration(minutes: 2));

      expect(job(id).state, ConversionState.done, reason: '${job(id).error} ${job(id).message}');
      expect(pid.existsSync(), isFalse, reason: 'COLMAP did not run again');
      expect(states, isNot(contains(ConversionState.features)));
      expect(work.listSync(), isEmpty, reason: 'the work folder goes once the file is saved');
    }, skip: _skipFakes());

    test('Retry from the poses after a training that failed: COLMAP not run again', () async {
      brushEnvironment['IMMUCH360_FAKE_BRUSH_MODE'] = 'fail';
      final pid = File(p.join(folder.path, 'colmap.pid'));
      container = realContainer();
      final id = addSplat(photos(24), settings: quick);
      await until((state) => job(id).state.isEnded, within: const Duration(minutes: 2));
      expect(job(id).error, ImmersiveErrorCode.trainingFailed);
      expect(work.listSync().whereType<Directory>(), hasLength(1));

      brushEnvironment['IMMUCH360_FAKE_BRUSH_MODE'] = 'ok';
      colmapEnvironment['IMMUCH360_FAKE_COLMAP_PID'] = pid.path;
      final states = <ConversionState>{};
      container.listen(conversionQueueProvider, (_, next) => states.add(next.byId(id)!.state));
      queue().retry(id);
      await until((state) => job(id).state.isEnded, within: const Duration(minutes: 2));

      expect(job(id).state, ConversionState.done, reason: '${job(id).error} ${job(id).message}');
      expect(pid.existsSync(), isFalse, reason: 'COLMAP did not run again');
      expect(states, isNot(contains(ConversionState.features)));
      expect(states, contains(ConversionState.training));
    }, skip: _skipFakes());
  });
}
