// Why this file exists: "Preview in 3D" (design-final 2026-10-27, section 2.7) draws a 3D scene on a computer with
// Canvas.drawVertices, the way the 360° viewer draws its sphere (panorama_viewer.widget.dart), so that a scene can be
// judged, and refused, before it goes to the NAS. No shader and nothing new in the pubspec: the vertices are projected
// here, in plain Dart, and this file holds all the geometry of the preview, apart from any widget, for its tests.
//
// What the preview does, as the headset does it (SceneNavigator.kt, make_scene_golden.py step 10):
// 1. The eye starts where the photo was taken, looking towards -z, the photo filling the view across its field of
//    view; the mouse moves the eye within the zone, the wheel forward and back, and nothing turns the view: a scene
//    is frontal.
// 2. Beyond the safe zone (rho over 1) the layers flatten towards the photo plane on their rays from the camera, flat
//    at rho 1.5 (the background 1 cm behind), and the scene darkens from rho 1.25 up to 95 %.
// 3. The layers are drawn from the back to the front, the background first, then the photo, and within a layer the
//    triangles from the farthest to the nearest, sorted again at each frame (the painter's order: no depth buffer).
// 4. A draw holds the triangles of one texture and at most 65 535 vertices: drawVertices takes 16 bit indices, the
//    reason the meshes of glb-layers-v1 hold 65 535 vertices at most. The triangles nearer than 5 cm to the eye, or
//    behind it, are left out.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:immich_mobile/desktop/ai/scene/glb_reader.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The eye of the preview, in metres from where the photo was taken, in the frame of its camera (x right, y up, the
/// scene towards -z)
class SceneEye {
  const SceneEye(this.x, this.y, this.z);

  static const start = SceneEye(0, 0, 0);

  final double x;
  final double y;
  final double z;

  SceneEye operator *(double factor) => SceneEye(x * factor, y * factor, z * factor);

  @override
  bool operator ==(Object other) => other is SceneEye && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);

  @override
  String toString() => 'SceneEye($x, $y, $z)';
}

/// The edge of the zone, the curves of make_scene_golden.py (step 10) and of SceneNavigator.kt
abstract final class SceneEdge {
  /// smooth(t) = t * t * (3 - 2 * t), t clamped to [0, 1]: the curve of ReliefMesh, without plateaus
  static double smooth(double t) {
    final x = t.clamp(0.0, 1.0);
    return x * x * (3 - 2 * x);
  }

  /// How far the layers are flattened at [rho]: 0 within the zone, 1 from SceneV1.flattenTo
  static double flattenOf(double rho) =>
      smooth((rho - SceneV1.flattenFrom) / (SceneV1.flattenTo - SceneV1.flattenFrom));

  /// How dark the scene is at [rho]: 0 up to SceneV1.darkenFrom, SceneV1.darkenMax from SceneV1.flattenTo
  static double darkenOf(double rho) =>
      SceneV1.darkenMax * smooth((rho - SceneV1.darkenFrom) / (SceneV1.flattenTo - SceneV1.darkenFrom));

  /// The normalised distance of [eye] from where it started: towards the scene (z < 0) the forward reach, away from it
  /// the backward one. A reach of 0 allows no movement on its axis.
  static double rhoOf(SceneEye eye, SceneSafeZone safe) {
    double part(double value, double reach) => value == 0
        ? 0
        : reach <= 0
        ? double.infinity
        : value / reach;
    final a = part(eye.x, safe.lateral);
    final b = part(eye.y, safe.vertical);
    final c = part(eye.z, eye.z < 0 ? safe.forward : safe.backward);
    return math.sqrt(a * a + b * b + c * c);
  }

  /// A vertex at [x], [y], [z] (its depth -z) slid on its ray from the camera to the depth (1 - a) z + a [plane]: the
  /// view from the start does not change, and no hole can open. A vertex at the camera or behind it stays.
  static List<double> flattened(double x, double y, double z, double a, double plane) {
    final depth = -z;
    if (depth <= 0) {
      return [x, y, z];
    }
    final target = (1 - a) * depth + a * plane;
    return [x * target / depth, y * target / depth, z * target / depth];
  }

