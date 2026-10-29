// The inputs MI-GAN is given for a region (lot S1, then lot P3): the bands of a scene hide the near layer, so their
// holes are painted with the mean colour of the known pixels first (M2: the pipeline blends the first pixels of its fill
// with what lies under the hole); the seam of a panorama hides nothing but the seam itself, so its holes keep their
// pixels, and the blend at the edge of the band meets the panorama around it instead of a band of that mean colour
// (the essay of P3 on the RTX 4060 saw bright lines along both edges of the band with the mean).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/scene/migan_inpaint.dart';

void main() {
  // Two pixels across, one known (10, 20, 30), one a hole holding (200, 100, 50)
  final region = InpaintRegion(
    width: 2,
    height: 1,
    rgb: Uint8List.fromList([10, 20, 30, 200, 100, 50]),
    mask: Uint8List.fromList([255, 0]),
  );

  test('a band of a scene: the hole painted with the mean colour of the known pixels, planes of one colour', () {
    final (image, mask) = miganInputsOf(region);
    expect(image, [10, 10, 20, 20, 30, 30]);
    expect(mask, [255, 0]);
  });

  test('the seam of a panorama: the hole keeps its pixels', () {
    final (image, mask) = miganInputsOf(region, paintHoles: false);
    expect(image, [10, 200, 20, 100, 30, 50]);
    expect(mask, [255, 0]);
  });
}
