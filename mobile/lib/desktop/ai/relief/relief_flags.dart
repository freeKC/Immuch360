// The warnings relief-v1 raises on a photo (design-final 2026-10-26, section 2.4, step 7): little relief found, large
// areas filled in, a dark photo. They go on the line of the job and into Immuch360:QualityFlags, so that the user
// knows when the relief estimated by AI is likely to be weak or wrong. The thresholds are those of ReliefV1 and of
// .github/desktop/ai/make_relief_golden.py.

import 'dart:typed_data';

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The mean Rec. 709 luma of the photo [rgba] of [width] x [height] (rows from [offset], [stride] bytes apart), out
/// of 255. Added pixel after pixel, row after row, then divided, as the reference does: the Kotlin of the Quest adds
/// in the same order and gets the same double.
double meanLuma(Uint8List rgba, {required int width, required int height, int offset = 0, int? stride}) {
  final rowBytes = stride ?? width * 4;
  if (width < 1 || height < 1 || rowBytes < width * 4 || rgba.length < offset + (height - 1) * rowBytes + width * 4) {
    throw ArgumentError('${rgba.length} bytes do not hold a photo of $width x $height with rows of $rowBytes bytes');
  }
  var total = 0.0;
  for (var y = 0; y < height; y++) {
    var at = offset + y * rowBytes;
    for (var x = 0; x < width; x++) {
      total += 0.2126 * rgba[at] + 0.7152 * rgba[at + 1] + 0.0722 * rgba[at + 2];
      at += 4;
    }
  }
  return total / (width * height);
}

/// The flags of a right eye of [width] x [height] with [filledPixels] filled in, in the order of the XMP: lowRelief
/// (from the map), hiddenAreas past 5 % filled, dark under a mean luma of 20
List<ReliefQualityFlag> reliefFlags({
  required bool lowRelief,
  required int filledPixels,
  required int width,
  required int height,
  required double meanLuma,
}) => [
  if (lowRelief) ReliefQualityFlag.lowRelief,
  if (filledPixels > ReliefV1.hiddenAreasRatio * width * height) ReliefQualityFlag.hiddenAreas,
  if (meanLuma < ReliefV1.darkLuma) ReliefQualityFlag.dark,
];
