// The memory of the graphics card, read again before each job on it (design-final 2026-10-27, section 4.7, point 3):
// a game or a 3D app opened since the gate looked may hold most of it. The probe is started again (gpu_probe.dart) and
// the card the panorama runs on (the rule of the gate, panoramaCardOf) must have the memory the job needs free in the
// budget the system gives it; otherwise the job waits, "360° panoramas need 3.5 GiB of free graphics memory, 3.1 GiB
// free: close games, 3D apps or videos", and the queue asks again a little later, or at once when the user asks for it
// (ConversionQueueNotifier.checkGraphicsCardAgain). A card gone since (an external card unplugged, a driver removed)
// fails the job: "No graphics card can make this panorama". The budget of VK_EXT_memory_budget leaves out what other
// programs hold on the driver of NVIDIA under Windows (V3: 7.5 GB with 4.3 GB held by another program): the probe of
// Windows lowers it to what the counters of Windows leave of the card (windows/runner/gpu_probe.cpp, DedicatedUsage).
//
// What the app itself holds of the card counts as used in that budget, as another program's would (issue #13: 1.4 GiB
// of an RTX 2060 of 8 GB on Linux, with a photo open). The queue lets go of what it can before it asks (its paused
// videos and its cached pictures, graphics_release.dart), and the answer that makes the job wait carries the app's
// share apart when the probe could read it ([GpuBudgetWait.appHolds]): the message then says it.
//
// The need of a 360° panorama, measured on 5 November 2026 with the app's own sd-cli and its arguments at 1536 x 768
// (note ai-gpu-budget-2026-11-05/measure.md, sections 4 and 6): stable-diffusion.cpp keeps 512 MiB of the free memory
// in reserve and, when the rest is short, cuts the graph of its transformer into segments, which gives the same bytes
// as one segment, slower (294 s instead of 202 at the free memory of issue #13, about 8 min near the floor). It runs in
// one segment from 5 716 MiB free ([panoramaWholeGraphicsMemory]), in segments down to 3 212 MiB free, and fails at
// 3 112: [panoramaFreeGraphicsMemory] asks 3.5 GiB, 0.36 GiB above that floor for the desktop moving during the run,
// with the full reference for every card (one image per photo and seed). These figures come from Windows, where the low
// memory was emulated with a budget (--max-vram) on a card sd-cli read 7 188 MiB free on: there its Vulkan reading
// leaves other programs out, so its live check of the card never bound. On Linux that reading counts them, and the live
// check keeps 512 MiB free beyond all sd-cli holds: the floor there is probably 3.3 to 3.45 GiB, and the edge of one
// segment about 0.3 GiB higher, to be confirmed with the "SdCpp" lines of a Linux log (review of lot 13c). The
// reference capped at 1280 x 640 that desktop build 21 took between 5.1 and 6 GiB free is gone: the cut needs no other
// image, and the panoramas it made say so in their packet (GeneratorReferenceMaxPixels). Smaller outputs (1280 x 640)
// make a smaller panorama with a wider raw seam: not offered. The other kinds of jobs, the splat scenes apart (below),
// run on the processor and ask nothing of the card. The answer of a check that passes carries the whole report, so that
// the generator is given the card the check looked at (the guess of ggmlVulkanIndexOf, which sd-cli's own list confirms
// or corrects), the free memory it read (from which sd-cli is given a budget on Windows, [panoramaGeneratorBudget]),
// and whether the generation runs whole ([GpuBudgetReady.whole]), for the queue to wait a few seconds more while the
// app's share comes back.
//
// A splat scene (lot SP4) asks the same budget twice: in the queue before its job starts, and again by the runner of
// Brush once the poses are found, some minutes later ([brushCardOf]), with the need of the splat scenes
// (SplatV1.freeGraphicsMemory: 2.5 GiB, where M1 measured 1.0 to 1.2 GiB at the peak at 1 024 pixels) and the card
// its own rule chooses (splatCardOf of hardware_gate.dart: a dedicated card only). The queue asks with the need of the
// kind of each job ([gpuNeedOf], lot SP6): a panorama by the figures above, a splat scene by its one figure.

