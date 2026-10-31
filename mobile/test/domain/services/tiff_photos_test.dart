import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/services/tiff_photos.dart';

/// A TIFF [width] by [height], red on its left half and blue on its right, as the image package writes it
Uint8List tiffOf(int width, int height, {int? orientation}) {
  final image = img.Image(width: width, height: height);
  for (final pixel in image) {
    pixel
      ..r = pixel.x < width / 2 ? 255 : 0
      ..g = 0
      ..b = pixel.x < width / 2 ? 0 : 255;
  }
  if (orientation != null) {
    image.exif.imageIfd.orientation = orientation;
  }
  return img.encodeTiff(image);
}

void main() {
  group('the choice of the decoder on a device without TIFF decoder', () {
    PhotoDecodePath pathOf(String name, {String? mimeType, required bool fromServer}) =>
        photoDecodePath(name, mimeType: mimeType, fromServer: fromServer, deviceDecodesTiff: false);

    test('a TIFF of the server shows as the server makes it, not from its original', () {
      expect(pathOf('scan.tif', fromServer: true), PhotoDecodePath.serverPreview);
      expect(pathOf('SCAN.TIFF', fromServer: true), PhotoDecodePath.serverPreview);
      // A name without the extension, the type of the server telling
      expect(pathOf('scan', mimeType: 'image/tiff', fromServer: true), PhotoDecodePath.serverPreview);
    });

    test('a TIFF of the device or of a share goes to the Dart decoder', () {
      expect(pathOf('scan.tif', fromServer: false), PhotoDecodePath.dartTiff);
      expect(pathOf('Archive/plan.TIF', fromServer: false), PhotoDecodePath.dartTiff);
      expect(pathOf('plan', mimeType: 'image/x-tiff; charset=binary', fromServer: false), PhotoDecodePath.dartTiff);
    });

    test('a JPEG, a PNG, a HEIF and a video name are unchanged', () {
      for (final name in ['beach.jpg', 'beach.JPEG', 'map.png', 'IMG_1.HEIC', 'clip.mp4', 'tiff.jpg', 'a.tif.jpg']) {
        expect(pathOf(name, fromServer: true), PhotoDecodePath.platform, reason: name);
        expect(pathOf(name, fromServer: false), PhotoDecodePath.platform, reason: name);
      }
    });

    test('a camera raw file built on TIFF is unchanged, even typed image/tiff', () {
      for (final name in ['DSC_0001.NEF', 'IMG_2.CR2', 'photo.dng', 'A7.arw', 'P1.ORF', 'X.raf']) {
        expect(pathOf(name, fromServer: true), PhotoDecodePath.platform, reason: name);
        expect(pathOf(name, mimeType: 'image/tiff', fromServer: false), PhotoDecodePath.platform, reason: name);
      }
    });

    test('a device that decodes TIFF itself keeps its decoder', () {
      expect(
        photoDecodePath('scan.tif', fromServer: true, deviceDecodesTiff: true),
        PhotoDecodePath.platform,
      );
      expect(
        photoDecodePath('scan.tif', fromServer: false, deviceDecodesTiff: true),
        PhotoDecodePath.platform,
      );
    });

    test('Android has no TIFF decoder, iOS and the computers have theirs', () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(thisDeviceDecodesTiff, isFalse);
      expect(photoDecodePath('scan.tif', fromServer: true), PhotoDecodePath.serverPreview);
      for (final platform in [
        TargetPlatform.iOS,
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(thisDeviceDecodesTiff, isTrue, reason: '$platform');
        expect(photoDecodePath('scan.tif', fromServer: false), PhotoDecodePath.platform, reason: '$platform');
      }
    });
  });

  group('names, types and signatures', () {
    test('the TIFF names, types and first bytes', () {
      expect(isTiffName('a.tif'), isTrue);
      expect(isTiffName('a.tiff'), isTrue);
      expect(isTiffName('a.tifff'), isFalse);
      expect(isTiffMimeType('image/tiff'), isTrue);
      expect(isTiffMimeType('IMAGE/TIF'), isTrue);
      expect(isTiffMimeType('image/jpeg'), isFalse);
      expect(isTiffMimeType(null), isFalse);
      expect(hasTiffSignature(Uint8List.fromList('II*\u0000'.codeUnits)), isTrue);
      expect(hasTiffSignature(Uint8List.fromList('MM\u0000*'.codeUnits)), isTrue);
      expect(hasTiffSignature(Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0])), isFalse);
      expect(hasTiffSignature(tiffOf(4, 4)), isTrue);
    });
  });

  group('the Dart decoder', () {
    test('decodes a TIFF to RGBA pixels, scaled down to the long side asked', () async {
      final small = decodeTiffSync(tiffOf(64, 32), maxSide: 4096);
      expect((small.width, small.height), (64, 32));
      expect(small.rgba.length, 64 * 32 * 4);
      // Red on the left, blue on the right, opaque
      expect(small.rgba.sublist(0, 4), [255, 0, 0, 255]);
      expect(small.rgba.sublist((63) * 4, 64 * 4), [0, 0, 255, 255]);

      final scaled = await decodeTiff(tiffOf(400, 100), maxSide: 100);
      expect((scaled.width, scaled.height), (100, 25));
    });

    test('turns the photo upright as its orientation tag says', () {
      // 6: the camera was turned a quarter clockwise, the photo shows taller than wide
      final turned = decodeTiffSync(tiffOf(64, 32, orientation: 6), maxSide: 4096);
      expect((turned.width, turned.height), (32, 64));
    });

    test('refuses what is no TIFF, and a TIFF larger than it decodes, without decoding it', () async {
      expect(
        () => decodeTiffSync(Uint8List.fromList(List.filled(64, 7)), maxSide: 100),
        throwsA(isA<TiffDecodeException>()),
      );
      // A header that says 20000 x 20000 pixels of 16 bit RGB: 2.4 GB of samples
      final huge = img.Image(width: 1, height: 1);
      final header = img.encodeTiff(huge);
      final bytes = Uint8List.fromList(header);
      final view = ByteData.sublistView(bytes);
      // Its width (256), height (257) and bits per sample (258) entries rewritten in the first IFD
      final endian = bytes[0] == 0x4D ? Endian.big : Endian.little;
      final ifd = view.getUint32(4, endian);
      final count = view.getUint16(ifd, endian);
      for (var index = 0; index < count; index++) {
        final entry = ifd + 2 + index * 12;
        final tag = view.getUint16(entry, endian);
        final type = view.getUint16(entry + 2, endian);
        if (tag == 256 || tag == 257) {
          if (type == 3) {
            view.setUint16(entry + 8, 20000, endian);
          } else {
            view.setUint32(entry + 8, 20000, endian);
          }
        }
        if (tag == 258 && type == 3) {
          view.setUint16(entry + 8, 16, endian);
        }
      }
      expect(
        () => decodeTiffSync(bytes, maxSide: 100),
        throwsA(isA<TiffDecodeException>().having((error) => error.reason, 'reason', contains('20000 x 20000'))),
      );
      await expectLater(decodeTiff(bytes, maxSide: 100), throwsA(isA<TiffDecodeException>()));
    });
  });

  group('the failures of the session', () {
    setUp(UndecodablePhotos.instance.clear);

    test('remembers a failure until cleared, the oldest dropped beyond its size', () {
      final photos = UndecodablePhotos.instance;
      expect(photos.failureOf('share:/a.tif'), isNull);
      photos.remember('share:/a.tif', const TiffDecodeException('broken'));
      expect(photos.failureOf('share:/a.tif'), isA<TiffDecodeException>());
      for (var index = 0; index < UndecodablePhotos.maxEntries; index++) {
        photos.remember('share:/$index.tif', const TiffDecodeException('broken'));
      }
      expect(photos.failureOf('share:/a.tif'), isNull);
      expect(photos.failureOf('share:/0.tif'), isNotNull);
      photos.clear();
      expect(photos.failureOf('share:/0.tif'), isNull);
    });
  });
}
