// The two layers of a scene cut at the breaks of its depth (design-final 2026-10-27, section 2.3, steps 6, 8 and 9;
// lot S1), as the header of .github/desktop/ai/make_scene_golden.py writes them (its steps 3, 4, 7 and 8) and its
// fixture scene_golden_v1.json holds, every number within 1e-9 and every mask exactly:
//  1. the disparity q = 1 / z normalised as relief-v1 does (percentiles 2 and 98 by nearest rank), with lowRelief;
//  2. a break between two neighbours of the map, side by side or one above the other, when their normalised disparities
//     differ by more than 0.04 (the rule of relief-v1): the near one has the larger disparity;
//  3. the band each break hides on its near side, the values nearer than the middle of its jump within
//     w = clamp(floor(160 * jump + 0.5), 8, 48) of its near value, and the mask of the filling at 2 w, so that what
//     LaMa paints continues the background and never takes the near layer in;
//  4. the depth behind each value of the band: that of the nearest far value of a break (the first in the order of the
//     rows on a tie), then its mean over the band within a window of 5 x 5.
// Then the regions LaMa fills (the method of the measure M2): the connected parts of the mask, their boxes widened by
// 64 values and merged when they touch, cut in tiles of 512 at most; each tile is filled in a window of 512 x 512 of
// the map around it, every hole of the window masked, and only the holes of the tile are kept from it.
//
// The maps are rows of W x H values, the first row on top. The golden fixture spells out the rules on maps of a few
// hundred values; the same code runs on the maps of 1024 values of a photo, so the bands go through each break once
// and the nearest far value is looked for in buckets instead of over every value.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/scene/comfort_scale.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The disparity normalised as relief-v1 does it, and whether the relief is low
class NormalisedDisparity {
  const NormalisedDisparity({required this.values, required this.lowRelief});

  final Float64List values;
  final bool lowRelief;
}

/// [disparity] normalised between its percentiles 2 and 98 (step 1 of relief-v1): 0.5 everywhere when they are equal;
/// lowRelief when their spread is 0 or under 0.1 times the percentile 98
NormalisedDisparity normaliseDisparity(Float64List disparity) {
  final sorted = sortedCopy(disparity);
  final p2 = nearestRank(sorted, SceneV1.lowPercentile);
  final p98 = nearestRank(sorted, SceneV1.highPercentile);
  final spread = p98 - p2;
  final lowRelief = spread <= 0 || spread < ReliefV1.lowReliefRatio * p98.abs();
  final out = Float64List(disparity.length);
  for (var i = 0; i < disparity.length; i++) {
    out[i] = spread <= 0 ? 0.5 : math.min(1.0, math.max(0.0, (disparity[i] - p2) / spread));
  }
  return NormalisedDisparity(values: out, lowRelief: lowRelief);
}

/// The breaks of a map of normalised disparity: for each, its near value and its far value (as indices of the map) and
/// its jump, along the rows then down the columns, in the order of the map
class SceneBreaks {
  SceneBreaks(this.near, this.far, this.jump);

  final Int32List near;
  final Int32List far;
  final Float64List jump;

  int get length => near.length;

  /// The breaks of [d], [width] values wide
  factory SceneBreaks.of(Float64List d, int width, int height) {
    final near = <int>[];
    final far = <int>[];
    final jumps = <double>[];
    void add(int a, int b) {
      final jump = (d[a] - d[b]).abs();
      if (jump > SceneV1.breakThreshold) {
        final aNear = d[a] > d[b];
        near.add(aNear ? a : b);
        far.add(aNear ? b : a);
        jumps.add(jump);
      }
    }

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final at = y * width + x;
        if (x + 1 < width) {
          add(at, at + 1);
        }
        if (y + 1 < height) {
          add(at, at + width);
        }
      }
    }
    return SceneBreaks(Int32List.fromList(near), Int32List.fromList(far), Float64List.fromList(jumps));
  }
}

/// The width of the band of a break of [jump], in values of the map
int bandWidthOf(double jump) => (SceneV1.bandFactor * jump + 0.5).floor().clamp(SceneV1.bandMin, SceneV1.bandMax);

