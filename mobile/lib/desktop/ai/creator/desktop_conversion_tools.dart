// What the queue of the AI conversions runs with on a computer (ConversionTools of conversion_queue.dart), put together
// from the lots that made each part: the engine of lot A4b behind the hardware gate, the writer of the versions of
// lot A5b, and the versions the index of the folder library knows (lot A6a). desktopOverrides() gives them to the queue.
//
// The engines of the kinds of phases 2 and 3 are registered by kind in conversionEnginesProvider (lot C3): the 3D scene
// by lot S1 (DesktopSceneEngine, MoGe-2 and LaMa behind the gate of the feature scene), the 3D version of a 360°
// panorama by P1 (DesktopStereoPanoramaEngine, the depth model of phase 1 behind the gate of the feature
// stereoPanorama), the 360° panorama by P3 (or the ComfyUI of the user, P5). Until a lot registers its kind, this build
// does not make it (ConversionTools.supports), and the tests give the fakes. The times of the steps are kept in
// desktop_ai.json for the time left of the jobs.
//
// The engine is made when a job runs, from the components installed at that moment: they may be downloaded after the
// app started, from the conversion dialog or the settings. While it runs, or while the queue has a job under way, the
// components are not removed (AiComponentsService.inUse). Each engine kept between two jobs (keptAiEnginesProvider)
// is let go before the components are removed or moved (ai_settings_section.dart).
//
// The writer adapts SafeWriter to the queue. The partial file the dialog made to check a folder is handed over to the
// job of that photo, which writes into it; one no job took (a photo skipped, cancelled while waiting) is deleted at
// once. Its refusals become the codes of the queue: a disk full at the rename still pauses it. Before the final rename
// into a folder of the library, the guard of the album of the versions is asked again (design 4.3, point 3): until
// that album is out of the backup, no 3D photo takes its name there.

import 'dart:async';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/engine/dart_immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/library/generated_album.dart';
import 'package:immich_mobile/desktop/ai/panorama/stereo_panorama_engine.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_engine.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

final _log = Logger('DesktopConversionTools');

/// What the guard answers when the album of the versions is not out of the backup yet, as the message of a job
const libraryNotReadyMessage = 'the album of the generated 3D photos is not out of the backup yet';

/// The writer of the 3D photos as the queue asks for it, on SafeWriter
class SafeWriterOutput implements ConversionOutput {
  SafeWriterOutput({SafeWriter? writer, this._mayWriteInto}) : _writer = writer ?? SafeWriter.instance;

  final SafeWriter _writer;
  final Future<bool> Function(String folder)? _mayWriteInto;

  /// The partial files of the checks of the dialog, by the id of the job that takes each one
  final _adopted = <String, PartFile>{};

  /// The partial files being written, by their path
  final _parts = <String, PartFile>{};

  /// The jobs that have a partial file of the dialog waiting for them
  Set<String> get adoptedJobs => Set.unmodifiable(_adopted.keys);

  /// Hands [part], made by the check of the dialog, over to the job [jobId] of the queue
  void adopt(String jobId, PartFile part) {
    final earlier = _adopted[jobId];
    _adopted[jobId] = part;
    if (earlier != null && earlier.path != part.path) {
      unawaited(_writer.discard(earlier));
    }
  }

  /// Deletes the partial file waiting for [jobId], when there is one: the job ended without writing
  Future<void> drop(String jobId) async {
    final part = _adopted.remove(jobId);
    if (part != null) {
      await _writer.discard(part);
    }
  }

  @override
  Future<String> begin(ConversionJob job) async {
    final target = job.target!;
    final adopted = _adopted.remove(job.id);
    if (adopted != null) {
      if (_sameFolder(adopted.folder, target.folder) && adopted.finalName == target.fileName) {
        _parts[adopted.path] = adopted;
        return adopted.path;
      }
      await _writer.discard(adopted);
    }
    try {
      final part = await _writer.createPart(target.folder, target.fileName);
      _parts[part.path] = part;
      return part.path;
    } on CreatorWriteException catch (error) {
      throw ConversionException(error.failure.errorCode, error.message);
    }
  }

