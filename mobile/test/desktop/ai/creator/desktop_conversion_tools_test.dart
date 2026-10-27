// The tools the queue runs with on a computer: the writer of lot A5b behind the queue (the partial file of the check of
// the dialog taken over by its job, the one no job took deleted, the refusals of the system as the codes of the queue,
// a disk full at the rename that still pauses it, the guard of the album of the versions before the final name), the
// versions the index of the folder library knows, and the engine made from the components installed when a job runs.

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
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:path/path.dart' as p;

import '../../library/library_fixtures.dart';
import '../../library/library_test_support.dart';
import '../fakes/fake_immersive_engine.dart';
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
    final ours = File(p.join(photos, 'salon_3D_LRF_Full_SBS.jpg'))..writeAsBytesSync(fakeSbsJpeg(xmp: versionXmp(bytes)));
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

    final paths = await LibraryVersionIndex(library: () async => fixture.library()).versionPathsOf(
      sha1Base64(original),
    );

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

/// An engine that counts its jobs and tells one step
class _CountingEngine implements ImmersiveEngine {
  var runs = 0;
  var disposed = false;

  @override
  Future<ImmersiveResult> run(
    ImmersiveJob job, {
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
