// The memory of the graphics card, read again before each job on it (design-final 2026-10-27, section 4.7, point 3):
// a game or a 3D app opened since the gate looked may hold most of it. The probe is started again (gpu_probe.dart) and
// the card the panorama runs on (the rule of the gate, panoramaCardOf) must have the memory of one way to run the job
// free in the budget the system gives it; otherwise the job waits, "360° panoramas need 5.1 GiB of free graphics
// memory, 4.2 GiB free: close games, 3D apps or videos", and the queue asks again a little later, or at once when the
// user asks for it (ConversionQueueNotifier.checkGraphicsCardAgain). A card gone since (an external card unplugged, a
// driver removed) fails the job: "No graphics card can make this panorama". The budget of VK_EXT_memory_budget leaves
// out what other programs hold on the driver of NVIDIA under Windows (V3: 7.5 GB with 4.3 GB held by another
// program): the probe of Windows lowers it to what the counters of Windows leave of the card (windows/runner/
// gpu_probe.cpp, DedicatedUsage).
//
// What the app itself holds of the card counts as used in that budget, as another program's would (issue #13: 1.4 GiB
// of an RTX 2060 of 8 GB on Linux, with a photo open). The queue lets go of what it can before it asks (its paused
// videos and its cached pictures, graphics_release.dart), and the answer that makes the job wait carries the app's
// share apart when the probe could read it ([GpuBudgetWait.appHolds]): the message then says it.
//
// The ways to run a 360° panorama, measured on 4 November 2026 with the app's own sd-cli and its arguments (note
// ai-gpu-budget-2026-11-04/measure.md, sections 2.3 and 2.4). stable-diffusion.cpp keeps 512 MiB of the free memory in
// reserve and cuts its graph into segments when the rest is short, which with the LoRA and the guidance spoils the
// image (M3), and the queue then fails the job as gpuBusy; so the need is the free memory below which it cuts, plus a
// margin for the desktop moving during the run (M3 saw a run fall into segments at its third step):
//  - [PanoramaReference.full], the arguments of M3 (sd-cli reduces the control frame to 1456 x 720 for its reference):
//    5 388 MiB taken on the card, one segment from 5.54 to 5.60 GiB free; 6 GiB asked, 0.4 GiB of margin;
//  - [PanoramaReference.reduced], the reference capped at 1280 x 640 (--ref-image-args vae_input_max_pixels=819200):
//    4 676 MiB taken, one segment from 4.74 to 4.82 GiB free, the same 6144 x 3072 panorama made 15 s sooner; 5.1 GiB
//    asked, 0.28 GiB of margin. The image differs from the full reference's (another latent for the same seed): it is
//    taken only when the full one does not fit, and the packet of the panorama says so (GeneratorReferenceMaxPixels).
// Smaller outputs (1280 x 640, about 4.3 GiB taken) make a smaller panorama with a wider raw seam: not offered. The
// other kinds of jobs, the splat scenes apart (below), run on the processor and ask nothing of the card. The answer of
// a check that passes carries the whole report, so that the generator is given the card the check looked at
// (ggmlVulkanIndexOf), and the way chosen.
//
// A splat scene (lot SP4) asks the same budget twice: in the queue before its job starts, and again by the runner of
// Brush once the poses are found, some minutes later ([brushCardOf]), with the need of the splat scenes
// (SplatV1.freeGraphicsMemory: 2.5 GiB, where M1 measured 1.0 to 1.2 GiB at the peak at 1 024 pixels) and the card
// its own rule chooses (splatCardOf of hardware_gate.dart: a dedicated card only). The queue asks with the need of the
// kind of each job ([gpuNeedOf], lot SP6): a panorama by the ways above, a splat scene by its one figure.

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/splat/brush_runner.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

const _gib = 1024 * 1024 * 1024;

/// The memory of the graphics card a 360° panorama with its full reference needs free when it starts (see the top of
/// this file)
const panoramaFreeGraphicsMemory = 6 * _gib;

/// The pixels of the reference of a panorama made with less memory: 1280 x 640
const panoramaReducedReferencePixels = 1280 * 640;

/// The memory a 360° panorama with the reduced reference needs free when it starts: 5.1 GiB
const panoramaReducedFreeGraphicsMemory = 51 * _gib ~/ 10;

/// A way to make a 360° panorama on the card, from the one that keeps the image of M3 to the one that needs the least
/// memory (see the top of this file)
enum PanoramaReference {
  /// The reference sd-cli makes itself from the control frame
  full(null, panoramaFreeGraphicsMemory),

  /// The reference capped at [panoramaReducedReferencePixels]
  reduced(panoramaReducedReferencePixels, panoramaReducedFreeGraphicsMemory);

  const PanoramaReference(this.maxPixels, this.need);

  /// The cap given to sd-cli (vae_input_max_pixels), null for its own
  final int? maxPixels;

