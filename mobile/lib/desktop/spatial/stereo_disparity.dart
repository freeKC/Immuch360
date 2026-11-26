// Spatial 2.5D photos on the computers (release 53, lot P1): the depth of a 3D photo, as the disparity between its two
// eyes, computed once per photo on the processor, in a background isolate. The steps are those of the phones' video
// passes (SpatialShaders.kt): gray eyes at about 640 x 360, a 7 x 7 sum of absolute differences along the rows with a
// parabola for the sub pixel step, flat areas and borders marked unreliable, the left right check, then a blur in which
// each disparity weighs by its reliability. A photo has no previous frame, so there is no blend over time; instead the
// unreliable pixels first take the farther of their reliable neighbours on the row (the background, which is what an
// occlusion hides), and the blur runs twice.
//
// A disparity d is xLeft - xRight in pixels of the map: positive for what comes out of the screen. The shader of the
// page (shaders/spatial_photo.frag) reads the map as an opaque RGBA picture: the left map in red, the right map in
// green, both over the range [EncodedDisparity.minimum, + range], and the reliability of the left map in blue.
//
// The sums run as box filters: for each shift, the differences of a row, then a running sum along the row and one down
// the columns. At 640 x 360 with 65 shifts and both eyes, that is about 100 million additions.

import 'dart:math' as math;
import 'dart:typed_data';

/// The pixel count of the map: the high tier of the phones (SpatialRenderer.kt, Quality.HIGH)
const disparityMapWidth = 640;
const disparityMapHeight = 360;

/// How far the matching looks each way, as a fraction of the width of the map (SEARCH_FRACTION of the phones)
const disparitySearchFraction = 0.05;

/// The side of the matching window
const disparityWindow = 7;

/// Mean absolute deviation of the gray values (0 to 1) of a window under which it is too flat to match
const disparityMinContrast = 0.008;

/// Disagreement, in pixels of the map, over which the left right check rejects a match
const disparityConsistencyTolerance = 1.0;

/// The taps of the blur
const disparityBlurKernel = [1, 4, 6, 4, 1];

/// The two eyes of a photo in gray (0 to 1), at the size of the map, row after row
class GrayEyes {
  const GrayEyes({required this.width, required this.height, required this.left, required this.right});

  final int width;
  final int height;
  final Float32List left;
  final Float32List right;
}

/// The size of the map for an eye shown at [width] x [height]: the shape of the eye as it is seen, with the pixel
/// count of [disparityMapWidth] x [disparityMapHeight] at most
({int width, int height}) disparityMapSize(int width, int height) {
  const pixels = disparityMapWidth * disparityMapHeight;
  if (width * height <= pixels) {
    return (width: width, height: height);
  }
  final aspect = width / height;
  final mapHeight = math.max(16, math.sqrt(pixels / aspect).round());
  final mapWidth = math.max(16, (mapHeight * aspect).round());
  return (width: mapWidth, height: mapHeight);
}

/// How far the matching looks each way on a map [width] pixels wide
int disparityMapSearchRange(int width) => math.max(2, (width * disparitySearchFraction).round());

/// The result of the matching from one eye: a disparity and a reliability (0 or 1) per pixel
class RawDisparity {
  const RawDisparity(this.disparity, this.validity);

  final Float32List disparity;
  final Float32List validity;
}

const _noCost = 1.0e9;