/// The values on the near side of a break, nearer than the middle of its jump, within [factor] times its band width of
/// its near value: 1 in the mask, 0 elsewhere. [factor] 1 gives the band, SceneV1.inpaintMaskFactor the filling.
Uint8List bandMaskOf(Float64List d, int width, int height, SceneBreaks breaks, int factor) {
  final mask = Uint8List(width * height);
  for (var b = 0; b < breaks.length; b++) {
    final n = breaks.near[b];
    final nx = n % width;
    final ny = n ~/ width;
    final reach = factor * bandWidthOf(breaks.jump[b]);
    final middle = (d[n] + d[breaks.far[b]]) / 2;
    final reach2 = reach * reach;
    for (var y = math.max(0, ny - reach); y <= math.min(height - 1, ny + reach); y++) {
      final dy = y - ny;
      final row = y * width;
      for (var x = math.max(0, nx - reach); x <= math.min(width - 1, nx + reach); x++) {
        final dx = x - nx;
        if (dx * dx + dy * dy <= reach2 && d[row + x] > middle) {
          mask[row + x] = 1;
        }
      }
    }
  }
  return mask;
}

/// Points of a map in square buckets, to find the nearest one to a value: the smallest squared distance, the first in
/// the order of the rows then of the columns on a tie
class NearestPoints {
  NearestPoints(Iterable<int> points, this.width, this.height, {this.bucket = 16})
    : _columns = (width + bucket - 1) ~/ bucket,
      _rows = (height + bucket - 1) ~/ bucket {
    final lists = List<List<int>>.generate(_columns * _rows, (_) => <int>[]);
    for (final point in points) {
      lists[(point ~/ width) ~/ bucket * _columns + (point % width) ~/ bucket].add(point);
    }
    _buckets = [for (final list in lists) Int32List.fromList(list)];
    _empty = lists.every((list) => list.isEmpty);
  }

  final int width;
  final int height;
  final int bucket;
  final int _columns;
  final int _rows;
  late final List<Int32List> _buckets;
  late final bool _empty;

  bool get isEmpty => _empty;

  /// The point nearest to (x, y) (any real coordinates), -1 when there are none
  int nearestTo(double x, double y) {
    if (_empty) {
      return -1;
    }
    final bx = (x / bucket).floor().clamp(0, _columns - 1);
    final by = (y / bucket).floor().clamp(0, _rows - 1);
    var best = -1;
    var bestDistance = double.infinity;
    for (var ring = 0; ; ring++) {
      // Every point of the ring is at least this far: stop once the best is nearer than that (a tie may still come)
      final reach = (ring - 1) * bucket.toDouble();
      if (best >= 0 && ring > 0 && reach > 0 && reach * reach > bestDistance) {
        return best;
      }
      if (ring > _columns + _rows) {
        return best;
      }
      for (var row = by - ring; row <= by + ring; row++) {
        if (row < 0 || row >= _rows) {
          continue;
        }
        final edge = row == by - ring || row == by + ring;
        for (var column = bx - ring; column <= bx + ring; column += edge ? 1 : 2 * ring) {
          if (column >= 0 && column < _columns) {
            for (final point in _buckets[row * _columns + column]) {
              final dx = point % width - x;
              final dy = point ~/ width - y;
              final distance = dx * dx + dy * dy;
              if (distance < bestDistance || (distance == bestDistance && point < best)) {
                best = point;
                bestDistance = distance;
              }
            }
          }
          if (ring == 0) {
            break;
          }
        }
      }
    }
  }
}

/// The depth behind each value of [band] ([z] elsewhere stays out: NaN): the depth of the nearest far value of a break,
/// then its mean over the values of the band within a window of SceneV1.bandSmoothing
Float64List depthBehindOf(Float64List z, Uint8List band, SceneBreaks breaks, int width, int height) {
  final fars = NearestPoints(breaks.far, width, height);
  final raw = Float64List(width * height)..fillRange(0, width * height, double.nan);
  for (var i = 0; i < band.length; i++) {
    if (band[i] == 1) {
      raw[i] = z[fars.nearestTo((i % width).toDouble(), (i ~/ width).toDouble())];
    }
  }
  const radius = SceneV1.bandSmoothing ~/ 2;
  final out = Float64List(width * height)..fillRange(0, width * height, double.nan);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (band[y * width + x] != 1) {
        continue;
      }
      var total = 0.0;
      var count = 0;
      for (var yy = math.max(0, y - radius); yy <= math.min(height - 1, y + radius); yy++) {
        for (var xx = math.max(0, x - radius); xx <= math.min(width - 1, x + radius); xx++) {
          if (band[yy * width + xx] == 1) {
            total += raw[yy * width + xx];
            count++;
          }
        }
      }
      out[y * width + x] = total / count;
    }
  }
  return out;
}

