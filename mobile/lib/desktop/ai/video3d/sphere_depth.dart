// The depth of a 360° video, frame after frame (lot ai-360-3d-51, report store/m2/release-51/ai-360-3d-2026-11-22.md):
// the equirectangular frame seen through the six faces of a cube, each face a square pinhole view a little wider than
// the cube (half field tan 1.25, 102.7° across, 12.7° shared with each neighbour), each face a video of its own for
// Video Depth Anything Small (one window loop per face, vda_window_loop.dart, the cuts decided once for the whole
// frame); the maps of the faces brought to each other and merged into one map of the sphere by the rules of the 360°
// photos (pano_depth.dart): a disparity along the ray, cos(theta) * (a * x + b), x the map of the face between its
// percentiles, a scale and a shift per face by least squares where the faces overlap, each face weighted by (1 - e)^2
// towards its edge, e the larger of its distances across and down from its centre.
//
// Why the cube and not the 20 faces of the icosahedron of the photos: the depth of a video costs a window of 32 frames
// of the model per face, so the views are the price of the job. Six faces of 392 x 392 are 3.4 times the pixels of the
// flat video's 700 x 392; twenty would be 11 times. The cube still gives what the sphere needs: the poles are the
// centres of the top and bottom faces (the model sees the zenith and the nadir upright, never the stretched rows of the
// frame), the seam of the frame (longitude 180°) is the middle of the back face (no seam in the depth), and the
// weights fall to zero at the edge of each face where the next face is near its centre, so the map is continuous
// across the edges of the cube.
//
// Over time: each face keeps the scale and shift of its windows (the window loop) and its own smoothed percentiles;
// the scale and shift found for each face at each frame are smoothed again, decay 0.9 a frame like the percentiles,
// and so are the percentiles of the merged map, both reset at each cut. The percentiles of the map are taken on an
// equal area sample of the sphere (a row near a pole counts its cos(latitude) share), not on the rows of the frame.
//
// Pure Dart, synchronous, in double precision for the maps: the worker isolate of the job runs it.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/panorama/erp_math.dart';
import 'package:immich_mobile/desktop/ai/panorama/pano_depth.dart' show ViewAlignment, alignmentsFromPairs;
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart' show ReliefDepth;
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart' show Relief360V1, ReliefV1;

/// The half field of a face: tan 1.25, 102.7° across, so that two neighbours share 12.7° (the cube alone is 90°)
const sphereFaceTan = 1.25;

/// The faces of the cube
const sphereViewCount = 6;

/// The pull of the alignment towards a = 1 and b = 0, as the photos (panoDepthPull)
const sphereAlignPull = 1e-5;

/// The points the faces are aligned on: one every this many pixels of a map 1568 wide (faces of 392), as many for any
/// size (every pixel of a small map)
const sphereAlignStep = 8;
const _alignMapWidth = 1568;

/// How the scale and the shift of a face, and the percentiles of the map, are smoothed over the frames
const sphereSmoothingDecay = 0.9;

/// The axes of the six faces, in the frame of erp_math (x right, y up, z ahead): ahead, right, behind, left, up, down
const sphereFaceAxes = [
  SphereVector(0, 0, 1),
  SphereVector(1, 0, 0),
  SphereVector(0, 0, -1),
  SphereVector(-1, 0, 0),
  SphereVector(0, 1, 0),
  SphereVector(0, -1, 0),
];

/// The faces of a frame for a model input of [side] x [side]
List<TangentView> sphereVideoViews(int side) => [
  for (final axis in sphereFaceAxes) TangentView(axis, width: side, height: side, tanY: sphereFaceTan),
];

/// The map of the sphere for faces of [side] pixels: four faces across the equator, 2:1
({int width, int height}) sphereMapSize(int side) => (width: 4 * side, height: 2 * side);

/// [rgb] ([width] x [height], 3 bytes a pixel) brought to [toWidth] x [toHeight] by the average of the area each pixel
/// covers, each axis on its own, every channel rounded half up; [rgb] itself at the same size
Uint8List rgbAreaResample(Uint8List rgb, int width, int height, int toWidth, int toHeight) {
  if (width < 1 || height < 1 || toWidth < 1 || toHeight < 1 || rgb.length < width * height * 3) {
    throw ArgumentError('A frame of $width x $height to $toWidth x $toHeight');
  }
  if (width == toWidth && height == toHeight) {
    return rgb;
  }
  final across = _resampleAxis(rgb, lines: height, from: width, to: toWidth, alongRows: true);
  return _resampleAxis(across, lines: toWidth, from: height, to: toHeight, alongRows: false);
}

