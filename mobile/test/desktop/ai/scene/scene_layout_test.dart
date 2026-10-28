import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_layers.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_layout.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_mesh.dart';

// scene_layout.dart against scene_golden_v1.json, the fixture of .github/desktop/ai/make_scene_golden.py: on every
// case the sky plane, the comfort scale, the depth, the normalised disparity, the breaks and their bands, the mask of
// the filling, the depth behind the bands, the grid, its cells and triangles, the zone and the flags, every number
// within the tolerance of the fixture and every mask exactly

Map<String, dynamic> _golden() =>
    jsonDecode(File('test/fixtures/ai_immersive/scene_golden_v1.json').readAsStringSync()) as Map<String, dynamic>;

Float64List _flat(Object? rows) => Float64List.fromList([
  for (final row in rows! as List)
    if (row is List) ...row.map((value) => (value as num).toDouble()) else (row as num).toDouble(),
]);

String _maskRows(Uint8List mask, int width) =>
    [for (var y = 0; y < mask.length ~/ width; y++) mask.sublist(y * width, (y + 1) * width).join()].join('|');

void main() {
  final golden = _golden();
  final tolerance = (golden['tolerance'] as num).toDouble();
  final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();

  void close(double actual, num expected, String reason) =>
      expect(actual, closeTo(expected, tolerance * math.max(1, expected.abs())), reason: reason);

  void closeAll(Float64List actual, Float64List expected, String reason) {
    expect(actual.length, expected.length, reason: reason);
    for (var i = 0; i < actual.length; i++) {
      close(actual[i], expected[i], '$reason [$i]');
    }
  }

  for (final entry in cases) {
    final name = entry['name'] as String;
    test('$name: ${entry['description']}', () {
      final width = entry['width'] as int;
      final height = entry['height'] as int;
      final layout = SceneLayout.build(
        _flat(entry['input']),
        _flat(entry['mask']),
        width,
        height,
        (entry['focal'] as num).toDouble(),
        entry['gridStep'] as int,
      );

      close(layout.farPlane, entry['farPlane'] as num, 'far plane');
      close(layout.scale, entry['scale'] as num, 'comfort scale');
      closeAll(layout.depth, _flat(entry['depth']), 'depth');
      closeAll(layout.normalised, _flat(entry['normalized']), 'normalised disparity');

      final breaks = (entry['breaks'] as List).cast<List<dynamic>>();
      expect(layout.breaks.length, breaks.length, reason: 'breaks');
      for (var b = 0; b < breaks.length; b++) {
        expect(layout.breaks.near[b], (breaks[b][1] as int) * width + (breaks[b][0] as int), reason: 'near of $b');
        expect(layout.breaks.far[b], (breaks[b][3] as int) * width + (breaks[b][2] as int), reason: 'far of $b');
        close(layout.breaks.jump[b], breaks[b][4] as num, 'jump of $b');
        expect(bandWidthOf(layout.breaks.jump[b]), (entry['bandWidths'] as List)[b], reason: 'band width of $b');
      }
      expect(_maskRows(layout.band, width), (entry['band'] as List).join('|'), reason: 'band');
      expect(_maskRows(layout.inpaintMask, width), (entry['inpaintMask'] as List).join('|'), reason: 'filling');
      final behind = _flat(entry['depthBehind']);
      for (var i = 0; i < behind.length; i++) {
        if (layout.band[i] == 1) {
          close(layout.depthBehind[i], behind[i], 'depth behind [$i]');
        } else {
          expect(layout.depthBehind[i].isNaN, isTrue, reason: 'no depth behind out of the band [$i]');
        }
      }

      expect(layout.grid.columns, entry['columns']);
      expect(layout.grid.rows, entry['rows']);
      closeAll(layout.vertices, _flat(entry['vertices']), 'vertices');
      expect(_maskRows(layout.keptCells, layout.grid.columns - 1), (entry['keptCells'] as List).join('|'));
      expect(layout.indices, (entry['indices'] as List).cast<int>());

      final safe = (entry['safe'] as Map).cast<String, num>();
      close(layout.safe.lateral, safe['lateral']!, 'lateral');
      close(layout.safe.vertical, safe['vertical']!, 'vertical');
      close(layout.safe.forward, safe['forward']!, 'forward');
      close(layout.safe.backward, safe['backward']!, 'backward');
      expect(layout.flags.map((flag) => flag.xmp), entry['flags']);

      // The plane the headset flattens the photo layer towards: the median depth of the vertices its triangles use
      final used = layout.indices.toSet().toList()..sort();
      final depths = [for (final vertex in used) -layout.vertices[3 * vertex + 2]]..sort();
      if (entry['photoPlane'] != null) {
        close(depths[(depths.length - 1) ~/ 2], entry['photoPlane'] as num, 'photo plane');
      }
    });
  }

  test('the photo layer as one mesh: the grid with the uv of the photo, then its cut cells, nothing else', () {
    final entry = cases.firstWhere((entry) => entry['name'] == 'person');
    final width = entry['width'] as int;
    final layout = SceneLayout.build(
      _flat(entry['input']),
      _flat(entry['mask']),
      width,
      entry['height'] as int,
      (entry['focal'] as num).toDouble(),
      entry['gridStep'] as int,
    );
    final layer = layout.photoLayer;
    final meshes = meshesOf(layer, 0);
    final count = layout.grid.vertexCount;
    final cut = layout.keptCells.where((kept) => kept == 0).length;

    expect(cut, greaterThan(0), reason: 'the person stands in front of the wall');
    expect(meshes, hasLength(1));
    final mesh = meshes.single;
    expect(mesh.texture, 0);
    expect(mesh.triangles, layout.indices.length ~/ 3 + 2 * cut);
    expect(mesh.vertices, layer.indices.toSet().length);
    // The grid first, as the golden fixture has it
    expect(layer.indices.sublist(0, layout.indices.length), layout.indices);
    for (var t = 0; t < layer.indices.length; t++) {
      final vertex = layer.indices[t];
      final grid = vertex % count;
      final i = grid % layout.grid.columns;
      final j = grid ~/ layout.grid.columns;
      final local = mesh.indices[t];
      for (var c = 0; c < 3; c++) {
        expect(mesh.positions[3 * local + c], closeTo(layer.positions[3 * vertex + c], 1e-6));
        if (vertex < count) {
          expect(layer.positions[3 * vertex + c], layout.vertices[3 * vertex + c]);
        }
      }
      expect(mesh.uvs[2 * local], closeTo(i / (layout.grid.columns - 1), 1e-7));
      expect(mesh.uvs[2 * local + 1], closeTo(j / (layout.grid.rows - 1), 1e-7));
    }
  });

  test('seen from the start the photo layer is the photo: every cell, the cut ones behind their band', () {
    for (final entry in cases) {
      final name = entry['name'] as String;
      final width = entry['width'] as int;
      final height = entry['height'] as int;
      final layout = SceneLayout.build(
        _flat(entry['input']),
        _flat(entry['mask']),
        width,
        height,
        (entry['focal'] as num).toDouble(),
        entry['gridStep'] as int,
      );
      final grid = layout.grid;
      final layer = layout.photoLayer;
      final count = grid.vertexCount;
      final cellColumns = grid.columns - 1;

      // Each cell of the grid shows from the start, the kept ones by the grid and the cut ones by their own two
      // triangles: the cell of a triangle pair is that of its first corner
      final shown = <int>[];
      for (var t = 0; t < layer.indices.length; t += 6) {
        final corner = layer.indices[t] % count;
        shown.add((corner ~/ grid.columns) * cellColumns + corner % grid.columns);
      }
      expect(shown.toSet().length, shown.length, reason: '$name: no cell twice');
      expect(shown.toSet(), {for (var c = 0; c < layout.keptCells.length; c++) c}, reason: '$name: every cell');

      // Every vertex on the ray of its point of the photo: the start sees it where the photo has it
      for (final vertex in layer.indices.toSet()) {
        final at = vertex % count;
        final i = at % grid.columns;
        final j = at ~/ grid.columns;
        final depth = -layer.positions[3 * vertex + 2];
        expect(depth, greaterThan(0), reason: '$name: vertex $vertex in front of the camera');
        expect(
          layer.positions[3 * vertex] * layout.focal / depth + width / 2,
          closeTo(i / (grid.columns - 1) * width, 1e-7),
          reason: '$name: vertex $vertex',
        );
        expect(
          height / 2 - layer.positions[3 * vertex + 1] * layout.focal / depth,
          closeTo(j / (grid.rows - 1) * height, 1e-7),
          reason: '$name: vertex $vertex',
        );
      }

      // The vertices of the cut cells at the depth behind the band, in front of the background
      final behind = [
        for (var v = 0; v < layout.depthBehind.length; v++)
          if (layout.band[v] == 1) layout.depthBehind[v],
      ];
      final background = layout.backgroundLayer;
      for (var t = layout.indices.length; t < layer.indices.length; t++) {
        final vertex = layer.indices[t];
        expect(vertex, greaterThanOrEqualTo(count), reason: '$name: a cut cell has vertices of its own');
        final depth = -layer.positions[3 * vertex + 2];
        expect(depth, inInclusiveRange(behind.reduce(math.min) - 1e-9, behind.reduce(math.max) + 1e-9));
        expect(
          -background!.positions[3 * (vertex - count) + 2],
          closeTo(depth * backgroundPush, 1e-9),
          reason: '$name: the background lies right behind it',
        );
      }
    }
  });

  test(
    'the background lies behind every band, reaches one cell beyond, at the depth behind its nearest band value',
    () {
      final entry = cases.firstWhere((entry) => entry['name'] == 'person');
      final width = entry['width'] as int;
      final height = entry['height'] as int;
      final layout = SceneLayout.build(
        _flat(entry['input']),
        _flat(entry['mask']),
        width,
        height,
        (entry['focal'] as num).toDouble(),
        entry['gridStep'] as int,
      );
      final background = layout.backgroundLayer!;
      final grid = layout.grid;
      final used = background.indices.toSet();

      // Every value of the band is under a cell of the background
      final cells = <int>{for (var t = 0; t < background.indices.length; t += 6) background.indices[t]};
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          if (layout.band[y * width + x] != 1) {
            continue;
          }
          var covered = false;
          for (final corner in cells) {
            final i = corner % grid.columns;
            final j = corner ~/ grid.columns;
            covered =
                covered ||
                (x >= grid.cellLeft(i) && x <= grid.cellRight(i) && y >= grid.cellTop(j) && y <= grid.cellBottom(j));
          }
          expect(covered, isTrue, reason: 'band value $x, $y');
        }
      }
      // Its vertices on the rays of their points, behind the band
      final behind = [
        for (var i = 0; i < layout.depthBehind.length; i++)
          if (layout.band[i] == 1) layout.depthBehind[i],
      ];
      final farthest = behind.reduce(math.max);
      final nearest = behind.reduce(math.min);
      for (final vertex in used) {
        final i = vertex % grid.columns;
        final j = vertex ~/ grid.columns;
        final depth = -background.positions[3 * vertex + 2];
        expect(depth, inInclusiveRange(nearest * backgroundPush - 1e-9, farthest * backgroundPush + 1e-9));
        expect(
          background.positions[3 * vertex],
          closeTo((i / (grid.columns - 1) * width - width / 2) * depth / layout.focal, 1e-9),
        );
        expect(
          background.positions[3 * vertex + 1],
          closeTo((height / 2 - j / (grid.rows - 1) * height) * depth / layout.focal, 1e-9),
        );
      }
      // A wall without a break has no background
      final flat = cases.firstWhere((entry) => entry['name'] == 'flat');
      final none = SceneLayout.build(
        _flat(flat['input']),
        _flat(flat['mask']),
        flat['width'] as int,
        flat['height'] as int,
        (flat['focal'] as num).toDouble(),
        flat['gridStep'] as int,
      );
      expect(none.backgroundLayer, isNull);
    },
  );

  test('a layer of more vertices than a mesh holds is cut in bands of rows, each under the bound', () {
    final grid = SceneGrid(64, 48, 1);
    final q = Float64List(64 * 48)..fillRange(0, 64 * 48, 0.5);
    final cells = Uint8List((grid.columns - 1) * (grid.rows - 1))
      ..fillRange(0, (grid.columns - 1) * (grid.rows - 1), 1);
    final layer = GridLayer(
      positions: gridPositions(grid, q, 50),
      uvs: gridUvs(grid),
      indices: cellTriangles(grid, cells),
    );
    final meshes = meshesOf(layer, 1, maxVertices: 500);

    expect(meshes.length, greaterThan(1));
    var triangles = 0;
    for (final mesh in meshes) {
      expect(mesh.vertices, lessThanOrEqualTo(500));
      expect(mesh.indices.every((index) => index < mesh.vertices), isTrue);
      expect(mesh.texture, 1);
      triangles += mesh.triangles;
    }
    expect(triangles, layer.indices.length ~/ 3);
    // A band shares its first row with the one above: every triangle of the layer is in one mesh, whole
    final seen = <String>{};
    for (final mesh in meshes) {
      for (var t = 0; t < mesh.indices.length; t += 3) {
        final corners = [
          for (var c = 0; c < 3; c++) '${mesh.uvs[2 * mesh.indices[t + c]]},${mesh.uvs[2 * mesh.indices[t + c] + 1]}',
        ];
        expect(seen.add(corners.join(';')), isTrue);
      }
    }
  });

  test(
    'the regions of the filling: parts widened by 64, merged when they touch, windows of 512 around their tiles',
    () {
      const width = 1200;
      const height = 700;
      final mask = Uint8List(width * height);
      void hole(int left, int top, int right, int bottom) {
        for (var y = top; y < bottom; y++) {
          mask.fillRange(y * width + left, y * width + right, 1);
        }
      }

      // Two holes 100 apart (widened by 64 each, they touch), one far on the right, and a long one along the bottom
      hole(100, 100, 120, 140);
      hole(220, 100, 240, 140);
      hole(1100, 50, 1110, 60);
      hole(50, 650, 1150, 660);
      final tiles = inpaintTilesOf(mask, width, height);

      // In the order of their first value: the small one on the right first, then the two merged, then the long one
      expect(tiles.map((region) => region.tile).take(2), const [MapBox(0, 124, 1036, 1174), MapBox(36, 204, 36, 304)]);
      expect(tiles[0].window, const MapBox(0, 512, 688, 1200));
      expect(tiles[1].window, const MapBox(0, 512, 0, 512));
      for (final region in tiles) {
        expect(region.tile.width, lessThanOrEqualTo(512));
        expect(region.tile.height, lessThanOrEqualTo(512));
        expect(region.window.width, 512);
        expect(region.window.height, 512);
        expect(region.window.left <= region.tile.left && region.window.right >= region.tile.right, isTrue);
        expect(region.window.top <= region.tile.top && region.window.bottom >= region.tile.bottom, isTrue);
      }
      // Every hole in exactly one tile
      for (var i = 0; i < mask.length; i++) {
        if (mask[i] == 1) {
          expect(tiles.where((region) => region.tile.contains(i % width, i ~/ width)), hasLength(1));
        }
      }
      // The long one, as wide as the map once widened, in three tiles of 400
      expect(tiles.where((region) => region.tile.top == 586), hasLength(3));
    },
  );

  test('a map smaller than a window: the window is the whole map', () {
    const width = 1024;
    const height = 341;
    final mask = Uint8List(width * height);
    mask[100 * width + 500] = 1;
    final tiles = inpaintTilesOf(mask, width, height);

    expect(tiles.single.window, const MapBox(0, 341, 244, 756));
  });
}
