// The map step of relief-v1 on a computer (design-final 2026-10-26, sections 2.3 and 2.4): the depth the model gave,
// cut to the rectangle the photo filled in its input, normalised between its percentiles 2 and 98, then dilated so
// that the near objects keep their edges (Depth Anything draws soft halos around them). The rules are those of
// .github/desktop/ai/make_relief_golden.py, step by step and in double precision, so that the computers and the
// Quest (lot A8b) give the same map and the golden fixture holds both.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_input.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// A map of depths in double precision: [height] rows of [width] values, larger is nearer
class ReliefDepth {
  ReliefDepth(this.width, this.height, this.values) {
    if (width < 1 || height < 1 || values.length != width * height) {
      throw ArgumentError('A map of $width x $height has ${width * height} values, not ${values.length}');
    }
  }

  final int width;
  final int height;
  final Float64List values;
}

/// The depth of the photo alone: the rectangle of [frame] in [map], which has the size of the input of the model.
/// A stretched photo keeps the whole map.
ReliefDepth cropToPhoto(DepthMap map, ReliefInputFrame frame) {
  if (map.width != frame.inputWidth || map.height != frame.inputHeight) {
    throw ArgumentError(
      'The map is ${map.width} x ${map.height}, the input of the model ${frame.inputWidth} x ${frame.inputHeight}',
    );
  }
  final values = Float64List(frame.width * frame.height);
  for (var y = 0; y < frame.height; y++) {
    final from = (frame.top + y) * map.width + frame.left;
    for (var x = 0; x < frame.width; x++) {
      values[y * frame.width + x] = map.values[from + x];
    }
  }
  return ReliefDepth(frame.width, frame.height, values);
}

/// The percentile [percent] of [sorted] (increasing) by nearest rank: the value of rank max(1, (P * N + 99) ~/ 100),
/// ranks counted from 1
double reliefPercentile(Float64List sorted, int percent) {
  final rank = math.max(1, (percent * sorted.length + 99) ~/ 100);
  return sorted[rank - 1];
}

/// A map brought between 0 (the farthest) and 1 (the nearest), with the percentiles it was brought between
class NormalisedDepth {
  const NormalisedDepth(this.depth, this.p2, this.p98, {required this.lowRelief});

  final ReliefDepth depth;
  final double p2;
  final double p98;

  /// p98 - p2 is zero or under a tenth of |p98|: the photo has little relief, and says so
  final bool lowRelief;
}

/// [raw] normalised: d = (D - p2) / (p98 - p2) clamped to [0, 1], or 0.5 everywhere when p98 - p2 is not above zero.
/// A value that is not a finite number (a model that went wrong) is left out of the percentiles and becomes 1 for
/// +infinity, 0 for -infinity and 0.5 for NaN; a map with no finite spread at all is taken as flat.
NormalisedDepth normaliseDepth(ReliefDepth raw) {
  final source = raw.values;
  var finite = 0;
  for (var index = 0; index < source.length; index++) {
    if (source[index].isFinite) {
      finite++;
    }
  }
  final sorted = Float64List(finite);
  var at = 0;
  for (var index = 0; index < source.length; index++) {
    if (source[index].isFinite) {
      sorted[at++] = source[index];
    }
  }
  sorted.sort();
  final p2 = finite == 0 ? 0.0 : reliefPercentile(sorted, ReliefV1.lowPercentile);
  final p98 = finite == 0 ? 0.0 : reliefPercentile(sorted, ReliefV1.highPercentile);
  final spread = p98 - p2;
  final lowRelief = spread <= 0 || spread < ReliefV1.lowReliefRatio * p98.abs();
  final values = Float64List(source.length);
  if (spread <= 0) {
    values.fillRange(0, values.length, 0.5);
    return NormalisedDepth(ReliefDepth(raw.width, raw.height, values), p2, p98, lowRelief: lowRelief);
  }
  for (var index = 0; index < source.length; index++) {
    final value = source[index];
    if (value.isNaN) {
      values[index] = 0.5;
      continue;
    }
    final d = (value - p2) / spread;
    if (d < 0) {
      values[index] = 0;
    } else if (d > 1) {
      values[index] = 1;
    } else {
      values[index] = d;
    }
  }
  return NormalisedDepth(ReliefDepth(raw.width, raw.height, values), p2, p98, lowRelief: lowRelief);
}

/// Each value of [d] becomes the largest of the [window] x [window] square around it, the square cut at the edges.
/// The maximum over a rectangle is the maximum of the maxima of its rows: done as a pass along the rows, then one
/// along the columns, which gives exactly the values of the square.
ReliefDepth dilateForeground(ReliefDepth d, {int window = ReliefV1.dilationWindow}) {
  final radius = window ~/ 2;
  final width = d.width;
  final height = d.height;
  final source = d.values;
  final across = Float64List(source.length);
  for (var y = 0; y < height; y++) {
    final row = y * width;
    for (var x = 0; x < width; x++) {
      var best = source[row + x];
      final last = math.min(width - 1, x + radius);
      for (var xx = math.max(0, x - radius); xx <= last; xx++) {
        if (source[row + xx] > best) {
          best = source[row + xx];
        }
      }
      across[row + x] = best;
    }
  }
  final out = Float64List(source.length);
  for (var y = 0; y < height; y++) {
    final first = math.max(0, y - radius);
    final last = math.min(height - 1, y + radius);
    for (var x = 0; x < width; x++) {
      var best = across[y * width + x];
      for (var yy = first; yy <= last; yy++) {
        if (across[yy * width + x] > best) {
          best = across[yy * width + x];
        }
      }
      out[y * width + x] = best;
    }
  }
  return ReliefDepth(width, height, out);
}

/// The map relief-v1 draws the right eye from: normalised, then dilated
class ReliefMap {
  const ReliefMap(this.depth, this.p2, this.p98, {required this.lowRelief});

  /// d between 0 (far) and 1 (near), at the resolution of the model
  final ReliefDepth depth;
  final double p2;
  final double p98;
  final bool lowRelief;
}

/// The map of [raw], the depth of the photo alone (see [cropToPhoto])
ReliefMap reliefMapOf(ReliefDepth raw) {
  final normalised = normaliseDepth(raw);
  return ReliefMap(dilateForeground(normalised.depth), normalised.p2, normalised.p98, lowRelief: normalised.lowRelief);
}
