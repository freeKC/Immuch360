// The segments of a JPEG file, as the writer of the splat photos needs them (plan of 3 November 2026, section 2.2):
// SOI, the marker segments and their lengths, each scan with its entropy coded data up to the next marker (stuffed
// 0xFF 0x00 bytes and restart markers inside it, the several scans of a progressive JPEG one after the other), and the
// EOI of the first frame. Whatever follows that EOI (the video of a motion photo, the gain map of an Ultra HDR photo,
// a Samsung trailer) is not part of the image. Pure Dart, no decoding of the pixels.

import 'dart:convert';
import 'dart:typed_data';

/// SOI, EOI, SOS, COM
const jpegSoi = 0xD8;
const jpegEoi = 0xD9;
const jpegSos = 0xDA;
const jpegCom = 0xFE;

/// APP0 to APP15
const jpegApp0 = 0xE0;
const jpegApp1 = 0xE1;
const jpegApp2 = 0xE2;
const jpegApp14 = 0xEE;
const jpegApp15 = 0xEF;

/// Not a JPEG this walker can follow: no SOI, a segment cut short, no EOI
class JpegWalkException implements Exception {
  const JpegWalkException(this.detail);

  final String detail;

  @override
  String toString() => 'JpegWalkException: $detail';
}

/// One segment of a JPEG: its [marker] (0xE1 for APP1...), its first byte (the 0xFF of the marker) and its length in
/// the file, marker included; for a scan, the entropy coded data that follows its header is part of it
class JpegSegment {
  const JpegSegment({required this.marker, required this.offset, required this.length, this.headerLength = 0});

  final int marker;
  final int offset;
  final int length;

  /// The bytes of the marker segment proper, marker and length field included: the whole segment but for a scan
  final int headerLength;

  int get end => offset + length;

  bool get isApp => marker >= jpegApp0 && marker <= jpegApp15;

  /// The data of the segment after its marker and its length field (for a scan, its header only)
  Uint8List payloadOf(Uint8List file) => Uint8List.sublistView(file, offset + 4, offset + headerLength);

  /// Whether the payload of this segment starts with [signature] (a latin1 string with its NUL bytes)
  bool startsWith(Uint8List file, String signature) {
    final bytes = latin1.encode(signature);
    if (headerLength - 4 < bytes.length) {
      return false;
    }
    for (var i = 0; i < bytes.length; i++) {
      if (file[offset + 4 + i] != bytes[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  String toString() => 'JpegSegment(0x${marker.toRadixString(16)} at $offset, $length bytes)';
}

/// What [walkJpeg] found: the segments between SOI and EOI in their order, where the image ends (after its EOI), and
/// the size of the frame its SOF gives
class JpegLayout {
  const JpegLayout({required this.segments, required this.end, required this.width, required this.height});

  final List<JpegSegment> segments;

  /// The byte after the EOI of the first frame
  final int end;
  final int width;
  final int height;
}

/// Whether [marker] starts a frame (SOF0 to SOF15, without DHT, JPG and DAC)
bool isJpegSof(int marker) => marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;

/// The segments of the JPEG [bytes] up to the EOI of its first frame (see the top of this file); throws a
/// [JpegWalkException] for anything else
JpegLayout walkJpeg(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != jpegSoi) {
    throw const JpegWalkException('no SOI');
  }
  final segments = <JpegSegment>[];
  var width = 0;
  var height = 0;
  var at = 2;
  while (true) {
    if (at >= bytes.length || bytes[at] != 0xFF) {
      throw JpegWalkException('no marker at $at');
    }
    final start = at;
    // Fill bytes: any number of 0xFF before a marker
    while (at < bytes.length && bytes[at] == 0xFF) {
      at++;
    }
    if (at >= bytes.length) {
      throw const JpegWalkException('cut in a marker');
    }
    final marker = bytes[at];
    at++;
    if (marker == jpegEoi) {
      return JpegLayout(segments: segments, end: at, width: width, height: height);
    }
    if (marker == jpegSoi || marker == 0x00) {
      throw JpegWalkException('marker 0x${marker.toRadixString(16)} at $start');
    }
    // A restart marker or TEM out of a scan: a marker without a length
    if ((marker >= 0xD0 && marker <= 0xD7) || marker == 0x01) {
      segments.add(JpegSegment(marker: marker, offset: start, length: at - start, headerLength: at - start));
      continue;
    }
    if (at + 2 > bytes.length) {
      throw JpegWalkException('segment 0x${marker.toRadixString(16)} cut at $start');
    }
    final length = (bytes[at] << 8) | bytes[at + 1];
    if (length < 2 || at + length > bytes.length) {
      throw JpegWalkException('segment 0x${marker.toRadixString(16)} of $length bytes at $start');
    }
    // The fill bytes before a marker are dropped: a segment starts at the 0xFF of its marker
    final offset = at - 2;
    final headerEnd = at + length;
    if (isJpegSof(marker)) {
      if (length < 8) {
        throw JpegWalkException('SOF of $length bytes');
      }
      height = (bytes[at + 3] << 8) | bytes[at + 4];
      width = (bytes[at + 5] << 8) | bytes[at + 6];
    }
    if (marker == jpegSos) {
      final dataEnd = _entropyEnd(bytes, headerEnd);
      segments.add(
        JpegSegment(marker: marker, offset: offset, length: dataEnd - offset, headerLength: headerEnd - offset),
      );
      at = dataEnd;
    } else {
      segments.add(
        JpegSegment(marker: marker, offset: offset, length: headerEnd - offset, headerLength: headerEnd - offset),
      );
      at = headerEnd;
    }
  }
}

/// Where the entropy coded data that starts at [from] ends: the 0xFF of the first marker that is neither a stuffed
/// 0xFF 0x00 nor a restart marker
int _entropyEnd(Uint8List bytes, int from) {
  var at = from;
  while (true) {
    if (at + 1 >= bytes.length) {
      throw const JpegWalkException('scan without an end');
    }
    if (bytes[at] != 0xFF) {
      at++;
      continue;
    }
    final next = bytes[at + 1];
    if (next == 0x00 || (next >= 0xD0 && next <= 0xD7)) {
      at += 2;
      continue;
    }
    if (next == 0xFF) {
      // A fill byte before a marker
      at++;
      continue;
    }
    return at;
  }
}