  @override
  Future<ConversionSaved> finish(
    ConversionJob job,
    String partPath, {
    required ImmersiveSource original,
    required AiWhenExists whenExists,
    String? replaceName,
  }) async {
    final part = _parts.remove(partPath) ?? _partAt(job, partPath);
    final mayWrite = _mayWriteInto;
    if (mayWrite != null && !await mayWrite(part.folder)) {
      await _writer.discard(part);
      throw const ConversionException(ImmersiveErrorCode.writeFailed, libraryNotReadyMessage);
    }
    try {
      final saved = await _writer.commit(
        part,
        original: OriginalIdentity.of(original),
        whenExists: whenExists,
        replacing: replaceName,
        kind: job.kind.output,
      );
      return ConversionSaved(
        path: saved.path,
        outcome: switch (saved.outcome) {
          SaveOutcome.saved => ConversionSaveOutcome.saved,
          SaveOutcome.replaced => ConversionSaveOutcome.replaced,
          SaveOutcome.skipped => ConversionSaveOutcome.skipped,
        },
      );
    } on CreatorWriteException catch (error) {
      // As its code, or a disk full at the rename would no longer pause the queue
      throw ConversionException(error.failure.errorCode, error.message);
    }
  }

  @override
  Future<void> discard(String partPath) async {
    final part = _parts.remove(partPath);
    await _writer.discard(part ?? PartFile(folder: p.dirname(partPath), finalName: '', path: partPath));
  }

  PartFile _partAt(ConversionJob job, String partPath) =>
      PartFile(folder: p.dirname(partPath), finalName: job.target!.fileName, path: partPath);
}

bool _sameFolder(String a, String b) {
  final caseFold = Platform.isWindows || Platform.isMacOS;
  final left = p.normalize(p.absolute(a));
  final right = p.normalize(p.absolute(b));
  return caseFold ? left.toLowerCase() == right.toLowerCase() : left == right;
}

/// The versions of an original the index of the folder library knows, by the SHA-1 of the original (the source_sha1
/// column of lot A6a), in every folder
class LibraryVersionIndex implements DerivedVersionIndex {
  LibraryVersionIndex({Future<FolderLibrary> Function()? library}) : _library = library ?? FolderLibrary.shared;

  final Future<FolderLibrary> Function() _library;

  @override
  Future<List<String>> versionPathsOf(String sourceSha1) async {
    final library = await _library();
    final found = library.index.filesDerivedFrom(sourceSha1);
    return [for (final file in library.files(found.map((file) => file.id))) file.path];
  }
}

/// An engine kept from one job to the next, which holds ONNX Runtime and its models until it is let go
abstract interface class KeptAiEngine {
  /// Whether a job runs: the components are not removed meanwhile
  bool get isRunning;

  /// Lets the models and their worker go, before the components are removed or moved; the next job makes them again
  Future<void> release();
}

/// The engine of the 3D photos, made from the components installed when a job runs: DartImmersiveEngine on ONNX
/// Runtime and Depth Anything V2 Small, kept from one job to the next while the same files serve
class DesktopAiEngine implements ImmersiveEngine, KeptAiEngine {
  DesktopAiEngine({required this.gate, ImmersiveEngine Function(AiGateResult gate)? create})
    : _create = create ?? onnxEngineFor;

  final HardwareGate gate;
  final ImmersiveEngine Function(AiGateResult gate) _create;

  ImmersiveEngine? _engine;
  String? _files;
  var _running = false;

  @override
  bool get isRunning => _running;

  /// DartImmersiveEngine on the files [gate] found, their sizes those of the catalogue
  static ImmersiveEngine onnxEngineFor(AiGateResult gate) {
    final components = aiComponentsFor(gate.platform!);
    final runtime = components.firstWhere((component) => component.kind == AiComponentKind.runtime);
    final model = components.firstWhere((component) => component.kind == AiComponentKind.model);
    return DartImmersiveEngine.onnx(
      libraryPath: gate.runtimeFile!.path,
      modelPath: gate.modelFile!.path,
      librarySize: runtime.size,
      modelSize: model.size,
      modelSha256: model.sha256 ?? depthModelOnnxSha256,
    );
  }

  @override
  Future<ImmersiveResult> run(
    ImmersiveJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    _running = true;
    try {
      final found = await gate.evaluate();
      if (!found.isAvailable) {
        return ImmersiveResult.failed(switch (found.reason) {
          AiGateReason.componentsMissing || AiGateReason.componentsDamaged => ImmersiveErrorCode.componentsMissing,
          _ => ImmersiveErrorCode.modelFailed,
        }, message: found.message ?? found.reason?.name);
      }
      final files = '${found.runtimeFile!.path}|${found.modelFile!.path}';
      var engine = _engine;
      if (engine == null || files != _files) {
        await engine?.dispose();
        engine = _engine = _create(found);
        _files = files;
      }
      return await engine.run(job, cancel: cancel, onProgress: onProgress);
    } catch (error, stack) {
      _log.warning('The job ${job.id} could not run', error, stack);
      return ImmersiveResult.failed(ImmersiveErrorCode.modelFailed, message: '$error');
    } finally {
      _running = false;
    }
  }

