import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/exif_head.dart';

import '../../fixtures/raw/insta360.stub.dart';

void main() {
  group('parseExifHead', () {
    test('reads the make, the model, the MakerNote and the serial of IFD0 and the Exif IFD, in both byte orders', () {
      for (final (bigEndian, app0) in [(false, false), (true, false), (false, true)]) {
        final head = parseExifHead(insta360PhotoHead(serial: x3Serial, bigEndian: bigEndian, app0: app0));

        expect(
          head,
          const ExifHead(make: 'Arashi Vision', model: x3Model, serial: x3Serial, makerNote: x3MakerNote),
          reason: 'big endian $bigEndian, JFIF $app0',
        );
      }
    });

    test('reads the pixel size, LONG or SHORT', () {
      for (final (bigEndian, shortPixels) in [(false, false), (true, false), (false, true), (true, true)]) {
        final head = parseExifHead(
          insta360PhotoHead(
            make: 'GoPro',
            model: 'GoPro Max',
            pixelWidth: shortPixels ? 5760 : 15520,
            pixelHeight: shortPixels ? 2880 : 7760,
            shortPixels: shortPixels,
            bigEndian: bigEndian,
          ),
        )!;

        expect(head.make, 'GoPro');
        expect(head.model, 'GoPro Max');
        expect(
          (head.pixelWidth, head.pixelHeight),
          shortPixels ? (5760, 2880) : (15520, 7760),
          reason: 'big endian $bigEndian, SHORT $shortPixels',
        );
      }
    });

    test('gives null for each tag the head does not have', () {
      final head = parseExifHead(insta360PhotoHead(model: null, makerNote: ''))!;

      expect(head, const ExifHead(make: 'Arashi Vision'));
    });

    test('has nothing for a file that is not a JPEG, or whose EXIF is not in the head', () {
      expect(parseExifHead(Uint8List(0)), isNull);
      expect(parseExifHead(Uint8List.fromList(List.filled(4096, 0))), isNull);
      expect(parseExifHead(Uint8List.fromList(jpegStub)), isNull);
      // A JPEG whose scan starts before any EXIF
      expect(parseExifHead(Uint8List.fromList([0xff, 0xd8, 0xff, 0xda, 0, 2])), isNull);
      // Cut before the values: the tags that point past the head are null
      final cut = parseExifHead(Uint8List.sublistView(insta360PhotoHead(), 0, 100));
      expect(cut, const ExifHead());
    });
  });

  group('parseExifThumbnail', () {
    // A JPEG head with EXIF: IFD0 with the make, then IFD1 pointing at [thumbnail], little or big endian
    Uint8List head(List<int> thumbnail, {bool bigEndian = false, bool withIfd1 = true}) {
      List<int> u16(int value) => bigEndian ? [value >> 8 & 0xff, value & 0xff] : [value & 0xff, value >> 8 & 0xff];
      List<int> u32(int value) {
        final bytes = [value & 0xff, value >> 8 & 0xff, value >> 16 & 0xff, value >> 24 & 0xff];
        return bigEndian ? bytes.reversed.toList() : bytes;
      }

      List<int> entry(int tag, int type, int count, List<int> value) => [
        ...u16(tag),
        ...u16(type),
        ...u32(count),
        ...value,
      ];
      // TIFF header (8), IFD0 at 8: 1 entry (2 + 12 + 4), IFD1 at 26: 2 entries (2 + 24 + 4), thumbnail at 56
      const ifd1 = 26;
      const thumbnailAt = 56;
      final tiff = [
        ...(bigEndian ? 'MM'.codeUnits : 'II'.codeUnits),
        ...u16(42),
        ...u32(8),
        ...u16(1),
        ...entry(0x010f, 2, 4, 'DJI\x00'.codeUnits),
        ...u32(withIfd1 ? ifd1 : 0),
        ...u16(2),
        ...entry(0x0201, 4, 1, u32(thumbnailAt)),
        ...entry(0x0202, 4, 1, u32(thumbnail.length)),
        ...u32(0),
        ...thumbnail,
      ];
      final app1 = [...'Exif'.codeUnits, 0, 0, ...tiff];
      final length = app1.length + 2;
      return Uint8List.fromList([0xff, 0xd8, 0xff, 0xe1, length >> 8, length & 0xff, ...app1, 0xff, 0xda]);
    }

    final jpeg = [0xff, 0xd8, ...List.filled(40, 7), 0xff, 0xd9];

    test('gives the JPEG of IFD1, in both byte orders', () {
      expect(parseExifThumbnail(head(jpeg)), jpeg);
      expect(parseExifThumbnail(head(jpeg, bigEndian: true)), jpeg);
      expect(parseExifHead(head(jpeg))?.make, 'DJI');
    });

    test('gives null without IFD1, for a thumbnail past the head, and for no JPEG', () {
      expect(parseExifThumbnail(head(jpeg, withIfd1: false)), isNull);
      final whole = head(jpeg);
      expect(parseExifThumbnail(Uint8List.sublistView(whole, 0, whole.length - 20)), isNull);
      expect(parseExifThumbnail(head([1, 2, 3, 4, 5, 6])), isNull);
      expect(parseExifThumbnail(Uint8List.fromList([0x89, 0x50, 0x4e, 0x47])), isNull);
    });
  });
}
