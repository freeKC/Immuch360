// The right eye of relief-v2 on a computer (release 46, lot I3; ReliefV2 in immersive_format.dart). Two changes to
// relief-v1, the left eye still the original and only read:
//
//  - the depth at each pixel of the eye comes from a joint bilateral upsampling of the model's map, guided by the photo
//    (GuidedEyeDepth): each pixel weighs the 4 x 4 samples of the map around it by their distance and by how close the
//    mean colour of each sample's cell is to its own colour. A pixel of the background beside a near object then takes
//    the depth of the background even where the bilinear reading of relief-v1 gave a ramp several pixels wide, so the
//    jump falls on the edge the photo shows: no halo of background dragged with the object, no "cardboard" rim. The
//    map is normalised as in relief-v1 but not dilated, the dilation being the remedy of relief-v1 for those ramps.
//  - the holes the parallax opens are filled by MI-GAN when it is installed (inpaintHoles): the eye is cut into cells
//    of 384 pixels, each cell with a hole at least 4 pixels wide goes to MI-GAN with 64 pixels of context around it,
//    the pixels nearer than the background of its holes hidden from it as well, so that it continues the background
//    and never the object; only the holes of the cell are taken from its result, and the cells after it see them as
//    known. Thinner holes, and a cell with too little background around, keep the fill of relief-v1.
//
// Rows are computed one at a time, as in relief-v1: no map at the size of the eye is ever made. The fill by MI-GAN
// needs two bytes a pixel more (the mask of the holes and the depth of the right eye).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_flags.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/desktop/ai/relief/right_eye.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// d at each pixel of an eye of [eyeWidth] x [eyeHeight] from [map] (normalised, see normaliseDepth), by a joint
/// bilateral upsampling guided by the eye itself (see the top of this file). The eye is read from [eye], RGBA rows from
/// [offset], [stride] bytes apart, when the sampler is made (the mean colours of the cells) and at each row.
class GuidedEyeDepth implements EyeDepthRows {
  GuidedEyeDepth(
    this.map, {
    required this.eye,
    required this.eyeWidth,
    required this.eyeHeight,
    this.offset = 0,
    int? stride,
    double rangeSigma = ReliefV2.rangeSigma,
    double spatialSigma = ReliefV2.spatialSigma,
  }) : stride = stride ?? eyeWidth * 4,
       _columns = Int32List(eyeWidth * 4),
       _columnWeights = Float64List(eyeWidth * 4),
       _guide = Int32List(map.width * map.height * 3),
       _range = Float64List(3 * 255 * 255 + 1),
       _spatialSigma = spatialSigma {
    if (eyeWidth < 1 || eyeHeight < 1) {
      throw ArgumentError('An eye of $eyeWidth x $eyeHeight');
    }
    if (!(rangeSigma > 0) || !(spatialSigma > 0)) {
      throw ArgumentError('The weights need sigmas above zero: $rangeSigma, $spatialSigma');
    }
    if (offset < 0 ||
        this.stride < eyeWidth * 4 ||
        eye.length < offset + (eyeHeight - 1) * this.stride + eyeWidth * 4) {
      throw ArgumentError('${eye.length} bytes do not hold an eye of $eyeWidth x $eyeHeight');
    }
    final w = map.width;
    for (var x = 0; x < eyeWidth; x++) {
      final u = (x + 0.5) * w / eyeWidth - 0.5;
      final first = u.floor() - 1;
      for (var k = 0; k < 4; k++) {
        final at = first + k;
        _columns[x * 4 + k] = math.min(w - 1, math.max(0, at));
        _columnWeights[x * 4 + k] = _gauss(u - at, spatialSigma);
      }
    }
    final twoSigma2 = 2 * rangeSigma * rangeSigma;
    for (var d2 = 0; d2 < _range.length; d2++) {
      // A floor, so that a pixel unlike every sample around it still takes their mean by distance
      _range[d2] = math.exp(-d2 / twoSigma2) + _rangeFloor;
    }
    _meanColours();
  }

  final ReliefDepth map;
  final Uint8List eye;
  final int eyeWidth;
  final int eyeHeight;
  final int offset;
  final int stride;
  final double _spatialSigma;
  final Int32List _columns;
  final Float64List _columnWeights;

  /// The mean colour of the eye pixels of each sample's cell, RGB, rounded
  final Int32List _guide;