  @override
  Future<void> release() async {
    final engine = _engine;
    _engine = null;
    _files = null;
    await engine?.dispose();
  }

  @override
  Future<void> dispose() => release();
}

/// The engine of the 3D scenes, made from the components of the feature scene installed when a job runs (ONNX Runtime,
/// MoGe-2 ViT-S, LaMa): SceneEngine, kept from one job to the next while the same files serve. A scene asked while a
/// component is missing fails with componentsMissing, never downloads anything.
class DesktopSceneEngine implements ImmersiveEngine, KeptAiEngine {
  DesktopSceneEngine({required this.gate, ImmersiveEngine Function(AiGateResult gate)? create})
    : _create = create ?? onnxSceneEngineFor;

  final HardwareGate gate;
  final ImmersiveEngine Function(AiGateResult gate) _create;

  ImmersiveEngine? _engine;
  String? _files;
  var _running = false;

  @override
  bool get isRunning => _running;

  /// SceneEngine on the files [gate] found for the feature scene, their sizes and sums those of the catalogue
  static ImmersiveEngine onnxSceneEngineFor(AiGateResult gate) {
    final runtime = aiComponentsFor(
      gate.platform!,
      feature: AiFeature.scene,
    ).firstWhere((component) => component.kind == AiComponentKind.runtime);
    return SceneEngine.onnx(
      libraryPath: gate.runtimeFile!.path,
      mogePath: gate.fileOf(mogeGeometryComponent.id)!.path,
      mogeSha256: mogeGeometryComponent.sha256!,
      lamaPath: gate.fileOf(lamaInpaintComponent.id)!.path,
      lamaSha256: lamaInpaintComponent.sha256!,
      geometryModel: mogeGeometryComponent.id,
      inpaintModel: lamaInpaintComponent.id,
      librarySize: runtime.size,
      mogeSize: mogeGeometryComponent.size,
      lamaSize: lamaInpaintComponent.size,
    );
  }

  @override
  Future<ImmersiveResult> run(
    SceneJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    _running = true;
    try {
      final found = await gate.evaluate(feature: AiFeature.scene);
      final moge = found.fileOf(mogeGeometryComponent.id);
      final lama = found.fileOf(lamaInpaintComponent.id);
      if (!found.isAvailable || moge == null || lama == null) {
        return ImmersiveResult.failed(switch (found.reason) {
          AiGateReason.componentsMissing ||
          AiGateReason.componentsDamaged ||
          null => ImmersiveErrorCode.componentsMissing,
          _ => ImmersiveErrorCode.modelFailed,
        }, message: found.message ?? found.reason?.name ?? 'MoGe-2 or LaMa is missing');
      }
      final files = '${found.runtimeFile!.path}|${moge.path}|${lama.path}';
      var engine = _engine;
      if (engine == null || files != _files) {
        await engine?.dispose();
        engine = _engine = _create(found);
        _files = files;
      }
      return await engine.run(job, cancel: cancel, onProgress: onProgress);
    } catch (error, stack) {
      _log.warning('The scene ${job.id} could not run', error, stack);
      return ImmersiveResult.failed(ImmersiveErrorCode.modelFailed, message: '$error');
    } finally {
      _running = false;
    }
  }

  @override
  Future<void> release() async {
    final engine = _engine;
    _engine = null;
    _files = null;
    await engine?.dispose();
  }

  @override
  Future<void> dispose() => release();
}

/// The engine of the 3D scenes as the queue is given it: the key of the settings of a scene with the sums of MoGe-2 and
/// LaMa of the catalogue and the step of the grid of the photo
ConversionEngine sceneConversionEngine(ImmersiveEngine engine) => ConversionEngine(
  engine: engine,
  settingsKey: (source, quarterTurns) => sceneSettingsKeyOf(
    source,
    quarterTurns,
    geometrySha256: mogeGeometryComponent.sha256!,
    inpaintSha256: lamaInpaintComponent.sha256!,
  ),
);