import 'dart:io';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/splat/brush_runner.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

const _mib = 1024 * 1024;
const _gib = 1024 * _mib;

/// The memory of the graphics card a 360° panorama needs free when it starts: 3.5 GiB (see the top of this file)
const panoramaFreeGraphicsMemory = 7 * _gib ~/ 2;

/// The free memory from which the generator of a 360° panorama runs its transformer whole, in one segment, as measured
/// on 5 November 2026 (5 716 MiB; it cut at 5 701); below it the generation runs in segments, slower, the same image
const panoramaWholeGraphicsMemory = 5716 * _mib;

/// What sd-cli keeps of the free memory of the card in reserve when it reads it itself (512 MiB, measure of 5 November
/// 2026, section 1): the budget it is given on Windows is the free memory the queue read, less as much
const panoramaGeneratorReserve = 512 * _mib;

/// The budget sd-cli is given for a panorama (--max-vram) when the queue read [free] bytes free on its card just before
/// the job: on Windows only, [free] less [panoramaGeneratorReserve]; null on Linux, and when nothing would be left.
///
/// sd-cli fixes its budget at its start either way: its auto-fit plan writes it into the limits its runner reads once,
/// at load (the pinned build, backend_fit.cpp 466-472). Without --max-vram that budget is the free memory sd-cli reads
/// less its reserve of 512 MiB; a positive --max-vram gives the smaller of the value and that free memory, with no
/// reserve (backend_fit.cpp 152-157). A switch to segments in the middle of a run (M3 saw one segment become 27 at the
/// third step) comes from another check, live at every step, which reads the card again and keeps 512 MiB free plus
/// 128 MiB (model_manager.cpp 1770-1772): the flag does not change it.
///
/// On Windows, sd-cli's Vulkan reading leaves out what other programs hold (7 188 MiB in every run of the measure),
/// while the probe lowers its own to what Windows' counters leave of the card (windows/runner/gpu_probe.cpp): the
/// budget from the probe is the truthful one. On Linux both read VK_EXT_memory_budget a few seconds apart, and a budget
/// from the probe could only lower sd-cli's reserve when it reads less, or let auto-fit put the transformer's weights
/// on the card where its own reading streams them from the computer's memory: sd-cli reads the card itself there.
int? panoramaGeneratorBudget(int free, {required bool windows}) =>
    windows && free > panoramaGeneratorReserve ? free - panoramaGeneratorReserve : null;

/// What a kind of job needs of the graphics card: [bytes] free on the card [cardOf] chooses, and for a kind that runs
/// faster with more ([whole], a panorama in one segment), the free memory from which it runs at its best
class GpuNeed {
  const GpuNeed(this.bytes, this.cardOf, {this.whole});

  final int bytes;
  final PanoramaCard Function(GpuReport report, {required bool integratedAllowed}) cardOf;

  /// The free memory from which the job runs whole; null for a kind that runs the same with any memory above [bytes]
  final int? whole;
}

/// A 360° panorama: [panoramaFreeGraphicsMemory] on the card of panoramaCardOf, whole from
/// [panoramaWholeGraphicsMemory]
const panoramaGpuNeed = GpuNeed(panoramaFreeGraphicsMemory, panoramaCardOf, whole: panoramaWholeGraphicsMemory);

/// A splat scene: SplatV1.freeGraphicsMemory on the dedicated card of splatCardOf
const splatGpuNeed = GpuNeed(SplatV1.freeGraphicsMemory, splatCardOf);

/// What a job that makes a file of [kind] needs of the graphics card: a splat scene its own, any other job of the card
/// that of a panorama
GpuNeed gpuNeedOf(ImmersiveKind kind) => kind == ImmersiveKind.gaussianSplat ? splatGpuNeed : panoramaGpuNeed;

/// What the graphics card answers before a job
sealed class GpuBudgetCheck {
  const GpuBudgetCheck();
}

