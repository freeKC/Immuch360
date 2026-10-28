// The geometry of "Preview in 3D" on a computer (design-final 2026-10-27, section 2.7): the edge of the zone read
// again in scene_golden_v1.json (make_scene_golden.py, step 10, the curves SceneNavigator.kt follows in the headset),
// the photo plane, the projection of a vertex seen from an eye moved within the zone, the triangles sorted from the
// back to the front layer by layer, the draws cut in batches of 65 535 vertices at most (16 bit indices), and the
// mouse and the wheel that move the eye.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/scene/glb_reader.dart';
import 'package:immich_mobile/desktop/ai/scene_preview/scene_projection.dart';
import 'package:immich_mobile/desktop/window/desktop_shortcuts.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

import '../scene/glb_reader_test_files.dart';

final _golden =
    jsonDecode(File('test/fixtures/ai_immersive/scene_golden_v1.json').readAsStringSync()) as Map<String, Object?>;
final _tolerance = (_golden['tolerance']! as num).toDouble();
final _cases = [for (final c in _golden['cases']! as List<Object?>) c! as Map<String, Object?>];

List<double> _doubles(Object? list) => [for (final value in list! as List<Object?>) (value! as num).toDouble()];

void _close(double actual, double expected, String what, {double? within}) =>
    expect(actual, closeTo(expected, (within ?? _tolerance) * math.max(1, expected.abs())), reason: what);

SceneSafeZone _safeOf(Map<String, Object?> json) => SceneSafeZone.fromJson(json)!;

GlbMesh _mesh(List<double> positions, List<int> indices, {SceneLayer layer = SceneLayer.photo, int texture = 0}) =>
    GlbMesh(
      positions: Float32List.fromList(positions),
      uvs: Float32List(positions.length ~/ 3 * 2),
      indices: Uint32List.fromList(indices),
      texture: texture,
      layer: layer,
    );

GlbScene _scene(List<GlbMesh> meshes, {int textures = 2}) => GlbScene(
  meshes: meshes,
  textures: [for (var i = 0; i < textures; i++) GlbTexture(bytes: Uint8List(0), width: 40, height: 30)],
  format: glbLayersV1,
);

const _zone = SceneSafeZone(lateral: 0.2, vertical: 0.12, forward: 0.4, backward: 0.1);
const _sizes = [Size(40, 30), Size(40, 30)];

