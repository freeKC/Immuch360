// The photo on the sphere of a generated 360° panorama, pano-v1 (design-final 2026-10-27, section 4.3, points 3 and 6;
// lot P3): the photo seen at the centre of an equirectangular frame (yaw 0, pitch 0, the horizon level) through a
// pinhole of its horizontal field of view, as .github/desktop/ai/make_pano_golden.py writes it (steps 1 to 3), on the
// convention of erp_math.dart. The control frame of the LoRA is that projection with pure green everywhere else; the
// part of the sphere the photo covers is the sum of cos(latitude) over the pixels inside it; the frame is rolled by half
// a turn to bring its seam to the centre and back.
//
// The pixel (x, y) of the frame looks along (dx, dy, dz) (erp_math.dart); with z > 0 it meets the plane of the photo
// at (dx / dz, dy / dz), the point u = (a / t + 1) * w / 2, v = (1 - b / s) * h / 2 of the photo (its pixel edges),
// t = tan(hfov / 2) and s = t * h / w. Inside when 0 <= u <= w and 0 <= v <= h: the colour read in bilinear at
// (u - 0.5, v - 0.5), the edges repeated, rounded half up. Every operation in the order of the script, in double
// precision, so that the masks are the same to the pixel.
//
// A photo much larger than the frame would be read pixel by pixel and alias: photoForFrame reduces it by area first,
// to about 1.5 pixels of the photo per pixel of the frame at the centre (more pixels of the frame per degree towards
// the edges of the photo), never enlarges it.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/panorama/erp_math.dart';

/// The colour of the frame where the photo is not: the pure green the LoRA fills in
const controlGreen = [0, 255, 0];

/// [degrees] in radians, as Python's math.radians computes it (degrees times pi / 180)
double _radians(double degrees) => degrees * (math.pi / 180);

/// The vertical field of view in degrees of a photo of [width] x [height] whose horizontal one is [hfov]
double verticalFieldOfView(double hfov, int width, int height) {
  final t = math.tan(_radians(hfov) / 2);
  return 2 * math.atan(t * height / width) * (180 / math.pi);
}

/// Where the pixel ([x], [y]) of a frame of [width] x [height] meets a photo of [photoWidth] x [photoHeight] seen with
/// [hfov] degrees across: (u, v) in pixels of the photo from its top left edge, null outside it
(double, double)? photoPointOf(
  int x,
  int y,
  int width,
  int height, {
  required int photoWidth,
  required int photoHeight,
  required double hfov,
}) {
  final lon = erpLongitude(x, width);
  final lat = erpLatitude(y, height);
  final dz = math.cos(lat) * math.cos(lon);
  if (dz <= 0) {
    return null;
  }
  final dx = math.cos(lat) * math.sin(lon);
  final dy = math.sin(lat);
  final t = math.tan(_radians(hfov) / 2);
  final s = t * photoHeight / photoWidth;
  final u = (dx / dz / t + 1) * photoWidth / 2;
  final v = (1 - dy / dz / s) * photoHeight / 2;
  if (0 <= u && u <= photoWidth && 0 <= v && v <= photoHeight) {
    return (u, v);
  }
  return null;
}

int _clampIndex(int i, int size) => math.min(size - 1, math.max(0, i));

/// A value rounded half up and kept within a byte
int toByte(double value) => math.min(255, math.max(0, (value + 0.5).floor()));

/// The channels 0 to 2 of [photo] in bilinear at ([u] - 0.5, [v] - 0.5), its edges repeated, written into [out]
void readPhoto(SbsDecoded photo, double u, double v, Float64List out) {
  final w = photo.width;
  final h = photo.height;
  final px = u - 0.5;
  final py = v - 0.5;
  final x0 = px.floor();
  final y0 = py.floor();
  final fx = px - x0;
  final fy = py - y0;
  final left = _clampIndex(x0, w);
  final right = _clampIndex(x0 + 1, w);
  final top = _clampIndex(y0, h);
  final bottom = _clampIndex(y0 + 1, h);
  final rgba = photo.rgba;
  for (var k = 0; k < 3; k++) {
    final a = rgba[4 * (top * w + left) + k];
    final b = rgba[4 * (top * w + right) + k];
    final e = rgba[4 * (bottom * w + left) + k];
    final f = rgba[4 * (bottom * w + right) + k];
    final upper = a + (b - a) * fx;
    final lower = e + (f - e) * fx;
    out[k] = upper + (lower - upper) * fy;
  }
}

