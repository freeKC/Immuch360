// The depth of a whole 360° panorama for relief-360-v1 (design-final 2026-10-27, section 4.4, point 1; lot P1), the
// method of 360monodepth (MIT, https://github.com/manurare/360monodepth) simplified: the panorama seen through 20
// tangent views, one per face of an icosahedron, each the input of the depth model of phase 1 (Depth Anything V2
// Small by the DepthBackend that already exists, 686 x 518); the map of each view brought to the others by a scale
// and a shift of its disparity fitted by least squares where the views overlap; then the views blended into one map
// of the sphere, each weighted by its distance to its own centre.
//
// The rules, so that a test can hold them:
//  1. A view reaches 45° up and down from its centre, and as far to each side as its square pixels give (52.9° for
//     686 x 518), its horizon level; neighbours overlap by a third of their width or more.
//  2. Its input is the panorama read in bilinear around the sphere at the centre of each of its pixels, normalised as
//     the 3D photo does (reliefInputOf: the means and deviations of ImageNet).
//  3. The model gives a relative disparity, an affine function of 1 / z, z the depth along the axis of the view. The
//     map of the view is brought between its percentiles 2 and 98 (x), and a point at the distance r seen at the
//     angle theta from the axis has z = r * cos(theta): the disparity of the sphere, 1 / r up to one scale for all,
//     is cos(theta) * (a * x + b) with a scale a and a shift b per view.
//  4. The a and b of the views make the disparities of each pair of views agree on the points both see, sampled every
//     [panoDepthAlignStep] pixels of the map, each weighted by cos(latitude) (an area of the sphere) and by the
//     weights of both views (rule 5): least squares, the scales averaging 1, with a pull of 1e-5 of the mean weight
//     of a view towards a = 1 and b = 0, so that a view that sees no relief (the sky) still has a solution (a pull of
//     1e-3 already moved the disparity of a synthetic room by 0.6 %, the shifts being weakly held by the data). A
//     view whose scale comes out not above zero (a map the model read the wrong way round, a sky or a ceiling with
//     nothing to hold on to) is left out, the one with the lowest scale first, and the others are solved again
//     without it, until every scale left is above zero. A view left out has no weight in the map.
//  5. The map: at each pixel, the disparities of the views that see it, each weighted by (1 - e)^2, e the larger of
//     the distances of the pixel to the centre of the view across and down, from 0 at the centre to 1 at the edge. A
//     pixel no view kept sees is left at 0 and counted (uncovered): the engine refuses such a map rather than make
//     up its depth.
//
// Synchronous and in double precision, like the right eye: it runs in the worker isolate of the engine.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/panorama/erp_math.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_input.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// How far a tangent view reaches up and down from its centre: tan(45°)
const panoDepthViewTanY = 1.0;

/// The step, in pixels of the map, of the points the views are aligned on
const panoDepthAlignStep = 4;

/// The pull towards a = 1 and b = 0, a share of the mean weight of a view (rule 4)
const panoDepthPull = 1e-5;

/// The tangent views of relief-360-v1, one per face of the icosahedron, each [inputWidth] x [inputHeight]: the input
/// of the depth model
List<TangentView> relief360Views({int inputWidth = depthModelInputWidth, int inputHeight = depthModelInputHeight}) => [
  for (final centre in icosahedronFaceCentres())
    TangentView(centre, width: inputWidth, height: inputHeight, tanY: panoDepthViewTanY),
];

/// The input of the depth model for [view]: [panorama], a frame of the whole sphere, read in bilinear around the
/// sphere at the centre of each pixel of the view, as [1, 3, height, width] float32 normalised with ImageNet
Float32List tangentViewInput(SbsDecoded panorama, TangentView view) {
  final width = view.width;
  final height = view.height;
  final plane = width * height;
  final nchw = Float32List(3 * plane);
  final sphere = SphereBilinear(panorama.width, panorama.height);
  final rgba = panorama.rgba;
  for (var j = 0; j < height; j++) {
    for (var i = 0; i < width; i++) {
      final direction = view.directionOf(i.toDouble(), j.toDouble());
      final (u, v) = erpPixelOf(direction.x, direction.y, direction.z, panorama.width, panorama.height);
      final at = j * width + i;
      for (var channel = 0; channel < 3; channel++) {
        final value = sphere.readRgba(rgba, channel, u, v);
        nchw[channel * plane + at] = (value / 255 - reliefInputMean[channel]) / reliefInputStd[channel];
      }
    }
  }
  return nchw;
}

