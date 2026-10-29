// The upscale of a generated 360° panorama without a seam of its own, pano-v1 (design-final 2026-10-27, section 4.3,
// point 7; lot P3). Real-ESRGAN x4plus (UpscaleBackend, sd-cli of lot P2) works in tiles and knows nothing of the
// sphere: the panorama is widened by PanoV1.upscalePadding columns on each side, taken from the other side, then cut
// back by four times that after the upscale. 1536 x 768 becomes 1600 x 768, then 6400 x 3072, then 6144 x 3072, the
// size of the panorama written (M3: 17 pixels a degree).

import 'dart:typed_data';

/// [rgba] of [width] x [height] widened by [pad] columns on each side, wrapped around the sphere: the last [pad]
/// columns before the first, the first [pad] after the last
Uint8List wrapColumns(Uint8List rgba, int width, int height, int pad) {
  final wide = width + 2 * pad;
  final out = Uint8List(4 * wide * height);
  for (var y = 0; y < height; y++) {
    final from = 4 * y * width;
    final to = 4 * y * wide;
    out.setRange(to, to + 4 * pad, rgba, from + 4 * (width - pad));
    out.setRange(to + 4 * pad, to + 4 * (pad + width), rgba, from);
    out.setRange(to + 4 * (pad + width), to + 4 * wide, rgba, from);
  }
  return out;
}

/// [rgba] of [width] x [height] without its first and last [cut] columns
Uint8List cropColumns(Uint8List rgba, int width, int height, int cut) {
  final narrow = width - 2 * cut;
  final out = Uint8List(4 * narrow * height);
  for (var y = 0; y < height; y++) {
    final from = 4 * (y * width + cut);
    out.setRange(4 * y * narrow, 4 * (y + 1) * narrow, rgba, from);
  }
  return out;
}