  /// The median of [depths], the lower middle one of an even count; null when there is none
  static double? planeOf(List<double> depths) {
    if (depths.isEmpty) {
      return null;
    }
    final sorted = [...depths]..sort();
    return sorted[(sorted.length - 1) ~/ 2];
  }

  /// The photo plane of a scene: the median depth of the vertices the triangles of its photo layer use, a vertex shared
  /// by two bands of the layer (the same position in both) counted once; null without a photo layer
  static double? photoPlaneOf(List<GlbMesh> meshes) {
    final seen = <(double, double, double)>{};
    final depths = <double>[];
    for (final mesh in meshes) {
      if (mesh.layer != SceneLayer.photo) {
        continue;
      }
      final used = Uint8List(mesh.vertexCount);
      for (final index in mesh.indices) {
        used[index] = 1;
      }
      final p = mesh.positions;
      for (var k = 0; k < used.length; k++) {
        if (used[k] == 1 && seen.add((p[3 * k], p[3 * k + 1], p[3 * k + 2]))) {
          depths.add(-p[3 * k + 2]);
        }
      }
    }
    return planeOf(depths);
  }
}

/// Where the photo lies on the screen at the start, and the focal length in pixels that puts it there
class SceneView {
  const SceneView({required this.center, required this.focal, required this.photoRect});

  /// The photo of [aspect] (width over height) and of [fovDegrees] across its width, as large as fits in [size],
  /// centred
  factory SceneView.fit(Size size, {required double aspect, required double fovDegrees}) {
    final wide = size.width / size.height > aspect;
    final width = wide ? size.height * aspect : size.width;
    final height = wide ? size.height : size.width / aspect;
    final center = size.center(Offset.zero);
    return SceneView(
      center: center,
      focal: width / 2 / math.tan(fovDegrees * math.pi / 360),
      photoRect: Rect.fromCenter(center: center, width: width, height: height),
    );
  }

  /// Nearer than this to the eye, in metres, a vertex is not drawn
  static const nearest = 0.05;

  final Offset center;
  final double focal;
  final Rect photoRect;

  /// Where a point at [x], [y], [z] of the scene shows seen from [eye]; null when it is nearer than [nearest] or behind
  Offset? project(double x, double y, double z, SceneEye eye) {
    final depth = eye.z - z;
    if (!(depth >= nearest)) {
      return null;
    }
    return Offset(center.dx + focal * (x - eye.x) / depth, center.dy - focal * (y - eye.y) / depth);
  }
}

/// One draw: triangles of one texture, its vertices on the screen and in pixels of the texture, 16 bit indices
class SceneBatch {
  const SceneBatch({
    required this.texture,
    required this.positions,
    required this.textureCoordinates,
    required this.indices,
  });

  /// The index of its texture in GlbScene.textures
  final int texture;
  final Float32List positions;
  final Float32List textureCoordinates;
  final Uint16List indices;

  int get vertexCount => positions.length ~/ 2;
}

/// What the preview draws for one place of the eye: the draws in their order, and how flat and dark the scene is
class SceneFrame {
  SceneFrame._(
    this._screen,
    this._depth,
    this._vertexBase, {
    required this.rho,
    required this.flatten,
    required this.darken,
    required this.batches,
    required this.order,
  });

  final double rho;
  final double flatten;
  final double darken;
  final List<SceneBatch> batches;

  /// The triangles drawn, in their order: each one by its rank among the triangles of the scene, mesh after mesh
  final Int32List order;
  final Float32List _screen;
  final Float64List _depth;
  final List<int> _vertexBase;

  int get triangles => order.length;

  /// Where vertex [vertex] of mesh [mesh] shows; meaningless when it is not drawn
  Offset screenOf(int mesh, int vertex) {
    final g = _vertexBase[mesh] + vertex;
    return Offset(_screen[2 * g], _screen[2 * g + 1]);
  }

  /// How far in front of the eye vertex [vertex] of mesh [mesh] is, once flattened
  double depthOf(int mesh, int vertex) => _depth[_vertexBase[mesh] + vertex];
}

