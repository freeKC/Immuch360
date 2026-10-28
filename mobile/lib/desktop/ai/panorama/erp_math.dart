// The geometry of the equirectangular frames of the 360° panoramas (design-final 2026-10-27, sections 4.3 and 4.4):
// the direction each pixel looks to and back, as .github/desktop/ai/make_pano_golden.py writes them, so that the 3D
// version of a 360° photo (relief-360-v1, lot P1) and the panorama generated around a photo (pano-v1, lot P3) share
// one convention; the faces of an icosahedron and the tangent views the depth model sees on them; a bilinear read
// around the sphere (wrapped across the seam, the poles repeated); a resampling of a frame by area.
//
// The frame: W x H pixels, the pixel (x, y) looks towards the longitude lon = 2 * pi * ((x + 0.5) / W - 0.5), 0 at
// the centre column and positive to the right, and the latitude lat = pi * (0.5 - (y + 0.5) / H), positive upwards:
// the direction (cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon)) in a frame x right, y up, z ahead.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';

/// A direction of the sphere, a unit vector in the frame x right, y up, z ahead
class SphereVector {
  const SphereVector(this.x, this.y, this.z);

  /// [x], [y], [z] brought to a length of 1
  factory SphereVector.unit(double x, double y, double z) {
    final length = math.sqrt(x * x + y * y + z * z);
    return SphereVector(x / length, y / length, z / length);
  }

  final double x;
  final double y;
  final double z;

  double dot(SphereVector other) => x * other.x + y * other.y + z * other.z;

  SphereVector cross(SphereVector other) =>
      SphereVector(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x);

  /// The angle to [other] in radians
  double angleTo(SphereVector other) => math.acos(dot(other).clamp(-1.0, 1.0));

  @override
  String toString() => 'SphereVector($x, $y, $z)';
}

/// The longitude of the column [x] of a frame [width] wide, in radians
double erpLongitude(int x, int width) => 2 * math.pi * ((x + 0.5) / width - 0.5);

/// The latitude of the row [y] of a frame [height] high, in radians
double erpLatitude(int y, int height) => math.pi * (0.5 - (y + 0.5) / height);

/// The direction the pixel ([x], [y]) of a frame of [width] x [height] looks to
SphereVector erpDirection(int x, int y, int width, int height) {
  final lon = erpLongitude(x, width);
  final lat = erpLatitude(y, height);
  return SphereVector(math.cos(lat) * math.sin(lon), math.sin(lat), math.cos(lat) * math.cos(lon));
}

/// Where the direction ([x], [y], [z]) of length 1 falls in a frame of [width] x [height], in pixels whose centres are
/// the integers: the column from -0.5 to [width] - 0.5, the row from -0.5 to [height] - 0.5
(double, double) erpPixelOf(double x, double y, double z, int width, int height) {
  final lon = math.atan2(x, z);
  final lat = math.asin(y.clamp(-1.0, 1.0));
  return ((lon / (2 * math.pi) + 0.5) * width - 0.5, (0.5 - lat / math.pi) * height - 0.5);
}

/// The 20 faces of an icosahedron with a vertex at each pole, by the direction of their centre: five around the north
/// pole (latitude 52.6°), ten across the equator (10.8° up and down, staggered by 36°), five around the south pole.
/// Every direction of the sphere is within 37.4° of a centre; two neighbours are 41.8° apart.
List<SphereVector> icosahedronFaceCentres() {
  final ring = math.atan(0.5);
  SphereVector vertex(double lat, double lon) =>
      SphereVector(math.cos(lat) * math.sin(lon), math.sin(lat), math.cos(lat) * math.cos(lon));
  const north = SphereVector(0, 1, 0);
  const south = SphereVector(0, -1, 0);
  final upper = [for (var k = 0; k < 5; k++) vertex(ring, 2 * math.pi * k / 5)];
  final lower = [for (var k = 0; k < 5; k++) vertex(-ring, 2 * math.pi * (k + 0.5) / 5)];
  SphereVector centre(SphereVector a, SphereVector b, SphereVector c) =>
      SphereVector.unit(a.x + b.x + c.x, a.y + b.y + c.y, a.z + b.z + c.z);
  return [
    for (var k = 0; k < 5; k++) centre(north, upper[k], upper[(k + 1) % 5]),
    for (var k = 0; k < 5; k++) centre(upper[k], upper[(k + 1) % 5], lower[k]),
    for (var k = 0; k < 5; k++) centre(lower[k], lower[(k + 1) % 5], upper[(k + 1) % 5]),
    for (var k = 0; k < 5; k++) centre(south, lower[(k + 1) % 5], lower[k]),
  ];
}

