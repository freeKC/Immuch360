// scene-v1 from the metric depth of a map to its layers, its grid, its zone and its flags (design-final 2026-10-27,
// sections 2.3 and 2.4; lot S1): the function scene_v1 of .github/desktop/ai/make_scene_golden.py, step for step, so
// that the test of this lot meets its fixture scene_golden_v1.json on every number. The input is the depth z of a map
// of W x H values in metres (MoGe-2 after its shift and its metric scale), the mask of MoGe and the focal length of the
// map in values; the output is what the meshes, the filling and the packet are made from.

import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/scene/comfort_scale.dart';
import 'package:immich_mobile/desktop/ai/scene/safe_zone.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_layers.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_mesh.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// What scene-v1 makes of a map
class SceneLayout {
  SceneLayout._({
    required this.width,
    required this.height,
    required this.grid,
    required this.farPlane,
    required this.scale,
    required this.depth,
    required this.disparity,
    required this.normalised,
    required this.breaks,
    required this.band,
    required this.inpaintMask,
    required this.depthBehind,
    required this.vertices,
    required this.keptCells,
    required this.indices,
    required this.safe,
    required this.flags,
    required this.focal,
  });

  /// scene-v1 of the depth [z] of a map of [width] x [height] with its [mask], the focal length [focal] in values of
  /// the map, its grid at [step] (SceneV1.gridStepFor of the map)
  factory SceneLayout.build(Float64List z, Float64List mask, int width, int height, double focal, int step) {
    final sky = skyPlaneOf(z, mask);
    final comfort = comfortScaleOf(sky.depth);
    final depth = comfort.depth;
    final q = Float64List(depth.length);
    for (var i = 0; i < depth.length; i++) {
      q[i] = 1.0 / depth[i];
    }
    final normalised = normaliseDisparity(q);
    final d = normalised.values;
    final breaks = SceneBreaks.of(d, width, height);
    final band = bandMaskOf(d, width, height, breaks, 1);
    final inpaint = bandMaskOf(d, width, height, breaks, SceneV1.inpaintMaskFactor);
    final behind = depthBehindOf(depth, band, breaks, width, height);
    final grid = SceneGrid(width, height, step);
    final vertices = gridPositions(grid, q, focal);
    final kept = keptCellsOf(grid, d);
    final indices = cellTriangles(grid, kept);
    final safe = safeZoneOf(depth, q, breaks, focal);
    var bandCount = 0;
    for (final value in band) {
      bandCount += value;
    }
    return SceneLayout._(
      width: width,
      height: height,
      grid: grid,
      farPlane: sky.far,
      scale: comfort.scale,
      depth: depth,
      disparity: q,
      normalised: d,
      breaks: breaks,
      band: band,
      inpaintMask: inpaint,
      depthBehind: behind,
      vertices: vertices,
      keptCells: kept,
      indices: indices,
      safe: safe,
      flags: [
        if (normalised.lowRelief) ReliefQualityFlag.lowRelief,
        if (bandCount > SceneV1.hiddenAreasRatio * width * height) ReliefQualityFlag.hiddenAreas,
        if (sky.sky) ReliefQualityFlag.sky,
        if (isSmallZone(safe)) ReliefQualityFlag.smallZone,
      ],
      focal: focal,
    );
  }

  final int width;
  final int height;
  final SceneGrid grid;

  /// The depth the values without depth were put at, before the comfort scale
  final double farPlane;

  /// The comfort scale, 1 most of the time
  final double scale;

  /// The depth after the comfort scale, its disparity, and the disparity normalised
  final Float64List depth;
  final Float64List disparity;
  final Float64List normalised;
  final SceneBreaks breaks;

  /// 1 in the band of a break, in the mask of the filling
  final Uint8List band;
  final Uint8List inpaintMask;

  /// The depth behind each value of the band, NaN elsewhere
  final Float64List depthBehind;

  /// The positions of every vertex of the grid, and whether each cell keeps its triangles
  final Float64List vertices;
  final Uint8List keptCells;

  /// The triangles of the photo layer, on the vertices of the grid
  final Int32List indices;
  final SceneSafeZone safe;

  /// The flags scene-v1 itself raises: lowRelief, hiddenAreas, sky, smallZone
  final List<ReliefQualityFlag> flags;

  /// The focal length in values of the map
  final double focal;

  /// The part of the map the bands cover: what a step aside may show of what the photo hides
  double get hiddenFraction {
    var count = 0;
    for (final value in band) {
      count += value;
    }
    return count / band.length;
  }

  /// The photo layer: the grid, its triangles, the uv of the photo; then the cells a break cuts, on vertices of their
  /// own behind their band, so that the scene seen from the start is the photo (scene_mesh.dart, cutCellsLayerOf)
  GridLayer get photoLayer {
    final layer = GridLayer(positions: vertices, uvs: gridUvs(grid), indices: indices);
    final cut = cutCellsLayerOf(grid, keptCells, band, depthBehind, focal);
    return cut == null ? layer : joinedLayers(layer, cut);
  }

  /// The background layer, null without a band
  GridLayer? get backgroundLayer => backgroundLayerOf(grid, band, depthBehind, focal);
}