/// A scene ready for the preview: its meshes, its photo plane, its zone and the field of view of its photo. The packet
/// at the head of the file says the zone and the field of view ([safe], [fovDegrees]); its glb when the packet does
/// not; else the smallest zone scene-v1 writes, and the field of view its photo layer spans.
class ScenePreviewModel {
  ScenePreviewModel(this.scene, {SceneSafeZone? safe, double? fovDegrees})
    : safe = safe ?? scene.safe ?? fallbackZone,
      fovDegrees = _usableFov(fovDegrees) ?? _usableFov(scene.fovDegrees) ?? _fovOf(scene) ?? 60,
      photoPlane = SceneEdge.photoPlaneOf(scene.meshes) {
    var vertices = 0;
    var triangles = 0;
    for (final mesh in scene.meshes) {
      _vertexBase.add(vertices);
      _triangleBase.add(triangles);
      vertices += mesh.vertexCount;
      triangles += mesh.triangleCount;
    }
    _vertexCount = vertices;
    _meshOf = Uint8List(triangles);
    for (var m = 0; m < scene.meshes.length; m++) {
      _meshOf.fillRange(_triangleBase[m], _triangleBase[m] + scene.meshes[m].triangleCount, m);
    }
  }

  /// The zone of a scene that says none: the smallest scene-v1 writes
  static const fallbackZone = SceneSafeZone(
    lateral: SceneV1.lateralMin,
    vertical: SceneV1.lateralMin * SceneV1.verticalShare,
    forward: SceneV1.forwardMin,
    backward: SceneV1.backwardMin,
  );

  final GlbScene scene;
  final SceneSafeZone safe;
  final double fovDegrees;

  /// The median depth of the photo layer, which the layers flatten towards; null without a photo layer
  final double? photoPlane;

  final _vertexBase = <int>[];
  final _triangleBase = <int>[];
  late final int _vertexCount;
  late final Uint8List _meshOf;

  /// The width over the height of the photo, from its texture
  double get photoAspect {
    final photo = scene.photoTexture;
    final texture = photo == null ? null : scene.textures[photo];
    return texture == null ? 4 / 3 : texture.width / texture.height;
  }

  static double? _usableFov(double? degrees) => degrees != null && degrees > 1 && degrees < 179 ? degrees : null;

  // The field of view the photo layer spans across its width, for a scene that does not say it
  static double? _fovOf(GlbScene scene) {
    var widest = 0.0;
    for (final mesh in scene.meshes) {
      if (mesh.layer != SceneLayer.photo) {
        continue;
      }
      final p = mesh.positions;
      for (var k = 0; k < mesh.vertexCount; k++) {
        final depth = -p[3 * k + 2];
        if (depth > 0) {
          widest = math.max(widest, p[3 * k].abs() / depth);
        }
      }
    }
    return _usableFov(2 * math.atan(widest) * 180 / math.pi);
  }

  /// What the preview draws seen from [eye] in [view], the textures decoded at [textureSizes] (the texture
  /// coordinates are in their pixels), each draw of at most [maxBatchVertices] vertices (65 535 at most)
  SceneFrame frame(
    SceneView view,
    SceneEye eye, {
    required List<Size> textureSizes,
    int maxBatchVertices = SceneV1.maxMeshVertices,
  }) {
    final rho = SceneEdge.rhoOf(eye, safe);
    final flatten = SceneEdge.flattenOf(rho);
    final darken = SceneEdge.darkenOf(rho);
    final meshes = scene.meshes;
    final screen = Float32List(2 * _vertexCount);
    final depth = Float64List(_vertexCount);
    final plane = photoPlane;
    for (var m = 0; m < meshes.length; m++) {
      final mesh = meshes[m];
      final target = plane == null || flatten == 0
          ? null
          : mesh.layer == SceneLayer.photo
          ? plane
          : plane + SceneV1.flatBackground;
      final p = mesh.positions;
      final base = _vertexBase[m];
      for (var k = 0; k < mesh.vertexCount; k++) {
        var x = p[3 * k];
        var y = p[3 * k + 1];
        var z = p[3 * k + 2];
        if (target != null && z < 0) {
          final ratio = ((1 - flatten) * -z + flatten * target) / -z;
          x *= ratio;
          y *= ratio;
          z *= ratio;
        }
        final g = base + k;
        final ahead = eye.z - z;
        depth[g] = ahead;
        if (ahead >= SceneView.nearest) {
          screen[2 * g] = view.center.dx + view.focal * (x - eye.x) / ahead;
          screen[2 * g + 1] = view.center.dy - view.focal * (y - eye.y) / ahead;
        }
      }
    }
    final order = _sorted(depth);
    return SceneFrame._(
      screen,
      depth,
      List.unmodifiable(_vertexBase),
      rho: rho,
      flatten: flatten,
      darken: darken,
      batches: _batches(order, screen, textureSizes, math.min(math.max(3, maxBatchVertices), SceneV1.maxMeshVertices)),
      order: order,
    );
  }

