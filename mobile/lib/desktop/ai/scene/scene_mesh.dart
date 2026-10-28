// The meshes of a scene (design-final 2026-10-27, section 2.3, steps 7, 10 and 11; lot S1).
//
// The photo layer is the grid of .github/desktop/ai/make_scene_golden.py (its steps 5 and 6), as ReliefMesh makes it:
// columns x rows vertices over the photo at the step of the map, the vertex (i, j) showing the point
// (i / (columns - 1), j / (rows - 1)) of the photo from its top left corner (its uv), its depth read in bilinear in the
// disparity at the centres of the values; positions in the frame of the camera of glTF (x right, y up, looking towards
// -z): X = (u - W / 2) z / f, Y = (H / 2 - v) z / f, Z = -z. A cell over two neighbours that break has no triangle;
// the others give (a, c, b) and (b, c, d), counter clockwise as the camera sees them.
//
// The scene seen from where the photo was taken is the photo (design 2.1, 2.3 step 5, 3.4 and 8.2; S1-review M1,
// remedy A, chosen by V2, which found the background in front of the far side as well): along the ray of any point
// of the photo, the photo layer comes first.
//
// The cut cells: the cells the grid leaves without triangles get two triangles of their own on vertices of their own,
// each on the ray of its point of the photo at the depth behind the band nearest to it, or at the depth of the grid
// there when that lies farther (a far side that recedes), the depth of the background without its push. From the
// start each of their points shows where the photo has it; a step aside slides them with the far side, just in front
// of the background, which fills what the step uncovers. They join the photo layer after the grid (its texture is the
// photo): the grid of the golden fixture is untouched.
//
// The background layer, which the golden fixture leaves to the engine: the cells of the same grid whose values touch a
// band, and one cell more all around so that it reaches under the far side and no slit shows between the layers. Each
// of its vertices lies on the ray of its point of the photo at the depth behind the band nearest to it (the value of
// the band nearest to its point of the map), or at the depth of the grid there when that lies farther, pushed back by
// [backgroundPush]: where it lies under the far side of the photo layer the two never fight, and it never comes in
// front of the photo. Its uv are those of the photo layer, on the filled image of the map.
//
// Each layer keeps only the vertices its triangles use; beyond SceneV1.maxMeshVertices it is cut in bands of rows
// (the triangles come row after row), each mesh numbering its own vertices, at most SceneV1.maxMeshes meshes in all.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_layers.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// How much farther than the depth behind its band the background lies: 0.5 %, 5 mm at a metre
const backgroundPush = 1.005;

/// The grid of a map of [width] x [height] at [step], and where its vertices read the map
class SceneGrid {
  SceneGrid(this.width, this.height, this.step)
    : columns = SceneV1.gridLineCount(width, step),
      rows = SceneV1.gridLineCount(height, step) {
    xs = Float64List.fromList([for (var i = 0; i < columns; i++) i / (columns - 1) * width - 0.5]);
    ys = Float64List.fromList([for (var j = 0; j < rows; j++) j / (rows - 1) * height - 0.5]);
  }

  final int width;
  final int height;
  final int step;
  final int columns;
  final int rows;

  /// The coordinates in the map of the columns and of the rows of vertices
  late final Float64List xs;
  late final Float64List ys;

  int get vertexCount => columns * rows;

  /// The first and last columns and rows of the map the cell (i, j) covers, clamped to the map
  int cellLeft(int i) => _clamp(xs[i].floor(), width);
  int cellRight(int i) => _clamp(xs[i + 1].ceil(), width);
  int cellTop(int j) => _clamp(ys[j].floor(), height);
  int cellBottom(int j) => _clamp(ys[j + 1].ceil(), height);

  /// The u, v of the vertex (i, j) on the photo, 0 to 1 from its top left corner
  double u(int i) => i / (columns - 1);
  double v(int j) => j / (rows - 1);

  /// The position of the point of the photo of the vertex (i, j) at depth [depth], [focal] in values of the map
  void positionAt(int i, int j, double depth, double focal, Float64List out, int at) {
    final u = i / (columns - 1) * width;
    final v = j / (rows - 1) * height;
    out[at] = (u - width / 2) * depth / focal;
    out[at + 1] = (height / 2 - v) * depth / focal;
    out[at + 2] = -depth;
  }
}

int _clamp(int index, int size) => math.min(size - 1, math.max(0, index));

