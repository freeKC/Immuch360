import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/engine_picture.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';

import '../../../test_utils/heif_builder.dart';
import 'codec_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pixels the engine decodes', () {
    test('transparency put on black, every pixel opaque', () async {
      final decoded = await decodeWithEngine(codecFixture('transparent.png'), windows: false);
      expect((decoded.width, decoded.height), (32, 16));
      for (var alpha = 3; alpha < decoded.rgba.length; alpha += 4) {
        expect(decoded.rgba[alpha], 255);
      }
      final areas = codecExpected['png'] as Map<String, dynamic>;
      for (final MapEntry(key: name, value: area as Map<String, dynamic>) in areas.entries) {
        final found = rgbAt(decoded.rgba, decoded.width, area['x'] as int, area['y'] as int);
        expect(near(found, colourOf(area['onBlack']), 1), isTrue, reason: '$name: $found');
      }
    });

    test('no profile follows them, even from a PNG that has one, even on Windows', () async {
      for (final windows in [false, true]) {
        final decoded = await decodeWithEngine(codecFixture('display_p3.png'), windows: windows);
        expect(decoded.iccProfile, isNull, reason: 'windows: $windows');
        final out = const DartSbsCodec().encodeSbs(
          SbsPicture(width: decoded.width, height: decoded.height, rgba: decoded.rgba),
          SbsEncodeOptions(quality: 92, iccProfile: decoded.iccProfile),
        );
        expect(JpegHeader.read(out).segments.where((segment) => segment.marker == 0xE2), isEmpty);
      }
    });

    test('a photo wider than the cap decoded straight to it', () async {
      final decoded = await decodeWithEngine(codecFixture('transparent.png'), maxWidth: 16, windows: false);
      expect((decoded.width, decoded.height), (16, 8));
      expect(decoded.rgba, hasLength(16 * 8 * 4));
    });

    test('bytes the engine cannot decode are a codec error', () async {
      await expectLater(
        decodeWithEngine(Uint8List.fromList(List.filled(64, 7)), windows: false),
        throwsA(isA<SbsCodecException>()),
      );
    });
  });

  group('the profile of a HEIC', () {
    test('read from the colr box of its primary item, byte for byte', () {
      expect(heifIccProfile(codecFixture('display_p3.heic')), codecFixture('display_p3.icc'));
    });

    test('of the primary item, when another item carries its own', () {
      // As in a HEIC of an iPhone: a thumbnail, a gain map or a depth image may carry a colr box of its own, and come
      // first in ipco
      final heif = HeifBuilder(
        items: const [
          HeifItem(1, 'hvc1', hidden: true, properties: [1]),
          HeifItem(2, 'hvc1', properties: [2]),
        ],
        properties: [
          heifBox('colr', [...ascii.encode('prof'), ...ascii.encode('THUMB')]),
          heifBox('colr', [...ascii.encode('prof'), ...ascii.encode('PRIMARY')]),
        ],
        primaryItemId: 2,
      ).build();

      expect(heifIccProfile(heif), ascii.encode('PRIMARY'));
    });

    test('kept on Windows only, where the system decoder converts nothing', () {
      final heic = codecFixture('display_p3.heic');
      expect(enginePixelsProfile(heic, windows: true), codecFixture('display_p3.icc'));
      expect(enginePixelsProfile(heic, windows: false), isNull, reason: 'Core Graphics gives sRGB on macOS');
      expect(enginePixelsProfile(codecFixture('display_p3.png'), windows: true), isNull);
      expect(enginePixelsProfile(codecFixture('display_p3.jpg'), windows: true), isNull);
    });

    test('nothing for a file that is not one, or is cut short', () {
      expect(heifIccProfile(codecFixture('display_p3.jpg')), isNull);
      final heic = codecFixture('display_p3.heic');
      expect(heifIccProfile(Uint8List.sublistView(heic, 0, 200)), isNull);
      expect(heifIccProfile(Uint8List(0)), isNull);
    });

    // The question of design-final 2026-10-26, section 2.3, point 4, asked of the real decoder of Windows: are the
    // pixels of a Display P3 HEIC given in sRGB? Measured "no" on the PC of FreeKC (Microsoft HEIF and HEVC
    // extensions); the runners of GitHub have no HEIC decoder, so there the test says so and stops.
    test('on Windows, the system decoder gives a Display P3 HEIC in its own values, not in sRGB', () async {
      final SbsDecoded decoded;
      try {
        decoded = await decodeWithEngine(codecFixture('display_p3.heic'));
      } on SbsCodecException catch (error) {
        markTestSkipped('No HEIC decoder on this Windows (the HEIF and HEVC extensions): $error');
        return;
      }
      final patches = codecExpected['p3Patches'] as Map<String, dynamic>;
      final red = rgbAt(decoded.rgba, decoded.width, 32, 16);
      final grey = rgbAt(decoded.rgba, decoded.width, 10, 16);
      expect(near(grey, colourOf(patches['grey']['p3']), 3), isTrue, reason: 'grey $grey');
      expect(near(red, colourOf(patches['red']['p3']), 4), isTrue, reason: 'red $red, Display P3 values expected');
      expect(near(red, colourOf(patches['red']['srgb']), 4), isFalse, reason: 'red $red is sRGB');
      expect(decoded.iccProfile, codecFixture('display_p3.icc'));
    }, skip: Platform.isWindows ? false : 'The decoder of the system for HEIC is measured on Windows only');
  });
}