/// For each pixel of [reference], the shift of [other] with the smallest 7 x 7 sum of absolute differences, from
/// -[searchRange] to [searchRange], refined by a parabola. [direction] is 1 when the reference is the left eye (the
/// other pixel is at x - d), -1 for the right eye (x + d), so that both give xLeft - xRight. Rows past the top and
/// bottom repeat the edge row; a window of the other eye that leaves the picture does not count.
RawDisparity matchDisparity(
  Float32List reference,
  Float32List other,
  int width,
  int height, {
  required int searchRange,
  required int direction,
}) {
  const half = disparityWindow ~/ 2;
  final count = width * height;
  final best = Float32List(count)..fillRange(0, count, _noCost);
  final bestShift = Int32List(count);
  final before = Float32List(count)..fillRange(0, count, _noCost);
  final after = Float32List(count)..fillRange(0, count, _noCost);
  final previous = Float32List(count)..fillRange(0, count, _noCost);
  final takeNext = Uint8List(count);

  // The differences of a row, padded by the half window on each side; the sums along the rows; the cost
  final rowDiff = Float32List(width + 2 * half);
  final rowSums = Float32List(count);
  final cost = Float32List(count);

  for (var d = -searchRange; d <= searchRange; d++) {
    final move = direction * d;
    // Along the rows
    for (var y = 0; y < height; y++) {
      final row = y * width;
      for (var c = -half; c < width + half; c++) {
        final xo = c - move;
        final xr = c < 0 ? 0 : (c >= width ? width - 1 : c);
        rowDiff[c + half] = xo >= 0 && xo < width ? (reference[row + xr] - other[row + xo]).abs() : 0;
      }
      var sum = 0.0;
      for (var k = 0; k < disparityWindow; k++) {
        sum += rowDiff[k];
      }
      rowSums[row] = sum;
      for (var x = 1; x < width; x++) {
        sum += rowDiff[x + disparityWindow - 1] - rowDiff[x - 1];
        rowSums[row + x] = sum;
      }
    }
    // Down the columns, the edge rows repeated
    for (var x = 0; x < width; x++) {
      var sum = 0.0;
      for (var r = -half; r <= half; r++) {
        sum += rowSums[_clampRow(r, height) * width + x];
      }
      cost[x] = sum;
      for (var y = 1; y < height; y++) {
        sum += rowSums[_clampRow(y + half, height) * width + x] - rowSums[_clampRow(y - half - 1, height) * width + x];
        cost[y * width + x] = sum;
      }
    }
    // The window of the other eye must lie inside it
    final firstX = math.max(0, half + move);
    final endX = math.min(width, width - half + move);
    for (var y = 0; y < height; y++) {
      final row = y * width;
      for (var x = 0; x < width; x++) {
        final i = row + x;
        final value = x >= firstX && x < endX ? cost[i] : _noCost;
        if (takeNext[i] == 1) {
          after[i] = value;
          takeNext[i] = 0;
        }
        if (value < best[i]) {
          best[i] = value;
          bestShift[i] = d;
          before[i] = previous[i];
          after[i] = _noCost;
          takeNext[i] = 1;
        }
        previous[i] = value;
      }
    }
  }

  final disparity = Float32List(count);
  final validity = Float32List(count);
  final contrast = _contrast(reference, width, height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = y * width + x;
      var subPixel = 0.0;
      if (before[i] < _noCost && after[i] < _noCost) {
        final curvature = before[i] - 2 * best[i] + after[i];
        if (curvature > 1.0e-5) {
          subPixel = (0.5 * (before[i] - after[i]) / curvature).clamp(-0.5, 0.5);
        }
      }
      disparity[i] = bestShift[i] + subPixel;
      final inside = x >= half && x + half < width;
      validity[i] = best[i] < _noCost && contrast[i] > disparityMinContrast && inside ? 1 : 0;
    }
  }
  return RawDisparity(disparity, validity);
}

int _clampRow(int y, int height) => y < 0 ? 0 : (y >= height ? height - 1 : y);

/// The mean absolute deviation of each 7 x 7 window of [gray] from its mean, rows and columns repeated at the edges
Float32List _contrast(Float32List gray, int width, int height) {
  const half = disparityWindow ~/ 2;
  const area = disparityWindow * disparityWindow;
  final out = Float32List(width * height);
  final window = Float32List(area);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var n = 0;
      var mean = 0.0;
      for (var r = -half; r <= half; r++) {
        final row = _clampRow(y + r, height) * width;
        for (var c = -half; c <= half; c++) {
          final xc = x + c < 0 ? 0 : (x + c >= width ? width - 1 : x + c);
          final value = gray[row + xc];
          window[n++] = value;
          mean += value;
        }
      }
      mean /= area;
      var deviation = 0.0;
      for (var k = 0; k < area; k++) {
        deviation += (window[k] - mean).abs();
      }
      out[y * width + x] = deviation / area;
    }
  }
  return out;
}

