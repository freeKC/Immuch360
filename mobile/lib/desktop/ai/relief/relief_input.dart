// The input of the depth model on a computer (design-final 2026-10-26, section 2.3, step 5): the photo brought to the
// fixed 686 x 518 of the LiteRT export, which the computers keep too so that they and the Quest draw the same map from
// the same photo. Depth Anything V2 was validated stretched, so a photo from 1.0 to 1.9 wide for 1 high is stretched
// over the whole input; any other (a portrait, a flat panorama) is reduced with its proportions and centered on its
// mean colour, and the map is cut back to that rectangle (relief_map.dart).
//
// The rules, written so that the Kotlin of the Quest (lot A8b) can give the same numbers:
// 1. Stretched when width >= height and 10 * width <= 19 * height, in integers. Otherwise centered: when
//    inputWidth * height <= inputHeight * width the photo takes the whole width and its height is
//    (2 * height * inputWidth + width) ~/ (2 * width), otherwise the whole height and the width
//    (2 * width * inputHeight + height) ~/ (2 * height) (rounded half up), never under 1; left = (inputWidth - w) ~/ 2,
//    top = (inputHeight - h) ~/ 2.
// 2. Area average, exact in integers: on each axis, the input pixel i covers [i * S, (i + 1) * S) and the photo pixel
//    j covers [j * N, (j + 1) * N), in units of 1 / N of a photo pixel (S the size of the photo, N that of the
//    rectangle). The sum of overlapX * overlapY * value over the photo, divided by S_x * S_y as a double, is the value
//    v of the input pixel. It reduces and enlarges alike.
// 3. The background of a centered photo is the mean of its pixels, sum / (width * height) as a double.
// 4. Each value becomes (v / 255 - mean) / std with the means 0.485 0.456 0.406 and the deviations 0.229 0.224 0.225
//    of ImageNet, computed in double and stored in float32, planes R, G then B ([1, 3, inputHeight, inputWidth]).
// The alpha of the photo is not read: the codec lays a transparent PNG on black before (section 2.3, step 9).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The means of ImageNet, R, G, B, the model's input is normalised with
const reliefInputMean = [0.485, 0.456, 0.406];

/// The standard deviations of ImageNet, R, G, B
const reliefInputStd = [0.229, 0.224, 0.225];

/// How the photo fills the input of the model
enum ReliefFraming {
  /// Over the whole input, its proportions changed: a photo from 1.0 to 1.9 wide for 1 high
  stretched,

  /// Reduced with its proportions, in the middle of a background of its mean colour
  centered,
}