  /// The colour weight by the square of the colour difference
  final Float64List _range;

  static const _rangeFloor = 1e-4;

  static double _gauss(double distance, double sigma) => math.exp(-distance * distance / (2 * sigma * sigma));

  /// The cell of a sample covers the eye pixels whose centre falls in it; a cell no pixel falls in (an eye smaller than
  /// the map) takes the pixel at its centre
  void _meanColours() {
    final w = map.width;
    final h = map.height;
    final sums = Float64List(w * h * 3);
    final counts = Int32List(w * h);
    final cellOfColumn = Int32List(eyeWidth);
    for (var x = 0; x < eyeWidth; x++) {
      cellOfColumn[x] = math.min(w - 1, (x * w + (w >> 1)) ~/ eyeWidth);
    }
    for (var y = 0; y < eyeHeight; y++) {
      final row = math.min(h - 1, (y * h + (h >> 1)) ~/ eyeHeight) * w;
      final from = offset + y * stride;
      for (var x = 0; x < eyeWidth; x++) {
        final cell = row + cellOfColumn[x];
        final at = from + x * 4;
        sums[cell * 3] += eye[at];
        sums[cell * 3 + 1] += eye[at + 1];
        sums[cell * 3 + 2] += eye[at + 2];
        counts[cell]++;
      }
    }
    for (var cell = 0; cell < w * h; cell++) {
      final count = counts[cell];
      if (count > 0) {
        for (var c = 0; c < 3; c++) {
          _guide[cell * 3 + c] = (sums[cell * 3 + c] / count).round();
        }
        continue;
      }
      final x = math.min(eyeWidth - 1, ((cell % w + 0.5) * eyeWidth / w).floor());
      final y = math.min(eyeHeight - 1, ((cell ~/ w + 0.5) * eyeHeight / h).floor());
      final at = offset + y * stride + x * 4;
      for (var c = 0; c < 3; c++) {
        _guide[cell * 3 + c] = eye[at + c];
      }
    }
  }

  @override
  void sampleRow(int y, Float64List out) {
    final w = map.width;
    final h = map.height;
    final values = map.values;
    final v = (y + 0.5) * h / eyeHeight - 0.5;
    final first = v.floor() - 1;
    final rows = Int32List(4);
    final rowWeights = Float64List(4);
    for (var k = 0; k < 4; k++) {
      final at = first + k;
      rows[k] = math.min(h - 1, math.max(0, at)) * w;
      rowWeights[k] = _gauss(v - at, _spatialSigma);
    }
    final guide = _guide;
    final range = _range;
    final columns = _columns;
    final columnWeights = _columnWeights;
    final from = offset + y * stride;
    for (var x = 0; x < eyeWidth; x++) {
      final at = from + x * 4;
      final r = eye[at];
      final g = eye[at + 1];
      final b = eye[at + 2];
      var sum = 0.0;
      var weight = 0.0;
      for (var ky = 0; ky < 4; ky++) {
        final row = rows[ky];
        final wy = rowWeights[ky];
        for (var kx = 0; kx < 4; kx++) {
          final cell = row + columns[x * 4 + kx];
          final dr = r - guide[cell * 3];
          final dg = g - guide[cell * 3 + 1];
          final db = b - guide[cell * 3 + 2];
          final wt = wy * columnWeights[x * 4 + kx] * range[dr * dr + dg * dg + db * db];
          sum += wt * values[cell];
          weight += wt;
        }
      }
      out[x] = sum / weight;
    }
  }
}

/// What [inpaintHoles] did
class ReliefInpaintReport {
  const ReliefInpaintReport({required this.cells, required this.pixels});

  /// The cells MI-GAN filled
  final int cells;

  /// The pixels of holes it filled
  final int pixels;

  static const none = ReliefInpaintReport(cells: 0, pixels: 0);
}

