// The right eye of a 360° panorama, relief-360-v1 (design-final 2026-10-27, section 4.4, points 2 and 3; lot P1): the
// algorithm of relief-v1 row by row, around the sphere. The left eye is the panorama itself and is only read. Each
// row y moves its pixels by s(x) = -(W / 360) * m * d(x) * cos(lat(y)): the nearest (d = 1) goes left by m degrees at
// the equator, m being 1 (the budget of phase 1), nothing moves at the poles, where the stereo of a sphere bends, and
// the far stays put (convergence at infinity). The forward projection and the filling of the holes wrap across the
// seam, so that the right and left edges of the eye still meet.
//
// The steps and the order of every operation are those of .github/desktop/ai/make_pano_golden.py (steps 5 to 9), in
// double precision, and its fixture test/fixtures/ai_immersive/pano_golden_v1.json holds this code: each byte within
// one unit, the mask of the filled pixels exactly. The map d is read at each pixel of the eye in bilinear around the
// sphere (the columns wrap, the rows stop at the poles): equal sizes read it as it is, as the fixture does.
//
// Refused, with no file ("Not enough relief for a comfortable 3D panorama"), when the map is flat (the lowRelief rule
// of relief-v1) or when more than 8 % of the right eye was filled in: the mono panorama stays.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/panorama/erp_math.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/desktop/ai/relief/right_eye.dart' show ReliefCancelledException;
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// What the right eye of a panorama came to
class Relief360Eye {
  const Relief360Eye({required this.filledPixels, required this.width, required this.height, required this.lowRelief});

  /// How many pixels of the right eye no pixel of the panorama reached, filled from the background beside them
  final int filledPixels;
  final int width;
  final int height;

  /// The map has little relief (relief-v1, step 1)
  final bool lowRelief;

  /// The part of the eye filled in
  double get filledFraction => filledPixels / (width * height);

  /// lowRelief, then hiddenAreas past 5 % filled, in the order of the XMP
  List<ReliefQualityFlag> get flags => [
    if (lowRelief) ReliefQualityFlag.lowRelief,
    if (filledFraction > ReliefV1.hiddenAreasRatio) ReliefQualityFlag.hiddenAreas,
  ];

  /// No 3D version: the map is flat, or more than 8 % would be filled in
  bool get refused => lowRelief || filledFraction > Relief360V1.maxFilled;
}

/// d at each pixel of an eye of [eyeWidth] x [eyeHeight], read in bilinear around the sphere from [map] at the centre
/// of the pixel: u = (x + 0.5) * w / L - 0.5, the columns wrapped, the rows repeated at the poles, and a + (b - a) * f
/// so that equal neighbours give their value
class SphereDepthSampler {
  SphereDepthSampler(this.map, this.eyeWidth, this.eyeHeight)
    : _bilinear = SphereBilinear(map.width, map.height),
      _left = Int32List(eyeWidth),
      _right = Int32List(eyeWidth),
      _fx = Float64List(eyeWidth) {
    if (eyeWidth < 1 || eyeHeight < 1) {
      throw ArgumentError('An eye of $eyeWidth x $eyeHeight');
    }
    for (var x = 0; x < eyeWidth; x++) {
      final (left, right, fx) = _bilinear.columns((x + 0.5) * map.width / eyeWidth - 0.5);
      _left[x] = left;
      _right[x] = right;
      _fx[x] = fx;
    }
  }

  final ReliefDepth map;
  final int eyeWidth;
  final int eyeHeight;
  final SphereBilinear _bilinear;
  final Int32List _left;
  final Int32List _right;
  final Float64List _fx;

  /// Writes d of the row [y] of the eye into [out], which holds [eyeWidth] values
  void sampleRow(int y, Float64List out) {
    final (topRow, bottomRow, fy) = _bilinear.rows((y + 0.5) * map.height / eyeHeight - 0.5);
    final top = topRow * map.width;
    final bottom = bottomRow * map.width;
    final values = map.values;
    for (var x = 0; x < eyeWidth; x++) {
      final left = _left[x];
      final right = _right[x];
      final fx = _fx[x];
      final a = values[top + left];
      final b = values[top + right];
      final e = values[bottom + left];
      final f = values[bottom + right];
      final upper = a + (b - a) * fx;
      final lower = e + (f - e) * fx;
      out[x] = upper + (lower - upper) * fy;
    }
  }
}

