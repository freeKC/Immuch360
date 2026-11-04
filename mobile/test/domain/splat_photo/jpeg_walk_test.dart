import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/splat_photo/jpeg_walk.dart';

import 'splat_photo_fixtures.dart';

/// The walker of the JPEG segments the writer of the splat photos splices (plan of 3 November 2026, section 2.2)
void main() {
  List<int> segment(int marker, List<int> payload) => [
    0xFF,
    marker,
    (payload.length + 2) >> 8,
    (payload.length + 2) & 0xFF,
    ...payload,
  ];

  test('the poster of PIL: APP0, the tables, the frame, one scan, its EOI and its size', () {
    final bytes = splatPhotoFixture('poster.jpg');
    final layout = walkJpeg(bytes);
    expect(layout.width, 48);
    expect(layout.height, 32);
    expect(layout.end, bytes.length);
    expect(layout.segments.first.marker, jpegApp0);
    expect(layout.segments.where((s) => s.marker == jpegSos).length, 1);
    expect(layout.segments.where((s) => isJpegSof(s.marker)).length, 1);
  });

  test('a progressive JPEG: several scans, tables between them, stuffed bytes and restart markers in the data', () {
    final sof2 = segment(0xC2, [8, 0, 32, 0, 48, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
    final scan = [
      ...segment(jpegSos, [1, 1, 0, 0, 63, 0]),
      0x12,
      0xFF,
      0x00,
      0x34,
      0xFF,
      0xD0,
      0x56,
      0xFF,
      0xFF,
    ];
    final bytes = Uint8List.fromList([
      0xFF, jpegSoi, //
      ...segment(jpegApp0, [0x4A, 0x46, 0x49, 0x46, 0]),
      ...segment(0xDB, List.filled(65, 1)),
      ...sof2,
      ...segment(0xC4, List.filled(20, 0)),
      ...scan,
      ...segment(0xC4, List.filled(20, 0)),
      ...scan,
      0xFF, jpegEoi,
      // What follows the image: a trailer
      1, 2, 3, 0xFF, 0xD9,
    ]);
    final layout = walkJpeg(bytes);
    expect(layout.segments.map((s) => s.marker), [jpegApp0, 0xDB, 0xC2, 0xC4, jpegSos, 0xC4, jpegSos]);
    expect(layout.width, 48);
    expect(layout.height, 32);
    expect(layout.end, bytes.length - 5);
    // A scan runs up to the next marker, its stuffed bytes and restart markers included
    final firstScan = layout.segments[4];
    expect(firstScan.headerLength, 10);
    expect(firstScan.length, scan.length);
  });

  test('a fill byte before a marker belongs to the scan before it, never to the next segment', () {
    final bytes = Uint8List.fromList([
      0xFF, jpegSoi, //
      ...segment(0xC0, [8, 0, 2, 0, 3, 1, 1, 0x11, 0]),
      ...segment(jpegSos, [1, 1, 0, 0, 63, 0]),
      9, 9, 0xFF, 0xFF, 0xFF, jpegEoi,
    ]);
    final layout = walkJpeg(bytes);
    expect(layout.end, bytes.length);
    expect(layout.segments.last.end, bytes.length - 2);
  });

  test('refuses what is no JPEG, or a JPEG cut short', () {
    expect(() => walkJpeg(splatPhotoFixture('png_with_packet.png')), throwsA(isA<JpegWalkException>()));
    final poster = splatPhotoFixture('poster.jpg');
    expect(() => walkJpeg(Uint8List.sublistView(poster, 0, 200)), throwsA(isA<JpegWalkException>()));
    expect(() => walkJpeg(Uint8List.sublistView(poster, 0, poster.length - 2)), throwsA(isA<JpegWalkException>()));
  });
}