  /// The triangles in front of the eye, the background layer first, each layer from the farthest to the nearest
  Int32List _sorted(Float64List depth) {
    final meshes = scene.meshes;
    final order = Int32List(_meshOf.length);
    var drawn = 0;
    for (final layer in const [SceneLayer.background, SceneLayer.photo]) {
      final ids = <int>[];
      final keys = <double>[];
      for (var m = 0; m < meshes.length; m++) {
        final mesh = meshes[m];
        if (mesh.layer != layer) {
          continue;
        }
        final base = _vertexBase[m];
        final indices = mesh.indices;
        for (var t = 0; t < mesh.triangleCount; t++) {
          final a = depth[base + indices[3 * t]];
          final b = depth[base + indices[3 * t + 1]];
          final c = depth[base + indices[3 * t + 2]];
          if (a >= SceneView.nearest && b >= SceneView.nearest && c >= SceneView.nearest) {
            ids.add(_triangleBase[m] + t);
            keys.add((a + b + c) / 3);
          }
        }
      }
      for (final rank in farthestFirst(Float64List.fromList(keys))) {
        order[drawn++] = ids[rank];
      }
    }
    return Int32List.sublistView(order, 0, drawn);
  }

  /// The triangles of [order] in draws of one texture and at most [most] vertices each, the vertices numbered again
  /// within each draw
  List<SceneBatch> _batches(Int32List order, Float32List screen, List<Size> textureSizes, int most) {
    final meshes = scene.meshes;
    final batches = <SceneBatch>[];
    // The draw each vertex was last put in (0: none yet), and its number there
    final stamp = Int32List(_vertexCount);
    final local = Int32List(_vertexCount);
    var batch = 0;
    var texture = -1;
    var count = 0;
    var positions = Float32List(0);
    var coordinates = Float32List(0);
    var indices = <int>[];

    void flush({bool last = false}) {
      if (indices.isNotEmpty) {
        batches.add(
          SceneBatch(
            texture: texture,
            positions: Float32List.sublistView(positions, 0, 2 * count),
            textureCoordinates: Float32List.sublistView(coordinates, 0, 2 * count),
            indices: Uint16List.fromList(indices),
          ),
        );
      }
      if (last) {
        return;
      }
      batch++;
      count = 0;
      positions = Float32List(2 * most);
      coordinates = Float32List(2 * most);
      indices = <int>[];
    }

    late GlbMesh mesh;
    late Size size;
    late int base;
    void put(int g) {
      if (stamp[g] != batch) {
        stamp[g] = batch;
        local[g] = count;
        final k = g - base;
        positions[2 * count] = screen[2 * g];
        positions[2 * count + 1] = screen[2 * g + 1];
        coordinates[2 * count] = mesh.uvs[2 * k] * size.width;
        coordinates[2 * count + 1] = mesh.uvs[2 * k + 1] * size.height;
        count++;
      }
      indices.add(local[g]);
    }

    for (final id in order) {
      final m = _meshOf[id];
      mesh = meshes[m];
      final t = id - _triangleBase[m];
      base = _vertexBase[m];
      final g0 = base + mesh.indices[3 * t];
      final g1 = base + mesh.indices[3 * t + 1];
      final g2 = base + mesh.indices[3 * t + 2];
      var needed = 0;
      if (stamp[g0] != batch) {
        needed++;
      }
      if (g1 != g0 && stamp[g1] != batch) {
        needed++;
      }
      if (g2 != g0 && g2 != g1 && stamp[g2] != batch) {
        needed++;
      }
      if (mesh.texture != texture || count + needed > most) {
        flush();
        texture = mesh.texture;
      }
      size = mesh.texture < textureSizes.length
          ? textureSizes[mesh.texture]
          : Size(scene.textures[mesh.texture].width.toDouble(), scene.textures[mesh.texture].height.toDouble());
      put(g0);
      put(g1);
      put(g2);
    }
    flush(last: true);
    return batches;
  }
}