/// The reliabilities after the left right check: a left pixel stays reliable when the right pixel it matches points
/// back to it within [disparityConsistencyTolerance], and the other way round
({Float32List leftValidity, Float32List rightValidity}) checkConsistency(
  RawDisparity left,
  RawDisparity right,
  int width,
  int height,
) {
  final count = width * height;
  final leftValidity = Float32List.fromList(left.validity);
  final rightValidity = Float32List.fromList(right.validity);
  for (var y = 0; y < height; y++) {
    final row = y * width;
    for (var x = 0; x < width; x++) {
      final i = row + x;
      final xRight = (x - left.disparity[i] + 0.5).floor().clamp(0, width - 1);
      final back = row + xRight;
      if (right.validity[back] < 0.5 ||
          (right.disparity[back] - left.disparity[i]).abs() > disparityConsistencyTolerance) {
        leftValidity[i] = 0;
      }
      final xLeft = (x + right.disparity[i] + 0.5).floor().clamp(0, width - 1);
      final forth = row + xLeft;
      if (left.validity[forth] < 0.5 ||
          (left.disparity[forth] - right.disparity[i]).abs() > disparityConsistencyTolerance) {
        rightValidity[i] = 0;
      }
    }
  }
  assert(leftValidity.length == count);
  return (leftValidity: leftValidity, rightValidity: rightValidity);
}

/// Gives each unreliable pixel of [values] the smaller (farther) of the nearest reliable values on its row, left and
/// right; a row without any keeps its values. In place.
void fillHoles(Float32List values, Float32List validity, int width, int height) {
  for (var y = 0; y < height; y++) {
    final row = y * width;
    var x = 0;
    while (x < width) {
      if (validity[row + x] >= 0.5) {
        x++;
        continue;
      }
      final start = x;
      while (x < width && validity[row + x] < 0.5) {
        x++;
      }
      final hasBefore = start > 0;
      final hasAfter = x < width;
      if (!hasBefore && !hasAfter) {
        continue;
      }
      final fill = hasBefore && hasAfter
          ? math.min(values[row + start - 1], values[row + x])
          : (hasBefore ? values[row + start - 1] : values[row + x]);
      for (var k = start; k < x; k++) {
        values[row + k] = fill;
      }
    }
  }
}

/// One direction of the blur of the phones: each value weighs by the kernel times its reliability (plus a hundredth,
/// so that an area without any still averages); the reliability is blurred with the kernel alone
(Float32List, Float32List) blurOnce(
  Float32List values,
  Float32List validity,
  int width,
  int height, {
  required bool horizontal,
}) {
  final out = Float32List(width * height);
  final outValidity = Float32List(width * height);
  const kernelSum = 16.0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var sum = 0.0;
      var weight = 0.0;
      var reliable = 0.0;
      for (var t = 0; t < disparityBlurKernel.length; t++) {
        final offset = t - 2;
        final xs = horizontal ? (x + offset).clamp(0, width - 1) : x;
        final ys = horizontal ? y : (y + offset).clamp(0, height - 1);
        final i = ys * width + xs;
        final k = disparityBlurKernel[t].toDouble();
        final w = k * (validity[i] + 0.01);
        sum += w * values[i];
        weight += w;
        reliable += k * validity[i];
      }
      out[y * width + x] = sum / weight;
      outValidity[y * width + x] = reliable / kernelSum;
    }
  }
  return (out, outValidity);
}

/// The depth of a photo: the left and right maps in pixels of the map, and the reliability of the left one
class DisparityMap {
  const DisparityMap({
    required this.width,
    required this.height,
    required this.left,
    required this.right,
    required this.leftValidity,
  });

  final int width;
  final int height;
  final Float32List left;
  final Float32List right;
  final Float32List leftValidity;
}

