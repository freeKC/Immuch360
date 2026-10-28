// The input of LaMa for a region of the map (lot S1): the region padded to 512 on its right and bottom by reflection,
// and its mask with it, so that the reflection of a hole is a hole, as the evaluation code of LaMa pads both
// (pad_img_to_modulo). Without ONNX Runtime; LaMa on its tiny model is in scene_engine_ort_test.dart.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/scene/lama_inpaint.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

void main() {
  const side = SceneV1.inpaintRegionMax;
  const plane = side * side;

  /// A region of [width] x [height] whose pixels tell where they are, its holes where [hole] says
  InpaintRegion regionOf(int width, int height, bool Function(int x, int y) hole) => InpaintRegion(
    width: width,
    height: height,
    rgb: Uint8List.fromList([
      for (var y = 0; y < height; y++)
        for (var x = 0; x < width; x++) ...[x % 256, y % 256, (x ~/ 256) * 16 + (y ~/ 256)],
    ]),
    mask: Uint8List.fromList([
      for (var y = 0; y < height; y++)
        for (var x = 0; x < width; x++) hole(x, y) ? 0 : 255,
    ]),
  );

  /// Where the input of [region] is not the region reflected, its mask with it: empty when it is
  List<String> mismatchesOf(InpaintRegion region, bool Function(int x, int y) hole) {
    final (image, mask) = lamaInputOf(region);
    expect(image, hasLength(3 * plane));
    expect(mask, hasLength(plane));
    final wrong = <String>[];
    for (var y = 0; y < side && wrong.length < 10; y++) {
      final sy = reflectIndex(y, region.height);
      for (var x = 0; x < side && wrong.length < 10; x++) {
        final sx = reflectIndex(x, region.width);
        final at = y * side + x;
        final from = sy * region.width + sx;
        final expected = hole(sx, sy) ? 1.0 : 0.0;
        if (mask[at] != expected) {
          wrong.add('mask at ($x, $y): ${mask[at]}, not $expected');
        }
        for (var c = 0; c < 3; c++) {
          // float32 in [0, 1]
          if ((image[c * plane + at] * 255).round() != region.rgb[3 * from + c]) {
            wrong.add('channel $c at ($x, $y): ${image[c * plane + at]}');
          }
        }
      }
    }
    return wrong;
  }

  test('a region of 512 goes as it is, 1 on its holes', () {
    bool hole(int x, int y) => x >= 100 && x < 220 && y >= 40 && y < 90;
    final region = regionOf(side, side, hole);

    expect(mismatchesOf(region, hole), isEmpty);
    expect(lamaInputOf(region).$2.where((value) => value == 1), hasLength(120 * 50));
  });

  test('the map of a 3:1 panorama, 341 high: a hole on its bottom edge is a hole in the rows that reflect it', () {
    bool hole(int x, int y) => x >= 100 && x < 200 && y >= 330;
    final region = regionOf(side, 341, hole);
    final mask = lamaInputOf(region).$2;

    expect(mismatchesOf(region, hole), isEmpty);
    // Row 341 reflects row 339, row 350 row 330, row 351 row 329
    expect(mask[341 * side + 150], 1, reason: 'the reflection of a hole is a hole, never context for LaMa');
    expect(mask[350 * side + 150], 1);
    expect(mask[351 * side + 150], 0);
    expect(mask.where((value) => value == 1), hasLength(100 * 11 + 100 * 10));
  });

  test('a region smaller both ways: a hole in its bottom right corner reflected to the right, below and across', () {
    bool hole(int x, int y) => x >= 290 && y >= 190;
    final region = regionOf(300, 200, hole);
    final mask = lamaInputOf(region).$2;

    expect(mismatchesOf(region, hole), isEmpty);
    expect(mask[195 * side + 305], 1, reason: 'to the right');
    expect(mask[205 * side + 295], 1, reason: 'below');
    expect(mask[205 * side + 305], 1, reason: 'across the corner');
    expect(mask[195 * side + 320], 0, reason: 'column 320 reflects column 278');
  });

  test('a region of one row or one column reflects its only line', () {
    bool hole(int x, int y) => x == 3;
    expect(mismatchesOf(regionOf(10, 1, hole), hole), isEmpty);
    expect(mismatchesOf(regionOf(1, 10, (x, y) => y == 2), (x, y) => y == 2), isEmpty);
  });
}
