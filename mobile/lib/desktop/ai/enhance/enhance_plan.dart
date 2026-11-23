// What "Enhance (AI)" allows on a computer, level by level, and how long it takes, from the figures of the probe of
// 23 November 2026 (probe-e0.md, sections 4 and 7) on the laptop of the owner: an Intel Core i9-13980HX of 24 threads,
// 16 GB of memory, an RTX 4060 Laptop of 8 GB.
//
// Gates, in words the dialog can say:
//  - a photo of more than 50 megapixels is refused at every level (the app tiles a picture whatever its size, but the
//    buffers of the blend and the time grow with it; the probe went up to 12 MP);
//  - Sharpen needs a Vulkan graphics card of 2 GB (x4plus took 559 MiB on the card), dedicated or integrated;
//  - Rebuild details needs a dedicated card of 6 GB (3.7 to 3.9 GB above the desktop in the probe) and, when the run
//    starts, 4.5 GB free on it (the queue asks the card again); on the processor SeedVR2 was refused by its own
//    memory checks or would take well over 20 minutes for 3 MP, so there is no processor fallback;
//  - Natural runs on the processor and took 8.5 to 9.7 GB of commit and 5.5 GB of working set: a computer of less than
//    16 GB is refused, and less than 5.5 GB free is a warning;
//  - the memory free of the computer: the engine refused SeedVR2 runs three times on the 16 GB laptop when 1 to 2 GB
//    were free ("RAM graph capacity exceeded"), so the dialog says "close other programs" below the need of the level
//    (1.5 GB for Sharpen, 3 GB for Rebuild details), and the engine turns such a refusal into the same words;
//  - those needs were measured up to 12 MP; above, the buffers of the app grow with the photo (the float sums of the
//    blend, the colour fix, the copies between isolates: about 40 bytes a pixel), so each need takes 40 bytes for
//    every pixel above 12 MP, 1.5 GB more at 50 MP (enhanceExtraMemoryOf);
//  - on a Mac, Natural runs on an Apple chip; Sharpen and Rebuild details wait for the Metal build of stable-diffusion.cpp
//    (a later lot): the sd-cli the app ships has no Mac build, and x4plus on a processor took 8.3 minutes for 3 MP. An
//    Intel Mac has ONNX Runtime 1.23.2, on which VOSR was never run: not offered there.
//
// Times (wall time of the whole run, loading included):
//  - Sharpen: 28.3 s for 3 MP, 110.5 s for 12 MP, so 2 s and 9.1 s per megapixel;
//  - Rebuild details: 35.0 s for 20 tiles, 93.9 s for 63, so 7.6 s and 1.37 s per tile of 512 px; about 20 s more the
//    first time, while the Vulkan shaders compile;
//  - Natural: 16 s per tile on 22 threads of ONNX Runtime (16.4 s for 3 MP, 15.5 s for 12 MP) and 9 s of loading, the
//    time per tile in proportion to the threads (a laptop with half the cores, about twice as long).
// Another card or processor is not measured: the dialog says "on this computer, about" and the panel learns the real
// time as for the other kinds.

import 'dart:math' as math;

import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_pixels.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';

const _mib = 1024 * 1024;
const _gib = 1024 * _mib;

/// The largest photo every level takes, in pixels
const enhanceMaxPixels = 50 * 1000 * 1000;

/// The memory free each level needs on the computer (see the top of this file)
const sharpenFreeMemory = 3 * _gib ~/ 2;
const rebuildFreeMemory = 3 * _gib;
const naturalFreeMemory = 11 * _gib ~/ 2;

/// The memory of a computer Natural runs on: 16 GB, which Windows reports as a little less
const naturalPhysicalMemory = 15 * _gib;

/// The graphics card each level of the card needs, and the memory free on it when a run starts
const sharpenCardMemory = 2 * _gib;
const sharpenFreeGraphicsMemory = _gib;
const rebuildCardMemory = 6 * _gib;
const rebuildFreeGraphicsMemory = 9 * _gib ~/ 2;

