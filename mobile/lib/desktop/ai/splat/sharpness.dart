// How sharp a photo or a frame of a video is, for a splat scene (plan 2026-11-01, lot SP5): a blurred image gives
// COLMAP poor points and Brush a soft splat, and "a blurred photo is worse than none". The measure of the morning
// (tools/pick_sharp.py) kept the sharpest frame of each window of a video by the variance of the Laplacian of a grey
// copy of 512 pixels, and left out a window whose best stayed under half the median of its neighbours; the photos get
// the same rule against the photos taken just before and after them. Lot SPF2 adds a floor for the frames of a video, a
// quarter of the median of all of them, for a run of blurred ones whose neighbours are blurred too; not for photos (its
// review: in the room of measure M1, a sharp photo of a plain wall, a lamp and a sofa, 90.0 beside a median of 418.2,
// which COLMAP placed, would have gone). Pure Dart, run in the isolates that prepare the images.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The order of the channels of the pixels a picture is given in: RGBA (the codecs), or BGR0 (mpv's screenshot-raw)
enum PixelOrder { rgba, bgr0 }

/// A grey picture, one byte a pixel, rows top to bottom
class GreyPicture {
  GreyPicture({required this.width, required this.height, required this.pixels})
    : assert(pixels.length == width * height, 'Grey of $width x $height');

  final int width;
  final int height;
  final Uint8List pixels;
}

/// The size of a picture of [width] x [height] once fitted in a square of [side] pixels, proportions kept (rounded,
/// at least 1); the picture itself when it already fits
(int, int) fittedIn(int width, int height, int side) {
  if (width <= side && height <= side) {
    return (width, height);
  }
  final scale = side / math.max(width, height);
  return (math.max(1, math.min(side, (width * scale).round())), math.max(1, math.min(side, (height * scale).round())));
}

/// The grey copy of [pixels] ([width] x [height], rows of [stride] bytes, 4 bytes a pixel in [order]) fitted in a
/// square of [side] pixels by area average: the luma of ITU-R 601, as Pillow's "L" (299, 587 and 114 thousandths)
GreyPicture greyFitted(
  Uint8List pixels, {
  required int width,
  required int height,
  int? stride,
  PixelOrder order = PixelOrder.rgba,
  int side = SplatV1.sharpnessSide,
}) {
  final rowBytes = stride ?? width * 4;
  final red = order == PixelOrder.rgba ? 0 : 2;
  final blue = 2 - red;
  final luma = Uint8List(width * height);
  var out = 0;
  for (var y = 0; y < height; y++) {
    var at = y * rowBytes;
    for (var x = 0; x < width; x++) {
      luma[out++] = (299 * pixels[at + red] + 587 * pixels[at + 1] + 114 * pixels[at + blue] + 500) ~/ 1000;
      at += 4;
    }
  }
  final (outWidth, outHeight) = fittedIn(width, height, side);
  if (outWidth == width && outHeight == height) {
    return GreyPicture(width: width, height: height, pixels: luma);
  }
  final across = _reduceGrey(luma, count: height, from: width, to: outWidth, horizontal: true);
  final both = _reduceGrey(across, count: outWidth, from: height, to: outHeight, horizontal: false);
  return GreyPicture(width: outWidth, height: outHeight, pixels: both);
}

/// [grey] reduced along one axis from [from] to [to] pixels by area average, [count] lines across the other (rows
/// when [horizontal]); the overlaps counted in units of 1 / [to] of a source pixel, as fitEye does for the colours
Uint8List _reduceGrey(
  Uint8List grey, {
  required int count,
  required int from,
  required int to,
  required bool horizontal,
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
  final source = Int32List.fromList(sources);
  final weight = Int32List.fromList(weights);
  final out = Uint8List(to * count);
  final half = from ~/ 2;
  for (var line = 0; line < count; line++) {
    for (var i = 0; i < to; i++) {
      var sum = 0;
      for (var k = first[i]; k < first[i + 1]; k++) {
        sum += weight[k] * grey[horizontal ? line * from + source[k] : source[k] * count + line];
      }
      out[horizontal ? line * to + i : i * count + line] = (sum + half) ~/ from;
    }
  }
  return out;
}

/// The variance of the Laplacian of [grey] (the four neighbours less four times the pixel) over its inner pixels:
/// high for a sharp picture, low for a blurred one; 0 for a picture under 3 x 3
double laplacianVariance(GreyPicture grey) {
  final width = grey.width;
  final height = grey.height;
  if (width < 3 || height < 3) {
    return 0;
  }
  final pixels = grey.pixels;
  var sum = 0.0;
  var squares = 0.0;
  for (var y = 1; y < height - 1; y++) {
    var at = y * width + 1;
    for (var x = 1; x < width - 1; x++) {
      final value = pixels[at - width] + pixels[at + width] + pixels[at - 1] + pixels[at + 1] - 4 * pixels[at];
      sum += value;
      squares += value * value;
      at++;
    }
  }
  final count = (width - 2) * (height - 2);
  final mean = sum / count;
  return math.max(0, squares / count - mean * mean);
}

/// The sharpness of [pixels] (see [greyFitted]): the variance of the Laplacian of its grey copy of [side] pixels
double sharpnessOf(
  Uint8List pixels, {
  required int width,
  required int height,
  int? stride,
  PixelOrder order = PixelOrder.rgba,
  int side = SplatV1.sharpnessSide,
}) => laplacianVariance(greyFitted(pixels, width: width, height: height, stride: stride, order: order, side: side));

/// The images of [sharpness] (in the order of time) left out as blurred: those under [ratio] times the median of
/// their neighbours, up to [reach] before and [reach] after them (pick_sharp.py), and those under [floor] times the
/// median of all of them, which a run of blurred ones keeps from its neighbours: the frames of a video pass
/// SplatV1.blurFloorRatio (lot SPF2: the close-ups out of focus at the end of FreeKC's video of 3 November, nine frames
/// from 4.9 to 28.6 beside a median of 129.9, which COLMAP never placed), the photos none. An image alone is never
/// blurred.
Set<int> blurredAmong(List<double> sharpness, {double ratio = SplatV1.blurRatio, int reach = 2, double floor = 0}) {
  final blurred = <int>{};
  if (sharpness.length < 2) {
    return blurred;
  }
  final least = floor * _median(sharpness);
  for (var i = 0; i < sharpness.length; i++) {
    final neighbours = [
      for (var j = math.max(0, i - reach); j < math.min(sharpness.length, i + reach + 1); j++)
        if (j != i) sharpness[j],
    ];
    if (sharpness[i] < least || neighbours.isNotEmpty && sharpness[i] < ratio * _median(neighbours)) {
      blurred.add(i);
    }
  }
  return blurred;
}

/// The median of [values], the mean of the two middle ones for an even count (numpy's median)
double _median(List<double> values) {
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}