/// Writes the right eye of the panorama [left] ([width] x [height] RGBA, rows from [leftOffset], [leftStride] bytes
/// apart) into [target] (rows from [targetOffset], [targetStride] bytes apart, alpha 255), from [map], d between 0
/// (far) and 1 (near) as normaliseDepth gives it, whose [lowRelief] goes into the result. [maxShiftDegrees] is the
/// shift of the nearest at the equator. [holes], when given, receives 1 for each filled pixel and 0 for the others,
/// row after row. [isCancelled] is read before every 64th row and throws [ReliefCancelledException] when true;
/// [onRows] hears the rows done every 64 rows and at the end. [left] is only read.
Relief360Eye writeRelief360RightEye({
  required Uint8List left,
  required int width,
  required int height,
  int leftOffset = 0,
  int? leftStride,
  required ReliefDepth map,
  required bool lowRelief,
  double maxShiftDegrees = Relief360V1.maxShiftDegrees,
  required Uint8List target,
  int targetOffset = 0,
  int? targetStride,
  Uint8List? holes,
  bool Function()? isCancelled,
  void Function(int rows)? onRows,
}) {
  final leftRow = leftStride ?? width * 4;
  final targetRow = targetStride ?? width * 4;
  _checkPixels('left', left, width, height, leftOffset, leftRow);
  _checkPixels('target', target, width, height, targetOffset, targetRow);
  if (holes != null && holes.length != width * height) {
    throw ArgumentError('The mask of an eye of $width x $height has ${width * height} cells, not ${holes.length}');
  }
  if (!maxShiftDegrees.isFinite || maxShiftDegrees < 0 || maxShiftDegrees > 180) {
    throw ArgumentError.value(maxShiftDegrees, 'maxShiftDegrees', 'Degrees, 0 to 180');
  }

  final sampler = SphereDepthSampler(map, width, height);
  final d = Float64List(width);
  final t = Float64List(width);
  final depth = Float64List(width);
  final colour = Float64List(width * 3);
  final filledRow = Float64List(width * 3);
  const unwritten = double.negativeInfinity;
  var filled = 0;

  for (var y = 0; y < height; y++) {
    if (y % 64 == 0 && isCancelled != null && isCancelled()) {
      throw const ReliefCancelledException();
    }
    sampler.sampleRow(y, d);
    final cosLat = math.cos(erpLatitude(y, height));
    for (var x = 0; x < width; x++) {
      t[x] = x + -(width / 360) * maxShiftDegrees * d[x] * cosLat;
    }
    depth.fillRange(0, width, unwritten);
    final source = leftOffset + y * leftRow;

    void put(int column, double dd, double r, double g, double b) {
      final at = column % width;
      if (dd > depth[at]) {
        depth[at] = dd;
        colour[at * 3] = r;
        colour[at * 3 + 1] = g;
        colour[at * 3 + 2] = b;
      }
    }

    // Forward projection around the row: each pixel alone, then the segment to its right neighbour (the first pixel
    // after the last) when the two are linked
    for (var x = 0; x < width; x++) {
      final next = x + 1 < width ? x + 1 : 0;
      final d0 = d[x];
      final t0 = t[x];
      final at = source + x * 4;
      final r0 = left[at];
      final g0 = left[at + 1];
      final b0 = left[at + 2];
      put((t0 + 0.5).floor(), d0, r0.toDouble(), g0.toDouble(), b0.toDouble());
      final d1 = d[next];
      if ((d0 - d1).abs() > Relief360V1.linkThreshold) {
        continue;
      }
      final t1 = t[next] + (next == 0 ? width : 0);
      final to = source + next * 4;
      final r1 = left[to];
      final g1 = left[to + 1];
      final b1 = left[to + 2];
      final last = math.max(t0, t1).floor();
      for (var column = math.min(t0, t1).ceil(); column <= last; column++) {
        final a = t1 != t0 ? (column - t0) / (t1 - t0) : 0.0;
        put(column, d0 + (d1 - d0) * a, r0 + (r1 - r0) * a, g0 + (g1 - g0) * a, b0 + (b1 - b0) * a);
      }
    }

    // Filling around the row: each run of holes, read from the first pixel written, takes its background neighbour
    // (the smaller depth, the left one on a tie); a row with nothing written is black
    var start = -1;
    for (var x = 0; x < width; x++) {
      if (depth[x] != unwritten) {
        start = x;
        break;
      }
    }
    filledRow.setAll(0, colour);
    if (start < 0) {
      filledRow.fillRange(0, filledRow.length, 0);
    } else {
      var x = 0;
      while (x < width) {
        if (depth[(start + x) % width] != unwritten) {
          x++;
          continue;
        }
        final runStart = x;
        while (x < width && depth[(start + x) % width] == unwritten) {
          x++;
        }
        final before = (start + runStart - 1) % width;
        final after = (start + x) % width;
        final from = depth[before] <= depth[after] ? before : after;
        for (var k = runStart; k < x; k++) {
          final column = (start + k) % width;
          filledRow[column * 3] = colour[from * 3];
          filledRow[column * 3 + 1] = colour[from * 3 + 1];
          filledRow[column * 3 + 2] = colour[from * 3 + 2];
        }
      }
    }

    // The bytes: each filled pixel blurred over 3 on the filled row, around it, every channel rounded half up
    final out = targetOffset + y * targetRow;
    for (var x = 0; x < width; x++) {
      final at = out + x * 4;
      if (depth[x] != unwritten) {
        target[at] = _toByte(filledRow[x * 3]);
        target[at + 1] = _toByte(filledRow[x * 3 + 1]);
        target[at + 2] = _toByte(filledRow[x * 3 + 2]);
        if (holes != null) {
          holes[y * width + x] = 0;
        }
      } else {
        final previous = (x - 1) % width;
        final next = (x + 1) % width;
        for (var channel = 0; channel < 3; channel++) {
          target[at + channel] = _toByte(
            (filledRow[previous * 3 + channel] + filledRow[x * 3 + channel] + filledRow[next * 3 + channel]) / 3,
          );
        }
        filled++;
        if (holes != null) {
          holes[y * width + x] = 1;
        }
      }
      target[at + 3] = 255;
    }
    if (onRows != null && ((y + 1) % 64 == 0 || y + 1 == height)) {
      onRows(y + 1);
    }
  }
  return Relief360Eye(filledPixels: filled, width: width, height: height, lowRelief: lowRelief);
}

int _toByte(double value) => math.min(255, math.max(0, (value + 0.5).floor()));

void _checkPixels(String name, Uint8List bytes, int width, int height, int offset, int stride) {
  if (width < 1 || height < 1 || offset < 0 || stride < width * 4) {
    throw ArgumentError('The $name eye of $width x $height with rows of $stride bytes from $offset');
  }
  if (bytes.length < offset + (height - 1) * stride + width * 4) {
    throw ArgumentError('${bytes.length} bytes do not hold the $name eye of $width x $height from $offset');
  }
}
