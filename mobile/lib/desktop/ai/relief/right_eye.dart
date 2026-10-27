// The right eye of relief-v1 on a computer (design-final 2026-10-26, section 2.4, steps 3 to 6). The left eye is the
// photo itself and is only read: the "2D (original)" mode then shows the original exactly, and every hole and stretch
// lands on the right eye. Each row is a mesh of its pixels moved by their depth (forward projection), the nearest
// wins, the holes take the background beside them and are softened by a blur of 3 pixels. The steps and the order of
// every operation are those of .github/desktop/ai/make_relief_golden.py, in double precision, so that the computers
// and the Quest (lot A8b) round alike and the golden fixture holds both.
//
// Written to work in place in the pair of the engine (lot A4b): the left eye read from the left half of a 2L x H RGBA
// buffer and the right eye written into its right half, row after row, with the cancel flag read every 64 rows.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/relief/relief_flags.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// Thrown by [writeRightEye] when its cancel check says so; the rows already written are to be dropped
class ReliefCancelledException implements Exception {
  const ReliefCancelledException();

  @override
  String toString() => 'ReliefCancelledException';
}

/// d at each pixel of an eye of [eyeWidth] x [eyeHeight], read bilinearly at the centre of the pixel from [map]:
/// u = (x + 0.5) * w / L - 0.5, the edges repeated, and a + (b - a) * f so that equal neighbours give their value
class EyeDepthSampler {
  EyeDepthSampler(this.map, this.eyeWidth, this.eyeHeight)
    : _left = Int32List(eyeWidth),
      _right = Int32List(eyeWidth),
      _fx = Float64List(eyeWidth) {
    if (eyeWidth < 1 || eyeHeight < 1) {
      throw ArgumentError('An eye of $eyeWidth x $eyeHeight');
    }
    final w = map.width;
    for (var x = 0; x < eyeWidth; x++) {
      final u = (x + 0.5) * w / eyeWidth - 0.5;
      final x0 = u.floor();
      _fx[x] = u - x0;
      _left[x] = _clampIndex(x0, w);
      _right[x] = _clampIndex(x0 + 1, w);
    }
  }

  final ReliefDepth map;
  final int eyeWidth;
  final int eyeHeight;
  final Int32List _left;
  final Int32List _right;
  final Float64List _fx;

  /// Writes d of the row [y] of the eye into [out], which holds [eyeWidth] values
  void sampleRow(int y, Float64List out) {
    final h = map.height;
    final w = map.width;
    final v = (y + 0.5) * h / eyeHeight - 0.5;
    final y0 = v.floor();
    final fy = v - y0;
    final top = _clampIndex(y0, h) * w;
    final bottom = _clampIndex(y0 + 1, h) * w;
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

  static int _clampIndex(int index, int size) => math.min(size - 1, math.max(0, index));
}

/// What [writeRightEye] did
class RightEye {
  const RightEye(this.filledPixels);

