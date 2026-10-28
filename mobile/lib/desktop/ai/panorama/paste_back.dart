// The photo pasted back over a generated 360° panorama, pano-v1 (design-final 2026-10-27, section 4.3, point 8; lot
// P3): the generator only invents what lies beyond the edges of the photo, and its version of the photo itself, made
// at a quarter of the output and upscaled, is replaced by the photo reprojected at the size of the output. Step 4 of
// .github/desktop/ai/make_pano_golden.py: each pixel inside the photo (the projection of erp_projection.dart at that
// size) takes alpha * photo + (1 - alpha) * generated, alpha = clamp(e / 0.02, 0, 1) and e the distance to the nearest
// edge of the photo as a fraction of its size, so that the photo blends in over 2 % of its edge; outside, the
// generated pixel as it is. The pixels of the photo keep the colour space of the original (design 8.7).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/panorama/erp_projection.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The RGBA of [generated] (an equirectangular frame) with [photo], seen with [hfov] degrees across at its centre,
/// pasted back and blended over [feather] of its size; [generated] is not changed. [isCancelled] is read every 64
/// rows.
Uint8List pastePhotoBack(
  SbsDecoded generated,
  SbsDecoded photo, {
  required double hfov,
  double feather = PanoV1.pasteFeather,
  bool Function()? isCancelled,
}) {
  final width = generated.width;
  final height = generated.height;
  final w = photo.width;
  final h = photo.height;
  final out = Uint8List.fromList(generated.rgba);
  final colour = Float64List(3);
  for (var y = 0; y < height; y++) {
    if (y % 64 == 0 && (isCancelled?.call() ?? false)) {
      throw const ProjectionCancelled();
    }
    for (var x = 0; x < width; x++) {
      final point = photoPointOf(x, y, width, height, photoWidth: w, photoHeight: h, hfov: hfov);
      if (point == null) {
        continue;
      }
      final (u, v) = point;
      final edge = math.min(math.min(u / w, 1 - u / w), math.min(v / h, 1 - v / h));
      final alpha = math.min(1.0, math.max(0.0, edge / feather));
      readPhoto(photo, u, v, colour);
      final at = 4 * (y * width + x);
      for (var k = 0; k < 3; k++) {
        out[at + k] = toByte(alpha * colour[k] + (1 - alpha) * generated.rgba[at + k]);
      }
    }
  }
  return out;
}