/// How the map of one view was brought to the others (rule 3): the disparity of the sphere is cos(theta) * ([scale] *
/// x + [shift]), x the map of the view brought between its percentiles 2 and 98
class ViewAlignment {
  const ViewAlignment(this.scale, this.shift);

  /// A view left out of the map (rule 4)
  static const unused = ViewAlignment(0, 0);

  final double scale;
  final double shift;

  /// Whether the view has a weight in the map: its scale above zero
  bool get isUsed => scale > 0 && shift.isFinite;

  @override
  String toString() => 'ViewAlignment($scale, $shift)';
}

/// The depth of the whole sphere: [map], a relative disparity (larger is nearer) of the size asked, and how each view
/// was aligned
class PanoramaDepth {
  const PanoramaDepth(this.map, this.alignments, {required this.uncovered});

  final ReliefDepth map;
  final List<ViewAlignment> alignments;

  /// The pixels of the map no view kept saw, left at 0: none with the views of relief-360-v1 unless views were left
  /// out (rule 4)
  final int uncovered;
}

/// The map of one view, brought between its percentiles 2 and 98, read at the pixels of the view
class _ViewMap {
  _ViewMap(this.view, DepthMap raw) : width = raw.width, height = raw.height, values = Float64List(raw.values.length) {
    var finite = 0;
    for (final value in raw.values) {
      if (value.isFinite) {
        finite++;
      }
    }
    final sorted = Float64List(finite);
    var at = 0;
    for (final value in raw.values) {
      if (value.isFinite) {
        sorted[at++] = value;
      }
    }
    sorted.sort();
    final p2 = finite == 0 ? 0.0 : reliefPercentile(sorted, ReliefV1.lowPercentile);
    final p98 = finite == 0 ? 0.0 : reliefPercentile(sorted, ReliefV1.highPercentile);
    final spread = p98 - p2 > 0 ? p98 - p2 : 1.0;
    for (var i = 0; i < values.length; i++) {
      final value = raw.values[i];
      values[i] = value.isFinite ? (value - p2) / spread : double.nan;
    }
  }

  final TangentView view;
  final int width;
  final int height;
  final Float64List values;

  /// x at the pixel ([i], [j]) of the view, in bilinear, the edges repeated; NaN where the model gave no number
  double read(double i, double j) {
    final u = (i + 0.5) * width / view.width - 0.5;
    final v = (j + 0.5) * height / view.height - 0.5;
    final x0 = u.floor();
    final y0 = v.floor();
    final fx = u - x0;
    final fy = v - y0;
    final left = math.min(width - 1, math.max(0, x0));
    final right = math.min(width - 1, math.max(0, x0 + 1));
    final top = math.min(height - 1, math.max(0, y0)) * width;
    final bottom = math.min(height - 1, math.max(0, y0 + 1)) * width;
    final a = values[top + left];
    final b = values[top + right];
    final e = values[bottom + left];
    final f = values[bottom + right];
    final upper = a + (b - a) * fx;
    final lower = e + (f - e) * fx;
    return upper + (lower - upper) * fy;
  }
}

/// What a view tells of one direction: its weight, cos(theta) and x
class _Seen {
  _Seen(this.view, this.weight, this.cosine, this.x);

  final int view;
  final double weight;
  final double cosine;
  final double x;
}

/// The views that see the direction ([dx], [dy], [dz]), with what each tells of it
List<_Seen> _seenBy(List<_ViewMap> maps, double cosLimit, double dx, double dy, double dz) {
  final seen = <_Seen>[];
  for (var k = 0; k < maps.length; k++) {
    final view = maps[k].view;
    final forward = view.forward;
    final cosine = dx * forward.x + dy * forward.y + dz * forward.z;
    if (cosine <= cosLimit) {
      continue;
    }
    final (i, j) = view.pixelOf(dx, dy, dz)!;
    final weight = view.weightAt(i, j);
    if (weight <= 0) {
      continue;
    }
    final x = maps[k].read(i, j);
    if (x.isNaN) {
      continue;
    }
    seen.add(_Seen(k, weight, cosine, x));
  }
  return seen;
}

/// The cosine of the angle from the axis of [view] to its corners: nothing farther is in the view
double _cornerCosine(TangentView view) => 1 / math.sqrt(1 + view.tanX * view.tanX + view.tanY * view.tanY);

