// The memory of the graphics card, read again before each job on it (design-final 2026-10-27, section 4.7, point 3):
// a game or a 3D app opened since the gate looked may hold most of it. The probe is started again (gpu_probe.dart) and
// the card the panorama runs on (the rule of the gate, panoramaCardOf) must have [panoramaFreeGraphicsMemory] free in
// the budget the system gives it; otherwise the job waits, "Other apps use the graphics card memory (2.1 GB free):
// close games or 3D apps", and the queue asks again a little later, or at once when the user asks for it
// (ConversionQueueNotifier.checkGraphicsCardAgain). A card gone since (an external card unplugged, a driver removed)
// fails the job: "No graphics card can make this panorama". The budget of VK_EXT_memory_budget leaves out what other
// programs hold on the driver of NVIDIA under Windows (V3: 7.5 GB with 4.3 GB held by another program): the probe of
// Windows lowers it to what the counters of Windows leave of the card (windows/runner/gpu_probe.cpp, DedicatedUsage).
//
// Why 6 GiB (M3, section 9, point 6): stable-diffusion.cpp took 5.39 GiB of the card for the transformer in Q4_0 at
// 1536 x 768, and keeps 512 MiB of the free memory in reserve; with less free, it cuts its graph into segments, which
// with the LoRA and the guidance spoils the image. The answer of a check that passes carries the whole report, so that
// the generator is given the card the check looked at (ggmlVulkanIndexOf).
//
// A splat scene (lot SP4) asks the same budget twice: in the queue before its job starts, and again by the runner of
// Brush once the poses are found, some minutes later ([brushCardOf]), with the need of the splat scenes
// (SplatV1.freeGraphicsMemory: 2.5 GiB, where M1 measured 1.0 to 1.2 GiB at the peak at 1 024 pixels) and the card
// its own rule chooses (splatCardOf of hardware_gate.dart: a dedicated card only). The queue asks with the need of the
// kind of each job ([gpuNeedOf], lot SP6).

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/splat/brush_runner.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The memory of the graphics card a 360° panorama needs free when it starts (see the top of this file)
const panoramaFreeGraphicsMemory = 6 * 1024 * 1024 * 1024;

/// What a kind of job needs of the graphics card: [bytes] free on the card [cardOf] chooses
class GpuNeed {
  const GpuNeed(this.bytes, this.cardOf);

  final int bytes;
  final PanoramaCard Function(GpuReport report, {required bool integratedAllowed}) cardOf;
}

/// A 360° panorama: [panoramaFreeGraphicsMemory] on the card of panoramaCardOf
const panoramaGpuNeed = GpuNeed(panoramaFreeGraphicsMemory, panoramaCardOf);

/// A splat scene: SplatV1.freeGraphicsMemory on the dedicated card of splatCardOf
const splatGpuNeed = GpuNeed(SplatV1.freeGraphicsMemory, splatCardOf);

/// What a job that makes a file of [kind] needs of the graphics card: a splat scene its own, any other job of the card
/// that of a panorama
GpuNeed gpuNeedOf(ImmersiveKind kind) => kind == ImmersiveKind.gaussianSplat ? splatGpuNeed : panoramaGpuNeed;

/// What the graphics card answers before a job
sealed class GpuBudgetCheck {
  const GpuBudgetCheck();
}

/// The card has the memory free: the job starts on it
class GpuBudgetReady extends GpuBudgetCheck {
  const GpuBudgetReady(this.card, this.free, this.report);

  final GpuAdapter card;
  final int free;

  /// The answer of the probe the card comes from
  final GpuReport report;
}

/// Other programs hold the memory of the card: the job waits, [free] bytes being free now
class GpuBudgetWait extends GpuBudgetCheck {
  const GpuBudgetWait(this.card, this.free);

  final GpuAdapter card;
  final int free;
}

/// No card can take the job now, for [reason] (the reasons of the gate)
class GpuBudgetUnavailable extends GpuBudgetCheck {
  const GpuBudgetUnavailable(this.reason);

  final AiGateReason reason;
}

/// See the top of this file
class GpuBudget {
  GpuBudget({
    required this.probe,
    Future<bool> Function()? integratedAllowed,
    this.need = panoramaFreeGraphicsMemory,
    this.cardOf = panoramaCardOf,
  }) : _integratedAllowed = integratedAllowed ?? (() async => false);

  /// Starts the probe of the graphics cards again (the gate keeps its answer in the app)
  final Future<GpuReport> Function() probe;
  final Future<bool> Function() _integratedAllowed;

  /// The memory a job needs free on its card
  final int need;

  /// The rule of the gate that chooses the card: that of the panoramas unless told
  final PanoramaCard Function(GpuReport report, {required bool integratedAllowed}) cardOf;

  /// Starts the probe again and tells whether a job may start on the card now: a job that [need]s its own (the kind
  /// of the job, [gpuNeedOf]), else one of [GpuBudget.need] on the card of [GpuBudget.cardOf]
  Future<GpuBudgetCheck> check({GpuNeed? need}) async {
    final report = await probe();
    final choice = (need?.cardOf ?? cardOf)(report, integratedAllowed: await _integratedAllowed());
    final card = choice.card;
    if (card == null || choice.refusal != null) {
      return GpuBudgetUnavailable(choice.refusal ?? AiGateReason.gpuNone);
    }
    final free = card.freeMemory;
    return free >= (need?.bytes ?? this.need) ? GpuBudgetReady(card, free, report) : GpuBudgetWait(card, free);
  }
}

/// The answer of [budget] as the runner of Brush asks it before it starts (brush_runner.dart): the card and its report,
/// the memory free while other programs hold it, or the reason of the gate when no card can train
Future<BrushCard> brushCardOf(GpuBudget budget) async => switch (await budget.check()) {
  GpuBudgetReady(:final card, :final report) => BrushCardReady(card, report),
  GpuBudgetWait(:final free) => BrushCardWait(free),
  GpuBudgetUnavailable(:final reason) => BrushCardRefused(reason.name),
};
