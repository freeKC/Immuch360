// The seam of a generated 360° panorama, pano-v1 (design-final 2026-10-27, section 4.3, point 6; lot P3). The LoRA is
// asked to match the left and right edges, and M3 found the seam visible all the same before any work on it (the jump
// from the last column to the first 2.2 to 4.3 times the usual jump between two columns). So the panorama is rolled by
// half a turn, which brings the seam to its centre, the band of the seam is filled in by the filling of the panoramas
// (MI-GAN, InpaintBackend, migan_inpaint.dart), and the panorama is rolled back.
//
// The band is PanoV1.seamBand columns of the control frame in proportion to the generation (96 of 1536). It is filled
// in regions of the model's size at most, as wide as possible around the band so that the model sees both sides; down
// a band taller than a region, each region starts half a region above the end of the one before, takes what that one
// filled as known, fills again its last rows (seamRegionBlend) and is blended into them row by row, so that the
// regions meet without an edge. Only the pixels of the band change.
//
// The seam is measured before and after as M3 measured it; the flag seam is raised when it stays above PanoV1.seamRatio.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/panorama/erp_projection.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The band of the seam of a panorama [width] wide: PanoV1.seamBand of the control frame in proportion, even
int seamBandFor(int width) => math.max(2, 2 * (PanoV1.seamBand * width / PanoV1.controlWidth / 2).round());

/// How visible the seam of the panorama [rgba] of [width] x [height] is: the mean jump from its last column to its
/// first over the mean jump between two neighbouring columns, the three colours counted (M3, section 1)
double seamRatioOf(Uint8List rgba, int width, int height) {
  var neighbours = 0;
  var edge = 0;
  for (var y = 0; y < height; y++) {
    final row = 4 * y * width;
    for (var x = 0; x + 1 < width; x++) {
      final at = row + 4 * x;
      neighbours +=
          (rgba[at + 4] - rgba[at]).abs() + (rgba[at + 5] - rgba[at + 1]).abs() + (rgba[at + 6] - rgba[at + 2]).abs();
    }
    final last = row + 4 * (width - 1);
    edge +=
        (rgba[last] - rgba[row]).abs() +
        (rgba[last + 1] - rgba[row + 1]).abs() +
        (rgba[last + 2] - rgba[row + 2]).abs();
  }
  final usual = width < 2 ? 0.0 : neighbours / (3 * height * (width - 1));
  return (edge / (3 * height)) / math.max(usual, 1e-6);
}

/// The first row of each region down a band [height] high, regions [regionMax] high at most: each one half a region
/// above the end of the one before, the last one ending at the bottom
List<int> joinSeamRegionTops(int height, int regionMax) {
  final tall = math.min(height, regionMax);
  final overlap = tall ~/ 2;
  final tops = <int>[];
  var filled = 0;
  while (filled < height) {
    final top = tops.isEmpty ? 0 : math.max(0, math.min(filled - overlap, height - tall));
    tops.add(top);
    filled = top + tall;
  }
  return tops;
}

/// The rows a region down the band fills again at the end of the one above it, blended from that one to its own: a
/// sixteenth of a region, 2 rows at least (32 of a region of 512)
int seamRegionBlend(int regionMax) => math.max(2, regionMax ~/ 16);

/// The panorama with its seam filled in
class SeamJoin {
  const SeamJoin({required this.rgba, required this.before, required this.after, required this.regions});

  final Uint8List rgba;

  /// The seam measured before and after (seamRatioOf)
  final double before;
  final double after;

  /// How many regions the filling was given
  final int regions;

  /// The flag seam
  bool get visible => after > PanoV1.seamRatio;
}

/// [rgba] (RGBA) of [width] x [height] with the band of its seam filled in by [inpaint] (see the top of this file);
/// [band] columns, seamBandFor(width) when not given. [isCancelled] is read before each region, [onRegion] hears each
/// one done. Throws [BackendException]: cancelled, or what the filling throws.
SeamJoin joinSeam(
  Uint8List rgba,
  int width,
  int height,
  InpaintBackend inpaint, {
  int? band,
  bool Function()? isCancelled,
  void Function(int done, int total)? onRegion,
}) {
  final before = seamRatioOf(rgba, width, height);
  final columns = math.min(width, band ?? seamBandFor(width));
  final rolled = rollColumns(rgba, width, height, width ~/ 2);
  // In the rolled panorama the seam lies between the columns width / 2 - 1 and width / 2
  final bandLeft = width ~/ 2 - columns ~/ 2;
  final bandRight = bandLeft + columns;
  final regionWidth = math.min(width, math.max(columns, inpaint.regionMax));
  final left = math.max(0, math.min(width - regionWidth, width ~/ 2 - regionWidth ~/ 2));
  final tall = math.min(height, inpaint.regionMax);
  final tops = joinSeamRegionTops(height, inpaint.regionMax);
  final blend = math.min(seamRegionBlend(inpaint.regionMax), tall ~/ 2);
  var filled = 0;
  for (final (index, top) in tops.indexed) {
    if (isCancelled?.call() ?? false) {
      throw const BackendException(ImmersiveErrorCode.cancelled, 'Cancelled while the seam was joined');
    }
    // The rows from here on are holes: the last ones the region above filled are filled again, then blended
    final firstHole = index == 0 ? 0 : math.max(top, filled - blend);
    final rgb = Uint8List(3 * regionWidth * tall);
    final mask = Uint8List(regionWidth * tall);
    for (var y = 0; y < tall; y++) {
      for (var x = 0; x < regionWidth; x++) {
        final from = 4 * ((top + y) * width + left + x);
        final to = y * regionWidth + x;
        rgb[3 * to] = rolled[from];
        rgb[3 * to + 1] = rolled[from + 1];
        rgb[3 * to + 2] = rolled[from + 2];
        final column = left + x;
        final hole = column >= bandLeft && column < bandRight && top + y >= firstHole;
        mask[to] = hole ? 0 : 255;
      }
    }
    final out = inpaint.fill(InpaintRegion(width: regionWidth, height: tall, rgb: rgb, mask: mask));
    if (out.length != rgb.length) {
      throw BackendException(ImmersiveErrorCode.modelFailed, 'The filling gave ${out.length} bytes for ${rgb.length}');
    }
    for (var y = 0; y < tall; y++) {
      final row = top + y;
      // 0 to 1 over the rows filled again, from the fill above to this one; 1 below them
      final share = row >= filled ? 1.0 : (row - firstHole + 1) / (filled - firstHole + 1);
      for (var x = 0; x < regionWidth; x++) {
        if (mask[y * regionWidth + x] == 0) {
          final to = 4 * (row * width + left + x);
          final at = 3 * (y * regionWidth + x);
          for (var c = 0; c < 3; c++) {
            rolled[to + c] = (share * out[at + c] + (1 - share) * rolled[to + c]).round();
          }
        }
      }
    }
    filled = top + tall;
    onRegion?.call(index + 1, tops.length);
  }
  final joined = rollColumns(rolled, width, height, width - width ~/ 2);
  return SeamJoin(rgba: joined, before: before, after: seamRatioOf(joined, width, height), regions: tops.length);
}
