import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/exif_minimal.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

import 'codec_fixtures.dart';

/// The pair of [eye]: the eye twice, side by side, as the engine builds it (the right eye is a copy here)
SbsPicture pairOf(SbsDecoded eye) {
  final width = eye.width;
  final rgba = Uint8List(width * 2 * eye.height * 4);
  for (var y = 0; y < eye.height; y++) {
    final row = Uint8List.sublistView(eye.rgba, y * width * 4, (y + 1) * width * 4);
    rgba
      ..setAll(y * width * 8, row)
      ..setAll(y * width * 8 + width * 4, row);
  }
  return SbsPicture(width: width * 2, height: eye.height, rgba: rgba);
}

/// [decoded] as a package:image picture, to compare with its own turns
img.Image imageOf(SbsDecoded decoded) => img.Image.fromBytes(
  width: decoded.width,
  height: decoded.height,
  bytes: Uint8List.fromList(decoded.rgba).buffer,
  numChannels: 4,
);

void main() {
  const codec = DartSbsCodec();
  final orientation = codecExpected['orientation'] as Map<String, dynamic>;
  final quarters = (orientation['quarters'] as Map<String, dynamic>).map(
    (key, value) => MapEntry(key, colourOf(value)),
  );

  /// The colours at the middle of the four quarters of [decoded], by their names
  Map<String, List<int>> quartersOf(SbsDecoded decoded) {
    final w = decoded.width;
    final h = decoded.height;
    return {
      'topLeft': rgbAt(decoded.rgba, w, w ~/ 4, h ~/ 4),
      'topRight': rgbAt(decoded.rgba, w, 3 * w ~/ 4, h ~/ 4),
      'bottomLeft': rgbAt(decoded.rgba, w, w ~/ 4, 3 * h ~/ 4),
      'bottomRight': rgbAt(decoded.rgba, w, 3 * w ~/ 4, 3 * h ~/ 4),
    };
  }

  void expectQuarters(SbsDecoded decoded, Map<String, String> layout, {required String reason}) {
    final found = quartersOf(decoded);
    for (final MapEntry(key: where, value: name) in layout.entries) {
      expect(near(found[where]!, quarters[name]!, 6), isTrue, reason: '$reason: $where is ${found[where]}, not $name');
    }
  }

  const upright = {
    'topLeft': 'topLeft',
    'topRight': 'topRight',
    'bottomLeft': 'bottomLeft',
    'bottomRight': 'bottomRight',
  };

  group('orientation', () {
    test('the decoder gives the pixels as stored, whatever the EXIF says', () {
      for (var n = 1; n <= 8; n++) {
        final decoded = codec.decodeJpeg(codecFixture('orientation_$n.jpg'));
        expect((decoded.width, decoded.height), n >= 5 ? (16, 32) : (32, 16), reason: 'orientation $n');
        expect(decoded.rgba.length, decoded.width * decoded.height * 4);
      }
    });

    test('each of the eight orientations turns the stored picture upright', () {
      for (var n = 1; n <= 8; n++) {
        final bytes = codecFixture('orientation_$n.jpg');
        final shown = orientDecoded(codec.decodeJpeg(bytes), orientation: exifOrientation(JpegHeader.read(bytes).exif));
        expect((shown.width, shown.height), (32, 16), reason: 'orientation $n');
        expectQuarters(shown, upright, reason: 'orientation $n');
      }
    });

    test('quarter turns clockwise after the orientation', () {
      final bytes = codecFixture('orientation_6.jpg');
      final stored = codec.decodeJpeg(bytes);
      final once = orientDecoded(stored, orientation: 6, quarterTurns: 1);
      expect((once.width, once.height), (16, 32));
      expectQuarters(once, {
        'topLeft': 'bottomLeft',
        'topRight': 'topLeft',
        'bottomLeft': 'bottomRight',
        'bottomRight': 'topRight',
      }, reason: 'a quarter turn clockwise');
      final twice = orientDecoded(stored, orientation: 6, quarterTurns: 2);
      expectQuarters(twice, {
        'topLeft': 'bottomRight',
        'topRight': 'bottomLeft',
        'bottomLeft': 'topRight',
        'bottomRight': 'topLeft',
      }, reason: 'half a turn');
      final back = orientDecoded(stored, orientation: 6, quarterTurns: -1);
      final three = orientDecoded(stored, orientation: 6, quarterTurns: 3);
      expect(back.rgba, three.rgba, reason: '-1 is 3');
      expectQuarters(orientDecoded(stored, orientation: 6, quarterTurns: 4), upright, reason: 'a whole turn');
    });

    SbsDecoded randomPicture(int width, int height) {
      final random = Random(width * 31 + height);
      return SbsDecoded(
        width: width,
        height: height,
        rgba: Uint8List.fromList(
          List.generate(width * height * 4, (index) => index % 4 == 3 ? 255 : random.nextInt(256)),
        ),
      );
    }

    test('the same pixels as bakeOrientation then copyRotate of package:image, for every case', () {
      // An even size: bakeOrientation of package:image 4.9.1 leaves the middle row of an odd height unmirrored for
      // the orientation 3 (flipHorizontalVertical swaps rows in pairs only)
      final stored = randomPicture(6, 4);
      for (var n = 1; n <= 8; n++) {
        for (var turns = 0; turns < 4; turns++) {
          final ours = orientDecoded(stored, orientation: n, quarterTurns: turns);
          final reference = imageOf(stored)..exif.imageIfd.orientation = n;
          var theirs = img.bakeOrientation(reference);
          if (turns > 0) {
            theirs = img.copyRotate(theirs, angle: 90 * turns);
          }
          expect((ours.width, ours.height), (theirs.width, theirs.height), reason: 'orientation $n, $turns turns');
          expect(ours.rgba, theirs.getBytes(order: img.ChannelOrder.rgba), reason: 'orientation $n, $turns turns');
        }
      }
    });

    test('an odd size, against the definitions of the EXIF orientations, pixel by pixel', () {
      final stored = randomPicture(5, 3);
      const w = 5;
      const h = 3;
      // Where the stored pixel (x, y) is shown, for each orientation (EXIF 2.32, tag 0x0112)
      final shownAt = <int, (int, int) Function(int x, int y)>{
        1: (x, y) => (x, y),
        2: (x, y) => (w - 1 - x, y),
        3: (x, y) => (w - 1 - x, h - 1 - y),
        4: (x, y) => (x, h - 1 - y),
        5: (x, y) => (y, x),
        6: (x, y) => (h - 1 - y, x),
        7: (x, y) => (h - 1 - y, w - 1 - x),
        8: (x, y) => (y, w - 1 - x),
      };
      for (final MapEntry(key: n, value: place) in shownAt.entries) {
        for (var turns = 0; turns < 4; turns++) {
          final ours = orientDecoded(stored, orientation: n, quarterTurns: turns);
          final swaps = (n >= 5) != turns.isOdd;
          expect((ours.width, ours.height), swaps ? (h, w) : (w, h), reason: 'orientation $n, $turns turns');
          for (var y = 0; y < h; y++) {
            for (var x = 0; x < w; x++) {
              var (px, py) = place(x, y);
              var (width, height) = n >= 5 ? (h, w) : (w, h);
              for (var turn = 0; turn < turns; turn++) {
                // A quarter turn clockwise of a picture [height] high
                (px, py) = (height - 1 - py, px);
                (width, height) = (height, width);
              }
              expect(
                rgbAt(ours.rgba, ours.width, px, py),
                rgbAt(stored.rgba, w, x, y),
                reason: 'orientation $n, $turns turns, ($x, $y)',
              );
            }
          }
        }
      }
    });

    test('nothing to turn: the same pixels, not a copy; the profile follows the pixels', () {
      final decoded = codec.decodeJpeg(codecFixture('display_p3.jpg'));
      expect(identical(orientDecoded(decoded), decoded), isTrue);
      expect(identical(orientDecoded(decoded, orientation: 9), decoded), isTrue, reason: 'an unknown orientation');
      expect(orientDecoded(decoded, quarterTurns: 1).iccProfile, decoded.iccProfile);
    });
  });

  group('colours', () {
    test('a Display P3 JPEG decoded without conversion, its profile kept byte for byte', () {
      final decoded = codec.decodeJpeg(codecFixture('display_p3.jpg'));
      expect(decoded.iccProfile, codecFixture('display_p3.icc'));
      final patches = codecExpected['p3Patches'] as Map<String, dynamic>;
      // The red band holds the Display P3 value of sRGB (200, 60, 60), which a conversion would give back
      final red = rgbAt(decoded.rgba, decoded.width, 32, 16);
      expect(near(red, colourOf(patches['red']['p3']), 3), isTrue, reason: 'decoded $red');
    });

    test('the profile of the original goes into the pair, one chunk or two', () {
      for (final name in ['display_p3.jpg', 'icc_two_chunks.jpg']) {
        final decoded = codec.decodeJpeg(codecFixture(name));
        final out = codec.encodeSbs(pairOf(decoded), SbsEncodeOptions(quality: 92, iccProfile: decoded.iccProfile));
        final expected = codecExpected['iccProfiles'][name] as Map<String, dynamic>;
        final header = JpegHeader.read(out);
        expect(sha256Hex(header.iccProfile!), expected['sha256'], reason: name);
        expect(header.segments.where((segment) => segment.marker == 0xE2), hasLength(expected['chunks']), reason: name);
      }
    });

    test('a CMYK or grey profile is not given with the RGB pixels, an RGB one is', () {
      // The decoder gives RGB whatever the file holds: a profile of another colour space would describe other pixels
      Uint8List withSpace(String space) {
        final profile = Uint8List.fromList(codecFixture('display_p3.icc'));
        profile.setRange(16, 20, ascii.encode(space));
        return withSegments(codecFixture('quality_90.jpg'), iccProfile: profile);
      }

      for (final space in ['CMYK', 'GRAY', 'Lab ']) {
        final file = withSpace(space);
        expect(JpegHeader.read(file).iccProfile, isNotNull, reason: 'the header still reads the $space profile');
        expect(codec.decodeJpeg(file).iccProfile, isNull, reason: space);
      }
      expect(codec.decodeJpeg(withSpace('RGB ')).iccProfile, hasLength(2536));
      expect(isRgbIccProfile(Uint8List(127)..setRange(16, 20, ascii.encode('RGB '))), isFalse, reason: 'too short');
    });

    test('no profile asked, none written', () {
      final decoded = codec.decodeJpeg(codecFixture('quality_90.jpg'));
      final out = codec.encodeSbs(pairOf(decoded), const SbsEncodeOptions(quality: 90));
      expect(JpegHeader.read(out).iccProfile, isNull);
      expect(JpegHeader.read(out).segments.where((segment) => segment.marker == 0xE2), isEmpty);
    });
  });

  group('quality and subsampling', () {
    test('the quality of the original, found within 2, kept between 85 and 97 in the pair', () {
      for (final (quality, pairQuality) in [(75, 85), (90, 90), (95, 95)]) {
        final bytes = codecFixture('quality_$quality.jpg');
        final estimated = JpegHeader.read(bytes).estimatedQuality;
        expect(estimated, closeTo(quality, 2));
        final out = codec.encodeSbs(
          pairOf(codec.decodeJpeg(bytes)),
          SbsEncodeOptions(quality: sbsQualityFor(estimated)),
        );
        expect(JpegHeader.read(out).estimatedQuality, pairQuality, reason: 'quality_$quality.jpg');
      }
    });

    test('the subsampling of the original followed; 4:2:2 written 4:4:4, finer', () {
      for (final (name, written) in [
        ('420', ChromaSubsampling.s420),
        ('444', ChromaSubsampling.s444),
        ('422', ChromaSubsampling.s444),
      ]) {
        final bytes = codecFixture('subsampling_$name.jpg');
        final out = codec.encodeSbs(
          pairOf(codec.decodeJpeg(bytes)),
          SbsEncodeOptions(quality: 90, subsampling: sbsSubsamplingFor(JpegHeader.read(bytes).subsampling)),
        );
        expect(JpegHeader.read(out).subsampling, written, reason: 'subsampling_$name.jpg');
      }
    });
  });

  group('the pair as written', () {
    test('read back by package:image and by our XMP reader; EXIF without make, model or thumbnail', () {
      final original = codecFixture('exif_camera.jpg');
      final header = JpegHeader.read(original);
      final eye = orientDecoded(codec.decodeJpeg(original), orientation: exifOrientation(header.exif));
      expect((eye.width, eye.height), (32, 64), reason: 'the drone photo stood upright by its orientation 6');
      final xmp = StereoPhotoXmp.estimated(
        eyeWidth: eye.width,
        eyeHeight: eye.height,
        depthModelSha256: depthModelOnnxSha256,
        derivativeId: 'urn:uuid:6f1c2e0a-0000-4000-8000-000000000000',
        sourceName: 'DJI_0001.JPG',
        sourceSize: original.length,
        sourceSha1: 'X8tYgvibyzHDDN2yXGU/ft1XxeM=',
        sourceQuarterTurns: 0,
        created: '2026-10-27T10:12:00+01:00',
        creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
      );
      final out = codec.encodeSbs(
        pairOf(eye),
        SbsEncodeOptions(
          quality: sbsQualityFor(header.estimatedQuality),
          subsampling: sbsSubsamplingFor(header.subsampling),
          exif: minimalExif(keptExif(header.exif, software: 'Immuch360 Desktop 3.3.0')),
          xmp: xmp.toXml(),
        ),
      );

      final image = img.decodeJpg(out)!;
      expect((image.width, image.height), (64, 64));
      final left = image.getPixel(eye.width ~/ 2, 5);
      final right = image.getPixel(eye.width + eye.width ~/ 2, 5);
      final source = rgbAt(eye.rgba, eye.width, eye.width ~/ 2, 5);
      expect(near([left.r.toInt(), left.g.toInt(), left.b.toInt()], source, 12), isTrue);
      expect(near([right.r.toInt(), right.g.toInt(), right.b.toInt()], source, 12), isTrue);

      final read = StereoPhotoXmp.findIn(out)!;
      expect(read, xmp);
      expect(read.eyeWidth, 32);

      final exif = img.decodeJpgExif(out)!;
      expect(exif.imageIfd.orientation, 1);
      expect(exif.imageIfd.hasMake, isFalse);
      expect(exif.imageIfd.hasModel, isFalse);
      expect(exif.directories.containsKey('ifd1'), isFalse);
      expect(exif.exifIfd[0x9003].toString(), '2025:05:03 09:20:00');
      final text = latin1.decode(out);
      expect(text.contains('DJI'), isTrue, reason: 'the source name in the XMP');
      expect(text.contains('FC3582'), isFalse, reason: 'the model of the drone');
      expect(text.contains('10.01.02.07'), isFalse, reason: 'the software of the drone');

      // SOI, the EXIF, the XMP, then the image
      expect(JpegHeader.read(out).segments.take(2).map((segment) => segment.marker), [0xE1, 0xE1]);
    });

    test('the original bytes are never changed', () {
      final bytes = codecFixture('exif_camera.jpg');
      final before = Uint8List.fromList(bytes);
      codec.decodeJpeg(bytes);
      expect(bytes, before);
    });

    test('a file that is not a JPEG, or a damaged one, is a codec error', () {
      expect(() => codec.decodeJpeg(codecFixture('transparent.png')), throwsA(isA<SbsCodecException>()));
      final jpeg = codecFixture('quality_90.jpg');
      expect(() => codec.decodeJpeg(jpeg.sublist(0, 300)), throwsA(isA<SbsCodecException>()));
      expect(
        () => codec.encodeSbs(
          SbsPicture(width: 2, height: 1, rgba: Uint8List(8)),
          SbsEncodeOptions(quality: 90, exif: Uint8List.fromList([1, 2])),
        ),
        throwsA(isA<SbsCodecException>()),
      );
    });

    test('its name, for the logs and the measures', () {
      expect(codec.name, 'dart');
    });
  });
}