  /// How many pixels of the right eye no source pixel reached, filled from the background beside them
  final int filledPixels;
}

/// Writes the right eye of the left eye [left] ([width] x [height] RGBA, rows from [leftOffset], [leftStride] bytes
/// apart) into [target] (rows from [targetOffset], [targetStride] bytes apart, alpha 255), from [map], d between 0
/// and 1 (see reliefMapOf), with the parallax B and the convergence c of relief-v1: the pixel x moves to
/// x + B * L * (c - d). [holes], when given, receives 1 for each filled pixel and 0 for the others, row after row.
/// [isCancelled] is read before every 64th row and throws [ReliefCancelledException] when true; [onRows] hears the
/// rows done every 64 rows and at the end. [left] is only read.
RightEye writeRightEye({
  required Uint8List left,
  required int width,
  required int height,
  int leftOffset = 0,
  int? leftStride,
  required ReliefDepth map,
  required double parallax,
  required double convergence,
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
  if (!parallax.isFinite || parallax < 0 || parallax > 1) {
    throw ArgumentError.value(parallax, 'parallax', 'A fraction of the width of the eye, 0 to 1');
  }
  if (!convergence.isFinite || convergence < 0 || convergence > 1) {
    throw ArgumentError.value(convergence, 'convergence', 'A depth, 0 to 1');
  }

  final sampler = EyeDepthSampler(map, width, height);
  final d = Float64List(width);
  final t = Float64List(width);
  final depth = Float64List(width);
  final colour = Float64List(width * 3);
  final shift = parallax * width;
  const unwritten = double.negativeInfinity;
  var filled = 0;

  for (var y = 0; y < height; y++) {
    if (y % 64 == 0 && isCancelled != null && isCancelled()) {
      throw const ReliefCancelledException();
    }
    sampler.sampleRow(y, d);
    for (var x = 0; x < width; x++) {
      t[x] = x + shift * (convergence - d[x]);
    }
    depth.fillRange(0, width, unwritten);
    final source = leftOffset + y * leftRow;

    // Forward projection: each pixel alone, then the segment to its right neighbour when the two are linked
    for (var x = 0; x < width; x++) {
      final d0 = d[x];
      final t0 = t[x];
      final at = source + x * 4;
      final r0 = left[at];
      final g0 = left[at + 1];
      final b0 = left[at + 2];
      final alone = (t0 + 0.5).floor();
      if (alone >= 0 && alone < width && d0 > depth[alone]) {
        depth[alone] = d0;
        colour[alone * 3] = r0.toDouble();
        colour[alone * 3 + 1] = g0.toDouble();
        colour[alone * 3 + 2] = b0.toDouble();
      }
      if (x + 1 >= width) {
        continue;
      }
      final d1 = d[x + 1];
      if ((d0 - d1).abs() > ReliefV1.linkThreshold) {
        continue;
      }
      final t1 = t[x + 1];
      final r1 = left[at + 4];
      final g1 = left[at + 5];
      final b1 = left[at + 6];
      final first = math.max(0, math.min(t0, t1).ceil());
      final last = math.min(width - 1, math.max(t0, t1).floor());
      for (var column = first; column <= last; column++) {
        final a = t1 != t0 ? (column - t0) / (t1 - t0) : 0.0;
        final dd = d0 + (d1 - d0) * a;
        if (dd > depth[column]) {
          depth[column] = dd;
          colour[column * 3] = r0 + (r1 - r0) * a;
          colour[column * 3 + 1] = g0 + (g1 - g0) * a;
          colour[column * 3 + 2] = b0 + (b1 - b0) * a;
        }
      }
    }

    // Filling: each run of holes takes its background neighbour (the smaller depth, the left one on a tie), black
    // when the row has nothing written
    var x = 0;
    while (x < width) {
      if (depth[x] != unwritten) {
        x++;
        continue;
      }
      final start = x;
      while (x < width && depth[x] == unwritten) {
        x++;
      }
      final end = x - 1;
      final before = start - 1;
      final after = end + 1 < width ? end + 1 : -1;
      final int from;
      if (before >= 0 && after >= 0) {
        from = depth[before] <= depth[after] ? before : after;
      } else {
        from = before >= 0 ? before : after;
      }
      for (var column = start; column <= end; column++) {
        colour[column * 3] = from >= 0 ? colour[from * 3] : 0.0;
        colour[column * 3 + 1] = from >= 0 ? colour[from * 3 + 1] : 0.0;
        colour[column * 3 + 2] = from >= 0 ? colour[from * 3 + 2] : 0.0;
      }
    }

    // The bytes: each filled pixel blurred over 3 on the filled row, every channel rounded half up
    final out = targetOffset + y * targetRow;
    for (var x = 0; x < width; x++) {
      final at = out + x * 4;
      if (depth[x] != unwritten) {
        target[at] = _toByte(colour[x * 3]);
        target[at + 1] = _toByte(colour[x * 3 + 1]);
        target[at + 2] = _toByte(colour[x * 3 + 2]);
        if (holes != null) {
          holes[y * width + x] = 0;
        }
      } else {
        final previous = x > 0 ? x - 1 : 0;
        final next = x < width - 1 ? x + 1 : width - 1;
        for (var channel = 0; channel < 3; channel++) {
          target[at + channel] = _toByte(
            (colour[previous * 3 + channel] + colour[x * 3 + channel] + colour[next * 3 + channel]) / 3,
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
  return RightEye(filled);
}

/// The whole of relief-v1 for one eye: the map of [depth] (the model's map cut to the photo, see cropToPhoto), the
/// right eye written into [target], and the flags
class ReliefEyeResult {
  const ReliefEyeResult({
    required this.filledPixels,
    required this.flags,
    required this.meanLuma,
    required this.p2,
    required this.p98,
  });

  final int filledPixels;
  final List<ReliefQualityFlag> flags;
  final double meanLuma;
  final double p2;
  final double p98;
}

/// Normalises and dilates [depth], writes the right eye of [left] into [target] (see [writeRightEye]) and gives the
/// flags of the photo
ReliefEyeResult reliefV1RightEye({
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
  Uint8List? holes,
  bool Function()? isCancelled,
  void Function(int rows)? onRows,
}) {
  final map = reliefMapOf(depth);
  final eye = writeRightEye(
    left: left,
    width: width,
    height: height,
    leftOffset: leftOffset,
    leftStride: leftStride,
    map: map.depth,
    parallax: parallax,
    convergence: convergence,
    target: target,
    targetOffset: targetOffset,
    targetStride: targetStride,
    holes: holes,
    isCancelled: isCancelled,
    onRows: onRows,
  );
  final luma = meanLuma(left, width: width, height: height, offset: leftOffset, stride: leftStride);
  return ReliefEyeResult(
    filledPixels: eye.filledPixels,
    flags: reliefFlags(
      lowRelief: map.lowRelief,
      filledPixels: eye.filledPixels,
      width: width,
      height: height,
      meanLuma: luma,
    ),
    meanLuma: luma,
    p2: map.p2,
    p98: map.p98,
  );
}

int _toByte(double value) => math.min(255, math.max(0, (value + 0.5).floor()));

void _checkPixels(String name, Uint8List bytes, int width, int height, int offset, int stride) {
  if (width < 1 || height < 1 || offset < 0 || stride < width * 4) {
    throw ArgumentError('The $name eye of $width x $height with rows of $stride bytes from $offset');
  }
  if (bytes.length < offset + (height - 1) * stride + width * 4) {
    throw ArgumentError('${bytes.length} bytes do not hold the $name eye of $width x $height');
  }
}