/// The engine of the 3D versions of the 360° panoramas (lot P1), made from the components of the feature stereoPanorama
/// installed when a job runs (ONNX Runtime and Depth Anything V2 Small, those of the 3D photo): StereoPanoramaEngine,
/// kept from one job to the next while the same files serve. A job asked while a component is missing fails with
/// componentsMissing, never downloads anything.
class DesktopStereoPanoramaEngine implements ImmersiveEngine, KeptAiEngine {
  DesktopStereoPanoramaEngine({required this.gate, ImmersiveEngine Function(AiGateResult gate)? create})
    : _create = create ?? onnxStereoPanoramaEngineFor;

  final HardwareGate gate;
  final ImmersiveEngine Function(AiGateResult gate) _create;

  ImmersiveEngine? _engine;
  String? _files;
  var _running = false;

  @override
  bool get isRunning => _running;

  /// StereoPanoramaEngine on the files [gate] found for the feature stereoPanorama, their sizes and sums those of the
  /// catalogue
  static ImmersiveEngine onnxStereoPanoramaEngineFor(AiGateResult gate) {
    final runtime = aiComponentsFor(
      gate.platform!,
      feature: AiFeature.stereoPanorama,
    ).firstWhere((component) => component.kind == AiComponentKind.runtime);
    return StereoPanoramaEngine.onnx(
      libraryPath: gate.runtimeFile!.path,
      modelPath: gate.fileOf(depthModelOnnxComponent.id)!.path,
      modelSha256: depthModelOnnxComponent.sha256 ?? depthModelOnnxSha256,
      librarySize: runtime.size,
      modelSize: depthModelOnnxComponent.size,
    );
  }

  @override
  Future<ImmersiveResult> run(
    StereoPanoramaJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    _running = true;
    try {
      final found = await gate.evaluate(feature: AiFeature.stereoPanorama);
      final model = found.fileOf(depthModelOnnxComponent.id);
      if (!found.isAvailable || model == null) {
        return ImmersiveResult.failed(switch (found.reason) {
          AiGateReason.componentsMissing ||
          AiGateReason.componentsDamaged ||
          null => ImmersiveErrorCode.componentsMissing,
          _ => ImmersiveErrorCode.modelFailed,
        }, message: found.message ?? found.reason?.name ?? 'The depth model is missing');
      }
      final files = '${found.runtimeFile!.path}|${model.path}';
      var engine = _engine;
      if (engine == null || files != _files) {
        await engine?.dispose();
        engine = _engine = _create(found);
        _files = files;
      }
      return await engine.run(job, cancel: cancel, onProgress: onProgress);
    } catch (error, stack) {
      _log.warning('The 3D panorama ${job.id} could not run', error, stack);
      return ImmersiveResult.failed(ImmersiveErrorCode.modelFailed, message: '$error');
    } finally {
      _running = false;
    }
  }

  @override
  Future<void> release() async {
    final engine = _engine;
    _engine = null;
    _files = null;
    await engine?.dispose();
  }

  @override
  Future<void> dispose() => release();
}

/// The engine of the 3D versions of the 360° panoramas as the queue is given it: the key of the settings with the sum of
/// the depth model of the catalogue and the turns of the job (those of the photo of a generated panorama)
ConversionEngine stereoPanoramaConversionEngine(ImmersiveEngine engine) => ConversionEngine(
  engine: engine,
  settingsKey: (source, quarterTurns) => stereoPanoramaSettingsKeyOf(
    quarterTurns,
    depthModelSha256: depthModelOnnxComponent.sha256 ?? depthModelOnnxSha256,
  ),
);

/// "Immuch360 Desktop 3.3.0 (windows)", the xmp:CreatorTool of the 3D photos
String aiCreatorTool(String version, {String? system}) =>
    '${aiSoftware(version)} (${system ?? Platform.operatingSystem})';

/// "Immuch360 Desktop 3.3.0", the EXIF Software of the 3D photos
String aiSoftware(String version) => version.isEmpty ? 'Immuch360 Desktop' : 'Immuch360 Desktop $version';

/// The version of the app, read once
final aiAppVersionProvider = FutureProvider<String>((ref) async {
  try {
    return (await PackageInfo.fromPlatform()).version;
  } catch (error) {
    _log.warning('The version of the app could not be read: $error');
    return '';
  }
});

/// The hardware gate of this computer, on the components of the app
final desktopAiGateProvider = Provider<HardwareGate>(
  (ref) => HardwareGate(components: ServiceComponentFiles(ref.watch(aiComponentsServiceProvider))),
);