/// The maps of [views] given by the depth model ([raw], one per view, in the same order) aligned and merged into a
/// map of the sphere of [width] x [height] (see the top of this file)
PanoramaDepth mergeViewDepths(
  List<TangentView> views,
  List<DepthMap> raw, {
  required int width,
  required int height,
  int alignStep = panoDepthAlignStep,
  double pull = panoDepthPull,
}) {
  if (views.length != raw.length || views.isEmpty) {
    throw ArgumentError('${views.length} views and ${raw.length} maps');
  }
  if (width < 1 || height < 1 || alignStep < 1) {
    throw ArgumentError('A map of $width x $height aligned every $alignStep pixels');
  }
  final maps = [for (var k = 0; k < views.length; k++) _ViewMap(views[k], raw[k])];
  final cosLimit = views.map(_cornerCosine).reduce(math.min);
  final alignments = _align(maps, cosLimit, width, height, alignStep, pull);

  final values = Float64List(width * height);
  final sinLon = Float64List(width);
  final cosLon = Float64List(width);
  for (var x = 0; x < width; x++) {
    final lon = erpLongitude(x, width);
    sinLon[x] = math.sin(lon);
    cosLon[x] = math.cos(lon);
  }
  // The axes of the views side by side, read without a getter for each of the 2 million pixels of the map
  final n = views.length;
  final axes = Float64List(9 * n);
  for (var k = 0; k < n; k++) {
    final view = views[k];
    axes.setAll(9 * k, [
      view.forward.x,
      view.forward.y,
      view.forward.z,
      view.right.x,
      view.right.y,
      view.right.z,
      view.up.x,
      view.up.y,
      view.up.z,
    ]);
  }
  var uncovered = 0;
  for (var y = 0; y < height; y++) {
    final lat = erpLatitude(y, height);
    final sinLat = math.sin(lat);
    final cosLat = math.cos(lat);
    for (var x = 0; x < width; x++) {
      final dx = cosLat * sinLon[x];
      final dy = sinLat;
      final dz = cosLat * cosLon[x];
      var numerator = 0.0;
      var denominator = 0.0;
      for (var k = 0; k < n; k++) {
        final alignment = alignments[k];
        if (!alignment.isUsed) {
          continue;
        }
        final at = 9 * k;
        final cosine = dx * axes[at] + dy * axes[at + 1] + dz * axes[at + 2];
        if (cosine <= cosLimit) {
          continue;
        }
        final view = views[k];
        final a = (dx * axes[at + 3] + dy * axes[at + 4] + dz * axes[at + 5]) / cosine;
        final b = (dx * axes[at + 6] + dy * axes[at + 7] + dz * axes[at + 8]) / cosine;
        final i = (a / view.tanX + 1) * view.width / 2 - 0.5;
        final j = (1 - b / view.tanY) * view.height / 2 - 0.5;
        final weight = view.weightAt(i, j);
        if (weight <= 0) {
          continue;
        }
        final value = maps[k].read(i, j);
        if (value.isNaN) {
          continue;
        }
        numerator += weight * cosine * (alignment.scale * value + alignment.shift);
        denominator += weight;
      }
      if (denominator > 0) {
        values[y * width + x] = numerator / denominator;
      } else {
        uncovered++;
      }
    }
  }
  return PanoramaDepth(ReliefDepth(width, height, values), alignments, uncovered: uncovered);
}