void main() {
  group('the edge of the zone, as in the headset', () {
    test('its constants are those of the golden', () {
      expect(_doubles(_golden['flatten']), [
        SceneV1.flattenFrom,
        SceneV1.flattenTo,
        SceneV1.darkenFrom,
        SceneV1.darkenMax,
        SceneV1.flatBackground,
        SceneV1.flattenStep,
      ]);
    });

    test('the flattening and the darkening follow the curve of the golden', () {
      for (final row in _golden['edgeCurve']! as List<Object?>) {
        final [rho, flatten, darken] = _doubles(row);
        _close(SceneEdge.flattenOf(rho), flatten, 'flatten at $rho');
        _close(SceneEdge.darkenOf(rho), darken, 'darken at $rho');
      }
      expect(SceneEdge.smooth(-1), 0);
      expect(SceneEdge.smooth(2), 1);
    });

    test('rho of each eye of each case is the one of the golden, forward and backward told apart', () {
      var checked = 0;
      for (final c in _cases) {
        final safe = _safeOf(c['safe']! as Map<String, Object?>);
        for (final edge in c['edge']! as List<Object?>) {
          final entry = edge! as Map<String, Object?>;
          final [x, y, z] = _doubles(entry['eye']);
          final rho = SceneEdge.rhoOf(SceneEye(x, y, z), safe);
          _close(rho, (entry['rho']! as num).toDouble(), '${c['name']} rho');
          _close(SceneEdge.flattenOf(rho), (entry['flatten']! as num).toDouble(), '${c['name']} flatten');
          _close(SceneEdge.darkenOf(rho), (entry['darken']! as num).toDouble(), '${c['name']} darken');
          checked++;
        }
      }
      expect(checked, 6 * _cases.length);
      // A reach of 0 allows no movement on its axis
      expect(
        SceneEdge.rhoOf(
          const SceneEye(0.1, 0, 0),
          const SceneSafeZone(lateral: 0, vertical: 1, forward: 1, backward: 1),
        ),
        double.infinity,
      );
    });

    test('the photo plane of each case is the median depth of the vertices its triangles use', () {
      for (final c in _cases) {
        final vertices = _doubles(c['vertices']);
        final used = {for (final index in c['indices']! as List<Object?>) index! as int}.toList()..sort();
        final depths = [for (final index in used) -vertices[3 * index + 2]];
        _close(SceneEdge.planeOf(depths)!, (c['photoPlane']! as num).toDouble(), '${c['name']}');
      }
      expect(SceneEdge.planeOf(const []), isNull);
      // The lower middle of an even count
      expect(SceneEdge.planeOf(const [3, 1, 2, 4]), 2);
    });

    test('each vertex slides on its ray towards the plane, the background 1 cm behind', () {
      for (final c in _cases) {
        final probe = c['flattenedVertex']! as Map<String, Object?>;
        final [x, y, z] = _doubles(probe['vertex']);
        final plane = (c['photoPlane']! as num).toDouble();
        for (final (key, a, target) in [
          ('half', 0.5, plane),
          ('full', 1.0, plane),
          ('background', 1.0, plane + 0.01),
        ]) {
          final expected = _doubles(probe[key]);
          final actual = SceneEdge.flattened(x, y, z, a, target);
          for (var i = 0; i < 3; i++) {
            _close(actual[i], expected[i], '${c['name']} $key $i');
          }
        }
      }
      // A vertex at the camera or behind it stays where it is
      expect(SceneEdge.flattened(0.3, 0.2, 0.5, 1, 2), [0.3, 0.2, 0.5]);
    });

    test('the photo plane of the fixture, and a vertex shared by two bands counted once', () {
      // The photo layer of the fixture: three rows at 2, 2.25 and 2.5 m, three vertices each
      expect(SceneEdge.photoPlaneOf(GlbReader.read(tinyGlb()).meshes), 2.25);
      // Three rows at 1, 2 and 3 m cut in two bands that share the row at 2 m, the second band with a vertex at 100 m
      // that no triangle uses, and a background at 9 m
      const cells = [0, 3, 1, 1, 3, 4, 1, 4, 2, 2, 4, 5];
      List<double> row(double depth, double x) => [x, 0, -depth, x + 0.1, 0, -depth, x + 0.2, 0, -depth];
      final top = _mesh([...row(1, 0), ...row(2, 0.5)], cells);
      final bottom = _mesh([...row(2, 0.5), ...row(3, 1), 9, 9, -100], cells);
      final background = _mesh([0, 0, -9, 1, 0, -9, 0, 1, -9], [0, 1, 2], layer: SceneLayer.background, texture: 1);
      expect(SceneEdge.photoPlaneOf([top, bottom, background]), 2);
      expect(SceneEdge.photoPlaneOf([background]), isNull);
    });
  });

  group('the view', () {
    test('the photo fills the view at the start, its field of view across its width, letterboxed', () {
      // A 4:3 photo of 60 degrees in a wide view: the full height, centred
      final view = SceneView.fit(const Size(1000, 600), aspect: 4 / 3, fovDegrees: 60);
      expect(view.photoRect, const Rect.fromLTWH(100, 0, 800, 600));
      expect(view.focal, closeTo(400 / math.tan(math.pi / 6), 1e-9));
      // The top left corner of the photo at 2 m, seen from the start, on the top left corner of the rectangle
      final half = math.tan(math.pi / 6);
      final corner = view.project(-half * 2, half * 0.75 * 2, -2, SceneEye.start)!;
      expect(corner.dx, closeTo(100, 1e-9));
      expect(corner.dy, closeTo(0, 1e-9));
      // A tall view: the full width
      expect(
        SceneView.fit(const Size(400, 900), aspect: 4 / 3, fovDegrees: 60).photoRect,
        const Rect.fromLTWH(0, 300, 400, 300),
      );
    });

    test('a vertex seen from an eye moved to the right goes left, the more so the nearer, and none behind the eye', () {
      final view = SceneView.fit(const Size(800, 600), aspect: 4 / 3, fovDegrees: 60);
      final f = view.focal;
      final near = view.project(0, 0, -1, const SceneEye(0.1, 0, 0))!;
      final far = view.project(0, 0, -4, const SceneEye(0.1, 0, 0))!;
      expect(near.dx, closeTo(400 - f * 0.1 / 1, 1e-9));
      expect(far.dx, closeTo(400 - f * 0.1 / 4, 1e-9));
      // Up a little: the vertex goes down; forward: it grows away from the centre
      expect(view.project(0, 0, -2, const SceneEye(0, 0.1, 0))!.dy, closeTo(300 + f * 0.1 / 2, 1e-9));
      expect(view.project(1, 0, -2, const SceneEye(0, 0, -1))!.dx, closeTo(400 + f * 1 / 1, 1e-9));
      // Nearer than 5 cm, or behind the eye: not drawn
      expect(view.project(0, 0, -0.04, SceneEye.start), isNull);
      expect(view.project(0, 0, -1, const SceneEye(0, 0, -1.2)), isNull);
    });
  });

  group('the frame', () {
    test('the fixture seen from the start: every triangle, the background first, each draw of one texture', () {
      final glb = GlbReader.read(tinyGlb());
      final model = ScenePreviewModel(glb);
      final view = SceneView.fit(const Size(320, 240), aspect: 32 / 24, fovDegrees: 60);
      final frame = model.frame(view, SceneEye.start, textureSizes: const [Size(32, 24), Size(16, 16)]);

      expect(frame.rho, 0);
      expect(frame.flatten, 0);
      expect(frame.darken, 0);
      expect([for (final batch in frame.batches) batch.texture], [1, 0]);
      expect(frame.triangles, 10);
      // The photo layer covers the rectangle of the photo at the start: its corners on the corners of the view
      final photo = frame.batches[1];
      final xs = [for (var k = 0; k < photo.vertexCount; k++) photo.positions[2 * k]];
      final ys = [for (var k = 0; k < photo.vertexCount; k++) photo.positions[2 * k + 1]];
      expect(xs.reduce(math.min), closeTo(0, 1e-3));
      expect(xs.reduce(math.max), closeTo(320, 1e-3));
      expect(ys.reduce(math.min), closeTo(0, 1e-3));
      expect(ys.reduce(math.max), closeTo(240, 1e-3));
      // Texture coordinates in pixels of the texture as decoded
      final us = [for (var k = 0; k < photo.vertexCount; k++) photo.textureCoordinates[2 * k]];
      expect(us.reduce(math.max), 32);
      final background = frame.batches[0];
      expect(
        [for (var k = 0; k < background.vertexCount; k++) background.textureCoordinates[2 * k]].reduce(math.max),
        16,
      );
    });

    test('the triangles of a layer go from the farthest to the nearest, the background layer before the photo', () {
      // Three photo triangles at 3, 1 and 2 m, two background ones at 5 and 4 m, in that order in their meshes
      List<double> triangle(double depth) => [0, 0, -depth, 0.1, 0, -depth, 0, 0.1, -depth];
      final photo = _mesh([...triangle(3), ...triangle(1), ...triangle(2)], [0, 1, 2, 3, 4, 5, 6, 7, 8]);
      final back = _mesh(
        [...triangle(5), ...triangle(4)],
        [0, 1, 2, 3, 4, 5],
        layer: SceneLayer.background,
        texture: 1,
      );
      final model = ScenePreviewModel(_scene([photo, back]), safe: _zone, fovDegrees: 60);
      final view = SceneView.fit(const Size(400, 300), aspect: 4 / 3, fovDegrees: 60);
      final frame = model.frame(view, SceneEye.start, textureSizes: _sizes);

      // The triangles counted mesh after mesh: the photo ones 0, 1 and 2, the background ones 3 and 4
      expect(frame.order, [3, 4, 0, 2, 1]);
      expect([for (final batch in frame.batches) batch.texture], [1, 0]);
      expect([for (final batch in frame.batches) batch.indices.length ~/ 3], [2, 3]);
    });

    test('the eye in front of a near triangle leaves it out, the others drawn, every coordinate finite', () {
      // A photo triangle at 0.3 m and two at 2 m; the eye 0.27 m forward stands 3 cm from the near one
      List<double> triangle(double x, double depth) => [x, 0, -depth, x + 0.1, 0, -depth, x, 0.1, -depth];
      final photo = _mesh(
        [...triangle(0, 0.3), ...triangle(-0.5, 2), ...triangle(0.5, 2)],
        [0, 1, 2, 3, 4, 5, 6, 7, 8],
      );
      final model = ScenePreviewModel(_scene([photo]), safe: _zone, fovDegrees: 60);
      final view = SceneView.fit(const Size(400, 300), aspect: 4 / 3, fovDegrees: 60);
      final frame = model.frame(view, const SceneEye(0, 0, -0.27), textureSizes: _sizes);

      expect(frame.order, [1, 2], reason: 'the triangle 3 cm from the eye is left out');
      for (final batch in frame.batches) {
        expect(batch.positions.every((value) => value.isFinite), isTrue);
      }
    });

    test('one key far beyond the others sorts as fast and as exactly as the scene around it', () {
      // 120 000 keys from 1 to 5 m and one at 1 000 km: all but one in the first buckets (S4-review m4: 6 s on ai1)
      final random = math.Random(7);
      final keys = Float64List.fromList([for (var i = 0; i < 120000; i++) 1 + 4 * random.nextDouble(), 1e6]);
      final watch = Stopwatch()..start();
      final order = farthestFirst(keys);
      watch.stop();

      expect(order.first, 120000);
      for (var i = 1; i < order.length; i++) {
        final before = keys[order[i - 1]];
        final now = keys[order[i]];
        expect(before > now || (before == now && order[i - 1] < order[i]), isTrue, reason: 'rank $i');
      }
      expect(watch.elapsedMilliseconds, lessThan(1500));
    });

    test('the sort keeps its order exact within its buckets, ties in the order of the meshes', () {
      final keys = Float64List.fromList([1, 7, 3.0000001, 3, 7, 0.5, 3.0000002, 1000]);
      expect(farthestFirst(keys), [7, 1, 4, 6, 2, 3, 0, 5]);
      expect(farthestFirst(Float64List(0)), isEmpty);
      expect(farthestFirst(Float64List.fromList([2, 2, 2])), [0, 1, 2]);
    });

    test('a layer of more than 65 535 vertices is drawn in batches of 65 535 at most, re-indexed', () {
      // 255 x 257 = 65 535 vertices in one mesh, then 3 x 3 more in a band of the same layer, farther
      final large = gridMesh(255, 257, 2, 0);
      final band = gridMesh(3, 3, 2.5, 0);
      final meshes = [
        for (final mesh in [large, band]) _mesh(mesh.positions, mesh.indices),
      ];
      final model = ScenePreviewModel(_scene(meshes, textures: 1), safe: _zone, fovDegrees: 120);
      final view = SceneView.fit(const Size(800, 600), aspect: 4 / 3, fovDegrees: 120);
      const sizes = [Size(40, 30)];
      final frame = model.frame(view, SceneEye.start, textureSizes: sizes);

      const largeTriangles = 2 * 254 * 256;
      expect(frame.triangles, largeTriangles + 8);
      expect(frame.batches, hasLength(2));
      for (final batch in frame.batches) {
        expect(batch.vertexCount, lessThanOrEqualTo(65535));
        expect(batch.indices.every((index) => index < batch.vertexCount), isTrue);
      }
      // The band first, being farther, then the large mesh in its own order
      expect(frame.order.sublist(0, 8), [for (var t = 0; t < 8; t++) largeTriangles + t]);
      expect(frame.order.sublist(8), [for (var t = 0; t < largeTriangles; t++) t]);

      // Every corner of every triangle is the vertex it was, whatever the size of the batches
      List<Offset> corners(SceneFrame frame) => [
        for (final batch in frame.batches)
          for (final index in batch.indices) Offset(batch.positions[2 * index], batch.positions[2 * index + 1]),
      ];
      List<Offset> expected(SceneFrame frame) => [
        for (final id in frame.order)
          for (var c = 0; c < 3; c++)
            id < largeTriangles
                ? frame.screenOf(0, meshes[0].indices[3 * id + c])
                : frame.screenOf(1, meshes[1].indices[3 * (id - largeTriangles) + c]),
      ];
      expect(corners(frame), expected(frame));
      final small = model.frame(view, SceneEye.start, textureSizes: sizes, maxBatchVertices: 7);
      expect(small.order, frame.order);
      expect(corners(small), expected(small));
      for (final batch in small.batches) {
        expect(batch.vertexCount, lessThanOrEqualTo(7));
      }
      // Never more than 16 bit indices allow
      expect(model.frame(view, SceneEye.start, textureSizes: sizes, maxBatchVertices: 1 << 20).batches, hasLength(2));
    });

    test('beyond the zone the layers flatten towards the photo plane and the scene darkens, as in the headset', () {
      final glb = GlbReader.read(tinyGlb());
      final model = ScenePreviewModel(glb);
      final view = SceneView.fit(const Size(320, 240), aspect: 32 / 24, fovDegrees: 60);
      // The zone of the fixture is 15 cm to each side: at 30 cm the eye is at rho 2
      const eye = SceneEye(0.3, 0, 0);
      final frame = model.frame(view, eye, textureSizes: const [Size(32, 24), Size(16, 16)]);

      expect(frame.rho, closeTo(2, 1e-9));
      expect(frame.flatten, 1);
      expect(frame.darken, closeTo(SceneV1.darkenMax, 1e-12));
      // Flat: every vertex of the photo layer at 2.25 m, the background at 2.26 m, each on its ray from the camera
      final photo = glb.meshes[0];
      for (var k = 0; k < photo.vertexCount; k++) {
        final p = SceneEdge.flattened(
          photo.positions[3 * k],
          photo.positions[3 * k + 1],
          photo.positions[3 * k + 2],
          1,
          2.25,
        );
        expect(p[2], closeTo(-2.25, 1e-6));
        final shown = view.project(p[0], p[1], p[2], eye)!;
        expect(frame.screenOf(0, k), offsetMoreOrLessEquals(shown, epsilon: 1e-3));
      }
      expect(frame.depthOf(1, 0), closeTo(2.26, 1e-6));
      // Within the zone, nothing moves and nothing darkens
      final inside = model.frame(
        view,
        const SceneEye(0.1, 0.05, -0.1),
        textureSizes: const [Size(32, 24), Size(16, 16)],
      );
      expect(inside.flatten, 0);
      expect(inside.darken, 0);
      // The last vertex of the photo layer, 2.5 m deep, 10 cm nearer to an eye 10 cm forward
      expect(inside.depthOf(0, 8), closeTo(2.4, 1e-6));
    });

    test('a scene says its zone and field of view by its packet first, then by its glb', () {
      final glb = GlbReader.read(tinyGlb());
      expect(ScenePreviewModel(glb).safe, glb.safe);
      expect(ScenePreviewModel(glb).fovDegrees, 60);
      expect(ScenePreviewModel(glb).photoAspect, 32 / 24);
      expect(ScenePreviewModel(glb, safe: _zone, fovDegrees: 50).safe, _zone);
      expect(ScenePreviewModel(glb, safe: _zone, fovDegrees: 50).fovDegrees, 50);
      // Neither says it: the smallest zone scene-v1 writes, and the field of view the photo layer spans
      final bare = GlbScene(meshes: glb.meshes, textures: glb.textures, format: glbLayersV1);
      expect(
        ScenePreviewModel(bare).safe,
        const SceneSafeZone(
          lateral: SceneV1.lateralMin,
          vertical: SceneV1.lateralMin * SceneV1.verticalShare,
          forward: SceneV1.forwardMin,
          backward: SceneV1.backwardMin,
        ),
      );
      expect(ScenePreviewModel(bare).fovDegrees, closeTo(60, 1e-4));
    });
  });

  group('the mouse and the wheel', () {
    const view = Size(800, 600);

    test('a drag moves the eye the way it goes, half the view to the side being twice the zone', () {
      final right = SceneEyeMoves.drag(SceneEye.start, const Offset(200, 0), view, _zone);
      expect(right.x, closeTo(_zone.lateral, 1e-12));
      expect(right.y, 0);
      final up = SceneEyeMoves.drag(SceneEye.start, const Offset(0, -150), view, _zone);
      expect(up.y, closeTo(_zone.vertical, 1e-12));
      // As far as rho 2, where the scene is flat and dark: further changes nothing
      final far = SceneEyeMoves.drag(SceneEye.start, const Offset(1000, 0), view, _zone);
      expect(SceneEdge.rhoOf(far, _zone), closeTo(SceneEyeMoves.maxRho, 1e-12));
      expect(far.x, closeTo(2 * _zone.lateral, 1e-12));
    });

    test('the wheel goes forward by its forward reach and back by its backward reach, a notch a quarter of it', () {
      final forward = SceneEyeMoves.wheel(SceneEye.start, -100, _zone, notch: 100);
      expect(forward.z, closeTo(-0.25 * _zone.forward, 1e-12));
      final back = SceneEyeMoves.wheel(SceneEye.start, 100, _zone, notch: 100);
      expect(back.z, closeTo(0.25 * _zone.backward, 1e-12));
      // From behind the start, forward again: through the start, then by the forward reach
      final through = SceneEyeMoves.wheel(back, -200, _zone, notch: 100);
      expect(through.z, closeTo(-0.25 * _zone.forward, 1e-12));
      // Many notches stop at rho 2
      var eye = SceneEye.start;
      for (var i = 0; i < 40; i++) {
        eye = SceneEyeMoves.wheel(eye, -100, _zone, notch: 100);
      }
      expect(eye.z, closeTo(-2 * _zone.forward, 1e-12));
    });

    test('a notch is what this computer sends for one, and one event counts three notches at most', () {
      // Windows sends 100 physical pixels, 50 logical at 200 % (V2 needed 16 notches for rho 2 instead of 8)
      for (final (platform, ratio) in [
        (TargetPlatform.windows, 2.0),
        (TargetPlatform.windows, 1.5),
        (TargetPlatform.linux, 1.0),
        (TargetPlatform.macOS, 2.0),
      ]) {
        final notch = desktopWheelNotch(platform, ratio);
        final one = SceneEyeMoves.wheel(SceneEye.start, -notch, _zone, notch: notch);
        expect(one.z, closeTo(-0.25 * _zone.forward, 1e-12), reason: '$platform at $ratio');
      }
      final jump = SceneEyeMoves.wheel(SceneEye.start, -1000, _zone, notch: 50);
      expect(jump.z, closeTo(-0.75 * _zone.forward, 1e-12));
    });

    test('two fingers apart on a touchpad go forward, together go back, a doubling half the reach', () {
      final apart = SceneEyeMoves.pinch(SceneEye.start, 2, _zone);
      expect(apart.z, closeTo(-0.5 * _zone.forward, 1e-12));
      final together = SceneEyeMoves.pinch(SceneEye.start, 0.5, _zone);
      expect(together.z, closeTo(0.5 * _zone.backward, 1e-12));
      // In two steps as in one
      final twice = SceneEyeMoves.pinch(SceneEyeMoves.pinch(SceneEye.start, math.sqrt2, _zone), math.sqrt2, _zone);
      expect(twice.z, closeTo(apart.z, 1e-12));
      expect(SceneEyeMoves.pinch(const SceneEye(0.1, 0, 0), 1, _zone), const SceneEye(0.1, 0, 0));
      // Far apart stops at rho 2
      expect(SceneEyeMoves.pinch(SceneEye.start, 1000, _zone).z, closeTo(-2 * _zone.forward, 1e-12));
    });
  });
}