/// The ranks of [keys] from the largest to the smallest, equal keys in their order: a counting sort over buckets of
/// the range of the keys, each bucket then sorted exactly. A frame of a scene sorts some 100 000 triangles at each move
/// of the mouse, in a time that grows with their count only.
Int32List farthestFirst(Float64List keys) {
  final n = keys.length;
  final order = Int32List(n);
  if (n == 0) {
    return order;
  }
  var low = keys[0];
  var high = keys[0];
  for (final key in keys) {
    low = math.min(low, key);
    high = math.max(high, key);
  }
  final buckets = math.min(n, 1 << 16);
  final scale = high > low ? (buckets - 1) / (high - low) : 0.0;
  int bucketOf(int i) => ((high - keys[i]) * scale).floor().clamp(0, buckets - 1);
  final starts = Int32List(buckets + 1);
  for (var i = 0; i < n; i++) {
    starts[bucketOf(i) + 1]++;
  }
  for (var b = 0; b < buckets; b++) {
    starts[b + 1] += starts[b];
  }
  final next = Int32List.fromList(starts);
  for (var i = 0; i < n; i++) {
    order[next[bucketOf(i)]++] = i;
  }
  // Within a bucket, by key from the largest, then by rank: an insertion sort, the buckets being small
  for (var b = 0; b < buckets; b++) {
    for (var i = starts[b] + 1; i < starts[b + 1]; i++) {
      final rank = order[i];
      final key = keys[rank];
      var j = i - 1;
      while (j >= starts[b] && (keys[order[j]] < key || (keys[order[j]] == key && order[j] > rank))) {
        order[j + 1] = order[j];
        j--;
      }
      order[j + 1] = rank;
    }
  }
  return order;
}

/// How the mouse and the wheel move the eye of the preview
abstract final class SceneEyeMoves {
  /// The eye goes no further than this normalised distance, where the scene is flat and dark
  static const maxRho = 2.0;

  /// Across the whole width (or height) of the view, a drag moves the eye by this many reaches of the zone: from the
  /// middle to a side, to where the scene is flat
  static const dragReaches = 4.0;

  /// A notch of the wheel (100 logical pixels of scroll) moves the eye by this share of its reach
  static const notchShare = 0.25;
  static const notch = 100.0;

  /// The eye moved by a drag of [delta] in a view of [size]: the way the pointer goes, up being up
  static SceneEye drag(SceneEye eye, Offset delta, Size size, SceneSafeZone safe) {
    if (size.width <= 0 || size.height <= 0) {
      return eye;
    }
    return clamp(
      SceneEye(
        eye.x + delta.dx / size.width * dragReaches * safe.lateral,
        eye.y - delta.dy / size.height * dragReaches * safe.vertical,
        eye.z,
      ),
      safe,
    );
  }

  /// The eye moved by [scroll] of the wheel: forward (towards the scene) when it is negative, by the forward reach in
  /// front of the start and the backward one behind it
  static SceneEye wheel(SceneEye eye, double scroll, SceneSafeZone safe) {
    double share(double z, double reach) => reach > 0 ? z / reach : 0;
    final now = eye.z < 0 ? share(eye.z, safe.forward) : share(eye.z, safe.backward);
    final next = now + scroll / notch * notchShare;
    return clamp(SceneEye(eye.x, eye.y, next < 0 ? next * safe.forward : next * safe.backward), safe);
  }

  /// [eye] brought back to [maxRho] when it went beyond
  static SceneEye clamp(SceneEye eye, SceneSafeZone safe) {
    final rho = SceneEdge.rhoOf(eye, safe);
    if (!rho.isFinite) {
      return SceneEye.start;
    }
    return rho > maxRho ? eye * (maxRho / rho) : eye;
  }
}