/// The positions of the vertices of [grid] over the disparity [q] (bilinear, the edges repeated), x, y, z one vertex
/// after the other, row after row
Float64List gridPositions(SceneGrid grid, Float64List q, double focal) {
  final width = grid.width;
  final height = grid.height;
  final out = Float64List(3 * grid.vertexCount);
  for (var j = 0; j < grid.rows; j++) {
    final y0 = grid.ys[j].floor();
    final fy = grid.ys[j] - y0;
    final top = _clamp(y0, height) * width;
    final bottom = _clamp(y0 + 1, height) * width;
    for (var i = 0; i < grid.columns; i++) {
      final x0 = grid.xs[i].floor();
      final fx = grid.xs[i] - x0;
      final left = _clamp(x0, width);
      final right = _clamp(x0 + 1, width);
      final upper = q[top + left] + (q[top + right] - q[top + left]) * fx;
      final lower = q[bottom + left] + (q[bottom + right] - q[bottom + left]) * fx;
      final depth = 1.0 / (upper + (lower - upper) * fy);
      grid.positionAt(i, j, depth, focal, out, 3 * (j * grid.columns + i));
    }
  }
  return out;
}

/// Whether each cell of [grid] keeps its two triangles: none of its pairs of neighbours of the map breaks
Uint8List keptCellsOf(SceneGrid grid, Float64List d) {
  final width = grid.width;
  bool breaks(int a, int b) => (d[a] - d[b]).abs() > SceneV1.breakThreshold;
  final kept = Uint8List((grid.columns - 1) * (grid.rows - 1));
  for (var j = 0; j < grid.rows - 1; j++) {
    final top = grid.cellTop(j);
    final bottom = grid.cellBottom(j);
    for (var i = 0; i < grid.columns - 1; i++) {
      final left = grid.cellLeft(i);
      final right = grid.cellRight(i);
      var cut = false;
      for (var y = top; y <= bottom && !cut; y++) {
        for (var x = left; x <= right && !cut; x++) {
          final at = y * width + x;
          cut = (x < right && breaks(at, at + 1)) || (y < bottom && breaks(at, at + width));
        }
      }
      kept[j * (grid.columns - 1) + i] = cut ? 0 : 1;
    }
  }
  return kept;
}

/// The triangles of the cells of [grid] marked in [cells]: (a, c, b) and (b, c, d) for each, row after row
Int32List cellTriangles(SceneGrid grid, Uint8List cells) {
  final out = <int>[];
  for (var j = 0; j < grid.rows - 1; j++) {
    for (var i = 0; i < grid.columns - 1; i++) {
      if (cells[j * (grid.columns - 1) + i] == 1) {
        final a = j * grid.columns + i;
        final b = a + 1;
        final c = a + grid.columns;
        final d = c + 1;
        out.addAll([a, c, b, b, c, d]);
      }
    }
  }
  return Int32List.fromList(out);
}

/// The uv of the vertices of [grid], u and v one vertex after the other
Float64List gridUvs(SceneGrid grid) {
  final out = Float64List(2 * grid.vertexCount);
  for (var j = 0; j < grid.rows; j++) {
    for (var i = 0; i < grid.columns; i++) {
      out[2 * (j * grid.columns + i)] = grid.u(i);
      out[2 * (j * grid.columns + i) + 1] = grid.v(j);
    }
  }
  return out;
}

/// A layer before it is cut in meshes: positions and uv of the vertices of the grid, its triangles
class GridLayer {
  const GridLayer({required this.positions, required this.uvs, required this.indices});

  final Float64List positions;
  final Float64List uvs;
  final Int32List indices;
}

/// [first] then [then] as one layer: the vertices of [then] after those of [first], its triangles renumbered
GridLayer joinedLayers(GridLayer first, GridLayer then) {
  final count = first.positions.length ~/ 3;
  return GridLayer(
    positions: Float64List.fromList([...first.positions, ...then.positions]),
    uvs: Float64List.fromList([...first.uvs, ...then.uvs]),
    indices: Int32List.fromList([...first.indices, for (final vertex in then.indices) vertex + count]),
  );
}

/// The vertices of [grid] the triangles [indices] use, each on the ray of its point at the depth behind the value of
/// [band] nearest to it, or at the depth of the grid [photo] there when that is farther, times [push]; the others at 0
Float64List _behindBands(
  SceneGrid grid,
  Int32List indices,
  Uint8List band,
  Float64List depthBehind,
  Float64List photo,
  double focal,
  double push,
) {
  final bandValues = NearestPoints(
    [
      for (var i = 0; i < band.length; i++)
        if (band[i] == 1) i,
    ],
    grid.width,
    grid.height,
  );
  final positions = Float64List(3 * grid.vertexCount);
  final used = Uint8List(grid.vertexCount);
  for (final vertex in indices) {
    used[vertex] = 1;
  }
  for (var vertex = 0; vertex < grid.vertexCount; vertex++) {
    if (used[vertex] == 0) {
      continue;
    }
    final i = vertex % grid.columns;
    final j = vertex ~/ grid.columns;
    final nearest = bandValues.nearestTo(grid.xs[i], grid.ys[j]);
    final depth = math.max(depthBehind[nearest], -photo[3 * vertex + 2]);
    grid.positionAt(i, j, depth * push, focal, positions, 3 * vertex);
  }
  return positions;
}

