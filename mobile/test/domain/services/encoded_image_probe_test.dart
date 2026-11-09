// The probe that keeps the formats the engine does not decode itself away from it on Android (crash M1 of the Meta
// Quest store, 8 November 2026). The table of first bytes is the one of EngineImageFormatsTest.kt, so that the Dart
// probe and the Kotlin fallback of RemoteImagesImpl agree byte for byte.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/encoded_image_probe.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';

List<int> _ascii(String text) => ascii.encode(text);

/// An ISO BMFF file type box: its size, ftyp, the [major] brand, a minor version and the [compatible] brands
List<int> _ftyp(String major, List<String> compatible) {
  final size = ByteData(4)..setUint32(0, 16 + 4 * compatible.length);
  return [
    ...size.buffer.asUint8List(),
    ..._ascii('ftyp$major'),
    ...[0, 0, 0, 0],
    for (final brand in compatible) ..._ascii(brand),
    // The next box, as a file goes on
    ...[0, 0, 0, 0x24],
    ..._ascii('meta'),
  ];
}

/// The first bytes of each kind of file, and what the probe tells of them
final probeTable = <(String, List<int>, EncodedImageKind)>[
  ('JPEG JFIF', [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, ..._ascii('JFIF'), 0], EncodedImageKind.jpeg),
  ('JPEG Exif', [0xFF, 0xD8, 0xFF, 0xE1, 0x12, 0x34, ..._ascii('Exif'), 0, 0], EncodedImageKind.jpeg),
  ('PNG', [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, ..._ascii('IHDR')], EncodedImageKind.png),
  ('GIF87a', [..._ascii('GIF87a'), 1, 0, 1, 0, 0x80, 0, 0], EncodedImageKind.gif),
  ('GIF89a', [..._ascii('GIF89a'), 1, 0, 1, 0, 0x80, 0, 0], EncodedImageKind.gif),
  ('WebP lossy', [..._ascii('RIFF'), 0x24, 0, 0, 0, ..._ascii('WEBPVP8 '), 0x18, 0, 0, 0], EncodedImageKind.webp),
  ('WebP lossless', [..._ascii('RIFF'), 0x24, 0, 0, 0, ..._ascii('WEBPVP8L'), 0x18, 0, 0, 0], EncodedImageKind.webp),
  ('WebP extended', [..._ascii('RIFF'), 0x24, 0, 0, 0, ..._ascii('WEBPVP8X'), 0x0A, 0, 0, 0], EncodedImageKind.webp),
  ('BMP', [..._ascii('BM'), 0x36, 0, 0, 0, 0, 0, 0, 0, 0x36, 0, 0, 0, 40, 0, 0, 0, 1, 0, 0, 0], EncodedImageKind.bmp),
  ('ICO', [0, 0, 1, 0, 1, 0, 16, 16, 0, 0, 1, 0, 32, 0], EncodedImageKind.ico),
  ('CUR', [0, 0, 2, 0, 1, 0, 32, 32, 0, 0, 1, 0, 1, 0], EncodedImageKind.ico),
  ('HEIC of an iPhone', _ftyp('heic', ['mif1', 'heic']), EncodedImageKind.heif),
  (
    'HEIC spatial photo of an iPhone',
    _ftyp('heic', ['mif1', 'MiHE', 'MiPr', 'miaf', 'MiHB', 'heic']),
    EncodedImageKind.heif,
  ),
  ('HEIC heix', _ftyp('heix', ['mif1', 'heix']), EncodedImageKind.heif),
  ('HEIF mif1 with heic', _ftyp('mif1', ['mif1', 'heic']), EncodedImageKind.heif),
  ('HEIF sequence msf1', _ftyp('msf1', ['msf1', 'hevc']), EncodedImageKind.heif),
  ('AVIF', _ftyp('avif', ['mif1', 'miaf', 'MA1B']), EncodedImageKind.avif),
  ('AVIF sequence', _ftyp('avis', ['avis', 'msf1', 'miaf', 'MA1B']), EncodedImageKind.avif),
  ('AVIF mif1 with avif', _ftyp('mif1', ['mif1', 'avif', 'miaf']), EncodedImageKind.avif),
  ('Canon CR3', _ftyp('crx ', ['crx ', 'isom']), EncodedImageKind.raw),
  ('MP4 video', _ftyp('isom', ['isom', 'iso2', 'avc1', 'mp41']), EncodedImageKind.notImage),
  ('QuickTime video', _ftyp('qt  ', ['qt  ']), EncodedImageKind.notImage),
  ('TIFF little endian', [..._ascii('II'), 0x2A, 0, 8, 0, 0, 0, 0x10, 0], EncodedImageKind.tiff),
  ('TIFF big endian', [..._ascii('MM'), 0, 0x2A, 0, 0, 0, 8, 0, 0x10], EncodedImageKind.tiff),
  ('DNG', [..._ascii('II'), 0x2A, 0, 8, 0, 0, 0, 0x1C, 0, 0xFE, 0], EncodedImageKind.tiff),
  ('Canon CR2', [..._ascii('II'), 0x2A, 0, 0x10, 0, 0, 0, ..._ascii('CR'), 2, 0], EncodedImageKind.tiff),
  ('Olympus ORF', [..._ascii('IIRO'), 8, 0, 0, 0, 0x14, 0], EncodedImageKind.raw),
  ('Panasonic RW2', [..._ascii('IIU'), 0, 0x18, 0, 0, 0, 0x88, 0xE7], EncodedImageKind.raw),
  ('Fuji RAF', _ascii('FUJIFILMCCD-RAW 0201FF383501'), EncodedImageKind.raw),
  ('Canon CRW', [..._ascii('II'), 0x1A, 0, 0, 0, ..._ascii('HEAPCCDR'), 1, 0], EncodedImageKind.raw),
  ('Sigma X3F', [..._ascii('FOVb'), 0, 0, 2, 0, 0x10, 0], EncodedImageKind.raw),
  ('JPEG XL bare', [0xFF, 0x0A, 0xFA, 0x7F, 0x01, 0x90], EncodedImageKind.jxl),
  (
    'JPEG XL container',
    [0, 0, 0, 0x0C, ..._ascii('JXL '), 0x0D, 0x0A, 0x87, 0x0A, 0, 0, 0, 0x14, ..._ascii('ftypjxl ')],
    EncodedImageKind.jxl,
  ),
  ('SVG', _ascii('<svg xmlns="http://www.w3.org/2000/svg" width="10"/>'), EncodedImageKind.text),
  ('SVG after a byte order mark', [0xEF, 0xBB, 0xBF, ..._ascii('<?xml version="1.0"?><svg/>')], EncodedImageKind.text),
  ('HTML page', _ascii('\r\n  <!DOCTYPE html><html><body>Not found</body></html>'), EncodedImageKind.text),
  ('JSON', _ascii('{"message":"Asset not found","statusCode":404}'), EncodedImageKind.text),
  ('empty', <int>[], EncodedImageKind.empty),
  ('one byte of a JPEG', [0xFF], EncodedImageKind.unknown),
  ('two bytes of a JPEG', [0xFF, 0xD8], EncodedImageKind.unknown),
  ('three bytes of a PNG', [0x89, 0x50, 0x4E], EncodedImageKind.unknown),
  ('BM and no BMP header', _ascii('BMW of my neighbour, a photo'), EncodedImageKind.unknown),
  ('an icon of no image', [0, 0, 1, 0, 0, 0, 16, 16], EncodedImageKind.unknown),
  ('WBMP', [0, 0, 0x40, 0x40, 0xFF, 0xFF], EncodedImageKind.unknown),
  ('random bytes', [0x13, 0x37, 0xC0, 0xDE, 0x42, 0x99, 0x01, 0x7E, 0x55, 0xAA, 0x10, 0x20], EncodedImageKind.unknown),
];

