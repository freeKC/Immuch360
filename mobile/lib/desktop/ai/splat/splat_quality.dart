// The quality of a splat scene (lot Q1, FreeKC's decision of 5 November 2026, from the measure
// store/m2/splat-maker-2026-11-01/quality-measure-2026-11-05.md): what the dialog tells of each of its three lines
// before anything runs, and the definition of Maximum.
//
// Maximum is Detailed at the definition of the source, as far as the memory of the computer holds it: Brush 0.3 decodes
// every image whole before it trains, and the measure found its private memory some 1.3 GB plus 5 bytes a pixel of the
// images it loads plus 2.2 KB a gaussian, its graphics memory some 1.2 GB plus 2 KB a gaussian. The 140 frames of an
// 8K video took 11.4 GB in 26 s on the PC of 16 GB of the measure, emptied the memory of Windows and crashed Brush: so
// the app prepares the images at the largest definition whose memory, for a scene of a million gaussians, fits in half
// of the physical memory and in the memory free when the dialog opens (less the reserve of the processes), and in the
// graphics memory of the card; never more than the longest side of the largest image. When that comes back to the
// 1 920 pixels of Detailed (a video of 1080p, photos no larger, a computer whose memory is short for more), Maximum
// is the same as Detailed on this computer and its line is greyed.
//
// The sizes: the .spz takes some 24 bytes a gaussian (22.6 to 25.3 measured), the .ply 236; Headset trains 150 000 at
// most, Detailed and Maximum as many as the scene grows (126 000 to 131 000 for an object, 721 000 to 846 000 for a
// place in the measure), told here as 150 000 and 850 000. The .spz of Headset is the copy for the headset: for an
// object, the copy cropped to it (40 365 gaussians, 1.0 MB in the measure), told as 48 000 (review of lot Q1); its
// .ply keeps the whole scene. Pure Dart: no Flutter.

import 'dart:math' as math;

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The size of one image a scene trains from, in pixels
typedef SplatImageSize = ({int width, int height});

/// The pixels of [image] once reduced to [resolution] on its longest side, never enlarged
int _pixelsAt(SplatImageSize image, int resolution) {
  final long = math.max(image.width, image.height);
  if (long <= 0) {
    return 0;
  }
  if (long <= resolution) {
    return image.width * image.height;
  }
  final ratio = resolution / long;
  return (image.width * ratio).round() * (image.height * ratio).round();
}

/// The private memory Brush takes to train from [images] at [resolution] pixels on their longest side, for a scene of
/// [gaussians] gaussians (the memory model of the measure, see the top of this file)
int splatBrushMemory(Iterable<SplatImageSize> images, int resolution, {int gaussians = SplatV1.plannedGaussians}) {
  var pixels = 0;
  for (final image in images) {
    pixels += _pixelsAt(image, resolution);
  }
  return SplatV1.brushMemoryBase + SplatV1.brushMemoryPerPixel * pixels + SplatV1.brushMemoryPerGaussian * gaussians;
}

/// The graphics memory Brush takes for a scene of [gaussians] gaussians
int splatBrushCardMemory({int gaussians = SplatV1.plannedGaussians}) =>
    SplatV1.brushCardBase + SplatV1.brushCardPerGaussian * gaussians;

/// What Maximum may take of the memory of a computer of [physical] bytes with [available] free now: half of the
/// physical memory, and the memory free less the reserve of the processes when the system says it; null when the
/// physical memory is not known
int? splatMaximumBudget({required int? physical, int? available}) {
  if (physical == null || physical <= 0) {
    return null;
  }
  final share = (physical * SplatV1.maximumMemoryShare).floor();
  return available == null ? share : math.min(share, available - SplatV1.colmapMemoryReserve);
}

/// The definition of Maximum for [images] (each photo, or each frame of the video) on a computer of [physical] bytes of
/// memory, [available] of it free, and a card of [cardMemory] bytes: the largest multiple of
/// SplatV1.maximumResolutionStep up to the longest side of the largest image whose memory fits ([splatBrushMemory],
/// [splatMaximumBudget]), when the card holds the scene too. Null when that is not more than SplatV1.detailedResolution,
/// or when the sizes of the images or the memory are not known: Maximum is then the same as Detailed
int? splatMaximumResolution({
  required List<SplatImageSize> images,
  required int? physical,
  int? available,
  int? cardMemory,
}) {
  if (images.isEmpty || images.any((image) => image.width <= 0 || image.height <= 0)) {
    return null;
  }
  final budget = splatMaximumBudget(physical: physical, available: available);
  if (budget == null) {
    return null;
  }
  if (cardMemory != null && splatBrushCardMemory() > cardMemory) {
    return null;
  }
  final longest = images.map((image) => math.max(image.width, image.height)).reduce(math.max);
  const step = SplatV1.maximumResolutionStep;
  const floor = SplatV1.detailedResolution;
  if (longest <= floor) {
    return null;
  }
  // The memory grows with the definition: the largest one that fits, by halves between Detailed and the source
  bool fits(int resolution) => splatBrushMemory(images, resolution) <= budget;
  if (fits(longest)) {
    return longest;
  }
  var low = floor ~/ step;
  var high = longest ~/ step;
  if (!fits((low + 1) * step)) {
    return null;
  }
  low++;
  while (low < high) {
    final middle = (low + high + 1) ~/ 2;
    if (fits(middle * step)) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  final found = low * step;
  return found > floor ? found : null;
}

/// The gaussians the whole scene of [quality] of [subject] is told before it is made, those of its .ply (see the top
/// of this file)
int splatSceneGaussiansOf(SplatQuality quality, SplatSubject subject) => switch (quality) {
  SplatQuality.headset => SplatV1.maxGaussians,
  SplatQuality.detailed ||
  SplatQuality.maximum => subject == SplatSubject.place ? SplatV1.placeGaussians : SplatV1.objectGaussians,
};

/// The gaussians the .spz of a scene of [quality] of [subject] is told before it is made: for Headset the copy for the
/// headset, cropped to an object ([SplatV1.headsetObjectGaussians]); the whole scene for Detailed and Maximum
int splatPlannedGaussiansOf(SplatQuality quality, SplatSubject subject) =>
    quality == SplatQuality.headset && subject == SplatSubject.object
    ? SplatV1.headsetObjectGaussians
    : splatSceneGaussiansOf(quality, subject);

/// The size the .spz of a scene of [quality] of [subject] is told ([splatPlannedGaussiansOf])
int splatSpzBytesOf(SplatQuality quality, SplatSubject subject) =>
    splatPlannedGaussiansOf(quality, subject) * SplatV1.spzBytesPerGaussian;

/// The size the .ply of the same scene is told: the whole scene at every quality
int splatPlyBytesOf(SplatQuality quality, SplatSubject subject) =>
    splatSceneGaussiansOf(quality, subject) * SplatV1.plyBytesPerGaussian;

/// The size of the copy for the headset: 150 000 gaussians at most
const splatHeadsetCopyBytes = SplatV1.headsetGaussians * SplatV1.spzBytesPerGaussian;
