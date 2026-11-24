// The graphics card of the levels of "Enhance (AI)" that run on it, as the queue asks it before each job (gpu_budget.dart):
// Sharpen takes any Vulkan card the app numbers, an integrated chip too (x4plus took 559 MiB on the card in the probe),
// whatever "Try on integrated graphics" says, which is the switch of the 360° panoramas; Rebuild details a dedicated
// card only, with 4.5 GB free (3.7 to 3.9 GB above the desktop in the probe). Natural runs on the processor.

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_plan.dart';
import 'package:immich_mobile/desktop/ai/gpu/gpu_budget.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';

/// The card of Sharpen: the dedicated card, else the integrated chip
PanoramaCard sharpenCardOf(GpuReport report, {bool integratedAllowed = true}) =>
    panoramaCardOf(report, integratedAllowed: true);

/// The card of Rebuild details: a dedicated card only
PanoramaCard rebuildCardOf(GpuReport report, {bool integratedAllowed = false}) =>
    panoramaCardOf(report, integratedAllowed: false);

/// What a job of [level] asks of the card; null for Natural
GpuNeed? enhanceGpuNeedOf(EnhanceLevel level) => switch (level) {
  EnhanceLevel.sharpen => const GpuNeed(sharpenFreeGraphicsMemory, sharpenCardOf),
  EnhanceLevel.rebuild => const GpuNeed(rebuildFreeGraphicsMemory, rebuildCardOf),
  EnhanceLevel.natural => null,
};

/// The card [report] gives a level of the card, as the gates of the dialog read it (enhance_plan.dart); null when
/// none fits or the level runs on the processor
EnhanceCard? enhanceCardOf(EnhanceLevel level, GpuReport report) {
  final choice = switch (level) {
    EnhanceLevel.sharpen => sharpenCardOf(report),
    EnhanceLevel.rebuild => panoramaCardOf(report, integratedAllowed: true),
    EnhanceLevel.natural => null,
  };
  final card = choice?.card;
  if (card == null) {
    return null;
  }
  return EnhanceCard(
    name: card.name,
    dedicated: card.kind == GpuKind.discrete,
    localMemory: card.localMemory,
    freeMemory: card.budget == null ? null : card.freeMemory,
  );
}