  /// The memory of the card it needs free when it starts
  final int need;
}

/// What a kind of job needs of the graphics card: [bytes] free on the card [cardOf] chooses, or, for a kind that may
/// run with less ([byReferences]), the memory of the first way of GpuBudget.references that fits
class GpuNeed {
  const GpuNeed(this.bytes, this.cardOf, {this.byReferences = false});

  final int bytes;
  final PanoramaCard Function(GpuReport report, {required bool integratedAllowed}) cardOf;

  /// The job runs one of the ways of GpuBudget.references (a panorama, [bytes] being its full reference's need)
  final bool byReferences;
}

/// A 360° panorama: [panoramaFreeGraphicsMemory] on the card of panoramaCardOf, or the 5.1 GiB of its reduced
/// reference (PanoramaReference)
const panoramaGpuNeed = GpuNeed(panoramaFreeGraphicsMemory, panoramaCardOf, byReferences: true);

/// A splat scene: SplatV1.freeGraphicsMemory on the dedicated card of splatCardOf
const splatGpuNeed = GpuNeed(SplatV1.freeGraphicsMemory, splatCardOf);

/// What a job that makes a file of [kind] needs of the graphics card: a splat scene its own, any other job of the card
/// that of a panorama
GpuNeed gpuNeedOf(ImmersiveKind kind) => kind == ImmersiveKind.gaussianSplat ? splatGpuNeed : panoramaGpuNeed;

/// What the graphics card answers before a job
sealed class GpuBudgetCheck {
  const GpuBudgetCheck();
}

/// The card has the memory free: the job starts on it, the way [reference] says
class GpuBudgetReady extends GpuBudgetCheck {
  const GpuBudgetReady(this.card, this.free, this.report, {this.reference = PanoramaReference.full, this.appHolds});

  final GpuAdapter card;
  final int free;

  /// The answer of the probe the card comes from
  final GpuReport report;

  /// The way the panorama is made with the memory free
  final PanoramaReference reference;

  /// The bytes of the card this app holds, null when not read
  final int? appHolds;
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
    this.references = PanoramaReference.values,
    this._appMemoryOf,
    this._need,
    this.cardOf = panoramaCardOf,
  }) : assert(references.isNotEmpty, 'At least one way to run the job'),
       _integratedAllowed = integratedAllowed ?? (() async => false);

  /// Starts the probe of the graphics cards again (the gate keeps its answer in the app)
  final Future<GpuReport> Function() probe;
  final Future<bool> Function() _integratedAllowed;

  /// The ways a job may run, the one preferred first
  final List<PanoramaReference> references;

  /// The share of the app on a card the probe did not read it for (the DRM fdinfo of the app on Linux)
  final Future<int?> Function(GpuAdapter card)? _appMemoryOf;

  /// The one need the budget was made with (the runner of Brush asks a splat scene's); null: the ways of [references]
  final int? _need;

  /// The rule of the gate that chooses the card: that of the panoramas unless told
  final PanoramaCard Function(GpuReport report, {required bool integratedAllowed}) cardOf;

  /// The least memory a job needs free on its card: the need the budget was made with, else that of the way that asks
  /// the least
  int get need => _need ?? _leastReference;

  int get _leastReference => references.map((reference) => reference.need).reduce((a, b) => a < b ? a : b);

  /// Starts the probe again and tells whether a job may start on the card now, and how: a job that [need]s its own
  /// (the kind of the job, [gpuNeedOf]) on the card of its rule, by the first of [references] that fits for a
  /// panorama; without [need], the one the budget was made with on the card of [GpuBudget.cardOf], by [references]
  /// when it was made with none
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
    // One figure: a kind that runs one way (a splat scene), or a budget made with its own need
    final bytes = need == null ? _need : (need.byReferences ? null : need.bytes);
    if (bytes != null) {
      return free >= bytes
          ? GpuBudgetReady(card, free, report, appHolds: appHolds)
          : GpuBudgetWait(card, free, need: bytes, appHolds: appHolds);
    }
    for (final reference in references) {
      if (free >= reference.need) {
        return GpuBudgetReady(card, free, report, reference: reference, appHolds: appHolds);
      }
    }
    return GpuBudgetWait(card, free, need: _leastReference, appHolds: appHolds);
  }
}

/// The answer of [budget] as the runner of Brush asks it before it starts (brush_runner.dart): the card and its report,
/// the memory free while other programs hold it, or the reason of the gate when no card can train
Future<BrushCard> brushCardOf(GpuBudget budget) async => switch (await budget.check()) {
  GpuBudgetReady(:final card, :final report) => BrushCardReady(card, report),
  GpuBudgetWait(:final free) => BrushCardWait(free),
  GpuBudgetUnavailable(:final reason) => BrushCardRefused(reason.name),
};
