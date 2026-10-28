// The memory of the graphics card, read again before each job on it (design-final 2026-10-27, section 4.7, point 3):
// a game or a 3D app opened since the gate looked may hold most of it. The probe is started again (gpu_probe.dart) and
// the card the panorama runs on (the rule of the gate, panoramaCardOf) must have [panoramaFreeGraphicsMemory] free in
// the budget the system gives it; otherwise the job waits, "Other apps use the graphics card memory (2.1 GB free):
// close games or 3D apps", and the queue asks again a little later, or at once when the user asks for it
// (ConversionQueueNotifier.checkGraphicsCardAgain). A card gone since (an external card unplugged, a driver removed)
// fails the job: "No graphics card can make this panorama".
//
// Why 6 GiB (M3, section 9, point 6): stable-diffusion.cpp took 5.39 GiB of the card for the transformer in Q4_0 at
// 1536 x 768, and keeps 512 MiB of the free memory in reserve; with less free, it cuts its graph into segments, which
// with the LoRA and the guidance spoils the image. The answer of a check that passes carries the whole report, so that
// the generator is given the card the check looked at (ggmlVulkanIndexOf).

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';

/// The memory of the graphics card a 360° panorama needs free when it starts (see the top of this file)
const panoramaFreeGraphicsMemory = 6 * 1024 * 1024 * 1024;

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
  GpuBudget({required this.probe, Future<bool> Function()? integratedAllowed, this.need = panoramaFreeGraphicsMemory})
    : _integratedAllowed = integratedAllowed ?? (() async => false);

  /// Starts the probe of the graphics cards again (the gate keeps its answer in the app)
  final Future<GpuReport> Function() probe;
  final Future<bool> Function() _integratedAllowed;

  /// The memory a job needs free on its card
  final int need;

  /// Starts the probe again and tells whether a job may start on the card now
  Future<GpuBudgetCheck> check() async {
    final report = await probe();
    final choice = panoramaCardOf(report, integratedAllowed: await _integratedAllowed());
    final card = choice.card;
    if (card == null || choice.refusal != null) {
      return GpuBudgetUnavailable(choice.refusal ?? AiGateReason.gpuNone);
    }
    final free = card.freeMemory;
    return free >= need ? GpuBudgetReady(card, free, report) : GpuBudgetWait(card, free);
  }
}
