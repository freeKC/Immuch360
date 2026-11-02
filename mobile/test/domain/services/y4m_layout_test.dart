// The byte layout of the virtual y4m of the AV2 companion (lot AD1 of store/m2/av2-2026-11-02/plan-2026-11-02.md): the
// header written by us, the size of a picture per format, and the byte ranges of the player mapped to pictures. The
// sizes of the fixtures are those of FIXTURES.md (55 296 bytes a picture in 8 bits, 110 592 in 10 bits).

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/y4m_layout.dart';

void main() {
  Y4mLayout layout({
    int width = 256,
    int height = 144,
    int bits = 8,
    int fpsNumerator = 30,
    int fpsDenominator = 1,
    int frames = 12,
    bool fullRange = false,
  }) => Y4mLayout(
    width: width,
    height: height,
    bits: bits,
    fpsNumerator: fpsNumerator,
    fpsDenominator: fpsDenominator,
    frames: frames,
    fullRange: fullRange,
  );

  test('writes the header of the companion: size, rate, progressive, square pixels, colour space and range', () {
    expect(layout().header, 'YUV4MPEG2 W256 H144 F30:1 Ip A1:1 C420 XCOLORRANGE=LIMITED\n');
    expect(layout(bits: 10).header, 'YUV4MPEG2 W256 H144 F30:1 Ip A1:1 C420p10 XCOLORRANGE=LIMITED\n');
    expect(
      layout(width: 1080, height: 1920, fpsNumerator: 60000, fpsDenominator: 1001, fullRange: true).header,
      'YUV4MPEG2 W1080 H1920 F60000:1001 Ip A1:1 C420 XCOLORRANGE=FULL\n',
    );
    expect(layout().headerLength, layout().header.length);
  });

  test('a picture takes its luma and two chroma planes of half the size rounded up, 2 bytes a sample in 10 bits', () {
    // The fixtures (FIXTURES.md): the payload after FRAME\n whose MD5 avmdec and dav2d agree on
    expect(layout().frameBytes, 55296);
    expect(layout(bits: 10).frameBytes, 110592);
    expect(layout(width: 1920, height: 1080).frameBytes, 3110400);
    expect(layout(width: 4096, height: 2160, bits: 10, fpsNumerator: 24).frameBytes, 26542080);
    // Odd sizes round the chroma planes up, as the companion does
    expect(layout(width: 3, height: 3).frameBytes, 9 + 2 * 4);
    expect(layout(width: 1, height: 1, bits: 10).frameBytes, (1 + 2) * 2);
    expect(layout().recordBytes, 6 + 55296);
    expect(layout().length, layout().headerLength + 12 * (6 + 55296));
    expect(y4mFrameMarker, 'FRAME\n');
  });

  test('maps a byte to its picture and a range to the pictures it reads', () {
    final y4m = layout();
    final header = y4m.headerLength;
    final record = y4m.recordBytes;

    expect(y4m.offsetOf(0), header);
    expect(y4m.offsetOf(11), header + 11 * record);
    expect(y4m.positionOf(0), (frame: -1, offset: 0));
    expect(y4m.positionOf(header - 1), (frame: -1, offset: header - 1));
    expect(y4m.positionOf(header), (frame: 0, offset: 0));
    expect(y4m.positionOf(header + record + 7), (frame: 1, offset: 7));
    expect(y4m.positionOf(y4m.length - 1), (frame: 11, offset: record - 1));
    // The whole file, the header alone, a range from the middle of a picture (as mpv asks after a seek), one picture
    expect(y4m.framesOf(0, y4m.length - 1), (first: 0, last: 11, whole: 12));
    expect(y4m.framesOf(0, header - 1), (first: 0, last: -1, whole: 0));
    expect(y4m.framesOf(header + 3 * record + 100, y4m.length - 1), (first: 3, last: 11, whole: 8));
    expect(y4m.framesOf(y4m.offsetOf(5), y4m.offsetOf(6) - 1), (first: 5, last: 5, whole: 1));
    expect(y4m.framesOf(y4m.offsetOf(5), y4m.offsetOf(6) - 2), (first: 5, last: 5, whole: 0));
    expect(() => y4m.positionOf(y4m.length), throwsRangeError);
    expect(() => y4m.offsetOf(12), throwsRangeError);
    expect(() => y4m.framesOf(10, 9), throwsRangeError);
  });

  test('refuses what the companion refuses: no picture, other depths, no rate, no frames', () {
    expect(() => layout(width: 0), throwsArgumentError);
    expect(() => layout(height: 65537), throwsArgumentError);
    expect(() => layout(bits: 12), throwsArgumentError);
    expect(() => layout(fpsNumerator: 0), throwsArgumentError);
    expect(() => layout(fpsDenominator: 0), throwsArgumentError);
    expect(() => layout(frames: 0), throwsArgumentError);
    expect(() => layout(frames: 100000001), throwsArgumentError);
    expect(layout(width: 65536, height: 1, frames: 100000000).length, greaterThan(0));
  });
}
