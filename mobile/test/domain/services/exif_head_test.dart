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
}
