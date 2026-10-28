// The upscale of a generated 360° panorama without a seam of its own (lot P3, design-final 2026-10-27, section 4.3,
// point 7): the panorama widened by 32 columns wrapped from the other side on each side, upscaled four times, then cut
// back to four times its size; and the PNG files the generator and the upscaler read and write.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/panorama/control_image.dart';
import 'package:immich_mobile/desktop/ai/panorama/upscale.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

Uint8List _columns(int width, int height) => Uint8List.fromList([
  for (var y = 0; y < height; y++)
    for (var x = 0; x < width; x++) ...[x, y, 7, 255],
]);

void main() {
  test('wrapped: the last columns before, the first ones after', () {
    final wrapped = wrapColumns(_columns(10, 2), 10, 2, 3);
    final firstRow = [for (var x = 0; x < 16; x++) wrapped[4 * x]];
    expect(firstRow, [7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2]);
    expect(wrapped.sublist(4 * 16, 4 * 16 + 2), [7, 1]);
  });

  test('cut back after the upscale: the padding times the scale off each side', () {
    final upscaled = _columns(16 * 4, 2 * 4);
    final cut = cropColumns(upscaled, 16 * 4, 2 * 4, 3 * 4);
    expect(cut.length, 4 * 40 * 8);
    expect(cut[0], 12);
    expect(cut[4 * 39], 51);
  });

  test('the sizes of the app: 1536 x 768 widened to 1600, upscaled to 6400 x 3072, cut to 6144 x 3072', () {
    expect(PanoV1.generationWidth + 2 * PanoV1.upscalePadding, 1600);
    expect(PanoV1.outputWidth, 6144);
    expect(PanoV1.outputHeight, 3072);
  });

  test('a picture through a PNG file and back, opaque', () {
    final rgba = _columns(5, 3);
    final back = decodePngPicture(encodePngPicture(SbsDecoded(width: 5, height: 3, rgba: rgba)));
    expect(back.width, 5);
    expect(back.height, 3);
    expect(back.rgba, rgba);
  });

  test('a PNG of grey levels comes back as RGBA', () {
    final image = img.Image(width: 4, height: 2, numChannels: 1)..clear(img.ColorUint8.rgb(99, 99, 99));
    final grey = decodePngPicture(img.encodePng(image));
    expect(grey.rgba.sublist(0, 8), [99, 99, 99, 255, 99, 99, 99, 255]);
  });

  test('no PNG: a FormatException', () {
    expect(() => decodePngPicture(Uint8List.fromList([1, 2, 3])), throwsFormatException);
  });
}
