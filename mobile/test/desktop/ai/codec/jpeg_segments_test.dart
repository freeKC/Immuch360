import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';

import 'codec_fixtures.dart';

/// A small picture with some detail, as package:image encodes it
Uint8List encoded({int quality = 90, img.JpegChroma chroma = img.JpegChroma.yuv420, int width = 40, int height = 24}) {
  final image = img.Image(width: width, height: height);
  for (final pixel in image) {
    pixel
      ..r = (pixel.x * 7 + pixel.y * 3) % 256
      ..g = (pixel.x * 13) % 256
      ..b = (pixel.y * 29 + pixel.x) % 256;
  }
  return img.encodeJpg(image, quality: quality, chroma: chroma);
}

/// The markers of the segments of [jpeg] before its image data
List<int> markersOf(Uint8List jpeg) => [for (final segment in JpegHeader.read(jpeg).segments) segment.marker];

void main() {
  group('reading the head of a JPEG', () {
    test('the frame, its components and the quantisation tables of another encoder', () {
      final header = JpegHeader.read(codecFixture('quality_90.jpg'));
      expect(header.frameMarker, 0xC0);
      expect((header.width, header.height), (64, 48));
      expect(header.components, hasLength(3));
      expect(header.tables.keys, containsAll([0, 1]));
      // The first value of the luminance table at quality 90 of the IJG library: 16 * 20 / 100 rounded, 3
      expect(header.tables[header.components.first.table]![0], 3);
      expect(header.iccProfile, isNull);
      expect(header.exif, isNull);
    });

    test('the quality of the files of libjpeg is found within 2, here exactly', () {
      for (final quality in (codecExpected['qualities'] as List).cast<int>()) {
        final estimated = JpegHeader.read(codecFixture('quality_$quality.jpg')).estimatedQuality;
        expect(estimated, closeTo(quality, 2), reason: 'quality_$quality.jpg');
        expect(estimated, quality, reason: 'the IJG tables of quality $quality');
      }
    });

    test('the quality of the files of package:image is found exactly', () {
      for (final quality in [30, 50, 75, 85, 90, 92, 95, 97]) {
        expect(JpegHeader.read(encoded(quality: quality)).estimatedQuality, quality, reason: 'quality $quality');
      }
    });

    test('the colour subsampling from the sampling factors', () {
      expect(JpegHeader.read(codecFixture('subsampling_444.jpg')).subsampling, ChromaSubsampling.s444);
      expect(JpegHeader.read(codecFixture('subsampling_422.jpg')).subsampling, ChromaSubsampling.s422);
      expect(JpegHeader.read(codecFixture('subsampling_420.jpg')).subsampling, ChromaSubsampling.s420);
      expect(JpegHeader.read(encoded(chroma: img.JpegChroma.yuv444)).subsampling, ChromaSubsampling.s444);
    });

    test('the ICC profile of one chunk, byte for byte', () {
      final profile = JpegHeader.read(codecFixture('display_p3.jpg')).iccProfile;
      expect(profile, codecFixture('display_p3.icc'));
      final expected = codecExpected['iccProfiles']['display_p3.jpg'] as Map<String, dynamic>;
      expect(sha256Hex(profile!), expected['sha256']);
    });

    test('the ICC profile of two chunks, joined in their order', () {
      final jpeg = codecFixture('icc_two_chunks.jpg');
      final header = JpegHeader.read(jpeg);
      expect(header.segments.where((segment) => segment.marker == 0xE2), hasLength(2));
      final expected = codecExpected['iccProfiles']['icc_two_chunks.jpg'] as Map<String, dynamic>;
      expect(header.iccProfile, hasLength(expected['length']));
      expect(sha256Hex(header.iccProfile!), expected['sha256']);
    });

    test('chunks that do not make a whole profile give none', () {
      final profile = Uint8List.fromList(List.generate(70000, (index) => index % 251));
      final chunks = iccChunks(profile);
      expect(chunks, hasLength(2));
      final jpeg = encoded();
      Uint8List withChunks(List<Uint8List> segments) =>
          Uint8List.fromList([0xFF, 0xD8, for (final segment in segments) ...segment, ...jpeg.sublist(2)]);

      expect(JpegHeader.read(withChunks(chunks)).iccProfile, profile);
      expect(JpegHeader.read(withChunks(chunks.reversed.toList())).iccProfile, profile, reason: 'any order');
      expect(JpegHeader.read(withChunks([chunks.first])).iccProfile, isNull, reason: 'a chunk missing');
      expect(JpegHeader.read(withChunks([chunks.first, chunks.first])).iccProfile, isNull, reason: 'a chunk twice');
      final otherCount = Uint8List.fromList(chunks.last)..[4 + 13] = 3;
      expect(JpegHeader.read(withChunks([chunks.first, otherCount])).iccProfile, isNull, reason: 'counts differ');
    });

    test('the EXIF payload, from its signature on', () {
      final exif = JpegHeader.read(codecFixture('exif_camera.jpg')).exif!;
      expect(ascii.decode(exif.sublist(0, 4)), 'Exif');
      expect(exif.sublist(4, 6), [0, 0]);
      expect(ascii.decode(exif.sublist(6, 8)), 'II');
    });

    test('a file that is not a JPEG, or ends in its head, is refused', () {
      expect(() => JpegHeader.read(codecFixture('transparent.png')), throwsFormatException);
      expect(() => JpegHeader.read(Uint8List(0)), throwsFormatException);
      final jpeg = codecFixture('display_p3.jpg');
      expect(() => JpegHeader.read(jpeg.sublist(0, 100)), throwsFormatException);
    });

    test('the pixels only: the metadata segments dropped, the same pixels decoded', () {
      final jpeg = codecFixture('exif_camera.jpg');
      final header = JpegHeader.read(jpeg);
      final pixels = header.pixelsOnly(jpeg);
      expect(markersOf(jpeg), contains(0xE1));
      expect(markersOf(pixels), isNot(contains(0xE1)));
      expect(markersOf(pixels), containsAll([0xDB, 0xC0, 0xC4]));
      final decoded = img.decodeJpg(pixels)!;
      // Not turned by the orientation 6 of the EXIF any more: the size as stored
      expect((decoded.width, decoded.height), (64, 32));
      // A file without metadata is given back as it is
      final plain = encoded();
      expect(identical(JpegHeader.read(plain).pixelsOnly(plain), plain), isTrue);
    });
  });

  group('writing our segments', () {
    // "Exif\0\0", a little endian TIFF header, an empty IFD0 and no next IFD
    final exif = Uint8List.fromList([
      ...ascii.encode('Exif'),
      0,
      0,
      ...ascii.encode('II*'),
      0,
      8,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
    const xmp = '<x:xmpmeta xmlns:x="adobe:ns:meta/"/>';

    test('SOI, the EXIF, the XMP, the ICC chunks, then the image of the encoder', () {
      final profile = codecFixture('display_p3.icc');
      final jpeg = encoded();
      final out = withSegments(jpeg, exif: exif, xmp: xmp, iccProfile: profile);
      final header = JpegHeader.read(out);
      expect(out.sublist(0, 2), [0xFF, 0xD8]);
      expect(header.segments.take(3).map((segment) => segment.marker), [0xE1, 0xE1, 0xE2]);
      expect(header.exif, exif);
      expect(xmpPacketsOf(out), [xmp]);
      expect(header.iccProfile, profile);
      // The JFIF of the encoder is dropped for the EXIF, which wants to come first
      expect(markersOf(out), isNot(contains(0xE0)));
      // The image data is the encoder's
      final scan = JpegHeader.read(jpeg).imageDataOffset;
      expect(out.sublist(header.imageDataOffset), jpeg.sublist(scan));
      expect(img.decodeJpg(out), isNotNull);
    });

    test('without an EXIF, the JFIF of the encoder stays first', () {
      final out = withSegments(encoded(), xmp: xmp);
      expect(markersOf(out).take(2), [0xE0, 0xE1]);
      expect(xmpPacketsOf(out), [xmp]);
    });

    test('a profile larger than a segment goes in numbered chunks of 65 519 bytes', () {
      final profile = Uint8List.fromList(List.generate(3 * iccChunkPayload + 10, (index) => index * 7 % 256));
      final out = withSegments(encoded(), iccProfile: profile);
      final header = JpegHeader.read(out);
      final chunks = header.segments.where((segment) => segment.marker == 0xE2).toList();
      expect(chunks, hasLength(4));
      for (var number = 1; number <= 4; number++) {
        final chunk = chunks[number - 1];
        expect(out[chunk.payloadOffset + 12], number);
        expect(out[chunk.payloadOffset + 13], 4);
        expect(chunk.payloadLength - 14, number < 4 ? iccChunkPayload : 10);
      }
      expect(header.iccProfile, profile);
      expect(iccChunks(Uint8List(iccChunkPayload)), hasLength(1));
      expect(iccChunks(Uint8List(iccChunkPayload + 1)), hasLength(2));
    });

    test('the encoder segments of metadata are dropped, its tables kept', () {
      final image = img.Image(width: 8, height: 8)..exif.imageIfd.make = 'Camera';
      final jpeg = img.encodeJpg(image);
      expect(markersOf(jpeg), contains(0xE1));
      final out = withSegments(jpeg, xmp: xmp);
      expect(xmpPacketsOf(out), [xmp]);
      expect(JpegHeader.read(out).exif, isNull);
      expect(latin1.decode(out).contains('Camera'), isFalse);
    });

    test('an EXIF without its signature, or a profile of more than 255 chunks, is refused', () {
      expect(() => withSegments(encoded(), exif: Uint8List.fromList([1, 2, 3])), throwsFormatException);
      expect(() => iccChunks(Uint8List(255 * iccChunkPayload + 1)), throwsFormatException);
    });
  });

  test('the quality and the subsampling of a pair, from those of its original', () {
    expect(sbsQualityFor(null), 92);
    expect(sbsQualityFor(75), 85);
    expect(sbsQualityFor(90), 90);
    expect(sbsQualityFor(100), 97);
    expect(sbsSubsamplingFor(null), ChromaSubsampling.s444);
    expect(sbsSubsamplingFor(ChromaSubsampling.s420), ChromaSubsampling.s420);
  });
}
