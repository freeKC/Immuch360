// The Dart TIFF decoder against files of other writers (test/fixtures/tiff, written by tifffile and Pillow with
// make_tiffs.py there): the predictor with LZW and Deflate, 16 bit samples, both byte orders, tiles that do not fill
// the image, planes, pages, alpha, CMYK, a palette, JPEG in TIFF, and the files it must refuse rather than show wrong.
// The image package alone showed the Deflate and 16 bit files with a predictor as black or noise without an error.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/services/tiff_decoder.dart';

/// The sample [c] of the pixel ([x], [y]) of the fixtures, on [bits] bits, as make_tiffs.py writes it
int sample(int x, int y, int c, int bits) =>
    (((x * 7919 + y * 104729 + c * 31337 + 17) * 2654435761) >> 13) & ((1 << bits) - 1);

/// The gradient of the JPEG fixtures, [width] by [height]
int smooth(int x, int y, int c, int width, int height) => switch (c) {
  0 => x * 255 ~/ (width - 1),
  1 => y * 255 ~/ (height - 1),
  _ => (x + y) * 255 ~/ (width + height - 2),
};

Uint8List fixture(String name) => File('test/fixtures/tiff/$name').readAsBytesSync();

TiffPixels decode(String name, {int maxSide = 4096}) =>
    decodeTiffPixels(fixture(name), maxSide: maxSide, maxDecodedBytes: 64 << 20);

/// The largest difference between the pixels of [pixels] and [expected] (red, green, blue, alpha of each pixel)
int largestDifference(TiffPixels pixels, List<int> Function(int x, int y) expected) {
  var largest = 0;
  for (var y = 0; y < pixels.height; y++) {
    for (var x = 0; x < pixels.width; x++) {
      final want = expected(x, y);
      for (var c = 0; c < 4; c++) {
        final difference = (pixels.rgba[(y * pixels.width + x) * 4 + c] - want[c]).abs();
        if (difference > largest) {
          largest = difference;
        }
      }
    }
  }
  return largest;
}

/// The RGB pixels of the fixtures on [bits] bits, kept on 8, opaque
List<int> rgbOf(int x, int y, int bits) => [for (var c = 0; c < 3; c++) sample(x, y, c, bits) >> (bits - 8), 255];