/// A pinhole view of [width] x [height] square pixels looking at [forward], its horizon level: what the depth model is
/// given for one face of the icosahedron. The view reaches [tanY] (the tangent of half its vertical field) up and down
/// and tanY * width / height to each side; a point ([a], [b]) of its plane, at distance 1 ahead, is the pixel
/// i = (a / tanX + 1) * width / 2 - 0.5, j = (1 - b / tanY) * height / 2 - 0.5 (centres at the integers).
class TangentView {
  TangentView(this.forward, {required this.width, required this.height, this.tanY = 1.0})
    : tanX = tanY * width / height,
      right = _rightOf(forward),
      up = forward.cross(_rightOf(forward)) {
    if (width < 1 || height < 1 || !(tanY > 0)) {
      throw ArgumentError('A view of $width x $height reaching $tanY up');
    }
  }

  final SphereVector forward;
  final SphereVector right;
  final SphereVector up;
  final int width;
  final int height;
  final double tanX;
  final double tanY;

  static SphereVector _rightOf(SphereVector forward) {
    // The world's up crossed with the axis, which keeps the horizon level; straight up or down, the world's ahead
    final across = const SphereVector(0, 1, 0).cross(forward);
    final length = math.sqrt(across.dot(across));
    if (length < 1e-9) {
      return const SphereVector(1, 0, 0);
    }
    return SphereVector(across.x / length, across.y / length, across.z / length);
  }

  /// The point of the plane the centre of the pixel ([i], [j]) shows
  (double, double) planeOf(double i, double j) =>
      (((i + 0.5) / width * 2 - 1) * tanX, (1 - (j + 0.5) / height * 2) * tanY);

  /// The direction the centre of the pixel ([i], [j]) looks to
  SphereVector directionOf(double i, double j) {
    final (a, b) = planeOf(i, j);
    return SphereVector.unit(
      forward.x + a * right.x + b * up.x,
      forward.y + a * right.y + b * up.y,
      forward.z + a * right.z + b * up.z,
    );
  }

  /// The pixel of the view the direction ([x], [y], [z]) falls on, null behind it; outside the frame too, the caller
  /// tells by [weightAt]
  (double, double)? pixelOf(double x, double y, double z) {
    final ahead = x * forward.x + y * forward.y + z * forward.z;
    if (ahead <= 0) {
      return null;
    }
    final a = (x * right.x + y * right.y + z * right.z) / ahead;
    final b = (x * up.x + y * up.y + z * up.z) / ahead;
    return ((a / tanX + 1) * width / 2 - 0.5, (1 - b / tanY) * height / 2 - 0.5);
  }

  /// How much the view counts at its pixel ([i], [j]): 1 at its centre, falling as the square of the way to its
  /// nearer edge, 0 on and beyond its frame
  double weightAt(double i, double j) {
    final across = ((i + 0.5) / width * 2 - 1).abs();
    final down = ((j + 0.5) / height * 2 - 1).abs();
    final edge = 1 - math.max<double>(across, down);
    return edge <= 0 ? 0.0 : edge * edge;
  }
}

/// Reads a value of a frame of [width] x [height] in bilinear around the sphere: the columns wrap across the seam,
/// the rows stop at the poles
class SphereBilinear {
  SphereBilinear(this.width, this.height) {
    if (width < 1 || height < 1) {
      throw ArgumentError('A frame of $width x $height');
    }
  }

  final int width;
  final int height;

  /// The two columns around [u] (wrapped) and the share of the second
  (int, int, double) columns(double u) {
    final x0 = u.floor();
    final left = x0 % width;
    return (left, (left + 1) % width, u - x0);
  }

  /// The two rows around [v] (the poles repeated) and the share of the second
  (int, int, double) rows(double v) {
    final y0 = v.floor();
    final top = math.min(height - 1, math.max(0, y0));
    final bottom = math.min(height - 1, math.max(0, y0 + 1));
    return (top, bottom, v - y0);
  }