/// Every step for [eyes]: matching from both eyes, the check, the holes filled, two blurs of each map
DisparityMap computeDisparity(GrayEyes eyes, {int? searchRange, int blurPasses = 2}) {
  final width = eyes.width;
  final height = eyes.height;
  final range = searchRange ?? disparityMapSearchRange(width);
  final rawLeft = matchDisparity(eyes.left, eyes.right, width, height, searchRange: range, direction: 1);
  final rawRight = matchDisparity(eyes.right, eyes.left, width, height, searchRange: range, direction: -1);
  final checked = checkConsistency(rawLeft, rawRight, width, height);

  (Float32List, Float32List) smooth(Float32List values, Float32List validity) {
    final filled = Float32List.fromList(values);
    fillHoles(filled, validity, width, height);
    var current = (filled, validity);
    for (var pass = 0; pass < blurPasses; pass++) {
      current = blurOnce(current.$1, current.$2, width, height, horizontal: true);
      current = blurOnce(current.$1, current.$2, width, height, horizontal: false);
    }
    return current;
  }

  final left = smooth(rawLeft.disparity, checked.leftValidity);
  final right = smooth(rawRight.disparity, checked.rightValidity);
  return DisparityMap(width: width, height: height, left: left.$1, right: right.$1, leftValidity: checked.leftValidity);
}

/// A map as the shader reads it: opaque RGBA (alpha 255, so that no premultiplication touches the data), the left
/// disparity in red and the right one in green over [minimum] to [minimum] + [range] pixels of the map, the reliability
/// of the left one in blue
class EncodedDisparity {
  const EncodedDisparity({
    required this.width,
    required this.height,
    required this.rgba,
    required this.minimum,
    required this.range,
  });

  final int width;
  final int height;
  final Uint8List rgba;
  final double minimum;
  final double range;

  /// The disparity, in pixels of the map, of the channel value [value]
  double decode(int value) => minimum + value / 255 * range;
}

/// [map] encoded for the shader, over the range its two maps span
EncodedDisparity encodeDisparityMap(DisparityMap map) {
  var low = double.infinity;
  var high = double.negativeInfinity;
  for (final values in [map.left, map.right]) {
    for (final value in values) {
      low = math.min(low, value);
      high = math.max(high, value);
    }
  }
  if (!low.isFinite) {
    low = 0;
    high = 0;
  }
  // A flat map gets one pixel of range, so that the decoding never divides by zero
  final range = high - low < 1e-6 ? 1.0 : high - low;
  int channel(double value) => ((value - low) / range * 255).round().clamp(0, 255);
  final count = map.width * map.height;
  final rgba = Uint8List(count * 4);
  for (var i = 0; i < count; i++) {
    rgba[i * 4] = channel(map.left[i]);
    rgba[i * 4 + 1] = channel(map.right[i]);
    rgba[i * 4 + 2] = (map.leftValidity[i] * 255).round().clamp(0, 255);
    rgba[i * 4 + 3] = 255;
  }
  return EncodedDisparity(width: map.width, height: map.height, rgba: rgba, minimum: low, range: range);
}

/// The gray (0 to 1) of the RGBA pixels [rgba] of a picture [stride] pixels wide, from column [x0], [width] x [height]
Float32List grayOf(Uint8List rgba, int stride, int x0, int width, int height) {
  final out = Float32List(width * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * stride + x0 + x) * 4;
      out[y * width + x] = (0.299 * rgba[i] + 0.587 * rgba[i + 1] + 0.114 * rgba[i + 2]) / 255;
    }
  }
  return out;
}

/// The whole work of the isolate: [rgba], both eyes side by side at the size of the map ([width] each, [height] high),
/// to the encoded map
EncodedDisparity disparityOfSideBySide(Uint8List rgba, int width, int height) {
  final eyes = GrayEyes(
    width: width,
    height: height,
    left: grayOf(rgba, width * 2, 0, width, height),
    right: grayOf(rgba, width * 2, width, width, height),
  );
  return encodeDisparityMap(computeDisparity(eyes));
}