void main() {
  group('the files photo editors write', () {
    for (final (name, bits) in [
      ('rgb8_lzw_pred.tif', 8),
      ('rgb8_deflate_pred.tif', 8),
      ('rgb16_lzw_pred.tif', 16),
      ('rgb16_deflate_pred.tif', 16),
      ('rgb16_be_lzw_pred.tif', 16),
      ('rgb16_be_none.tif', 16),
      ('rgb8_strips_lzw_pred.tif', 8),
      ('rgb8_planar_lzw_pred.tif', 8),
      ('rgb8_packbits_pillow.tif', 8),
      ('pages_lzw_pred.tif', 8),
    ]) {
      test('$name decodes to its exact pixels', () {
        final pixels = decode(name);
        expect((pixels.width, pixels.height), (64, 32));
        expect(largestDifference(pixels, (x, y) => rgbOf(x, y, bits)), 0);
      });
    }

    test('an LZW stream long enough to clear its table decodes to its exact pixels', () {
      final pixels = decode('rgb8_lzw_noise.tif');
      expect((pixels.width, pixels.height), (96, 64));
      expect(largestDifference(pixels, (x, y) => rgbOf(x, y, 8)), 0);
    });

    test('tiles that do not fill the right and bottom edges, 8 bit Deflate and 16 bit LZW with the predictor', () {
      for (final (name, bits) in [('rgb8_tiled_deflate_pred.tif', 8), ('rgb16_tiled_lzw_pred.tif', 16)]) {
        final pixels = decode(name);
        expect((pixels.width, pixels.height), (72, 40), reason: name);
        expect(largestDifference(pixels, (x, y) => rgbOf(x, y, bits)), 0, reason: name);
      }
    });

    test('alpha, gray, CMYK and a palette', () {
      expect(
        largestDifference(decode('rgba8_deflate_pred.tif'), (x, y) => [for (var c = 0; c < 4; c++) sample(x, y, c, 8)]),
        0,
      );
      expect(
        largestDifference(decode('gray16_lzw_pred.tif'), (x, y) {
          final gray = sample(x, y, 0, 16) >> 8;
          return [gray, gray, gray, 255];
        }),
        0,
      );
      expect(
        largestDifference(decode('cmyk8_lzw.tif'), (x, y) {
          final white = 255 - sample(x, y, 3, 8);
          return [for (var c = 0; c < 3; c++) ((255 - sample(x, y, c, 8)) * white + 127) ~/ 255, 255];
        }),
        0,
      );
      expect(
        largestDifference(decode('palette8_lzw.tif'), (x, y) {
          final index = sample(x, y, 0, 8);
          return [for (var c = 0; c < 3; c++) sample(index, 0, c, 16) >> 8, 255];
        }),
        0,
      );
    });

    test('JPEG in TIFF: whole JPEG strips in YCbCr, tiles, and RGB strips sharing their tables', () {
      for (final (name, width, height) in [
        ('smooth_jpeg_ycbcr.tif', 96, 64),
        ('smooth_jpeg_tiled.tif', 72, 40),
        ('smooth_jpeg_rgb_tables.tif', 96, 64),
      ]) {
        final pixels = decode(name);
        expect((pixels.width, pixels.height), (width, height), reason: name);
        // JPEG keeps a gradient within a few levels
        expect(
          largestDifference(pixels, (x, y) => [for (var c = 0; c < 3; c++) smooth(x, y, c, width, height), 255]),
          lessThanOrEqualTo(8),
          reason: name,
        );
      }
    });

    test('turned upright as its orientation tag says, after it is scaled down', () {
      final turned = decode('rgb8_lzw_pred_orientation6.tif');
      // 6: shown a quarter turn clockwise, taller than wide
      expect((turned.width, turned.height), (32, 64));
      expect(largestDifference(turned, (x, y) => rgbOf(y, 31 - x, 8)), 0);

      final small = decode('rgb8_lzw_pred_orientation6.tif', maxSide: 16);
      expect((small.width, small.height), (8, 16));
    });

    test('scaled down to the long side asked, each pixel the mean of those it covers', () {
      final pixels = decode('rgb8_lzw_pred.tif', maxSide: 32);
      expect((pixels.width, pixels.height), (32, 16));
      // Each pixel of the result covers 2 x 2 pixels of the file
      expect(
        largestDifference(pixels, (x, y) {
          return [
            for (var c = 0; c < 3; c++)
              ((sample(2 * x, 2 * y, c, 8) +
                          sample(2 * x + 1, 2 * y, c, 8) +
                          sample(2 * x, 2 * y + 1, c, 8) +
                          sample(2 * x + 1, 2 * y + 1, c, 8)) +
                      2) ~/
                  4,
            255,
          ];
        }),
        0,
      );
    });
  });

  group('the files it refuses rather than show a wrong picture', () {
    for (final (name, why) in [
      ('rgb8_lzw_damaged.tif', 'an LZW strip cut half way'),
      ('float32_pred3.tif', 'the floating point predictor'),
      ('old_jpeg.tif', 'the JPEG of TIFF 6.0'),
    ]) {
      test('$name: $why', () {
        expect(() => decode(name), throwsA(isA<TiffDecodeException>()));
      });
    }

    test('a file cut short, and what is no TIFF', () {
      final whole = fixture('rgb8_deflate_pred.tif');
      expect(
        () => decodeTiffPixels(
          Uint8List.sublistView(whole, 0, whole.length - 200),
          maxSide: 100,
          maxDecodedBytes: 1 << 20,
        ),
        throwsA(isA<TiffDecodeException>()),
      );
      expect(
        () => decodeTiffPixels(Uint8List.fromList(List.filled(64, 7)), maxSide: 100, maxDecodedBytes: 1 << 20),
        throwsA(isA<TiffDecodeException>()),
      );
    });

    test('an image of more samples than the device decodes, before it is decoded', () {
      expect(
        () => decodeTiffPixels(fixture('rgb16_lzw_pred.tif'), maxSide: 100, maxDecodedBytes: 64 * 32 * 6 - 1),
        throwsA(isA<TiffDecodeException>().having((error) => error.reason, 'reason', contains('64 x 32'))),
      );
    });
  });

  group('the pieces', () {
    test('the eight orientations turn as the image package turns them, the half turn of an odd height included', () {
      final source = img.Image(width: 5, height: 3);
      for (final pixel in source) {
        pixel
          ..r = pixel.x * 40
          ..g = pixel.y * 80
          ..b = 7
          ..a = 255;
      }
      final pixels = TiffPixels(Uint8List.fromList(source.getBytes(order: img.ChannelOrder.rgba)), 5, 3);
      for (var orientation = 1; orientation <= 8; orientation++) {
        final turned = uprightTiffPixels(pixels, orientation);
        // 3 is a half turn: the image package's flip of both directions leaves the middle row of an odd height as it was
        final expected = orientation == 3
            ? img.copyRotate(source, angle: 180)
            : img.bakeOrientation(img.Image.from(source)..exif.imageIfd.orientation = orientation);
        expect((turned.width, turned.height), (expected.width, expected.height), reason: '$orientation');
        expect(turned.rgba, expected.getBytes(order: img.ChannelOrder.rgba), reason: '$orientation');
      }
    });

    test('the horizontal predictor of 16 bit samples wraps modulo their size, in either byte order', () {
      for (final endian in [Endian.little, Endian.big]) {
        final data = ByteData(8)
          ..setUint16(0, 0xFFF0, endian)
          ..setUint16(2, 0x0020, endian)
          ..setUint16(4, 0x0001, endian)
          ..setUint16(6, 0xFFFF, endian);
        final bytes = data.buffer.asUint8List();
        undoHorizontalPredictor(bytes, width: 4, rows: 1, samplesPerPixel: 1, bytesPerSample: 2, endian: endian);
        expect([for (var i = 0; i < 4; i++) data.getUint16(i * 2, endian)], [0xFFF0, 0x0010, 0x0011, 0x0010]);
      }
    });

    test('LZW stops at the length asked, and refuses a code it cannot hold', () {
      // 9 bit codes: clear, 'A', 'B', 258 ('AB'), end
      final stream = Uint8List.fromList(const [0x80, 0x10, 0x48, 0x50, 0x28, 0x08]);
      expect(lzwDecode(stream, 4), [0x41, 0x42, 0x41, 0x42]);
      expect(lzwDecode(stream, 2), [0x41, 0x42]);
      // clear, 'A', then 300 (not defined yet)
      expect(
        () => lzwDecode(Uint8List.fromList(const [0x80, 0x10, 0x65, 0x80]), 8),
        throwsA(isA<TiffDecodeException>()),
      );
    });
  });
}