  /// The value of [values] (one per pixel, row after row) at ([u], [v])
  double read(List<double> values, double u, double v) {
    final (left, right, fx) = columns(u);
    final (top, bottom, fy) = rows(v);
    final a = values[top * width + left];
    final b = values[top * width + right];
    final e = values[bottom * width + left];
    final f = values[bottom * width + right];
    final upper = a + (b - a) * fx;
    final lower = e + (f - e) * fx;
    return upper + (lower - upper) * fy;
  }

  /// The channel [channel] of the RGBA pixels [rgba] at ([u], [v])
  double readRgba(Uint8List rgba, int channel, double u, double v) {
    final (left, right, fx) = columns(u);
    final (top, bottom, fy) = rows(v);
    final a = rgba[4 * (top * width + left) + channel];
    final b = rgba[4 * (top * width + right) + channel];
    final e = rgba[4 * (bottom * width + left) + channel];
    final f = rgba[4 * (bottom * width + right) + channel];
    final upper = a + (b - a) * fx;
    final lower = e + (f - e) * fx;
    return upper + (lower - upper) * fy;
  }
}

/// [picture] brought to [width] x [height] by the average of the area each pixel covers, on each axis on its own (its
/// proportions are not kept: a frame of 6 000 x 3 008 becomes an exact 2:1), larger or smaller; the profile goes with
/// the pixels. [picture] itself when it has that size already.
SbsDecoded resampleArea(SbsDecoded picture, int width, int height) {
  if (width < 1 || height < 1) {
    throw ArgumentError('A frame of $width x $height');
  }
  if (width == picture.width && height == picture.height) {
    return picture;
  }
  final across = _resampleAxis(picture.rgba, lines: picture.height, from: picture.width, to: width, alongRows: true);
  final rgba = _resampleAxis(across, lines: width, from: picture.height, to: height, alongRows: false);
  return SbsDecoded(width: width, height: height, rgba: rgba, iccProfile: picture.iccProfile);
}

/// [rgba] resampled along one axis from [from] to [to] pixels, [lines] lines across the other: the pixel i of the
/// result covers [i * from, (i + 1) * from) and the source pixel j covers [j * to, (j + 1) * to), in units of 1 / to of
/// a source pixel; each channel is the sum of overlap * value over [from], rounded half up
Uint8List _resampleAxis(
  Uint8List rgba, {
  required int lines,
  required int from,
  required int to,
  required bool alongRows,
}) {
  final first = Int32List(to + 1);
  final sources = <int>[];
  final weights = <int>[];
  for (var i = 0; i < to; i++) {
    first[i] = sources.length;
    final start = i * from;
    final end = (i + 1) * from;
    for (var j = start ~/ to; j * to < end && j < from; j++) {
      final overlap = math.min<int>(end, (j + 1) * to) - math.max<int>(start, j * to);
      if (overlap > 0) {
        sources.add(j);
        weights.add(overlap);
      }
    }
  }
  first[to] = sources.length;
  final out = Uint8List(4 * to * lines);
  final half = from ~/ 2;
  // Along a row the next pixel is 4 bytes on and a line the width of a row; along a column the other way round
  final inWidth = alongRows ? from : lines;
  final outWidth = alongRows ? to : lines;
  for (var line = 0; line < lines; line++) {
    for (var i = 0; i < to; i++) {
      var r = 0;
      var g = 0;
      var b = 0;
      var a = 0;
      for (var k = first[i]; k < first[i + 1]; k++) {
        final at = alongRows ? 4 * (line * inWidth + sources[k]) : 4 * (sources[k] * inWidth + line);
        final w = weights[k];
        r += w * rgba[at];
        g += w * rgba[at + 1];
        b += w * rgba[at + 2];
        a += w * rgba[at + 3];
      }
      final at = alongRows ? 4 * (line * outWidth + i) : 4 * (i * outWidth + line);
      out[at] = (r + half) ~/ from;
      out[at + 1] = (g + half) ~/ from;
      out[at + 2] = (b + half) ~/ from;
      out[at + 3] = (a + half) ~/ from;
    }
  }
  return out;
}