/// The engine of the 3D photos of the app. While it runs, or while the queue has a job under way, the components stay.
final desktopAiEngineProvider = Provider<DesktopAiEngine>((ref) {
  final engine = DesktopAiEngine(gate: ref.watch(desktopAiGateProvider));
  final service = ref.watch(aiComponentsServiceProvider);
  service.inUse = () =>
      engine.isRunning || (ref.exists(conversionQueueProvider) && ref.read(conversionQueueProvider).current != null);
  ref.onDispose(() {
    service.inUse = () => false;
    unawaited(engine.dispose());
  });
  return engine;
});

/// The engine of the 3D scenes of the app (lot S1)
final desktopSceneEngineProvider = Provider<DesktopSceneEngine>((ref) {
  final engine = DesktopSceneEngine(gate: ref.watch(desktopAiGateProvider));
  ref.onDispose(() => unawaited(engine.dispose()));
  return engine;
});

/// The engine of the 3D versions of the 360° panoramas of the app (lot P1)
final desktopStereoPanoramaEngineProvider = Provider<DesktopStereoPanoramaEngine>((ref) {
  final engine = DesktopStereoPanoramaEngine(gate: ref.watch(desktopAiGateProvider));
  ref.onDispose(() => unawaited(engine.dispose()));
  return engine;
});

/// The engines kept between two jobs, let go before the components are removed or moved: the 3D photos, the 3D scenes
/// (S1) and the 3D versions of the 360° panoramas (P1); P3 (or P5) adds its own here
final keptAiEnginesProvider = Provider<List<KeptAiEngine>>(
  (ref) => [
    ref.watch(desktopAiEngineProvider),
    ref.watch(desktopSceneEngineProvider),
    ref.watch(desktopStereoPanoramaEngineProvider),
  ],
);

/// The engines of the kinds of phases 2 and 3, by kind, each with the key of the settings its files carry: the 3D
/// scene (S1), the 3D version of a 360° panorama (P1); P3 (or P5) adds its own here. The tests give the fakes.
final conversionEnginesProvider = Provider<Map<ConversionKind, ConversionEngine>>(
  (ref) => {
    ConversionKind.sceneFromPhoto: sceneConversionEngine(ref.watch(desktopSceneEngineProvider)),
    ConversionKind.stereoPanoramaFromPanorama: stereoPanoramaConversionEngine(
      ref.watch(desktopStereoPanoramaEngineProvider),
    ),
  },
);

/// desktop_ai.json, where the screens read and keep the settings of the conversions
final desktopAiSettingsStoreProvider = Provider<DesktopAiSettingsStore>((ref) => DesktopAiSettingsStore.instance);

/// Whether a 3D photo may be written into a folder now: the guard of the album of the versions (lot A6a)
final aiWriteGuardProvider = Provider<Future<bool> Function(String folder)>(
  (ref) => ref.watch(generatedAlbumGuardProvider).mayWriteInto,
);

/// The writer of the app; the partial files of the dialog that no job took are deleted as their jobs end
final safeWriterOutputProvider = Provider<SafeWriterOutput>((ref) {
  final output = SafeWriterOutput(mayWriteInto: ref.watch(aiWriteGuardProvider));
  ref.listen(conversionQueueProvider, (_, next) => dropUntakenParts(output, next));
  return output;
});

/// Deletes the partial files of the dialog whose jobs ended without taking them (skipped, cancelled while waiting)
void dropUntakenParts(SafeWriterOutput output, ConversionQueueState state) {
  for (final job in state.jobs) {
    if (job.state.isEnded && output.adoptedJobs.contains(job.id)) {
      unawaited(output.drop(job.id));
    }
  }
}

/// The tools of the queue on a computer (see the top of this file); desktopOverrides() gives them to
/// conversionToolsProvider
ConversionTools desktopConversionTools(Ref ref) {
  final version = ref.watch(aiAppVersionProvider).valueOrNull ?? '';
  return ConversionTools(
    engine: ref.watch(desktopAiEngineProvider),
    engines: ref.watch(conversionEnginesProvider),
    output: ref.watch(safeWriterOutputProvider),
    finder: ExistingVersionFinder(index: LibraryVersionIndex()),
    creatorTool: aiCreatorTool(version),
    software: aiSoftware(version),
    settings: ref.watch(desktopAiSettingsStoreProvider),
  );
}
