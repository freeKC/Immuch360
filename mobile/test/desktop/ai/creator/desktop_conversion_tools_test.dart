// The tools the queue runs with on a computer: the writer of lot A5b behind the queue (the partial file of the check of
// the dialog taken over by its job, the one no job took deleted, the refusals of the system as the codes of the queue,
// a disk full at the rename that still pauses it, the guard of the album of the versions before the final name), the
// versions the index of the folder library knows, and the engine made from the components installed when a job runs.

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:path/path.dart' as p;

import '../../library/library_fixtures.dart';
import '../../library/library_test_support.dart';
import '../fakes/fake_conversion_engines.dart';
import '../fakes/fake_gpu_probe.dart';
import '../fakes/fake_immersive_engine.dart';
import '../fakes/fake_scene_engine.dart';
import '../fakes/recording_creator_files.dart';
import '../library/version_fixtures.dart';

/// The code of a disk full and of a refusal on this system, as writeFailureOf reads them
final _diskFull = OSError('No space left on device', Platform.isWindows ? 112 : 28);
final _denied = OSError('Permission denied', Platform.isWindows ? 5 : 13);

void main() {
  late Directory root;
  late String photos;
  late RecordingCreatorFiles files;
  late SafeWriter writer;
  late SafeWriterOutput output;
  late _Engines engines;
  late ProviderContainer container;
  late bool libraryReady;
  late List<String> guarded;

  setUp(() {
    root = Directory.systemTemp.createTempSync('desktop_conversion_tools');
    photos = p.join(root.path, 'photos');
    Directory(photos).createSync();
    final support = Directory(p.join(root.path, 'support'))..createSync();
    files = RecordingCreatorFiles();
    writer = SafeWriter(
      files: files,
      journal: InflightJournal(settingsDirectory: () async => support),
      processId: 4242,
    );
    libraryReady = true;
    guarded = [];
    output = SafeWriterOutput(
      writer: writer,
      mayWriteInto: (folder) async {
        guarded.add(folder);
        return libraryReady;
      },
    );
    engines = _Engines();
    container = ProviderContainer(
      overrides: [
        conversionToolsProvider.overrideWithValue(
          ConversionTools(
            engine: engines,
            output: output,
            finder: ExistingVersionFinder(),
            creatorTool: aiCreatorTool('3.3.0', system: 'linux'),
            software: aiSoftware('3.3.0'),
          ),
        ),
      ],
    );
    container.listen(conversionQueueProvider, (_, next) => dropUntakenParts(output, next));
  });

  tearDown(() {
    container.dispose();
    root.deleteSync(recursive: true);
  });

  ConversionQueueNotifier queue() => container.read(conversionQueueProvider.notifier);
  ConversionQueueState current() => container.read(conversionQueueProvider);

  Future<void> allEnded() async {
    for (var wait = 0; wait < 500 && !current().jobs.every((job) => job.state.isEnded); wait++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(current().jobs.every((job) => job.state.isEnded), isTrue, reason: '${current().jobs}');
  }

  ConversionRequest photo(String name) {
    final path = p.join(photos, name);
    File(path).writeAsBytesSync(Uint8List.fromList(List.generate(64, (i) => (i * 3 + name.length) & 0xff)));
    return ConversionRequest(source: LocalFileSource(path), target: ConversionTarget.nextTo(path));
  }

  List<String> folder() => [for (final entry in Directory(photos).listSync()) p.basename(entry.path)]..sort();

  test('the partial file the dialog made to check the folder is the one the job writes, then renamed', () async {
    final request = photo('salon.jpg');
    final probe = await writer.createPart(photos, request.target!.fileName);

    final id = queue().add([request]).single;
    output.adopt(id, probe);
    await allEnded();

    expect(current().byId(id)!.state, ConversionState.done);
    expect(engines.current.jobs.single.partPath, probe.path);
    expect(files.calls.where((call) => call.startsWith('createNew')), ['createNew ${probe.path}']);
    expect(folder(), ['salon.jpg', 'salon_3D_LRF_Full_SBS.jpg']);
    expect(guarded, [photos], reason: 'the guard is asked before the final name');
  });

  test('the engines of the other kinds come by kind, and the writer knows the kind of each version', () async {
    final bare = ProviderContainer();
    addTearDown(bare.dispose);
    expect(bare.read(conversionEnginesProvider).keys, [
      ConversionKind.sceneFromPhoto,
      ConversionKind.panoramaFromPhoto,
      ConversionKind.stereoPanoramaFromPanorama,
    ], reason: 'S1 registers the 3D scene, P3 the 360° panorama, P1 the 3D version of a 360° panorama');
    final panorama = bare.read(conversionEnginesProvider)[ConversionKind.panoramaFromPhoto]!;
    expect(panorama.engine, isA<DesktopPanoramaEngine>());
    expect(panorama.generator, fluxTransformerComponent.id);
    expect(panorama.steps, PanoV1.steps);
    expect(
      bare.read(keptAiEnginesProvider),
      contains(bare.read(desktopPanoramaEngineProvider)),
      reason: 'the components of the panoramas are not removed while one is made',
    );
    expect(bare.read(conversionEnginesProvider)[ConversionKind.sceneFromPhoto]!.engine, isA<DesktopSceneEngine>());
    expect(
      bare.read(conversionEnginesProvider)[ConversionKind.stereoPanoramaFromPanorama]!.engine,
      isA<DesktopStereoPanoramaEngine>(),
    );
    expect(
      bare.read(keptAiEnginesProvider),
      contains(bare.read(desktopStereoPanoramaEngineProvider)),
      reason: 'let go with the others before the components are removed or moved',
    );

    final scenes = ProviderContainer(
      overrides: [
        conversionToolsProvider.overrideWithValue(
          ConversionTools(
            engine: engines,
            engines: fakeConversionEngines(scene: FakeSceneEngine()),
            output: output,
            finder: ExistingVersionFinder(),
            creatorTool: aiCreatorTool('3.3.0', system: 'linux'),
          ),
        ),
      ],
    );
    addTearDown(scenes.dispose);
    final sceneQueue = scenes.read(conversionQueueProvider.notifier);
    Future<ConversionJob> made(ExistingVersionChoice existing) async {
      final path = p.join(photos, 'salon.jpg');
      File(path).writeAsBytesSync(List.generate(64, (i) => i));
      final id = sceneQueue
          .add(
            [
              ConversionRequest(
                source: LocalFileSource(path),
                target: ConversionTarget.nextTo(path, kind: ConversionKind.sceneFromPhoto),
              ),
            ],
            kind: ConversionKind.sceneFromPhoto,
            existing: existing,
          )
          .single;
      for (var wait = 0; wait < 500 && !scenes.read(conversionQueueProvider).byId(id)!.state.isEnded; wait++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return scenes.read(conversionQueueProvider).byId(id)!;
    }

    final first = await made(ExistingVersionChoice.skip);
    expect(first.writtenPath, p.join(photos, 'salon_scene3D.jpg'));
    final again = await made(ExistingVersionChoice.replace);

    // The scene of ours took its own place: the writer was told it replaces a scene
    expect(again.state, ConversionState.done);
    expect(again.replaced, isTrue);
    expect(again.writtenPath, first.writtenPath);
    expect(folder(), ['salon.jpg', 'salon_scene3D.jpg']);
  });

  test('a partial file no job took is deleted once its job ends: a photo cancelled while it waited', () async {
    final held = engines.current = FakeImmersiveEngine(holdStage: ImmersiveStage.depth);
    final first = photo('a.jpg');
    final second = photo('b.jpg');
    final parts = [
      await writer.createPart(photos, first.target!.fileName),
      await writer.createPart(photos, second.target!.fileName),
    ];
    final ids = queue().add([first, second]);
    output.adopt(ids[0], parts[0]);
    output.adopt(ids[1], parts[1]);
    await held.reachedHold.stream.first;

    queue().cancel(ids[1]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(File(parts[1].path).existsSync(), isFalse);
    expect(output.adoptedJobs, isEmpty);

    held.release();
    await allEnded();
    expect(folder(), ['a.jpg', 'a_3D_LRF_Full_SBS.jpg', 'b.jpg']);
  });

  test('a disk full when the 3D photo takes its name pauses the queue; Resume runs it again', () async {
    files.renameFailures[photos] = _diskFull;
    final id = queue().add([photo('salon.jpg')]).single;
    await allEnded();

    final failed = current().byId(id)!;
    expect(failed.state, ConversionState.failed);
    expect(failed.error, ImmersiveErrorCode.diskFull);
    expect(current().isPaused, isTrue);
    expect(folder(), ['salon.jpg'], reason: 'no partial file, nothing under the final name');

    files.renameFailures.clear();
    queue().resume();
    await allEnded();
    expect(current().byId(id)!.state, ConversionState.done);
    expect(current().isPaused, isFalse);
  });

  test('a folder that refuses the partial file fails the photo as read only, and the next one runs', () async {
    final other = p.join(root.path, 'other');
    Directory(other).createSync();
    files.failures[photos] = _denied;
    final refused = photo('salon.jpg');
    final elsewhere = File(p.join(other, 'cuisine.jpg'))..writeAsBytesSync(List.generate(40, (i) => i));
    final ids = queue().add([
      refused,
      ConversionRequest(source: LocalFileSource(elsewhere.path), target: ConversionTarget.nextTo(elsewhere.path)),
    ]);
    await allEnded();

    expect(current().byId(ids[0])!.error, ImmersiveErrorCode.readOnly);
    expect(current().byId(ids[1])!.state, ConversionState.done);
    expect(current().isPaused, isFalse);
  });

  test('until the album of the versions is out of the backup, no 3D photo takes its name in the library', () async {
    libraryReady = false;
    final id = queue().add([photo('salon.jpg')]).single;
    await allEnded();

    final failed = current().byId(id)!;
    expect(failed.state, ConversionState.failed);
    expect(failed.error, ImmersiveErrorCode.writeFailed);
    expect(failed.message, libraryNotReadyMessage);
    expect(folder(), ['salon.jpg']);
  });

  test('Replace takes the place of a version made from the same original only, by its sum', () async {
    final request = photo('salon.jpg');
    final bytes = File(p.join(photos, 'salon.jpg')).readAsBytesSync();
    final ours = File(p.join(photos, 'salon_3D_LRF_Full_SBS.jpg'))
      ..writeAsBytesSync(fakeSbsJpeg(xmp: versionXmp(bytes)));
    final oldId = StereoPhotoXmp.findIn(ours.readAsBytesSync())!.derivativeId;

    final id = queue().add([request], existing: ExistingVersionChoice.newVersion, whenExists: .replace).single;
    await allEnded();
    // A new version never replaces
    expect(current().byId(id)!.replaced, isFalse);
    expect(folder(), ['salon.jpg', 'salon_3D_LRF_Full_SBS (1).jpg', 'salon_3D_LRF_Full_SBS.jpg']);

    File(p.join(photos, 'salon_3D_LRF_Full_SBS (1).jpg')).deleteSync();
    final again = queue().add([photo('salon.jpg')], existing: ExistingVersionChoice.replace).single;
    await allEnded();
    final replaced = current().byId(again)!;
    // The version of the folder has the settings of the job (the same model, no turn): replaced
    expect(replaced.state, ConversionState.done, reason: '${replaced.error} ${replaced.message}');
    expect(replaced.replaced, isTrue);
    expect(StereoPhotoXmp.findIn(ours.readAsBytesSync())!.derivativeId, isNot(oldId));
  });

  test('the versions the index of the library knows, by the sum of their original, in every folder', () async {
    final fixture = TestLibrary();
    addTearDown(fixture.dispose);
    fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
    final original = jpegBytes(width: 40, height: 30);
    final library = p.join(fixture.files.path, 'Photos');
    fixture
      ..write('Photos/salon.jpg', original)
      ..write('Photos/salon_3D_LRF_Full_SBS.jpg', fakeSbsJpeg(xmp: versionXmp(original)))
      ..write('Photos/3D/salon_3D_LRF_Full_SBS (1).jpg', fakeSbsJpeg(xmp: versionXmp(original, quarterTurns: 1)))
      ..write('Photos/salon2_3D_LRF_Full_SBS.jpg', fakeSbsJpeg(xmp: versionXmp(jpegBytes(width: 4, height: 3))));
    fixture.library().addRoot(library);
    await fixture.scan();

    final paths = await LibraryVersionIndex(
      library: () async => fixture.library(),
    ).versionPathsOf(sha1Base64(original));

    expect(paths.toSet(), {
      p.join(library, 'salon_3D_LRF_Full_SBS.jpg'),
      p.join(library, '3D', 'salon_3D_LRF_Full_SBS (1).jpg'),
    });
  });

  test('the names the 3D photos carry: CreatorTool with the system, Software without', () {
    expect(aiCreatorTool('3.3.0', system: 'windows'), 'Immuch360 Desktop 3.3.0 (windows)');
    expect(aiSoftware('3.3.0'), 'Immuch360 Desktop 3.3.0');
    expect(aiSoftware(''), 'Immuch360 Desktop');
  });

  group('the engine of the app', () {
    late _Components components;
    late List<AiGateResult> made;
    late List<_CountingEngine> counted;

    DesktopAiEngine engineOf() => DesktopAiEngine(
      gate: HardwareGate(
        components: components,
        facts: () => const AiHardwareFacts(abi: Abi.linuxX64, processors: 8, physicalMemory: 16 << 30),
        loadRuntime: (path) async => (version: '1.31.0', error: null),
      ),
      create: (gate) {
        made.add(gate);
        final engine = _CountingEngine();
        counted.add(engine);
        return engine;
      },
    );

    ImmersiveJob job() => const ImmersiveJob(
      id: 'job',
      source: ImmersiveSource(name: 'salon.jpg', size: 1, sha1: 'sum', path: '/nowhere/salon.jpg'),
      partPath: '/nowhere/.part',
      derivativeId: 'urn:uuid:1',
      creatorTool: 'test',
      created: '2026-10-27T10:12:00+01:00',
    );

    setUp(() {
      components = _Components(root.path);
      made = [];
      counted = [];
    });

    test('without its components, a job ends as components missing, and no model is made', () async {
      final engine = engineOf();
      final flag = NativeCancelFlag();
      addTearDown(flag.free);

      final result = await engine.run(job(), cancel: flag);

      expect(result.error, ImmersiveErrorCode.componentsMissing);
      expect(made, isEmpty);
      expect(engine.isRunning, isFalse);
    });

    test('made from the files installed when a job runs, kept while they serve, let go before a removal', () async {
      final engine = engineOf();
      final flag = NativeCancelFlag();
      addTearDown(flag.free);
      components.install(onnxRuntimeLinuxComponent);
      components.install(depthModelOnnxComponent);

      final running = <bool>[];
      final first = engine.run(job(), cancel: flag, onProgress: (_) => running.add(engine.isRunning));
      expect((await first).isDone, isTrue);
      expect((await engine.run(job(), cancel: flag)).isDone, isTrue);

      expect(made, hasLength(1), reason: 'one model for the two jobs');
      expect(made.single.runtimeFile!.path, components.fileOf(onnxRuntimeLinuxComponent).path);
      expect(counted.single.runs, 2);
      expect(running, [true], reason: 'running while the job runs: the components are not removed then');
      expect(engine.isRunning, isFalse);

      await engine.release();
      expect(counted.single.disposed, isTrue);
      expect((await engine.run(job(), cancel: flag)).isDone, isTrue);
      expect(made, hasLength(2), reason: 'made again after it was let go');
    });
  });

  _sceneEngineTests(() => root);
  _stereoPanoramaEngineTests(() => root);
  _panoramaEngineTests(() => root);
}

/// The head of a JPEG of [width] x [height]: its frame header, then the start of its scan
Uint8List jpegOfSize(int width, int height) => Uint8List.fromList([
  ...[0xFF, 0xD8],
  ...[
    0xFF,
    0xC0,
    0,
    17,
    8,
    height >> 8,
    height & 0xFF,
    width >> 8,
    width & 0xFF,
    3,
    1,
    0x11,
    0,
    2,
    0x11,
    1,
    3,
    0x11,
    1,
  ],
  ...[0xFF, 0xDA, 0, 12, 3, 1, 0, 2, 0x11, 3, 0x11, 0, 63, 0],
  ...[0xFF, 0xD9],
]);

/// The engine of the 3D scenes of the app (lot S1), on the gate of the feature scene
void _sceneEngineTests(Directory Function() root) {
  group('the engine of the 3D scenes of the app', () {
    late _Components components;
    late List<AiGateResult> made;
    late List<_CountingEngine> counted;

    DesktopSceneEngine engineOf() => DesktopSceneEngine(
      gate: HardwareGate(
        components: components,
        facts: () => const AiHardwareFacts(abi: Abi.linuxX64, processors: 8, physicalMemory: 16 << 30),
        loadRuntime: (path) async => (version: '1.31.0', error: null),
      ),
      create: (gate) {
        made.add(gate);
        final engine = _CountingEngine();
        counted.add(engine);
        return engine;
      },
    );

    SceneJob job() => const SceneJob(
      id: 'scene',
      sources: [ImmersiveSource(name: 'salon.jpg', size: 1, sha1: 'sum', path: '/nowhere/salon.jpg')],
      partPath: '/nowhere/.part',
      derivativeId: 'urn:uuid:1',
      creatorTool: 'test',
      created: '2026-10-28T10:12:00+01:00',
    );

    setUp(() {
      components = _Components(root().path);
      made = [];
      counted = [];
    });

    test('without MoGe-2 or LaMa, a scene ends as components missing, and no model is made', () async {
      final engine = engineOf();
      final flag = NativeCancelFlag();
      addTearDown(flag.free);
      components.install(onnxRuntimeLinuxComponent);
      components.install(depthModelOnnxComponent);
      components.install(mogeGeometryComponent);

      final result = await engine.run(job(), cancel: flag);

      expect(result.error, ImmersiveErrorCode.componentsMissing);
      expect(made, isEmpty);
      expect(engine.isRunning, isFalse);
    });

    test('made from ONNX Runtime, MoGe-2 and LaMa installed when a job runs, kept while they serve', () async {
      final engine = engineOf();
      final flag = NativeCancelFlag();
      addTearDown(flag.free);
      components.install(onnxRuntimeLinuxComponent);
      components.install(mogeGeometryComponent);
      components.install(lamaInpaintComponent);

      expect((await engine.run(job(), cancel: flag)).isDone, isTrue);
      expect((await engine.run(job(), cancel: flag)).isDone, isTrue);

      expect(made, hasLength(1), reason: 'one engine for the two scenes');
      expect(made.single.feature, AiFeature.scene);
      expect(made.single.fileOf(mogeGeometryComponent.id)!.path, components.fileOf(mogeGeometryComponent).path);
      expect(made.single.fileOf(lamaInpaintComponent.id)!.path, components.fileOf(lamaInpaintComponent).path);
      expect(counted.single.runs, 2);

      await engine.release();
      expect(counted.single.disposed, isTrue);
      expect((await engine.run(job(), cancel: flag)).isDone, isTrue);
      expect(made, hasLength(2), reason: 'made again after it was let go');
    });

    test('the key of the settings of a scene: the sums of the catalogue, the step of the grid of the photo', () async {
      final engine = sceneConversionEngine(engineOf());
      String photo(String name, int width, int height) {
        final path = p.join(root().path, name);
        File(path).writeAsBytesSync(jpegOfSize(width, height));
        return path;
      }

      Future<String?> keyOf(String path, int turns) => Future.value(
        engine.settingsKey(ImmersiveSource(name: p.basename(path), size: 1, sha1: 's', path: path), turns),
      );
      final sums = '${mogeGeometryComponent.sha256}|${lamaInpaintComponent.sha256}';

      expect(await keyOf(photo('wide.jpg', 4032, 3024), 0), '$sums|scene-v1|4|0');
      expect(await keyOf(photo('square.jpg', 3000, 3000), 1), '$sums|scene-v1|5|1', reason: 'a square map of 1024');
      final png = p.join(root().path, 'drawing.png');
      File(png).writeAsBytesSync([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]);
      expect(await keyOf(png, 0), isNull, reason: 'its size is not read before it is decoded: no version looked for');
      expect(await keyOf(p.join(root().path, 'gone.jpg'), 0), isNull);
    });
  });
}

/// The engine of the 3D versions of the 360° panoramas of the app (lot P1), on the gate of the feature stereoPanorama
void _stereoPanoramaEngineTests(Directory Function() root) {
  group('the engine of the 3D versions of the 360° panoramas of the app', () {
    late _Components components;
    late List<AiGateResult> made;
    late List<_CountingEngine> counted;

    DesktopStereoPanoramaEngine engineOf() => DesktopStereoPanoramaEngine(
      gate: HardwareGate(
        components: components,
        facts: () => const AiHardwareFacts(abi: Abi.linuxX64, processors: 8, physicalMemory: 16 << 30),
        loadRuntime: (path) async => (version: '1.31.0', error: null),
      ),
      create: (gate) {
        made.add(gate);
        final engine = _CountingEngine();
        counted.add(engine);
        return engine;
      },
    );

    StereoPanoramaJob job() => const StereoPanoramaJob(
      id: 'pano',
      source: ImmersiveSource(name: 'PANO_0001.jpg', size: 1, sha1: 'sum', path: '/nowhere/PANO_0001.jpg'),
      partPath: '/nowhere/.part',
      derivativeId: 'urn:uuid:1',
      creatorTool: 'test',
      created: '2026-10-28T10:12:00+01:00',
    );

    setUp(() {
      components = _Components(root().path);
      made = [];
      counted = [];
    });

    test('without the depth model, a 3D panorama ends as components missing, and no model is made', () async {
      final engine = engineOf();
      final flag = NativeCancelFlag();
      addTearDown(flag.free);
      components.install(onnxRuntimeLinuxComponent);

      final result = await engine.run(job(), cancel: flag);

      expect(result.error, ImmersiveErrorCode.componentsMissing);
      expect(made, isEmpty);
      expect(engine.isRunning, isFalse);
    });

    test('made from ONNX Runtime and the depth model of the 3D photo, kept while they serve, let go', () async {
      final engine = engineOf();
      final flag = NativeCancelFlag();
      addTearDown(flag.free);
      components.install(onnxRuntimeLinuxComponent);
      components.install(depthModelOnnxComponent);

      final running = <bool>[];
      expect((await engine.run(job(), cancel: flag, onProgress: (_) => running.add(engine.isRunning))).isDone, isTrue);
      expect((await engine.run(job(), cancel: flag)).isDone, isTrue);

      expect(made, hasLength(1), reason: 'one engine for the two panoramas');
      expect(made.single.feature, AiFeature.stereoPanorama);
      expect(made.single.runtimeFile!.path, components.fileOf(onnxRuntimeLinuxComponent).path);
      expect(made.single.fileOf(depthModelOnnxComponent.id)!.path, components.fileOf(depthModelOnnxComponent).path);
      expect(counted.single.runs, 2);
      expect(running, [true]);

      await engine.release();
      expect(counted.single.disposed, isTrue);
      expect((await engine.run(job(), cancel: flag)).isDone, isTrue);
      expect(made, hasLength(2), reason: 'made again after it was let go');
    });

    test(
      'the key of the settings: the depth model of the catalogue, relief-360-v1, 1°, the turns of the job',
      () async {
        final engine = stereoPanoramaConversionEngine(engineOf());
        const source = ImmersiveSource(name: 'PANO_0001.jpg', size: 1, sha1: 's', path: '/nowhere/PANO_0001.jpg');

        expect(await engine.settingsKey(source, 0), '${depthModelOnnxComponent.sha256}|relief-360-v1|1.0|0');
        expect(await engine.settingsKey(source, 3), '${depthModelOnnxComponent.sha256}|relief-360-v1|1.0|3');
      },
    );
  });
}

/// The engine of the 360° panoramas of the app (lot P3), on the gate of the feature panorama and the probe of the cards
void _panoramaEngineTests(Directory Function() root) {
  group('the engine of the 360° panoramas of the app', () {
    late _Components components;
    late List<PanoramaSetup> made;
    late List<_CountingEngine> counted;
    late GpuReport cards;

    GpuReport fixture(String name) =>
        GpuReport.fromJson(jsonDecode(File('test/fixtures/ai_immersive/$name').readAsStringSync()));

    DesktopPanoramaEngine engineOf({
      Abi abi = Abi.windowsX64,
      bool integratedAllowed = false,
      int physicalMemory = 16 << 30,
      Set<AiFeatureGroup> heldGroups = const {},
    }) => DesktopPanoramaEngine(
      gate: HardwareGate(
        components: components,
        facts: () => AiHardwareFacts(abi: abi, processors: 32, physicalMemory: physicalMemory),
        loadRuntime: (path) async => (version: '1.31.0', error: null),
        gpu: FakeGpuProbe.of(cards),
        integratedGpuAllowed: () async => integratedAllowed,
        heldGroups: heldGroups,
      ),
      create: (setup) {
        made.add(setup);
        final engine = _CountingEngine();
        counted.add(engine);
        return engine;
      },
    );

    PanoramaJob job() => const PanoramaJob(
      id: 'pano',
      source: ImmersiveSource(name: 'salon.jpg', size: 1, sha1: 'sum', path: '/nowhere/salon.jpg'),
      partPath: '/nowhere/.part',
      derivativeId: 'urn:uuid:1',
      creatorTool: 'test',
      created: '2026-10-28T10:12:00+01:00',
      generator: 'flux2-klein-base-4b-q4_0',
      steps: 20,
      seed: 1002,
    );

    void installAll(AiPlatform platform) {
      for (final component in aiComponentsFor(platform, feature: AiFeature.panorama, graphicsMemory: 8 << 30)) {
        components.install(component);
      }
    }

    setUp(() {
      components = _Components(root().path);
      made = [];
      counted = [];
      cards = fixture('gpu_probe_rtx4060_laptop.json');
    });

    test('a component missing: componentsMissing, and nothing is made', () async {
      final flag = NativeCancelFlag();
      addTearDown(flag.free);
      components.install(onnxRuntimeWindowsComponent);
      final result = await engineOf().run(job(), cancel: flag);
      expect(result.error, ImmersiveErrorCode.componentsMissing);
      expect(made, isEmpty);
    });

    test('no card that can make it: gpuUnavailable with the reason of the gate', () async {
      final flag = NativeCancelFlag();
      addTearDown(flag.free);
      installAll(AiPlatform.windowsX64);
      cards = const GpuReport(problem: GpuProbeProblem.noVulkan);
      final none = await engineOf().run(job(), cancel: flag);
      expect(none.error, ImmersiveErrorCode.gpuUnavailable);
      expect(none.message, AiGateReason.gpuNone.name);
      expect(made, isEmpty);
    });

    test('each reason of the gate fails with the code whose words say it, never "not installed" for another', () {
      // The panel shows the words of the code (and, for gpuUnavailable, those of the reason the message names); a
      // shortage of memory is not a missing card, a feature held back is not a missing component
      const expected = {
        AiGateReason.system: ImmersiveErrorCode.modelFailed,
        AiGateReason.processor: ImmersiveErrorCode.modelFailed,
        AiGateReason.memory: ImmersiveErrorCode.outOfMemory,
        AiGateReason.componentsMissing: ImmersiveErrorCode.componentsMissing,
        AiGateReason.componentsDamaged: ImmersiveErrorCode.componentsMissing,
        AiGateReason.runtimeFailed: ImmersiveErrorCode.modelFailed,
        AiGateReason.notHere: ImmersiveErrorCode.modelFailed,
        AiGateReason.notInThisVersion: ImmersiveErrorCode.modelFailed,
        AiGateReason.notYetOnMac: ImmersiveErrorCode.gpuUnavailable,
        AiGateReason.panoramaMemory: ImmersiveErrorCode.outOfMemory,
        AiGateReason.gpuNone: ImmersiveErrorCode.gpuUnavailable,
        AiGateReason.gpuNoAnswer: ImmersiveErrorCode.gpuUnavailable,
        AiGateReason.gpuIntegrated: ImmersiveErrorCode.gpuUnavailable,
        AiGateReason.gpuTooSmall: ImmersiveErrorCode.gpuUnavailable,
      };
      expect(expected.keys, unorderedEquals(AiGateReason.values), reason: 'every reason has its code');
      for (final reason in AiGateReason.values) {
        expect(panoramaRefusalCode(reason), expected[reason], reason: reason.name);
      }
      expect(panoramaRefusalCode(null), ImmersiveErrorCode.componentsMissing);
    });

    test('less than 14 GB of memory: outOfMemory, not a missing card', () async {
      final flag = NativeCancelFlag();
      addTearDown(flag.free);
      installAll(AiPlatform.windowsX64);
      final result = await engineOf(physicalMemory: 12 << 30).run(job(), cancel: flag);
      expect(result.error, ImmersiveErrorCode.outOfMemory);
      expect(result.message, AiGateReason.panoramaMemory.name);
      expect(made, isEmpty);
    });

    test('the panoramas held back by a version: the reason told, not "not installed"', () async {
      final flag = NativeCancelFlag();
      addTearDown(flag.free);
      installAll(AiPlatform.windowsX64);
      final result = await engineOf(heldGroups: const {AiFeatureGroup.panoramas}).run(job(), cancel: flag);
      expect(result.error, ImmersiveErrorCode.modelFailed);
      expect(result.message, AiGateReason.notInThisVersion.name);
      expect(made, isEmpty);
    });

    test(
      'on the laptop of the owner: sd-cli of the archive, the models of the gate, the RTX 4060 as Vulkan1',
      () async {
        final flag = NativeCancelFlag();
        addTearDown(flag.free);
        installAll(AiPlatform.windowsX64);
        final engine = engineOf();

        final running = <bool>[];
        expect(
          (await engine.run(job(), cancel: flag, onProgress: (_) => running.add(engine.isRunning))).isDone,
          isTrue,
        );
        expect(running, [true]);
        expect(engine.isRunning, isFalse);

        final setup = made.single;
        final settings = setup.settings;
        final archive = p.dirname(components.fileOf(sdCppWindowsComponent).path);
        expect(settings.sdCli, p.join(archive, 'sd-cli.exe'));
        expect(settings.device, 'Vulkan1');
        expect(settings.stallTimeout, const Duration(seconds: 180));
        expect(settings.environment, isEmpty, reason: 'never GGML_VK_VISIBLE_DEVICES with Vulkan<n> (review of P2, 4)');
        expect(settings.models.diffusionModel, components.fileOf(fluxTransformerComponent).path);
        expect(settings.models.vae, components.fileOf(fluxVaeComponent).path);
        expect(settings.models.textEncoder, components.fileOf(qwenTextEncoderComponent).path);
        expect(settings.models.lora, components.fileOf(panoramaLoraComponent).path);
        expect(settings.models.upscaler, components.fileOf(upscalerComponent).path);
        expect(setup.models.libraryPath, components.fileOf(onnxRuntimeWindowsComponent).path);
        expect(setup.models.miganPath, components.fileOf(miganInpaintComponent).path);
        expect(setup.models.mogePath, components.fileOf(mogeGeometryComponent).path);
        expect(setup.models.inpaintSha256, miganInpaintComponent.sha256);
        expect(setup.transformer, same(fluxTransformerComponent));
        expect(setup.linuxLauncher, isNull);
        expect(setup.card.name, contains('RTX 4060'));
        expect(counted.single.disposed, isTrue, reason: 'one engine per job: the card is asked again before each one');
      },
    );

    test('on Linux: through immuch360-run of the archive', () async {
      final flag = NativeCancelFlag();
      addTearDown(flag.free);
      installAll(AiPlatform.linuxX64);
      expect((await engineOf(abi: Abi.linuxX64).run(job(), cancel: flag)).isDone, isTrue);
      final archive = p.dirname(components.fileOf(sdCppLinuxComponent).path);
      expect(made.single.settings.sdCli, p.join(archive, 'sd-cli'));
      expect(made.single.linuxLauncher, p.join(archive, 'immuch360-run'));
    });

    test('integrated graphics allowed by the switch: a step may take minutes, the silence allowed is longer', () async {
      final flag = NativeCancelFlag();
      addTearDown(flag.free);
      installAll(AiPlatform.linuxX64);
      cards = fixture('gpu_probe_iris_xe_mesa.json');
      final result = await engineOf(abi: Abi.linuxX64, integratedAllowed: true).run(job(), cancel: flag);
      expect(result.isDone, isTrue, reason: '${result.error} ${result.message}');
      expect(made.single.settings.stallTimeout, panoramaIntegratedStallTimeout);
      expect(made.single.settings.device, 'Vulkan0');
    });

    test(
      'the key of the settings: the transformer and the LoRA of the catalogue, pano-v1, the steps, the turns',
      () async {
        final engine = panoramaConversionEngine(engineOf());
        const source = ImmersiveSource(name: 'salon.jpg', size: 1, sha1: 's', path: '/nowhere/salon.jpg');
        final sums = '${fluxTransformerComponent.sha256}|${panoramaLoraComponent.sha256}';
        expect(await engine.settingsKey(source, 0), '$sums|pano-v1|20|0');
        expect(await engine.settingsKey(source, 1), '$sums|pano-v1|20|1');
      },
    );
  });
}

/// The components of a test: a file per component installed, none otherwise
class _Components implements AiComponentFiles {
  _Components(this.folder);

  final String folder;
  final _installed = <String>{};

  File fileOf(AiComponent component) => File(p.join(folder, 'components', component.id));

  void install(AiComponent component) {
    fileOf(component)
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    _installed.add(component.id);
  }

  @override
  Future<File?> verifiedFile(AiComponent component) async =>
      _installed.contains(component.id) ? fileOf(component) : null;

  @override
  AiComponentState stateOf(AiComponent component) =>
      _installed.contains(component.id) ? AiComponentState.installed : AiComponentState.notInstalled;
}

/// An engine that counts its jobs, of any kind, and tells one step
class _CountingEngine implements ImmersiveEngine {
  var runs = 0;
  var disposed = false;

  @override
  Future<ImmersiveResult> run(
    ImmersiveJobSpec job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    runs++;
    onProgress?.call(const ImmersiveProgress(ImmersiveStage.depth, 400));
    return const ImmersiveResult.done(eyeWidth: 8, eyeHeight: 6, bytesWritten: 10);
  }

  @override
  Future<void> dispose() async => disposed = true;
}

/// The fake engine of the test in turn
class _Engines implements ImmersiveEngine {
  FakeImmersiveEngine current = FakeImmersiveEngine();

  @override
  Future<ImmersiveResult> run(
    ImmersiveJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) => current.run(job, cancel: cancel, onProgress: onProgress);

  @override
  Future<void> dispose() async {}
}