/// The cells of [ReliefV2.inpaintCell] pixels of an eye of [width] x [height] that have a hole (1 in [holes]) of at
/// least [minRun] pixels along a row, by index row after row (cellsAcross = ceil(width / cell))
List<int> inpaintCellsOf(
  Uint8List holes,
  int width,
  int height, {
  int cell = ReliefV2.inpaintCell,
  int minRun = ReliefV2.inpaintMinRun,
}) {
  final across = (width + cell - 1) ~/ cell;
  final down = (height + cell - 1) ~/ cell;
  final marked = Uint8List(across * down);
  for (var y = 0; y < height; y++) {
    final row = y * width;
    final cellRow = (y ~/ cell) * across;
    var x = 0;
    while (x < width) {
      if (holes[row + x] == 0) {
        x++;
        continue;
      }
      final start = x;
      while (x < width && holes[row + x] != 0) {
        x++;
      }
      if (x - start >= minRun) {
        for (var c = start ~/ cell; c <= (x - 1) ~/ cell; c++) {
          marked[cellRow + c] = 1;
        }
      }
    }
  }
  return [
    for (var index = 0; index < marked.length; index++)
      if (marked[index] == 1) index,
  ];
}

/// Fills the holes of the right eye in [target] (RGBA rows from [targetOffset], [targetStride] bytes apart, already
/// filled by relief-v1) with [inpaint], cell after cell (see the top of this file). [holes] has 1 for each hole,
/// [eyeDepth] the depth of each pixel out of 255 (a hole that of its background), both as writeRightEye gives them;
/// neither is changed. [isCancelled] is read before each cell and throws ReliefCancelledException; [onCells] hears the
/// cells done out of the cells to do. Throws BackendException when the model fails.
ReliefInpaintReport inpaintHoles({
  required Uint8List target,
  required int width,
  required int height,
  int targetOffset = 0,
  int? targetStride,
  required Uint8List holes,
  required Uint8List eyeDepth,
  required InpaintBackend inpaint,
  int cell = ReliefV2.inpaintCell,
  int margin = ReliefV2.inpaintMargin,
  int minRun = ReliefV2.inpaintMinRun,
  bool Function()? isCancelled,
  void Function(int done, int total)? onCells,
}) {
  final rowBytes = targetStride ?? width * 4;
  if (holes.length != width * height || eyeDepth.length != width * height) {
    throw ArgumentError('The mask and the depths of an eye of $width x $height');
  }
  if (target.length < targetOffset + (height - 1) * rowBytes + width * 4) {
    throw ArgumentError('${target.length} bytes do not hold an eye of $width x $height');
  }
  final cells = inpaintCellsOf(holes, width, height, cell: cell, minRun: minRun);
  onCells?.call(0, cells.length);
  if (cells.isEmpty) {
    return ReliefInpaintReport.none;
  }
  final across = (width + cell - 1) ~/ cell;
  // The holes MI-GAN has not filled yet; a filled one is known to the next cells, with the depth of its background
  final open = Uint8List.fromList(holes);
  final nearer = (ReliefV1.linkThreshold * 255).round();
  var done = 0;
  var filledCells = 0;
  var filledPixels = 0;
  for (final index in cells) {
    if (isCancelled != null && isCancelled()) {
      throw const ReliefCancelledException();
    }
    final coreLeft = (index % across) * cell;
    final coreTop = (index ~/ across) * cell;
    final coreRight = math.min(width, coreLeft + cell);
    final coreBottom = math.min(height, coreTop + cell);
    final left = math.max(0, coreLeft - margin);
    final top = math.max(0, coreTop - margin);
    final right = math.min(width, coreRight + margin);
    final bottom = math.min(height, coreBottom + margin);
    final regionWidth = right - left;
    final regionHeight = bottom - top;

    // The farthest background of the holes of the cell: what is nearer than it by more than the link threshold is an
    // object in front, hidden from MI-GAN with the holes
    var background = -1;
    for (var y = coreTop; y < coreBottom; y++) {
      for (var x = coreLeft; x < coreRight; x++) {
        final at = y * width + x;
        if (open[at] == 1 && eyeDepth[at] > background) {
          background = eyeDepth[at];
        }
      }
    }
    if (background >= 0) {
      final limit = background + nearer;
      final rgb = Uint8List(3 * regionWidth * regionHeight);
      final mask = Uint8List(regionWidth * regionHeight);
      var known = 0;
      for (var y = top; y < bottom; y++) {
        for (var x = left; x < right; x++) {
          final at = y * width + x;
          final cellAt = (y - top) * regionWidth + (x - left);
          final pixel = targetOffset + y * rowBytes + x * 4;
          rgb[cellAt * 3] = target[pixel];
          rgb[cellAt * 3 + 1] = target[pixel + 1];
          rgb[cellAt * 3 + 2] = target[pixel + 2];
          if (open[at] == 0 && eyeDepth[at] <= limit) {
            mask[cellAt] = 1;
            known++;
          }
        }
      }
      if (known >= ReliefV2.inpaintMinContext * regionWidth * regionHeight) {
        final out = inpaint.fill(InpaintRegion(width: regionWidth, height: regionHeight, rgb: rgb, mask: mask));
        for (var y = coreTop; y < coreBottom; y++) {
          for (var x = coreLeft; x < coreRight; x++) {
            final at = y * width + x;
            if (open[at] == 0) {
              continue;
            }
            final cellAt = (y - top) * regionWidth + (x - left);
            final pixel = targetOffset + y * rowBytes + x * 4;
            target[pixel] = out[cellAt * 3];
            target[pixel + 1] = out[cellAt * 3 + 1];
            target[pixel + 2] = out[cellAt * 3 + 2];
            open[at] = 0;
            filledPixels++;
          }
        }
        filledCells++;
      }
    }
    done++;
    onCells?.call(done, cells.length);
  }
  return ReliefInpaintReport(cells: filledCells, pixels: filledPixels);
}

