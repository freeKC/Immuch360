// The memory of the graphics card, read again before each job on it (design-final 2026-10-27, section 4.7, point 3):
// a game or a 3D app opened since the gate looked may hold most of it. The probe is started again (gpu_probe.dart) and
// the card the panorama runs on (the rule of the gate, panoramaCardOf) must have the memory of one way to run the job
// free in the budget the system gives it; otherwise the job waits, "Other apps use the graphics card memory (2.1 GB
// free): close games or 3D apps", and the queue asks again a little later, or at once when the user asks for it
// (ConversionQueueNotifier.checkGraphicsCardAgain). A card gone since (an external card unplugged, a driver removed)
// fails the job: "No graphics card can make this panorama". The budget of VK_EXT_memory_budget leaves out what other
// programs hold on the driver of NVIDIA under Windows (V3: 7.5 GB with 4.3 GB held by another program): the probe of
// Windows lowers it to what the counters of Windows leave of the card (windows/runner/gpu_probe.cpp, DedicatedUsage).
//
// What the app itself holds of the card counts as used in that budget, as another program's would (issue #13: 1.4 GiB
// of an RTX 2060 of 8 GB on Linux, with a photo open). The queue lets go of what it can before it asks (its paused
// videos and its cached pictures, graphics_release.dart), and the answer that makes the job wait carries the app's
// share apart when the probe could read it ([GpuBudgetWait.appHolds]), with the memory it needs.
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
// other kinds of jobs run on the processor and ask nothing of the card. The answer of a check that passes carries the
// whole report, so that the generator is given the card the check looked at (ggmlVulkanIndexOf), and the way chosen.

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';

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
  }) : assert(references.isNotEmpty, 'At least one way to run the job'),
       _integratedAllowed = integratedAllowed ?? (() async => false);

  /// Starts the probe of the graphics cards again (the gate keeps its answer in the app)
  final Future<GpuReport> Function() probe;
  final Future<bool> Function() _integratedAllowed;

  /// The ways a job may run, the one preferred first
  final List<PanoramaReference> references;

  /// The share of the app on a card the probe did not read it for (the DRM fdinfo of the app on Linux)
  final Future<int?> Function(GpuAdapter card)? _appMemoryOf;

  /// The least memory a job needs free on its card: that of the way that asks the least
  int get need => references.map((reference) => reference.need).reduce((a, b) => a < b ? a : b);

  /// Starts the probe again and tells whether a job may start on the card now, and how
  Future<GpuBudgetCheck> check() async {
    final report = await probe();
    final choice = panoramaCardOf(report, integratedAllowed: await _integratedAllowed());
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
    for (final reference in references) {
      if (free >= reference.need) {
        return GpuBudgetReady(card, free, report, reference: reference, appHolds: appHolds);
      }
    }
    return GpuBudgetWait(card, free, need: need, appHolds: appHolds);
  }
}