void main() {
  group('the kind of an encoded image, by its first bytes', () {
    for (final (name, bytes, kind) in probeTable) {
      test(name, () {
        expect(sniffEncodedImage(Uint8List.fromList(bytes)), kind);
      });
    }

    test('reads only the first 64 bytes, whatever follows', () {
      final heic = Uint8List.fromList([..._ftyp('heic', ['mif1', 'heic']), ...List.filled(1 << 16, 0x3C)]);
      expect(sniffEncodedImage(heic), EncodedImageKind.heif);

      // A blank page longer than the probe tells nothing
      expect(sniffEncodedImage(Uint8List.fromList([...List.filled(100, 0x20), 0x3C])), EncodedImageKind.unknown);
    });

    test('the brands of a file type box stop at its end', () {
      // A box of 16 bytes (no compatible brand) followed by a box whose type is avif: not an AVIF
      final bytes = Uint8List.fromList([0, 0, 0, 16, ..._ascii('ftypisom'), 0, 0, 2, 0, 0, 0, 0, 8, ..._ascii('avif')]);
      expect(sniffEncodedImage(bytes), EncodedImageKind.notImage);
    });

    test('random buffers are never told as a format of the engine unless they start as one', () {
      // A fixed sequence of pseudo random buffers: the same on every run
      var seed = 20261108;
      int next() => seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      for (var i = 0; i < 2000; i++) {
        final bytes = Uint8List.fromList([for (var j = 0; j < 1 + i % 64; j++) next() >> 16 & 0xFF]);
        final kind = sniffEncodedImage(bytes);
        if (engineDecodesKind(kind)) {
          final starts = switch (kind) {
            EncodedImageKind.jpeg => bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF,
            EncodedImageKind.png => bytes[0] == 0x89 && bytes[1] == 0x50,
            EncodedImageKind.gif => bytes[0] == 0x47 && bytes[1] == 0x49,
            EncodedImageKind.webp => bytes[0] == 0x52 && bytes[8] == 0x57,
            EncodedImageKind.bmp => bytes[0] == 0x42 && bytes[1] == 0x4D,
            EncodedImageKind.ico => bytes[0] == 0 && bytes[1] == 0 && bytes[3] == 0,
            _ => false,
          };
          expect(starts, isTrue, reason: '$bytes told as $kind');
        }
      }
    });
  });

  group('the formats the engine decodes itself', () {
    test('are those of its own codecs, nothing else', () {
      expect(EncodedImageKind.values.where(engineDecodesKind).toSet(), {
        EncodedImageKind.jpeg,
        EncodedImageKind.png,
        EncodedImageKind.gif,
        EncodedImageKind.webp,
        EncodedImageKind.bmp,
        EncodedImageKind.ico,
      });
    });
  });

  group('where an encoded image is decoded', () {
    EncodedImageRoute onAndroid(EncodedImageKind kind, {String? name, String? mimeType}) =>
        encodedImageRoute(kind, name: name, mimeType: mimeType, isAndroid: true);

    test('on Android: the engine for its formats, the native decoder for the others, text and videos refused', () {
      for (final kind in [
        EncodedImageKind.jpeg,
        EncodedImageKind.png,
        EncodedImageKind.gif,
        EncodedImageKind.webp,
        EncodedImageKind.bmp,
        EncodedImageKind.ico,
      ]) {
        expect(onAndroid(kind), EncodedImageRoute.engine, reason: kind.name);
      }
      for (final kind in [
        EncodedImageKind.heif,
        EncodedImageKind.avif,
        EncodedImageKind.raw,
        EncodedImageKind.tiff,
        EncodedImageKind.jxl,
        EncodedImageKind.unknown,
      ]) {
        expect(onAndroid(kind), EncodedImageRoute.native, reason: kind.name);
      }
      for (final kind in [EncodedImageKind.text, EncodedImageKind.notImage, EncodedImageKind.empty]) {
        expect(onAndroid(kind), EncodedImageRoute.refuse, reason: kind.name);
      }
    });

    test('on Android, a TIFF goes to the Dart decoder when its name or type says TIFF, as photoDecodePath says', () {
      final cases = <(String?, String?)>[
        ('scan.tif', null),
        ('plan.TIFF', null),
        ('scan_0001', 'image/tiff'),
        ('scan_0001', null),
        ('DSC_0001.dng', null),
        ('DSC_0001.NEF', 'image/tiff'),
        ('IMG_0001.CR2', null),
        ('photo.ARW', null),
        (null, 'image/tiff'),
        (null, null),
      ];
      for (final (name, mimeType) in cases) {
        final dartTiff =
            (name != null || mimeType != null) &&
            photoDecodePath(name ?? '', mimeType: mimeType, fromServer: false, platformKeepsTiffPath: false) ==
                PhotoDecodePath.dartTiff;
        expect(
          onAndroid(EncodedImageKind.tiff, name: name, mimeType: mimeType),
          dartTiff ? EncodedImageRoute.dartTiff : EncodedImageRoute.native,
          reason: '$name $mimeType',
        );
      }
      expect(onAndroid(EncodedImageKind.tiff, name: 'scan.tif'), EncodedImageRoute.dartTiff);
      expect(onAndroid(EncodedImageKind.tiff, name: 'DSC_0001.dng'), EncodedImageRoute.native);
      // The name of a TIFF on bytes of another kind changes nothing
      expect(onAndroid(EncodedImageKind.heif, name: 'scan.tif'), EncodedImageRoute.native);
      expect(onAndroid(EncodedImageKind.jpeg, name: 'scan.tif'), EncodedImageRoute.engine);
    });

    test('off Android, the engine for every buffer, as before', () {
      for (final kind in EncodedImageKind.values) {
        final route = encodedImageRoute(kind, name: 'scan.tif', isAndroid: false);
        expect(route, EncodedImageRoute.engine, reason: kind.name);
      }
    });

    test('the platform of the app decides when no platform is given', () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          encodedImageRoute(EncodedImageKind.heif),
          platform == TargetPlatform.android ? EncodedImageRoute.native : EncodedImageRoute.engine,
          reason: platform.name,
        );
        expect(encodedImageRoute(EncodedImageKind.jpeg), EncodedImageRoute.engine, reason: platform.name);
      }
    });
  });

  test('a refused image tells its kind and its size', () {
    expect(
      const UnsupportedEncodedImage(EncodedImageKind.heif, 1234).toString(),
      'UnsupportedEncodedImage: heif, 1234 bytes, not decoded on this device',
    );
  });
}
