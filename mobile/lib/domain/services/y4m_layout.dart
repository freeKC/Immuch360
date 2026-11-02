// The virtual y4m the AV2 companion serves to the player of the app (store/m2/av2-2026-11-02/plan-2026-11-02.md,
// section 2.1, point 4; mobile/native/av2/README.md): a header written by us, then each picture as "FRAME\n" and its
// samples, 4:2:0, one byte per sample in 8 bits, or 10 bits in 16-bit little endian words. Its length is known before
// anything is decoded, so the player opens it as a file of a known size and seeks by byte ranges. The header is ours
// because the dav2d program writes a wrong frame rate for the files of avmenc (16.3 frames per second for WorldCup,
// which is 30: measure of 2 November, section 5): the rate comes from the container.
//
// The same layout as the y4m_layout of the companion (mobile/native/av2/src/stream.c): the app checks the "listening"
// line of the companion against it and reads the "request" lines with it, and the fake companion of the tests serves
// it. Pure Dart, without Flutter.

/// The bytes before the samples of each picture
const y4mFrameMarker = 'FRAME\n';

/// Where a byte of the y4m falls: in the header ([frame] -1), or in the record of picture [frame] ("FRAME\n" and its
/// samples), [offset] bytes into it
typedef Y4mPosition = ({int frame, int offset});

/// The bytes of a virtual y4m of [frames] pictures of [width] x [height] pixels, 4:2:0, of [bits] bits per sample (8,
/// or 10 in 16-bit words), at [fpsNumerator] / [fpsDenominator] frames per second, in the limited colour range unless
/// [fullRange]
class Y4mLayout {
  factory Y4mLayout({
    required int width,
    required int height,
    required int bits,
    required int fpsNumerator,
    required int fpsDenominator,
    required int frames,
    bool fullRange = false,
  }) {
    // The limits of the companion: a picture of 65536 pixels a side at most, 100 million pictures at most
    if (width < 1 || height < 1 || width > 65536 || height > 65536) {
      throw ArgumentError('a y4m picture of ${width}x$height');
    }
    if (bits != 8 && bits != 10) {
      throw ArgumentError.value(bits, 'bits', 'a y4m of 8 or 10 bits');
    }
    if (fpsNumerator < 1 || fpsDenominator < 1 || fpsNumerator > 0xffffffff || fpsDenominator > 0xffffffff) {
      throw ArgumentError('a frame rate of $fpsNumerator/$fpsDenominator');
    }
    if (frames < 1 || frames > 100000000) {
      throw ArgumentError.value(frames, 'frames', 'from 1 to 100000000 pictures');
    }
    final header =
        'YUV4MPEG2 W$width H$height F$fpsNumerator:$fpsDenominator Ip A1:1 C${bits == 8 ? '420' : '420p10'} '
        'XCOLORRANGE=${fullRange ? 'FULL' : 'LIMITED'}\n';
    final chroma = ((width + 1) ~/ 2) * ((height + 1) ~/ 2);
    final frameBytes = (width * height + 2 * chroma) * (bits == 8 ? 1 : 2);
    return Y4mLayout._(
      width: width,
      height: height,
      bits: bits,
      fpsNumerator: fpsNumerator,
      fpsDenominator: fpsDenominator,
      frames: frames,
      fullRange: fullRange,
      header: header,
      frameBytes: frameBytes,
    );
  }

  const Y4mLayout._({
    required this.width,
    required this.height,
    required this.bits,
    required this.fpsNumerator,
    required this.fpsDenominator,
    required this.frames,
    required this.fullRange,
    required this.header,
    required this.frameBytes,
  });

  final int width;
  final int height;
  final int bits;
  final int fpsNumerator;
  final int fpsDenominator;
  final int frames;
  final bool fullRange;

  /// "YUV4MPEG2 W1920 H1080 F30:1 Ip A1:1 C420 XCOLORRANGE=LIMITED\n", ASCII
  final String header;

  /// The samples of one picture: Y, then U, then V, each chroma plane of half the size rounded up
  final int frameBytes;

  /// The bytes of the header
  int get headerLength => header.length;

  /// The bytes of one picture in the y4m: "FRAME\n" and its samples
  int get recordBytes => y4mFrameMarker.length + frameBytes;

  /// The bytes of the whole y4m
  int get length => headerLength + frames * recordBytes;

  /// Where the record of picture [frame] starts
  int offsetOf(int frame) {
    RangeError.checkValueInInterval(frame, 0, frames - 1, 'frame');
    return headerLength + frame * recordBytes;
  }

  /// Where the byte at [offset] falls
  Y4mPosition positionOf(int offset) {
    RangeError.checkValueInInterval(offset, 0, length - 1, 'offset');
    if (offset < headerLength) {
      return (frame: -1, offset: offset);
    }
    final inPictures = offset - headerLength;
    return (frame: inPictures ~/ recordBytes, offset: inPictures % recordBytes);
  }

  /// The pictures a request of the bytes [first] to [last] (both included) reads, at least in part: the first picture
  /// is the one the companion starts from (0 for a request that starts in the header), the last one, and the number
  /// of pictures read whole
  ({int first, int last, int whole}) framesOf(int first, int last) {
    RangeError.checkValueInInterval(first, 0, length - 1, 'first');
    RangeError.checkValueInInterval(last, first, length - 1, 'last');
    final from = positionOf(first);
    final to = positionOf(last);
    final firstFrame = from.frame < 0 ? 0 : from.frame;
    if (to.frame < 0) {
      return (first: 0, last: -1, whole: 0);
    }
    // A picture is read whole when the range holds its record from its first byte to its last one
    final firstWhole = from.frame < 0 || from.offset == 0 ? firstFrame : firstFrame + 1;
    final lastWhole = to.offset == recordBytes - 1 ? to.frame : to.frame - 1;
    return (first: firstFrame, last: to.frame, whole: lastWhole < firstWhole ? 0 : lastWhole - firstWhole + 1);
  }

  @override
  String toString() => 'Y4mLayout(${header.trim()}, $frames frames of $recordBytes bytes)';
}