/// A box of the map, rows [top] to [bottom] and columns [left] to [right], the ends excluded
class MapBox {
  const MapBox(this.top, this.bottom, this.left, this.right);

  final int top;
  final int bottom;
  final int left;
  final int right;

  int get width => right - left;
  int get height => bottom - top;

  bool contains(int x, int y) => x >= left && x < right && y >= top && y < bottom;

  @override
  bool operator ==(Object other) =>
      other is MapBox && other.top == top && other.bottom == bottom && other.left == left && other.right == right;

  @override
  int get hashCode => Object.hash(top, bottom, left, right);

  @override
  String toString() => 'MapBox($top..$bottom, $left..$right)';
}

/// One region LaMa fills: the holes of [tile] are taken from the filling of [window]
class InpaintTile {
  const InpaintTile(this.tile, this.window);

  final MapBox tile;
  final MapBox window;

  @override
  String toString() => 'InpaintTile($tile in $window)';
}

/// The regions that fill the holes of [mask] (1 for a hole) of a map of [width] x [height]: see the top of this file
List<InpaintTile> inpaintTilesOf(Uint8List mask, int width, int height) {
  const margin = SceneV1.inpaintMargin;
  const side = SceneV1.inpaintRegionMax;
  // The connected parts (four neighbours), in the order of their first value
  final seen = Uint8List(width * height);
  final boxes = <List<int>>[];
  final stack = <int>[];
  for (var start = 0; start < mask.length; start++) {
    if (mask[start] != 1 || seen[start] == 1) {
      continue;
    }
    var top = height;
    var bottom = 0;
    var left = width;
    var right = 0;
    seen[start] = 1;
    stack.add(start);
    while (stack.isNotEmpty) {
      final at = stack.removeLast();
      final x = at % width;
      final y = at ~/ width;
      top = math.min(top, y);
      bottom = math.max(bottom, y + 1);
      left = math.min(left, x);
      right = math.max(right, x + 1);
      for (final next in [
        if (x > 0) at - 1,
        if (x + 1 < width) at + 1,
        if (y > 0) at - width,
        if (y + 1 < height) at + width,
      ]) {
        if (mask[next] == 1 && seen[next] == 0) {
          seen[next] = 1;
          stack.add(next);
        }
      }
    }
    boxes.add([
      math.max(0, top - margin),
      math.min(height, bottom + margin),
      math.max(0, left - margin),
      math.min(width, right + margin),
    ]);
  }
  // Merged while two touch
  var merged = true;
  while (merged) {
    merged = false;
    for (var i = 0; i < boxes.length && !merged; i++) {
      for (var j = i + 1; j < boxes.length; j++) {
        final a = boxes[i];
        final b = boxes[j];
        if (a[0] <= b[1] && b[0] <= a[1] && a[2] <= b[3] && b[2] <= a[3]) {
          boxes[i] = [math.min(a[0], b[0]), math.max(a[1], b[1]), math.min(a[2], b[2]), math.max(a[3], b[3])];
          boxes.removeAt(j);
          merged = true;
          break;
        }
      }
    }
  }
  bool hasHole(MapBox box) {
    for (var y = box.top; y < box.bottom; y++) {
      for (var x = box.left; x < box.right; x++) {
        if (mask[y * width + x] == 1) {
          return true;
        }
      }
    }
    return false;
  }

  final tiles = <InpaintTile>[];
  for (final [top, bottom, left, right] in boxes) {
    final rows = (bottom - top + side - 1) ~/ side;
    final columns = (right - left + side - 1) ~/ side;
    for (var ty = 0; ty < rows; ty++) {
      for (var tx = 0; tx < columns; tx++) {
        final tile = MapBox(
          top + (bottom - top) * ty ~/ rows,
          top + (bottom - top) * (ty + 1) ~/ rows,
          left + (right - left) * tx ~/ columns,
          left + (right - left) * (tx + 1) ~/ columns,
        );
        if (!hasHole(tile)) {
          continue;
        }
        final cy = (tile.top + tile.bottom) ~/ 2;
        final cx = (tile.left + tile.right) ~/ 2;
        final wy = math.min(math.max(0, cy - side ~/ 2), math.max(0, height - side));
        final wx = math.min(math.max(0, cx - side ~/ 2), math.max(0, width - side));
        tiles.add(InpaintTile(tile, MapBox(wy, math.min(height, wy + side), wx, math.min(width, wx + side))));
      }
    }
  }
  return tiles;
}