/// The memory a job of each level may take on the computer, for the queue that runs it beside a job of the other lane
const sharpenJobMemory = 2 * _gib;
const rebuildJobMemory = 5 * _gib;
const naturalJobMemory = 10 * _gib;

/// A run longer than this is said to be long
const enhanceLongRun = Duration(minutes: 20);

/// The graphics card the levels of the card would run on
class EnhanceCard {
  const EnhanceCard({required this.name, required this.dedicated, required this.localMemory, this.freeMemory});

  final String name;
  final bool dedicated;

  /// Its memory, and what is free now when the probe could read it
  final int localMemory;
  final int? freeMemory;
}

/// What the gates read of this computer
class EnhanceMachine {
  const EnhanceMachine({required this.platform, this.physicalMemory, this.freeMemory, this.processors = 8, this.card});

  /// Null for a system or a processor the AI features do not run on
  final AiPlatform? platform;
  final int? physicalMemory;
  final int? freeMemory;

  /// Logical processors
  final int processors;

  /// The card the levels of the card would take, null when there is none (no Vulkan, no answer of the probe)
  final EnhanceCard? card;
}

/// Why a level is not offered for a photo on this computer
enum EnhanceRefusal {
  /// Not on this system (a phone, the headset, an unknown processor)
  notOnThisSystem,

  /// Sharpen and Rebuild details on a Mac: the Metal build of the engine is a later lot
  macNotYet,

  /// Natural on an Intel Mac, whose ONNX Runtime never ran the model
  intelMacNotChecked,

  /// No graphics card the engine can use (Vulkan)
  noGraphicsCard,

  /// Rebuild details on an integrated chip
  dedicatedCardNeeded,

  /// A card with less memory than the level needs
  graphicsCardTooSmall,

  /// Natural on a computer of less than 16 GB
  memoryTooSmall,

  /// A photo of more than 50 megapixels
  tooLarge,
}

/// What the dialog says beside a level that runs
enum EnhanceWarning {
  /// Less memory free than the level needs: close other programs first
  closeOtherPrograms,

  /// The card has less memory free than the level needs now: the job waits for it
  graphicsMemoryBusy,

  /// More than 20 minutes for this photo
  longRun,
}

/// A level for one photo on this computer: refused with its reason, or offered with its warnings and its time
class EnhanceVerdict {
  const EnhanceVerdict(this.level, {this.refusal, this.warnings = const [], this.estimate, this.memoryNeeded});

  final EnhanceLevel level;
  final EnhanceRefusal? refusal;
  final List<EnhanceWarning> warnings;

  /// How long it takes here, as far as the measures tell; null when refused
  final Duration? estimate;

  /// The memory free it needs on the computer
  final int? memoryNeeded;

  bool get isOffered => refusal == null;
}

/// The size up to which the needs of memory were measured, in pixels
const enhanceMeasuredPixels = 12 * 1000 * 1000;

/// What the buffers of the app take per pixel of the photo (see the top of this file)
const enhanceBytesPerPixel = 40;

/// The memory a photo of [pixels] needs above the needs measured up to 12 MP; nothing when its size is not known
int enhanceExtraMemoryOf(int? pixels) =>
    pixels == null ? 0 : enhanceBytesPerPixel * math.max(0, pixels - enhanceMeasuredPixels);

/// The memory free [level] needs on the computer for a photo of [pixels]
int enhanceFreeMemoryOf(EnhanceLevel level, {int? pixels}) =>
    enhanceExtraMemoryOf(pixels) +
    switch (level) {
      EnhanceLevel.sharpen => sharpenFreeMemory,
      EnhanceLevel.rebuild => rebuildFreeMemory,
      EnhanceLevel.natural => naturalFreeMemory,
    };

/// What a job of [level] may take of the memory of the computer for a photo of [pixels]
int enhanceJobMemoryOf(EnhanceLevel level, {int? pixels}) =>
    enhanceExtraMemoryOf(pixels) +
    switch (level) {
      EnhanceLevel.sharpen => sharpenJobMemory,
      EnhanceLevel.rebuild => rebuildJobMemory,
      EnhanceLevel.natural => naturalJobMemory,
    };