/// The cells of [grid] a break cuts (0 in [keptCells]) as seen from the start, [photo] the positions of the grid: see
/// the top of this file. Null when no cell is cut, or without a band.
GridLayer? cutCellsLayerOf(
  SceneGrid grid,
  Uint8List keptCells,
  Uint8List band,
  Float64List depthBehind,
  Float64List photo,
  double focal,
) {
  final cut = Uint8List(keptCells.length);
  var any = false;
  for (var cell = 0; cell < keptCells.length; cell++) {
    if (keptCells[cell] == 0) {
      cut[cell] = 1;
      any = true;
    }
  }
  if (!any || !band.contains(1)) {
    return null;
  }
  final indices = cellTriangles(grid, cut);
  return GridLayer(
    positions: _behindBands(grid, indices, band, depthBehind, photo, focal, 1),
    uvs: gridUvs(grid),
    indices: indices,
  );
}

/// The background layer of a scene, [photo] the positions of the grid: see the top of this file. Null when there is no
/// band.
GridLayer? backgroundLayerOf(SceneGrid grid, Uint8List band, Float64List depthBehind, Float64List photo, double focal) {
  final width = grid.width;
  final cellColumns = grid.columns - 1;
  final cellRows = grid.rows - 1;
  final touched = Uint8List(cellColumns * cellRows);
  var any = false;
  for (var j = 0; j < cellRows; j++) {
    for (var i = 0; i < cellColumns; i++) {
      var hit = false;
      for (var y = grid.cellTop(j); y <= grid.cellBottom(j) && !hit; y++) {
        for (var x = grid.cellLeft(i); x <= grid.cellRight(i) && !hit; x++) {
          hit = band[y * width + x] == 1;
        }
      }
      if (hit) {
        touched[j * cellColumns + i] = 1;
        any = true;
      }
    }
  }
  if (!any) {
    return null;
  }
  // One cell more all around
  final cells = Uint8List(cellColumns * cellRows);
  for (var j = 0; j < cellRows; j++) {
    for (var i = 0; i < cellColumns; i++) {
      var near = false;
      for (var jj = math.max(0, j - 1); jj <= math.min(cellRows - 1, j + 1) && !near; jj++) {
        for (var ii = math.max(0, i - 1); ii <= math.min(cellColumns - 1, i + 1) && !near; ii++) {
          near = touched[jj * cellColumns + ii] == 1;
        }
      }
      cells[j * cellColumns + i] = near ? 1 : 0;
    }
  }
  final indices = cellTriangles(grid, cells);
  return GridLayer(
    positions: _behindBands(grid, indices, band, depthBehind, photo, focal, backgroundPush),
    uvs: gridUvs(grid),
    indices: indices,
  );
}

/// [layer] as meshes of at most [maxVertices] vertices each, showing the texture [texture]: only the vertices its
/// triangles use, cut in bands of rows when there are more
List<SceneMeshData> meshesOf(GridLayer layer, int texture, {int maxVertices = SceneV1.maxMeshVertices}) {
  final meshes = <SceneMeshData>[];
  final local = <int, int>{};
  final positions = <double>[];
  final uvs = <double>[];
  final indices = <int>[];
  void flush() {
    if (indices.isEmpty) {
      return;
    }
    meshes.add(
      SceneMeshData(
        positions: Float32List.fromList(positions),
        uvs: Float32List.fromList(uvs),
        indices: Uint32List.fromList(indices),
        texture: texture,
      ),
    );
    local.clear();
    positions.clear();
    uvs.clear();
    indices.clear();
  }

  for (var t = 0; t < layer.indices.length; t += 3) {
    final corners = layer.indices.sublist(t, t + 3);
    final fresh = corners.where((vertex) => !local.containsKey(vertex)).toSet().length;
    if (local.length + fresh > maxVertices) {
      flush();
    }
    for (final vertex in corners) {
      indices.add(
        local.putIfAbsent(vertex, () {
          positions.addAll(layer.positions.sublist(3 * vertex, 3 * vertex + 3));
          uvs.addAll(layer.uvs.sublist(2 * vertex, 2 * vertex + 2));
          return local.length;
        }),
      );
    }
  }
  flush();
  return meshes;
}
