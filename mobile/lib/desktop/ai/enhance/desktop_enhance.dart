// The engines of "Enhance (AI)" in the app, one per level, registered in the queue by their kinds
// (desktop_conversion_tools.dart, conversionEnginesProvider): each made for a job from what is on this computer when
// the job runs, the files of its level (enhance_files.dart: the components, or the folder of the developer override)
// and, for the levels of the graphics card, the card the probe reads again then (the queue asked it just before with
// the need of the level, enhance_gpu.dart). Nothing is kept between two jobs: sd-cli is a program of its own for each
// run, and the graphs of VOSR are opened by the worker of each job (9 s of loading in the probe). Its programs run in
// the AiProcessSession of the app, its work folders are those of the session.

import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_files.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_gpu.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/natural_backend.dart';
import 'package:immich_mobile/desktop/ai/enhance/rebuild_backend.dart';
import 'package:immich_mobile/desktop/ai/enhance/sharpen_backend.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/gpu/gpu_probe.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_enhance_manifest.dart';
import 'package:logging/logging.dart';

final _log = Logger('DesktopEnhance');

/// The message of a level whose components are not complete in this version
const enhanceNotInThisVersion = 'notInThisVersion';

/// How long sd-cli may stay silent on an integrated chip (Sharpen allows one)
const _integratedStall = Duration(minutes: 15);

/// See the top of this file
class DesktopEnhanceEngine implements ImmersiveEngine, KeptAiEngine {
  DesktopEnhanceEngine({required this.level, required this.gate, required this._session, this._environment});

  final EnhanceLevel level;
  final HardwareGate gate;
  final AiProcessSession Function() _session;
  final Map<String, String>? _environment;
  var _running = false;

  @override
  bool get isRunning => _running;

  /// The files of the level now: the folder of the developer override when it holds them, else the components
  Future<EnhanceComponentsFound> filesNow(AiPlatform platform) async {
    final probe = enhanceProbeFolder(environment: _environment);
    if (probe != null) {
      final files = enhanceProbeFiles(level, probe);
      if (files != null) {
        _log.info('Enhance (${level.name}) takes the files of the developer override in $probe');
        return (files: files, missing: const <AiComponent>[], notInThisVersion: false);
      }
    }
    return enhanceComponentFiles(level, platform, gate.components);
  }

  @override
  Future<ImmersiveResult> run(
    EnhanceJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    _running = true;
    try {
      final facts = AiHardwareFacts.ofThisComputer();
      final platform = aiPlatformOf(facts.abi);
      if (platform == null) {
        return ImmersiveResult.failed(ImmersiveErrorCode.modelFailed, message: AiGateReason.system.name);
      }
      final found = await filesNow(platform);
      final files = found.files;
      if (files == null) {
        return ImmersiveResult.failed(
          ImmersiveErrorCode.componentsMissing,
          message: found.notInThisVersion
              ? enhanceNotInThisVersion
              : found.missing.map((component) => component.title).join(', '),
        );
      }
      final (backend, refused) = await _backendOf(files);
      if (backend == null) {
        return refused!;
      }
      final session = _session();
      final engine = EnhanceEngine(
        backend: backend,
        workFolder: (id) => session.folders.create('enhance-$id'),
        dropWorkFolder: (folder) => session.folders.delete(folder),
      );
      return await engine.run(job, cancel: cancel, onProgress: onProgress);
    } catch (error, stack) {
      _log.warning('Enhance ${job.id} could not run', error, stack);
      return ImmersiveResult.failed(ImmersiveErrorCode.modelFailed, message: '$error');
    } finally {
      _running = false;
    }
  }

  /// The backend of the level on [files], or the failure that stops the job
  Future<(EnhanceBackend?, ImmersiveResult?)> _backendOf(EnhanceFiles files) async {
    if (level == EnhanceLevel.natural) {
      return (OrtNaturalBackend(files: files.natural!, modelSha256: vosrTransformerComponent.sha256!), null);
    }
    final report = await gate.gpuReport(fresh: true);
    final choice = level == EnhanceLevel.sharpen ? sharpenCardOf(report) : rebuildCardOf(report);
    final card = choice.card;
    final index = card == null ? null : ggmlVulkanIndexOf(report, card);
    if (card == null || choice.refusal != null || index == null) {
      return (
        null,
        ImmersiveResult.failed(
          ImmersiveErrorCode.gpuUnavailable,
          message: (choice.refusal ?? AiGateReason.gpuNone).name,
        ),
      );
    }
    final integrated = card.kind == GpuKind.integrated;
    final sharpen = files.sharpen;
    final rebuild = files.rebuild;
    final settings = SdCppSettings(
      sdCli: sharpen?.sdCli ?? rebuild!.sdCli,
      models: SdCppModels(diffusionModel: '', vae: '', textEncoder: '', lora: '', upscaler: sharpen?.upscaler ?? ''),
      device: 'Vulkan$index',
      card: SdCppCard(name: card.name, integrated: integrated),
      stallTimeout: integrated ? _integratedStall : const Duration(seconds: 180),
    );
    final runner = _session().runner(linuxLauncher: sharpen?.linuxLauncher ?? rebuild?.linuxLauncher);
    if (sharpen != null) {
      final upscaler = SdCppUpscaler(runner: runner, settings: settings, modelSha256: upscalerComponent.sha256!);
      return (SdCppSharpenBackend(upscaler: upscaler), null);
    }
    final backend = SdCppRebuildBackend(
      runner: runner,
      settings: settings,
      files: rebuild!,
      modelSha256: seedVr2DitComponent.sha256!,
      graphicsFree: card.budget == null ? null : card.freeMemory,
    );
    return (backend, null);
  }

  @override
  Future<void> release() async {}

  @override
  Future<void> dispose() async {}
}

/// The engine of a level as the queue is given it: every enhanced photo is a new version, no key of its settings is
/// looked for
ConversionEngine enhanceConversionEngine(ImmersiveEngine engine) =>
    ConversionEngine(engine: engine, settingsKey: (source, quarterTurns) => null);

/// The engines of the three levels of the app
final desktopEnhanceEnginesProvider = Provider<Map<EnhanceLevel, DesktopEnhanceEngine>>((ref) {
  final gate = ref.watch(desktopAiGateProvider);
  final engines = {
    for (final level in EnhanceLevel.values)
      level: DesktopEnhanceEngine(level: level, gate: gate, session: () => ref.read(aiProcessSessionProvider)),
  };
  ref.onDispose(() {
    for (final engine in engines.values) {
      unawaited(engine.dispose());
    }
  });
  return engines;
});
