// What the queue of the AI conversions runs with on a computer (ConversionTools of conversion_queue.dart), put together
// from the lots that made each part: the engine of lot A4b behind the hardware gate, the writer of the versions of
// lot A5b, and the versions the index of the folder library knows (lot A6a). desktopOverrides() gives them to the queue.
//
// The engines of the kinds of phases 2 and 3 are registered by kind in conversionEnginesProvider (lot C3): the 3D scene
// by lot S1 (DesktopSceneEngine, MoGe-2 and LaMa behind the gate of the feature scene), the 3D version of a 360°
// panorama by P1 (DesktopStereoPanoramaEngine, the depth model of phase 1 behind the gate of the feature
// stereoPanorama), the 360° panorama by P3 (DesktopPanoramaEngine: stable-diffusion.cpp on the graphics card the gate
// found, MoGe-2 and MI-GAN, behind the gate of the feature panorama; the dialog of lot U3 offers it since the hold of
// the panoramas was lifted). Until a lot registers its kind, this build does not make it (ConversionTools.supports),
// and the tests give the fakes. The times of the steps are kept in desktop_ai.json for the time left of the jobs.
//
// The programs the engines start (sd-cli) belong to one AiProcessSession of the app, opened at the first job that
// starts one: the programs an earlier session left running are stopped then, once (managed_process.dart).
//
// The gate and the queue ask the graphics cards through the probe of lot C6 (gpu_probe.dart): the gate when it looks at
// the 360° panoramas, the queue again before each job of the graphics card, through the gate, whose answer the dialog
// and the settings then see too.
//
// The engine is made when a job runs, from the components installed at that moment: they may be downloaded after the
// app started, from the conversion dialog or the settings. While it runs, or while the queue has a job under way, the
// components are not removed (AiComponentsService.inUse). Each engine kept between two jobs (keptAiEnginesProvider)
// is let go before the components are removed or moved (ai_settings_section.dart).
//
// The splat scenes (plan 2026-11-01, lot SP6) are registered too: DesktopSplatEngine, made for each job from what the
// gate of the feature splatScene finds then (COLMAP and Brush of the archives of ai-components-4, the dedicated card of
// splatCardOf), their programs through the same session, Brush asking the card again with the need of the splat scenes
// before it trains; the photos and the frames prepared by the app (splat_images.dart); the autotune cache of Brush kept
// from one job to the next in the support folder of the app, one folder per card and driver. The writer puts the .ply
// of a scene beside its .spz, under the same name (ConversionCompanionOutput).
//
// The writer adapts SafeWriter to the queue. The partial file the dialog made to check a folder is handed over to the
// job of that photo, which writes into it; one no job took (a photo skipped, cancelled while waiting) is deleted at
// once. Its refusals become the codes of the queue: a disk full at the rename still pauses it. Before the final rename
// into a folder of the library, the guard of the album of the versions is asked again (design 4.3, point 3): until
// that album is out of the backup, no 3D photo takes its name there.

import 'dart:async';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/codec/engine_picture.dart';
import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/dart_immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/gpu/gpu_budget.dart';
import 'package:immich_mobile/desktop/ai/gpu/gpu_probe.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/library/generated_album.dart';
import 'package:immich_mobile/desktop/ai/panorama/panorama_engine.dart';
import 'package:immich_mobile/desktop/ai/panorama/stereo_panorama_engine.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_engine.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/splat/brush_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/colmap_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_engine.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_images.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('DesktopConversionTools');

/// What the guard answers when the album of the versions is not out of the backup yet, as the message of a job
const libraryNotReadyMessage = 'the album of the generated 3D photos is not out of the backup yet';

/// The writer of the 3D photos as the queue asks for it, on SafeWriter
class SafeWriterOutput implements ConversionOutput, ConversionCompanionOutput {
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

  @override
  Future<String> beginCompanion(ConversionJob job, String fileName) async {
    try {
      final part = await _writer.createPart(job.target!.folder, fileName);
      _parts[part.path] = part;
      return part.path;
    } on CreatorWriteException catch (error) {
      throw ConversionException(error.failure.errorCode, error.message);
    }
  }