/// What relief-v2 did for one eye: the result of relief-v1's steps, and what MI-GAN filled
class ReliefV2EyeResult extends ReliefEyeResult {
  const ReliefV2EyeResult({
    required super.filledPixels,
    required super.flags,
    required super.meanLuma,
    required super.p2,
    required super.p98,
    this.inpaint = ReliefInpaintReport.none,
  });

  final ReliefInpaintReport inpaint;
}

/// relief-v2 for one eye: [depth] (the model's map cut to the photo, see cropToPhoto) normalised, read at each pixel by
/// [GuidedEyeDepth], the right eye of [left] written into [target] as writeRightEye does, then its holes filled by
/// [inpaint] when given (see [inpaintHoles]). [onRows] hears the rows of the right eye, [onCells] the cells of the
/// fill. [holes], when given, receives the mask of the holes as writeRightEye gives it.
ReliefV2EyeResult reliefV2RightEye({
  required Uint8List left,
  required int width,
  required int height,
  int leftOffset = 0,
  int? leftStride,
  required ReliefDepth depth,
  double parallax = ReliefV1.parallax,
  double convergence = ReliefV1.convergence,
  required Uint8List target,
  int targetOffset = 0,
  int? targetStride,
  InpaintBackend? inpaint,
  Uint8List? holes,
  bool Function()? isCancelled,
  void Function(int rows)? onRows,
  void Function(int done, int total)? onCells,
}) {
  final normalised = normaliseDepth(depth);
  final rows = GuidedEyeDepth(
    normalised.depth,
    eye: left,
    eyeWidth: width,
    eyeHeight: height,
    offset: leftOffset,
    stride: leftStride,
  );
  final mask = holes ?? (inpaint == null ? null : Uint8List(width * height));
  final eyeDepth = inpaint == null ? null : Uint8List(width * height);
  final eye = writeRightEye(
    left: left,
    width: width,
    height: height,
    leftOffset: leftOffset,
    leftStride: leftStride,
    map: normalised.depth,
    rows: rows,
    parallax: parallax,
    convergence: convergence,
    target: target,
    targetOffset: targetOffset,
    targetStride: targetStride,
    holes: mask,
    eyeDepth: eyeDepth,
    isCancelled: isCancelled,
    onRows: onRows,
  );
  var report = ReliefInpaintReport.none;
  if (inpaint != null && eye.filledPixels > 0) {
    report = inpaintHoles(
      target: target,
      width: width,
      height: height,
      targetOffset: targetOffset,
      targetStride: targetStride,
      holes: mask!,
      eyeDepth: eyeDepth!,
      inpaint: inpaint,
      isCancelled: isCancelled,
      onCells: onCells,
    );
  }
  final luma = meanLuma(left, width: width, height: height, offset: leftOffset, stride: leftStride);
  return ReliefV2EyeResult(
    filledPixels: eye.filledPixels,
    flags: reliefFlags(
      lowRelief: normalised.lowRelief,
      filledPixels: eye.filledPixels,
      width: width,
      height: height,
      meanLuma: luma,
    ),
    meanLuma: luma,
    p2: normalised.p2,
    p98: normalised.p98,
    inpaint: report,
  );
}