/// The scale and the shift of each view (rule 4); [ViewAlignment.unused] for a view left out
List<ViewAlignment> _align(List<_ViewMap> maps, double cosLimit, int width, int height, int step, double share) {
  final n = maps.length;
  // The normal equations of each pair of views apart, so that a view left out takes its pairs with it: the 4 x 4
  // block of (a_k, b_k, a_l, b_l) at k * n + l, k < l
  final pairs = List<Float64List?>.filled(n * n, null);
  for (var y = step ~/ 2; y < height; y += step) {
    final lat = erpLatitude(y, height);
    final area = math.cos(lat);
    for (var x = step ~/ 2; x < width; x += step) {
      final direction = erpDirection(x, y, width, height);
      final seen = _seenBy(maps, cosLimit, direction.x, direction.y, direction.z);
      for (var p = 0; p < seen.length; p++) {
        for (var q = p + 1; q < seen.length; q++) {
          final first = seen[p];
          final second = seen[q];
          final weight = area * first.weight * second.weight;
          // The difference of the two disparities, a linear form of (a_k, b_k, a_l, b_l)
          final row = [first.cosine * first.x, first.cosine, -second.cosine * second.x, -second.cosine];
          final block = pairs[first.view * n + second.view] ??= Float64List(16);
          for (var r = 0; r < 4; r++) {
            for (var c = 0; c < 4; c++) {
              block[4 * r + c] += weight * row[r] * row[c];
            }
          }
        }
      }
    }
  }

  final used = List<bool>.filled(n, true);
  while (true) {
    final active = [
      for (var k = 0; k < n; k++)
        if (used[k]) k,
    ];
    if (active.isEmpty) {
      return List.filled(n, ViewAlignment.unused);
    }
    final solution = _solveViews(pairs, n, active, share);
    if (solution == null) {
      return [for (var k = 0; k < n; k++) used[k] ? const ViewAlignment(1, 0) : ViewAlignment.unused];
    }
    final alignments = List.filled(n, ViewAlignment.unused);
    int? worst;
    for (final (index, k) in active.indexed) {
      final alignment = ViewAlignment(solution[2 * index], solution[2 * index + 1]);
      alignments[k] = alignment;
      if (!alignment.isUsed && (worst == null || !(alignment.scale >= alignments[worst].scale))) {
        worst = k;
      }
    }
    if (worst == null) {
      return alignments;
    }
    used[worst] = false;
  }
}

/// The scales and shifts of the views [active] (a_k, b_k in their order) from the blocks of their [pairs] (see
/// _align), the scales averaging 1, with the pull of rule 4; null when the system is singular
List<double>? _solveViews(List<Float64List?> pairs, int n, List<int> active, double share) {
  final m = active.length;
  final size = 2 * m;
  final normal = List.generate(size, (_) => Float64List(size));
  for (var p = 0; p < m; p++) {
    for (var q = p + 1; q < m; q++) {
      final block = pairs[active[p] * n + active[q]];
      if (block == null) {
        continue;
      }
      final index = [2 * p, 2 * p + 1, 2 * q, 2 * q + 1];
      for (var r = 0; r < 4; r++) {
        for (var c = 0; c < 4; c++) {
          normal[index[r]][index[c]] += block[4 * r + c];
        }
      }
    }
  }
  var trace = 0.0;
  for (var i = 0; i < size; i++) {
    trace += normal[i][i];
  }
  final pull = trace > 0 ? share * trace / size : 1e-9;

  // [normal + pull, the sum of the scales; that sum, 0] [a, b...; mu] = [pull for each a, 0 for each b; m]
  final system = List.generate(size + 1, (_) => Float64List(size + 2));
  for (var i = 0; i < size; i++) {
    for (var j = 0; j < size; j++) {
      system[i][j] = normal[i][j];
    }
    system[i][i] += pull;
    if (i.isEven) {
      system[i][size] = 1;
      system[size][i] = 1;
      system[i][size + 1] = pull;
    }
  }
  system[size][size + 1] = m.toDouble();
  return _solve(system);
}

/// The solution of the augmented system [rows] (each row its coefficients then its right side), by Gaussian
/// elimination with partial pivoting; null when it is singular
List<double>? _solve(List<Float64List> rows) {
  final size = rows.length;
  for (var column = 0; column < size; column++) {
    var pivot = column;
    for (var row = column + 1; row < size; row++) {
      if (rows[row][column].abs() > rows[pivot][column].abs()) {
        pivot = row;
      }
    }
    if (rows[pivot][column].abs() < 1e-300) {
      return null;
    }
    final swap = rows[pivot];
    rows[pivot] = rows[column];
    rows[column] = swap;
    final lead = rows[column];
    for (var row = column + 1; row < size; row++) {
      final factor = rows[row][column] / lead[column];
      if (factor == 0) {
        continue;
      }
      final target = rows[row];
      for (var c = column; c <= size; c++) {
        target[c] -= factor * lead[c];
      }
    }
  }
  final solution = List<double>.filled(size, 0);
  for (var row = size - 1; row >= 0; row--) {
    var sum = rows[row][size];
    for (var c = row + 1; c < size; c++) {
      sum -= rows[row][c] * solution[c];
    }
    solution[row] = sum / rows[row][row];
  }
  return solution.every((value) => value.isFinite) ? solution : null;
}