  @override
  Future<String> finishCompanion(
    ConversionJob job,
    String partPath, {
    required String versionPath,
    required ImmersiveSource original,
  }) async {
    final part = _parts.remove(partPath) ?? PartFile(folder: p.dirname(partPath), finalName: '', path: partPath);
    // The name of the version as it was saved ("salon_splat (1).spz"), with the extension of the companion
    final name = '${p.basenameWithoutExtension(versionPath)}${p.extension(part.finalName)}';
    try {
      final saved = await _writer.commit(
        PartFile(folder: p.dirname(versionPath), finalName: name, path: part.path),
        original: OriginalIdentity.of(original),
        kind: job.kind.output,
      );
      return saved.path;
    } on CreatorWriteException catch (error) {
      _parts[part.path] = part;
      throw ConversionException(error.failure.errorCode, error.message);
    }
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

/// How long sd-cli may stay silent on an integrated card allowed by "Try on integrated graphics (untested)": a step of
/// the generation there can take minutes, where 180 s is the rule of a dedicated card (review of lot P2, point 9)
const panoramaIntegratedStallTimeout = Duration(minutes: 15);

/// What the engine of a panorama is made from, read from what the gate found: sd-cli and its models, the card by its
/// index for ggml, MoGe-2 and MI-GAN, and on Linux the launcher of the archive
class PanoramaSetup {
  const PanoramaSetup({
    required this.settings,
    required this.models,
    required this.requiredFiles,
    required this.transformer,
    required this.card,
    this.linuxLauncher,
  });

  final SdCppSettings settings;
  final OrtPanoramaModelsSpec models;
  final Map<String, int?> requiredFiles;

  /// The variant of the transformer the gate chose for the card
  final AiComponent transformer;
  final GpuAdapter card;
  final String? linuxLauncher;
}

/// Why the engine of a panorama cannot be made from what the gate found
class PanoramaSetupRefused implements Exception {
  const PanoramaSetupRefused(this.code, this.message);

  final ImmersiveErrorCode code;
  final String message;
}

/// The engine of a panorama as the gate [found] it available: sd-cli of the archive of this system, the card the gate
/// chose given to it by its index among the cards ggml numbers (`Vulkan<n>`, never with GGML_VK_VISIBLE_DEVICES: review
/// of lot P2, point 4), the models of the catalogue by their id. Throws [PanoramaSetupRefused].
PanoramaSetup panoramaSetupOf(AiGateResult found) {
  final platform = found.platform!;
  final card = found.gpu;
  final report = found.gpuReport;
  final index = card == null || report == null ? null : ggmlVulkanIndexOf(report, card);
  if (card == null || index == null) {
    throw PanoramaSetupRefused(
      ImmersiveErrorCode.gpuUnavailable,
      card == null ? 'No graphics card was chosen' : '${card.name} is not one ggml numbers',
    );
  }
  final components = aiComponentsFor(platform, feature: AiFeature.panorama, graphicsMemory: found.graphicsMemory);
  File need(AiComponent component) =>
      found.fileOf(component.id) ??
      (throw PanoramaSetupRefused(ImmersiveErrorCode.componentsMissing, 'An AI component is missing: ${component.id}'));
  final archive = components.firstWhere((component) => component.kind == AiComponentKind.archive);
  final transformer = components.firstWhere(
    (component) => (component.variantOf ?? component.id) == fluxTransformerComponent.id,
  );
  final folder = p.dirname(need(archive).path);
  final windows = platform == AiPlatform.windowsX64;
  final models = [transformer, fluxVaeComponent, qwenTextEncoderComponent, panoramaLoraComponent, upscalerComponent];
  return PanoramaSetup(
    settings: SdCppSettings(
      sdCli: sdCliIn(folder, windows: windows),
      models: SdCppModels(
        diffusionModel: need(transformer).path,
        vae: need(fluxVaeComponent).path,
        textEncoder: need(qwenTextEncoderComponent).path,
        lora: need(panoramaLoraComponent).path,
        upscaler: need(upscalerComponent).path,
      ),
      device: 'Vulkan$index',
      stallTimeout: card.kind == GpuKind.integrated ? panoramaIntegratedStallTimeout : const Duration(seconds: 180),
    ),
    models: OrtPanoramaModelsSpec(
      libraryPath: found.runtimeFile!.path,
      miganPath: need(miganInpaintComponent).path,
      inpaintSha256: miganInpaintComponent.sha256!,
      mogePath: need(mogeGeometryComponent).path,
      mogeSha256: mogeGeometryComponent.sha256!,
    ),
    requiredFiles: {for (final component in models) need(component).path: component.size},
    transformer: transformer,
    card: card,
    linuxLauncher: platform == AiPlatform.linuxX64 ? p.join(folder, linuxLauncherName) : null,
  );
}

/// The code a panorama (or a splat scene) the gate refused for [reason] fails with, its message being the name of the
/// reason (that of ONNX Runtime when it does not load): a card the gate finds wanting is gpuUnavailable, a shortage of
/// memory outOfMemory, a component missing or damaged componentsMissing; a feature this computer or this version does
/// not offer is told by its reason after "The AI model failed", as the other engines tell it. Every reason is placed,
/// so that a new one has to be.
ImmersiveErrorCode panoramaRefusalCode(AiGateReason? reason) => switch (reason) {
  AiGateReason.gpuNone ||
  AiGateReason.gpuNoAnswer ||
  AiGateReason.gpuIntegrated ||
  AiGateReason.gpuTooSmall ||
  AiGateReason.splatGpuIntegrated ||
  AiGateReason.splatGpuTooSmall ||
  AiGateReason.notYetOnMac => ImmersiveErrorCode.gpuUnavailable,
  AiGateReason.memory || AiGateReason.panoramaMemory || AiGateReason.splatMemory => ImmersiveErrorCode.outOfMemory,
  AiGateReason.componentsMissing || AiGateReason.componentsDamaged || null => ImmersiveErrorCode.componentsMissing,
  AiGateReason.runtimeFailed ||
  AiGateReason.system ||
  AiGateReason.processor ||
  AiGateReason.notHere ||
  AiGateReason.notInThisVersion => ImmersiveErrorCode.modelFailed,
};

/// The engine of the 360° panoramas (lot P3), made for each job from what the gate finds then: the components of the
/// feature panorama and the graphics card the probe reads again (the queue asked it just before, gpu_budget.dart).
/// Nothing is kept between two jobs: sd-cli is a program of its own for each generation, and MoGe-2 and MI-GAN are
/// opened by the step that needs them. A panorama asked while a component is missing fails with componentsMissing,
/// never downloads anything; one without a card that can make it fails with gpuUnavailable and the reason of the gate.
class DesktopPanoramaEngine implements ImmersiveEngine, KeptAiEngine {
  DesktopPanoramaEngine({required this.gate, AiProcessSession Function()? session, this.create})
    : _openSession = session ?? AiProcessSession.new;

  final HardwareGate gate;
  final AiProcessSession Function() _openSession;

  /// Makes the engine of a job from its setup; null: PanoramaEngine on sd-cli ([sdCppEngineFor])
  final ImmersiveEngine Function(PanoramaSetup setup)? create;
  AiProcessSession? _session;
  var _running = false;

  @override
  bool get isRunning => _running;

  /// PanoramaEngine on sd-cli, through a runner of the session of the programs of the app
  static ImmersiveEngine sdCppEngineFor(PanoramaSetup setup, AiProcessSession session) {
    final runner = session.runner(linuxLauncher: setup.linuxLauncher);
    return PanoramaEngine(
      generator: SdCppGenerator(
        runner: runner,
        settings: setup.settings,
        generatorSha256: setup.transformer.sha256!,
        loraSha256: panoramaLoraComponent.sha256!,
      ),
      upscaler: SdCppUpscaler(runner: runner, settings: setup.settings, modelSha256: upscalerComponent.sha256!),
      models: setup.models,
      folders: session.folders,
      requiredFiles: setup.requiredFiles,
      decodeOther: (bytes, {maxWidth}) => decodeWithEngine(bytes, maxWidth: maxWidth),
    );
  }

  @override
  Future<ImmersiveResult> run(
    PanoramaJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    _running = true;
    ImmersiveEngine? engine;
    try {
      final found = await gate.evaluate(feature: AiFeature.panorama);
      if (!found.isAvailable) {
        return ImmersiveResult.failed(
          panoramaRefusalCode(found.reason),
          message: found.message ?? found.reason?.name ?? 'The panorama cannot be made here',
        );
      }
      final setup = panoramaSetupOf(found);
      final create = this.create;
      engine = create == null ? sdCppEngineFor(setup, _session ??= _openSession()) : create(setup);
      return await engine.run(job, cancel: cancel, onProgress: onProgress);
    } on PanoramaSetupRefused catch (refused) {
      return ImmersiveResult.failed(refused.code, message: refused.message);
    } catch (error, stack) {
      _log.warning('The panorama ${job.id} could not run', error, stack);
      return ImmersiveResult.failed(ImmersiveErrorCode.modelFailed, message: '$error');
    } finally {
      await engine?.dispose();
      _running = false;
    }
  }

  /// Nothing is kept between two jobs
  @override
  Future<void> release() async {}

  @override
  Future<void> dispose() => release();
}

/// The programs of a splat scene, read from what the gate found: COLMAP and Brush of the archives of this system, and
/// on Linux the launcher of the archive of COLMAP
class SplatSetup {
  const SplatSetup({required this.colmap, required this.brush, this.linuxLauncher});

  final String colmap;
  final String brush;
  final String? linuxLauncher;
}

/// The programs of a splat scene as the gate [found] them available. Throws [PanoramaSetupRefused] when a component is
/// missing.
SplatSetup splatSetupOf(AiGateResult found) {
  final platform = found.platform!;
  final windows = platform == AiPlatform.windowsX64;
  String program(AiComponent component, String Function(String folder, {bool? windows}) named) {
    final file =
        found.fileOf(component.id) ??
        (throw PanoramaSetupRefused(
          ImmersiveErrorCode.componentsMissing,
          'An AI component is missing: ${component.id}',
        ));
    // The main file of the archive, or the program of its folder
    final expected = named(p.dirname(file.path), windows: windows);
    return p.basename(file.path).toLowerCase() == p.basename(expected).toLowerCase() ? file.path : expected;
  }

  final components = aiComponentsFor(platform, feature: AiFeature.splatScene);
  final colmap = components.firstWhere((component) => component.name == 'COLMAP');
  final brush = components.firstWhere((component) => component.name == 'Brush');
  final colmapPath = program(colmap, colmapIn);
  return SplatSetup(
    colmap: colmapPath,
    brush: program(brush, brushIn),
    linuxLauncher: platform == AiPlatform.linuxX64 ? p.join(p.dirname(colmapPath), linuxLauncherName) : null,
  );
}

/// The folder the autotune cache of Brush is kept in, one folder per card and driver under it: in the support folder
/// of the app, kept from one job to the next
Future<Directory> brushCacheRoot() async =>
    Directory(p.join((await getApplicationSupportDirectory()).path, 'ai-cache', 'brush'));

/// The engine of the splat scenes (lot SP6), made for each job from what the gate finds then: the components of the
/// feature splatScene and the dedicated card the probe reads again (the queue asked it just before, with the need of
/// the splat scenes). COLMAP and Brush run through the session of the programs of the app; Brush asks the card again
/// before it trains, some minutes later. A scene asked while a component is missing fails with componentsMissing,
/// never downloads anything; one without a card that can train it fails with gpuUnavailable and the reason of the
/// gate.
class DesktopSplatEngine implements ImmersiveEngine, KeptAiEngine {
  DesktopSplatEngine({
    required this.gate,
    AiProcessSession Function()? session,
    SplatImagesMaker? images,
    Future<Directory> Function()? cacheRoot,
    this.create,
  }) : _openSession = session ?? AiProcessSession.new,
       _images = images ?? appSplatImages(),
       _cacheRoot = cacheRoot ?? brushCacheRoot;

  final HardwareGate gate;
  final AiProcessSession Function() _openSession;
  final SplatImagesMaker _images;
  final Future<Directory> Function() _cacheRoot;

  /// Makes the engine of a job; null: SplatEngine on the programs of [SplatSetup]
  final ImmersiveEngine Function(SplatSetup setup, AiGateResult found)? create;
  AiProcessSession? _session;
  var _running = false;

  @override
  bool get isRunning => _running;

  @override
  Future<ImmersiveResult> run(
    SplatJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    _running = true;
    try {
      final found = await gate.evaluate(feature: AiFeature.splatScene);
      if (!found.isAvailable) {
        return ImmersiveResult.failed(
          panoramaRefusalCode(found.reason),
          message: found.message ?? found.reason?.name ?? 'The splat scene cannot be made here',
        );
      }
      final setup = splatSetupOf(found);
      final make = create;
      final ImmersiveEngine engine;
      if (make != null) {
        engine = make(setup, found);
      } else {
        final runner = (_session ??= _openSession()).runner(linuxLauncher: setup.linuxLauncher);
        final budget = GpuBudget(
          probe: () => gate.gpuReport(fresh: true),
          need: SplatV1.freeGraphicsMemory,
          cardOf: splatCardOf,
        );
        engine = SplatEngine(
          images: _images,
          colmap: ColmapRunner(runner: runner, colmap: setup.colmap),
          brush: BrushRunner(
            runner: runner,
            brush: setup.brush,
            cardCheck: () => brushCardOf(budget),
            cacheRoot: await _cacheRoot(),
          ),
        );
      }
      return await engine.run(job, cancel: cancel, onProgress: onProgress);
    } on PanoramaSetupRefused catch (refused) {
      return ImmersiveResult.failed(refused.code, message: refused.message);
    } catch (error, stack) {
      _log.warning('The splat scene ${job.id} could not run', error, stack);
      return ImmersiveResult.failed(ImmersiveErrorCode.modelFailed, message: '$error');
    } finally {
      _running = false;
    }
  }

  /// Nothing is kept between two jobs
  @override
  Future<void> release() async {}

  @override
  Future<void> dispose() => release();
}

/// The engine of the splat scenes as the queue is given it: no version is looked for (a scene is a file of its own,
/// beside the photos), so no key of settings
ConversionEngine splatConversionEngine(ImmersiveEngine engine) =>
    ConversionEngine(engine: engine, settingsKey: (source, quarterTurns) => null);

/// The key of the settings a 360° panorama of a photo seen with [quarterTurns] would carry (PanoramaXmp.settingsKey):
/// the transformer and the LoRA of the catalogue, pano-v1 and its steps; the seed is not part of it
String? panoramaSettingsKeyOf(int quarterTurns) => PanoramaXmp(
  pipeline: PanoV1.pipeline,
  generatorSha256: fluxTransformerComponent.sha256,
  generatorLoraSha256: panoramaLoraComponent.sha256,
  steps: PanoV1.steps,
  sourceQuarterTurns: quarterTurns & 3,
).settingsKey;

/// The engine of the 360° panoramas as the queue is given it: the key of the settings, the transformer of the
/// catalogue and the steps of pano-v1 (M3)
ConversionEngine panoramaConversionEngine(ImmersiveEngine engine) => ConversionEngine(
  engine: engine,
  settingsKey: (source, quarterTurns) => panoramaSettingsKeyOf(quarterTurns),
  generator: fluxTransformerComponent.id,
  steps: PanoV1.steps,
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

/// The probe of the graphics cards of this computer: the app started again with its flag (lot C6)
final aiGpuProbeProvider = Provider<GpuProbe>((ref) => ProcessGpuProbe.ofThisApp());

/// Whether "Try on integrated graphics (untested)" is on (desktop_ai.json); off when the settings cannot be read
Future<bool> Function() integratedGpuAllowedOf(DesktopAiSettingsStore store) => () async {
  try {
    return (await store.read()).integratedGpuAllowed;
  } catch (error) {
    _log.warning('The settings of the conversions could not be read: $error');
    return false;
  }
};

/// The hardware gate of this computer, on the components of the app; for the 360° panoramas, on the graphics cards
/// the probe finds
final desktopAiGateProvider = Provider<HardwareGate>(
  (ref) => HardwareGate(
    components: ServiceComponentFiles(ref.watch(aiComponentsServiceProvider)),
    gpu: ref.watch(aiGpuProbeProvider),
    integratedGpuAllowed: integratedGpuAllowedOf(ref.watch(desktopAiSettingsStoreProvider)),
  ),
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

/// The programs of the AI features in this session of the app, opened at the first job that starts one
final aiProcessSessionProvider = Provider<AiProcessSession>((ref) => AiProcessSession());

/// The engine of the 360° panoramas of the app (lot P3)
final desktopPanoramaEngineProvider = Provider<DesktopPanoramaEngine>((ref) {
  final engine = DesktopPanoramaEngine(
    gate: ref.watch(desktopAiGateProvider),
    session: () => ref.read(aiProcessSessionProvider),
  );
  ref.onDispose(() => unawaited(engine.dispose()));
  return engine;
});

/// The engine of the splat scenes of the app (lot SP6)
final desktopSplatEngineProvider = Provider<DesktopSplatEngine>((ref) {
  final engine = DesktopSplatEngine(
    gate: ref.watch(desktopAiGateProvider),
    session: () => ref.read(aiProcessSessionProvider),
  );
  ref.onDispose(() => unawaited(engine.dispose()));
  return engine;
});

/// The engines kept between two jobs, let go before the components are removed or moved: the 3D photos, the 3D scenes
/// (S1), the 3D versions of the 360° panoramas (P1), the 360° panoramas (P3) and the splat scenes (SP6), the last two
/// keeping nothing but telling while they run
final keptAiEnginesProvider = Provider<List<KeptAiEngine>>(
  (ref) => [
    ref.watch(desktopAiEngineProvider),
    ref.watch(desktopSceneEngineProvider),
    ref.watch(desktopStereoPanoramaEngineProvider),
    ref.watch(desktopPanoramaEngineProvider),
    ref.watch(desktopSplatEngineProvider),
  ],
);

/// The engines of the kinds of phases 2 and 3, by kind, each with the key of the settings its files carry: the 3D
/// scene (S1), the 360° panorama (P3), the 3D version of a 360° panorama (P1), and the splat scene (SP6), which has
/// none. The tests give the fakes.
final conversionEnginesProvider = Provider<Map<ConversionKind, ConversionEngine>>(
  (ref) => {
    ConversionKind.sceneFromPhoto: sceneConversionEngine(ref.watch(desktopSceneEngineProvider)),
    ConversionKind.panoramaFromPhoto: panoramaConversionEngine(ref.watch(desktopPanoramaEngineProvider)),
    ConversionKind.stereoPanoramaFromPanorama: stereoPanoramaConversionEngine(
      ref.watch(desktopStereoPanoramaEngineProvider),
    ),
    ConversionKind.splatScene: splatConversionEngine(ref.watch(desktopSplatEngineProvider)),
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
  final gate = ref.watch(desktopAiGateProvider);
  return ConversionTools(
    engine: ref.watch(desktopAiEngineProvider),
    engines: ref.watch(conversionEnginesProvider),
    output: ref.watch(safeWriterOutputProvider),
    finder: ExistingVersionFinder(index: LibraryVersionIndex()),
    creatorTool: aiCreatorTool(version),
    software: aiSoftware(version),
    settings: ref.watch(desktopAiSettingsStoreProvider),
    // The answer of the probe the gate keeps is asked again, so that the dialog and the settings see it too
    gpuBudget: GpuBudget(
      probe: () => gate.gpuReport(fresh: true),
      integratedAllowed: integratedGpuAllowedOf(ref.watch(desktopAiSettingsStoreProvider)),
    ),
  );
}