Uint8List _resampleAxis(
  Uint8List rgb, {
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
  final out = Uint8List(3 * to * lines);
  final half = from ~/ 2;
  final inWidth = alongRows ? from : lines;
  final outWidth = alongRows ? to : lines;
  for (var line = 0; line < lines; line++) {
    for (var i = 0; i < to; i++) {
      var r = 0;
      var g = 0;
      var b = 0;
      for (var k = first[i]; k < first[i + 1]; k++) {
        final at = alongRows ? 3 * (line * inWidth + sources[k]) : 3 * (sources[k] * inWidth + line);
        final w = weights[k];
        r += w * rgb[at];
        g += w * rgb[at + 1];
        b += w * rgb[at + 2];
      }
      final at = alongRows ? 3 * (line * outWidth + i) : 3 * (i * outWidth + line);
      out[at] = (r + half) ~/ from;
      out[at + 1] = (g + half) ~/ from;
      out[at + 2] = (b + half) ~/ from;
    }
  }
  return out;
}

/// Makes the RGB pictures of the faces from an equirectangular RGB frame of [eyeWidth] x [eyeHeight]: the frame first
/// brought by area to about the sharpness of a face (four faces across), then read in bilinear around the sphere (the
/// columns wrapped across the seam, the rows stopped at the poles) at the centre of each pixel of each face
class SphereViewSampler {
  SphereViewSampler({required this.eyeWidth, required this.eyeHeight, required this.views})
    : sourceWidth = math.min(eyeWidth, 4 * views.first.width),
      sourceHeight = math.min(eyeHeight, 2 * views.first.width) {
    if (views.isEmpty || eyeWidth < 2 || eyeHeight < 1) {
      throw ArgumentError('${views.length} views of a frame of $eyeWidth x $eyeHeight');
    }
    final sphere = SphereBilinear(sourceWidth, sourceHeight);
    for (final view in views) {
      final count = view.width * view.height;
      final corners = Int32List(4 * count);
      final fractions = Float32List(2 * count);
      for (var j = 0; j < view.height; j++) {
        for (var i = 0; i < view.width; i++) {
          final direction = view.directionOf(i.toDouble(), j.toDouble());
          final (u, v) = erpPixelOf(direction.x, direction.y, direction.z, sourceWidth, sourceHeight);
          final (left, right, fx) = sphere.columns(u);
          final (top, bottom, fy) = sphere.rows(v);
          final at = j * view.width + i;
          corners[4 * at] = 3 * (top * sourceWidth + left);
          corners[4 * at + 1] = 3 * (top * sourceWidth + right);
          corners[4 * at + 2] = 3 * (bottom * sourceWidth + left);
          corners[4 * at + 3] = 3 * (bottom * sourceWidth + right);
          fractions[2 * at] = fx;
          fractions[2 * at + 1] = fy;
        }
      }
      _corners.add(corners);
      _fractions.add(fractions);
    }
  }

  final int eyeWidth;
  final int eyeHeight;
  final List<TangentView> views;

  /// The size the frame is read at
  final int sourceWidth;
  final int sourceHeight;
  final _corners = <Int32List>[];
  final _fractions = <Float32List>[];

  /// The faces of [rgb], one RGB picture of the size of its view each, in the order of [views]
  List<Uint8List> sample(Uint8List rgb) {
    final source = rgbAreaResample(rgb, eyeWidth, eyeHeight, sourceWidth, sourceHeight);
    return [for (var k = 0; k < views.length; k++) _sampleView(source, k)];
  }

  Uint8List _sampleView(Uint8List source, int k) {
    final corners = _corners[k];
    final fractions = _fractions[k];
    final count = views[k].width * views[k].height;
    final out = Uint8List(3 * count);
    for (var at = 0; at < count; at++) {
      final a = corners[4 * at];
      final b = corners[4 * at + 1];
      final e = corners[4 * at + 2];
      final f = corners[4 * at + 3];
      final fx = fractions[2 * at];
      final fy = fractions[2 * at + 1];
      for (var c = 0; c < 3; c++) {
        final upper = source[a + c] + (source[b + c] - source[a + c]) * fx;
        final lower = source[e + c] + (source[f + c] - source[e + c]) * fx;
        final value = upper + (lower - upper) * fy;
        out[3 * at + c] = math.min(255, math.max(0, (value + 0.5).floor()));
      }
    }
    return out;
  }
}

/// What the faces tell of the directions of a list (the pixels of the map, or the points of the alignment): for each
/// direction its first entry in [start], then for each face that sees it, its index, where (its pixel packed as
/// x0 + y0 * 65536, the shares fx and fy of the next ones), its weight and cos(theta)
class _Seen {
  _Seen(this.count);

  final int count;
  final start = <int>[];
  final view = <int>[];
  final corner = <int>[];
  final fx = <double>[];
  final fy = <double>[];
  final weight = <double>[];
  final cosine = <double>[];

  late final Int32List startList;
  late final Int8List viewList;
  late final Int32List cornerList;
  late final Float32List fxList;
  late final Float32List fyList;
  late final Float32List weightList;
  late final Float32List cosineList;

  void seal() {
    start.add(view.length);
    startList = Int32List.fromList(start);
    viewList = Int8List.fromList(view);
    cornerList = Int32List.fromList(corner);
    fxList = Float32List.fromList(fx);
    fyList = Float32List.fromList(fy);
    weightList = Float32List.fromList(weight);
    cosineList = Float32List.fromList(cosine);
  }
}

/// The faces seen from each direction ([dx], [dy], [dz]) of [directions], added to [seen]
void _addSeen(_Seen seen, List<TangentView> views, double dx, double dy, double dz) {
  seen.start.add(seen.view.length);
  for (var k = 0; k < views.length; k++) {
    final view = views[k];
    final cosine = dx * view.forward.x + dy * view.forward.y + dz * view.forward.z;
    if (cosine <= 0) {
      continue;
    }
    final (i, j) = view.pixelOf(dx, dy, dz)!;
    final weight = view.weightAt(i, j);
    if (weight <= 0) {
      continue;
    }
    // The edges repeated, as the map of a view is read (pano_depth.dart, _ViewMap.read)
    final u = math.min(view.width - 1.0, math.max(0.0, i));
    final v = math.min(view.height - 1.0, math.max(0.0, j));
    final x0 = u.floor();
    final y0 = v.floor();
    seen.view.add(k);
    seen.corner.add(x0 + y0 * 65536);
    seen.fx.add(u - x0);
    seen.fy.add(v - y0);
    seen.weight.add(weight);
    seen.cosine.add(cosine);
  }
}

/// The depth of the sphere from the maps of its faces (see the top of this file): [align] then [merge], with the
/// smoothing of [smooth] between them
class SphereDepthMerger {
  SphereDepthMerger({required this.views, required this.mapWidth, required this.mapHeight, int? step})
    : side = views.first.width,
      alignStep = step ?? math.max(1, sphereAlignStep * mapWidth ~/ _alignMapWidth) {
    if (views.isEmpty || views.length > 127 || mapWidth < 2 || mapHeight < 1 || alignStep < 1) {
      throw ArgumentError('${views.length} views for a map of $mapWidth x $mapHeight');
    }
    for (final view in views) {
      if (view.width != side || view.height != side) {
        throw ArgumentError('Faces of ${view.width} x ${view.height}, $side x $side expected');
      }
    }
    _map = _Seen(mapWidth * mapHeight);
    for (var y = 0; y < mapHeight; y++) {
      for (var x = 0; x < mapWidth; x++) {
        final direction = erpDirection(x, y, mapWidth, mapHeight);
        _addSeen(_map, views, direction.x, direction.y, direction.z);
      }
    }
    _map.seal();
    final points = <int>[];
    final areas = <double>[];
    final aligned = _Seen(0);
    for (var y = alignStep ~/ 2; y < mapHeight; y += alignStep) {
      final area = math.cos(erpLatitude(y, mapHeight));
      // About one point per alignStep of the sphere's own length along the row: fewer near the poles
      final step = math.max(alignStep, (alignStep / math.max(area, 1e-6)).round());
      for (var x = step ~/ 2; x < mapWidth; x += step) {
        final direction = erpDirection(x, y, mapWidth, mapHeight);
        final before = aligned.view.length;
        _addSeen(aligned, views, direction.x, direction.y, direction.z);
        if (aligned.view.length - before < 2) {
          // Seen by one face only: nothing to align on; dropped
          aligned.view.length = before;
          aligned.corner.length = before;
          aligned.fx.length = before;
          aligned.fy.length = before;
          aligned.weight.length = before;
          aligned.cosine.length = before;
          aligned.start.removeLast();
          continue;
        }
        points.add(y * mapWidth + x);
        areas.add(area * step / alignStep);
      }
    }
    aligned.seal();
    _aligned = aligned;
    _areas = Float64List.fromList(areas);
    var uncovered = 0;
    for (var p = 0; p < mapWidth * mapHeight; p++) {
      if (_map.startList[p + 1] == _map.startList[p]) {
        uncovered++;
      }
    }
    this.uncovered = uncovered;
  }

  final List<TangentView> views;
  final int mapWidth;
  final int mapHeight;
  final int alignStep;
  final int side;
  late final _Seen _map;
  late final _Seen _aligned;
  late final Float64List _areas;

  /// The pixels of the map no face sees: none for the cube of [sphereVideoViews]
  late final int uncovered;

  /// The points the faces are aligned on
  int get alignmentPoints => _areas.length;

  double _read(Float64List map, int corner, double fx, double fy) {
    final x0 = corner & 0xffff;
    final y0 = corner >> 16;
    final x1 = math.min(side - 1, x0 + 1);
    final y1 = math.min(side - 1, y0 + 1);
    final a = map[y0 * side + x0];
    final b = map[y0 * side + x1];
    final e = map[y1 * side + x0];
    final f = map[y1 * side + x1];
    final upper = a + (b - a) * fx;
    final lower = e + (f - e) * fx;
    return upper + (lower - upper) * fy;
  }

  /// The scale and the shift of each face for its map [x] (side x side, between its percentiles), so that the faces
  /// agree where they overlap: the normal equations of each pair at the points of the alignment, solved as the photos
  /// solve theirs (alignmentsFromPairs)
  List<ViewAlignment> align(List<Float64List> x, {double pull = sphereAlignPull}) {
    _checkMaps(x);
    final n = views.length;
    final pairs = List<Float64List?>.filled(n * n, null);
    final seen = _aligned;
    final values = Float64List(n);
    final row = Float64List(4);
    for (var p = 0; p < _areas.length; p++) {
      final from = seen.startList[p];
      final to = seen.startList[p + 1];
      for (var s = from; s < to; s++) {
        values[s - from] = _read(x[seen.viewList[s]], seen.cornerList[s], seen.fxList[s], seen.fyList[s]);
      }
      for (var s = from; s < to; s++) {
        for (var t = s + 1; t < to; t++) {
          final k = seen.viewList[s];
          final l = seen.viewList[t];
          final first = k < l ? s : t;
          final second = k < l ? t : s;
          final weight = _areas[p] * seen.weightList[s] * seen.weightList[t];
          row[0] = seen.cosineList[first] * values[first - from];
          row[1] = seen.cosineList[first];
          row[2] = -seen.cosineList[second] * values[second - from];
          row[3] = -seen.cosineList[second];
          final block = pairs[math.min(k, l) * n + math.max(k, l)] ??= Float64List(16);
          for (var r = 0; r < 4; r++) {
            for (var c = 0; c < 4; c++) {
              block[4 * r + c] += weight * row[r] * row[c];
            }
          }
        }
      }
    }
    return alignmentsFromPairs(pairs, n, pull);
  }

  /// The disparity of the sphere, larger is nearer: at each pixel of the map, the faces that see it, each
  /// cos(theta) * (a * x + b) weighted by its weight; 0 where no face kept sees it
  Float64List merge(List<Float64List> x, List<ViewAlignment> alignments) {
    _checkMaps(x);
    if (alignments.length != views.length) {
      throw ArgumentError('${alignments.length} alignments for ${views.length} faces');
    }
    final out = Float64List(mapWidth * mapHeight);
    final seen = _map;
    for (var p = 0; p < out.length; p++) {
      var numerator = 0.0;
      var denominator = 0.0;
      for (var s = seen.startList[p]; s < seen.startList[p + 1]; s++) {
        final k = seen.viewList[s];
        final alignment = alignments[k];
        if (!alignment.isUsed) {
          continue;
        }
        final value = _read(x[k], seen.cornerList[s], seen.fxList[s], seen.fyList[s]);
        final weight = seen.weightList[s];
        numerator += weight * seen.cosineList[s] * (alignment.scale * value + alignment.shift);
        denominator += weight;
      }
      if (denominator > 0) {
        out[p] = numerator / denominator;
      }
    }
    return out;
  }

  void _checkMaps(List<Float64List> x) {
    if (x.length != views.length) {
      throw ArgumentError('${x.length} maps for ${views.length} faces');
    }
    for (final map in x) {
      if (map.length != side * side) {
        throw ArgumentError('A map of ${map.length} values for a face of $side x $side');
      }
    }
  }
}

/// The map of a face brought between its percentiles [lo] and [hi] (the smoothed ones of its window loop)
Float64List sphereFaceNormalised(Float64List map, double lo, double hi) {
  final spread = hi - lo > 0 ? hi - lo : 1.0;
  final out = Float64List(map.length);
  for (var i = 0; i < map.length; i++) {
    out[i] = (map[i] - lo) / spread;
  }
  return out;
}

/// [solved] smoothed towards [previous] by [decay]: a face aligned in both takes decay * previous + (1 - decay) *
/// solved; a face left out now keeps its previous alignment, one new takes its own; no previous gives [solved]
List<ViewAlignment> smoothAlignments(
  List<ViewAlignment>? previous,
  List<ViewAlignment> solved, {
  double decay = sphereSmoothingDecay,
}) {
  if (previous == null) {
    return solved;
  }
  return [
    for (var k = 0; k < solved.length; k++)
      switch ((previous[k].isUsed, solved[k].isUsed)) {
        (true, true) => ViewAlignment(
          decay * previous[k].scale + (1 - decay) * solved[k].scale,
          decay * previous[k].shift + (1 - decay) * solved[k].shift,
        ),
        (true, false) => previous[k],
        _ => solved[k],
      },
  ];
}

/// The percentiles 2 and 98 of the map [values] of [width] x [height], on an equal area sample of the sphere: every
/// [step]-th row, and in each row about one pixel per [step] pixels of the length of that row on the sphere
(double, double) spherePercentiles(Float64List values, int width, int height, {int step = 4}) {
  final sample = <double>[];
  for (var y = step ~/ 2; y < height; y += step) {
    final area = math.cos(erpLatitude(y, height));
    final along = math.max(step, (step / math.max(area, 1e-6)).round());
    for (var x = along ~/ 2; x < width; x += along) {
      sample.add(values[y * width + x]);
    }
  }
  if (sample.isEmpty) {
    sample.addAll(values);
  }
  sample.sort();
  int rank(int percent) => math.max(1, (percent * sample.length + 99) ~/ 100) - 1;
  return (sample[rank(2)], sample[rank(98)]);
}

/// The map d of relief-360 (0 far, 1 near): [values] between [lo] and [hi], clipped
ReliefDepth sphereRelief(Float64List values, int width, int height, double lo, double hi) {
  final spread = hi - lo > 1e-12 ? hi - lo : 1.0;
  final out = Float64List(values.length);
  for (var i = 0; i < values.length; i++) {
    final d = (values[i] - lo) / spread;
    out[i] = d < 0 ? 0 : (d > 1 ? 1 : d);
  }
  return ReliefDepth(width, height, out);
}

/// The largest shift of the nearest point at the equator, in degrees, for the relief strength whose parallax is
/// [parallax] (ReliefStrength): the 1° of the 3D versions of the 360° photos at Normal (Relief360V1), scaled as the
/// strengths of the 3D videos are, so 0.75° Subtle, 1° Normal and 1.5° Strong. For an eye distance of 6.4 cm, 1°
/// is the disparity of a point about 3.7 m away against the far background.
double sphereShiftDegreesOf(double parallax) => Relief360V1.maxShiftDegrees * parallax / ReliefV1.parallax;