/// Where the photo lies in the input of the model, in pixels of the input
class ReliefInputFrame {
  const ReliefInputFrame({
    required this.framing,
    required this.inputWidth,
    required this.inputHeight,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final ReliefFraming framing;
  final int inputWidth;
  final int inputHeight;
  final int left;
  final int top;
  final int width;
  final int height;

  @override
  String toString() => 'ReliefInputFrame($framing, $width x $height at $left, $top of $inputWidth x $inputHeight)';
}

/// The frame of a photo of [photoWidth] x [photoHeight] in an input of [inputWidth] x [inputHeight]
ReliefInputFrame reliefInputFrameFor(
  int photoWidth,
  int photoHeight, {
  int inputWidth = depthModelInputWidth,
  int inputHeight = depthModelInputHeight,
}) {
  if (photoWidth < 1 || photoHeight < 1 || inputWidth < 1 || inputHeight < 1) {
    throw ArgumentError('A photo of $photoWidth x $photoHeight in an input of $inputWidth x $inputHeight');
  }
  if (photoWidth >= photoHeight && 10 * photoWidth <= 19 * photoHeight) {
    return ReliefInputFrame(
      framing: ReliefFraming.stretched,
      inputWidth: inputWidth,
      inputHeight: inputHeight,
      left: 0,
      top: 0,
      width: inputWidth,
      height: inputHeight,
    );
  }
  int width;
  int height;
  if (inputWidth * photoHeight <= inputHeight * photoWidth) {
    width = inputWidth;
    height = (2 * photoHeight * inputWidth + photoWidth) ~/ (2 * photoWidth);
  } else {
    height = inputHeight;
    width = (2 * photoWidth * inputHeight + photoHeight) ~/ (2 * photoHeight);
  }
  width = math.min(inputWidth, math.max(1, width));
  height = math.min(inputHeight, math.max(1, height));
  return ReliefInputFrame(
    framing: ReliefFraming.centered,
    inputWidth: inputWidth,
    inputHeight: inputHeight,
    left: (inputWidth - width) ~/ 2,
    top: (inputHeight - height) ~/ 2,
    width: width,
    height: height,
  );
}

/// What the depth model is given, and where the photo lies in it
class ReliefInput {
  const ReliefInput(this.frame, this.nchw);

  final ReliefInputFrame frame;

  /// [1, 3, inputHeight, inputWidth] float32, normalised
  final Float32List nchw;
}

/// The input of the model for the photo [rgba] of [width] x [height]: rows of RGBA bytes from [offset], [stride]
/// bytes apart (4 * width by default, 8 * width for the left eye of a pair)
ReliefInput reliefInputOf(
  Uint8List rgba, {
  required int width,
  required int height,
  int offset = 0,
  int? stride,
  int inputWidth = depthModelInputWidth,
  int inputHeight = depthModelInputHeight,
}) {
  final rowBytes = stride ?? width * 4;
  if (width < 1 || height < 1 || rowBytes < width * 4 || offset < 0) {
    throw ArgumentError('A photo of $width x $height with rows of $rowBytes bytes');
  }
  if (rgba.length < offset + (height - 1) * rowBytes + width * 4) {
    throw ArgumentError('${rgba.length} bytes do not hold a photo of $width x $height');
  }
  final frame = reliefInputFrameFor(width, height, inputWidth: inputWidth, inputHeight: inputHeight);
  final columns = _AxisCover(width, frame.width);
  final rows = _AxisCover(height, frame.height);

  // The sums of overlapX * value for one photo row, kept for the next input row, which may share it
  final across = Int64List(frame.width * 3);
  var acrossRow = -1;
  // The photo's own sum, in units of 1 / frame.width (each photo pixel is covered by frame.width units in all)
  final photoSum = Int64List(3);
  final sums = Int64List(frame.width * 3);
  final plane = inputWidth * inputHeight;
  final nchw = Float32List(3 * plane);
  final area = (width * height).toDouble();

  for (var outY = 0; outY < frame.height; outY++) {
    sums.fillRange(0, sums.length, 0);
    for (var k = rows.first[outY]; k < rows.first[outY + 1]; k++) {
      final photoY = rows.source[k];
      final overlapY = rows.overlap[k];
      if (photoY != acrossRow) {
        acrossRow = photoY;
        _sumAcross(rgba, offset + photoY * rowBytes, columns, across);
        for (var index = 0; index < across.length; index += 3) {
          photoSum[0] += across[index];
          photoSum[1] += across[index + 1];
          photoSum[2] += across[index + 2];
        }
      }
      for (var index = 0; index < sums.length; index++) {
        sums[index] += overlapY * across[index];
      }
    }
    final at = (frame.top + outY) * inputWidth + frame.left;
    for (var outX = 0; outX < frame.width; outX++) {
      for (var channel = 0; channel < 3; channel++) {
        final v = sums[outX * 3 + channel] / area;
        nchw[channel * plane + at + outX] = (v / 255 - reliefInputMean[channel]) / reliefInputStd[channel];
      }
    }
  }

  if (frame.framing == ReliefFraming.centered) {
    for (var channel = 0; channel < 3; channel++) {
      final mean = photoSum[channel] / (frame.width * area);
      final value = (mean / 255 - reliefInputMean[channel]) / reliefInputStd[channel];
      final start = channel * plane;
      for (var y = 0; y < inputHeight; y++) {
        final inside = y >= frame.top && y < frame.top + frame.height;
        if (!inside) {
          nchw.fillRange(start + y * inputWidth, start + (y + 1) * inputWidth, value);
          continue;
        }
        nchw.fillRange(start + y * inputWidth, start + y * inputWidth + frame.left, value);
        nchw.fillRange(start + y * inputWidth + frame.left + frame.width, start + (y + 1) * inputWidth, value);
      }
    }
  }
  return ReliefInput(frame, nchw);
}

/// For each input pixel along one axis, the photo pixels it covers and by how much, in units of 1 / [target] of a
/// photo pixel: the input pixel i covers [i * size, (i + 1) * size), the photo pixel j [j * target, (j + 1) * target)
class _AxisCover {
  _AxisCover(int size, int target) : first = Int32List(target + 1) {
    final sources = <int>[];
    final overlaps = <int>[];
    for (var i = 0; i < target; i++) {
      first[i] = sources.length;
      final start = i * size;
      final end = (i + 1) * size;
      for (var j = start ~/ target; j * target < end && j < size; j++) {
        final from = j * target > start ? j * target : start;
        final to = (j + 1) * target < end ? (j + 1) * target : end;
        if (to > from) {
          sources.add(j);
          overlaps.add(to - from);
        }
      }
    }
    first[target] = sources.length;
    source = Int32List.fromList(sources);
    overlap = Int32List.fromList(overlaps);
  }

  /// The covers of the input pixel i are first[i] to first[i + 1] - 1 in [source] and [overlap]
  final Int32List first;
  late final Int32List source;
  late final Int32List overlap;
}

/// The sums of overlapX * value of one photo row starting at [rowStart], per input pixel and channel
void _sumAcross(Uint8List rgba, int rowStart, _AxisCover columns, Int64List out) {
  final targetWidth = columns.first.length - 1;
  for (var outX = 0; outX < targetWidth; outX++) {
    var r = 0;
    var g = 0;
    var b = 0;
    for (var k = columns.first[outX]; k < columns.first[outX + 1]; k++) {
      final weight = columns.overlap[k];
      final at = rowStart + columns.source[k] * 4;
      r += weight * rgba[at];
      g += weight * rgba[at + 1];
      b += weight * rgba[at + 2];
    }
    out[outX * 3] = r;
    out[outX * 3 + 1] = g;
    out[outX * 3 + 2] = b;
  }
}