/// The card has the memory free: the job starts on it, [free] bytes being free
class GpuBudgetReady extends GpuBudgetCheck {
  const GpuBudgetReady(this.card, this.free, this.report, {this.appHolds, this.whole = true});

  final GpuAdapter card;
  final int free;

  /// The answer of the probe the card comes from
  final GpuReport report;

  /// The bytes of the card this app holds, null when not read
  final int? appHolds;

  /// Whether the job runs at its best with that memory (GpuNeed.whole): false for a panorama whose generator will run
  /// in segments, slower
  final bool whole;
}

/// The memory free is short: the job waits, [free] bytes being free now of the [need] it asks, this app holding
/// [appHolds] of the card (null when it could not be read)
class GpuBudgetWait extends GpuBudgetCheck {
  const GpuBudgetWait(this.card, this.free, {required this.need, this.appHolds});

  final GpuAdapter card;
  final int free;
  final int need;
  final int? appHolds;
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
    this._appMemoryOf,
    this._need,
    this.cardOf = panoramaCardOf,
    bool? windows,
  }) : _integratedAllowed = integratedAllowed ?? (() async => false),
       windows = windows ?? Platform.isWindows;

  /// Starts the probe of the graphics cards again (the gate keeps its answer in the app)
  final Future<GpuReport> Function() probe;
  final Future<bool> Function() _integratedAllowed;

  /// The share of the app on a card the probe did not read it for (the DRM fdinfo of the app on Linux)
  final Future<int?> Function(GpuAdapter card)? _appMemoryOf;

  /// The one need the budget was made with (the runner of Brush asks a splat scene's); null: a panorama's
  final int? _need;

  /// The rule of the gate that chooses the card: that of the panoramas unless told
  final PanoramaCard Function(GpuReport report, {required bool integratedAllowed}) cardOf;

  /// Whether the probe reads the free memory of Windows, lowered below Vulkan's figure by what other programs hold:
  /// only then is the generator given a budget from it ([panoramaGeneratorBudget])
  final bool windows;

  /// The memory a job needs free on its card: the need the budget was made with, else a panorama's
  int get need => _need ?? panoramaFreeGraphicsMemory;

  /// Starts the probe again and tells whether a job may start on the card now: a job that [need]s its own (the kind
  /// of the job, [gpuNeedOf]) on the card of its rule; without [need], the one the budget was made with on the card of
  /// [GpuBudget.cardOf], a panorama's when it was made with none
  Future<GpuBudgetCheck> check({GpuNeed? need}) async {
    final report = await probe();
    final choice = (need?.cardOf ?? cardOf)(report, integratedAllowed: await _integratedAllowed());
    final card = choice.card;
    if (card == null || choice.refusal != null) {
      return GpuBudgetUnavailable(choice.refusal ?? AiGateReason.gpuNone);
    }
    final free = card.freeMemory;
    var appHolds = card.appMemory;
    final read = _appMemoryOf;
    if (appHolds == null && read != null) {
      try {
        appHolds = await read(card);
      } catch (_) {
        appHolds = null;
      }
    }
    final bytes = need?.bytes ?? this.need;
    // A kind asked with its own need says whether it runs better with more; a budget made with one runs the same
    final whole = need != null ? need.whole : (_need == null ? panoramaGpuNeed.whole : null);
    return free >= bytes
        ? GpuBudgetReady(card, free, report, appHolds: appHolds, whole: whole == null || free >= whole)
        : GpuBudgetWait(card, free, need: bytes, appHolds: appHolds);
  }
}

/// The answer of [budget] as the runner of Brush asks it before it starts (brush_runner.dart): the card and its report,
/// the memory free while other programs hold it, or the reason of the gate when no card can train
Future<BrushCard> brushCardOf(GpuBudget budget) async => switch (await budget.check()) {
  GpuBudgetReady(:final card, :final report) => BrushCardReady(card, report),
  GpuBudgetWait(:final free) => BrushCardWait(free),
  GpuBudgetUnavailable(:final reason) => BrushCardRefused(reason.name),
};