/// The photo projected on a frame: its pixels (RGBA, opaque), 1 where the photo is and 0 elsewhere, and the part of
/// the sphere it covers
class ProjectedPhoto {
  const ProjectedPhoto({
    required this.width,
    required this.height,
    required this.rgba,
    required this.inside,
    required this.coverage,
    required this.insideCount,
  });

  final int width;
  final int height;
  final Uint8List rgba;
  final Uint8List inside;

  /// The fraction of the sphere the photo covers, 0 to 1 (SourceCoverage)
  final double coverage;
  final int insideCount;
}

/// The control frame of [photo] seen with [hfov] degrees across: the photo at the centre of a frame of [width] x
/// [height], pure green elsewhere (see the top of this file). [isCancelled] is read every 64 rows.
ProjectedPhoto projectPhoto(
  SbsDecoded photo, {
  required double hfov,
  required int width,
  required int height,
  bool Function()? isCancelled,
}) {
  final rgba = Uint8List(4 * width * height);
  final inside = Uint8List(width * height);
  final colour = Float64List(3);
  var covered = 0.0;
  var total = 0.0;
  var count = 0;
  for (var y = 0; y < height; y++) {
    if (y % 64 == 0 && (isCancelled?.call() ?? false)) {
      throw const ProjectionCancelled();
    }
    final weight = math.cos(erpLatitude(y, height));
    for (var x = 0; x < width; x++) {
      total += weight;
      final at = 4 * (y * width + x);
      rgba[at + 3] = 255;
      final point = photoPointOf(x, y, width, height, photoWidth: photo.width, photoHeight: photo.height, hfov: hfov);
      if (point == null) {
        rgba[at] = controlGreen[0];
        rgba[at + 1] = controlGreen[1];
        rgba[at + 2] = controlGreen[2];
        continue;
      }
      covered += weight;
      count++;
      inside[y * width + x] = 1;
      readPhoto(photo, point.$1, point.$2, colour);
      rgba[at] = toByte(colour[0]);
      rgba[at + 1] = toByte(colour[1]);
      rgba[at + 2] = toByte(colour[2]);
    }
  }
  return ProjectedPhoto(
    width: width,
    height: height,
    rgba: rgba,
    inside: inside,
    coverage: covered / total,
    insideCount: count,
  );
}

/// Thrown by [projectPhoto] and the paste back when their cancel flag is raised
class ProjectionCancelled implements Exception {
  const ProjectionCancelled();
}

/// The cells of [rgba] ([bytes] a pixel) of a frame of [width] x [height] rolled by [by] columns: the column x of the
/// result is the column (x + by) mod width of [rgba]
Uint8List rollColumns(Uint8List rgba, int width, int height, int by, {int bytes = 4}) {
  final out = Uint8List(rgba.length);
  final shift = by % width;
  final row = bytes * width;
  final head = bytes * (width - shift);
  for (var y = 0; y < height; y++) {
    final start = y * row;
    // The columns shift to width - 1 come first, then 0 to shift - 1
    out.setRange(start, start + head, rgba, start + bytes * shift);
    out.setRange(start + head, start + row, rgba, start);
  }
  return out;
}

/// [photo] reduced by area so that it holds about 1.5 of its pixels for each pixel of a frame [frameWidth] wide at the
/// centre of a photo seen with [hfov] degrees across; [photo] itself when it is no larger
SbsDecoded photoForFrame(SbsDecoded photo, {required double hfov, required int frameWidth}) {
  final across = 2 * math.tan(_radians(hfov) / 2) * frameWidth / (2 * math.pi);
  final width = (1.5 * across).ceil();
  if (width >= photo.width) {
    return photo;
  }
  final height = math.max(1, (width * photo.height / photo.width).round());
  return resampleArea(photo, width, height);
}