/// The memory free on the card [level] needs when its run starts; null for Natural, which runs on the processor
int? enhanceFreeGraphicsMemoryOf(EnhanceLevel level) => switch (level) {
  EnhanceLevel.sharpen => sharpenFreeGraphicsMemory,
  EnhanceLevel.rebuild => rebuildFreeGraphicsMemory,
  EnhanceLevel.natural => null,
};

/// The verdict of [level] for a photo of [width] x [height] on [machine] (see the top of this file)
EnhanceVerdict enhanceVerdict(EnhanceLevel level, EnhanceMachine machine, {required int width, required int height}) {
  EnhanceVerdict refused(EnhanceRefusal reason) => EnhanceVerdict(level, refusal: reason);
  final platform = machine.platform;
  final mac = platform == AiPlatform.macosArm64 || platform == AiPlatform.macosX64;
  if (platform == null || platform == AiPlatform.questArm64) {
    return refused(EnhanceRefusal.notOnThisSystem);
  }
  if (mac && level.onGraphicsCard) {
    return refused(EnhanceRefusal.macNotYet);
  }
  if (platform == AiPlatform.macosX64) {
    return refused(EnhanceRefusal.intelMacNotChecked);
  }
  if (width * height > enhanceMaxPixels) {
    return refused(EnhanceRefusal.tooLarge);
  }
  final warnings = <EnhanceWarning>[];
  final card = machine.card;
  if (level.onGraphicsCard) {
    if (card == null) {
      return refused(EnhanceRefusal.noGraphicsCard);
    }
    if (level == EnhanceLevel.rebuild && !card.dedicated) {
      return refused(EnhanceRefusal.dedicatedCardNeeded);
    }
    final minimum = level == EnhanceLevel.rebuild ? rebuildCardMemory : sharpenCardMemory;
    if (card.localMemory < minimum) {
      return refused(EnhanceRefusal.graphicsCardTooSmall);
    }
    final free = card.freeMemory;
    if (free != null && free < enhanceFreeGraphicsMemoryOf(level)!) {
      warnings.add(EnhanceWarning.graphicsMemoryBusy);
    }
  } else {
    final physical = machine.physicalMemory;
    if (physical != null && physical < naturalPhysicalMemory) {
      return refused(EnhanceRefusal.memoryTooSmall);
    }
  }
  final need = enhanceFreeMemoryOf(level, pixels: width * height);
  final free = machine.freeMemory;
  if (free != null && free < need) {
    warnings.add(EnhanceWarning.closeOtherPrograms);
  }
  final estimate = enhanceEstimate(level, width, height, processors: machine.processors);
  if (estimate > enhanceLongRun) {
    warnings.add(EnhanceWarning.longRun);
  }
  return EnhanceVerdict(level, warnings: warnings, estimate: estimate, memoryNeeded: need);
}

/// How long [level] takes for a photo of [width] x [height], from the measures of the probe (see the top of this file)
Duration enhanceEstimate(EnhanceLevel level, int width, int height, {int processors = 24}) {
  final megapixels = width * height / 1e6;
  final tiles = planTiles(width, height).length;
  final seconds = switch (level) {
    EnhanceLevel.sharpen => 2 + 9.1 * megapixels,
    EnhanceLevel.rebuild => 7.6 + 1.37 * tiles,
    EnhanceLevel.natural => 9 + tiles * 16.0 * 22 / math.max(1, processors - 2),
  };
  return Duration(milliseconds: (seconds * 1000).round());
}

/// The time of a batch of photos of [sizes] (width, height) at [level], the refused ones apart
Duration enhanceBatchEstimate(EnhanceLevel level, EnhanceMachine machine, Iterable<(int, int)> sizes) {
  var total = Duration.zero;
  for (final (width, height) in sizes) {
    total += enhanceVerdict(level, machine, width: width, height: height).estimate ?? Duration.zero;
  }
  return total;
}
