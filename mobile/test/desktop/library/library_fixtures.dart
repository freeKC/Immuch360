// Tiny media files for the folder library tests, built byte by byte: the heads the scanner reads (EXIF, XMP, frame
// sizes, ISO boxes), with no picture data. Synthetic, so they carry no licence and nobody's photos.

import 'dart:convert';
import 'dart:typed_data';

/// One TIFF field: its tag, its type (2 ASCII, 3 SHORT, 4 LONG, 5 RATIONAL) and its values (a string for ASCII,
/// numbers otherwise, numerator and denominator in turn for RATIONAL)
typedef TiffField = (int tag, int type, Object values);

const _typeSizes = {2: 1, 3: 2, 4: 4, 5: 8};

/// A TIFF structure (as the EXIF of a JPEG or a HEIF carries it) with IFD0, and an Exif IFD and a GPS IFD when given
Uint8List tiffBytes({
  List<TiffField> ifd0 = const [],
  List<TiffField> exif = const [],
  List<TiffField> gps = const [],
  bool littleEndian = false,
}) {
  final endian = littleEndian ? Endian.little : Endian.big;
  final ifds = <List<TiffField>>[
    [
      ...ifd0,
      if (exif.isNotEmpty) (0x8769, 4, [0]),
      if (gps.isNotEmpty) (0x8825, 4, [0]),
    ],
    exif,
    gps,
  ];

  List<int> encode(TiffField field) {
    final (_, type, values) = field;
    if (type == 2) {
      return [...ascii.encode(values as String), 0];
    }
    final numbers = (values as List).cast<int>();
    final data = ByteData(numbers.length * (type == 3 ? 2 : 4));
    for (var i = 0; i < numbers.length; i++) {
      if (type == 3) {
        data.setUint16(i * 2, numbers[i], endian);
      } else {
        data.setUint32(i * 4, numbers[i], endian);
      }
    }
    return data.buffer.asUint8List();
  }

  int countOf(TiffField field) => switch (field.$2) {
    2 => (field.$3 as String).length + 1,
    5 => (field.$3 as List).length ~/ 2,
    _ => (field.$3 as List).length,
  };

  // Layout: each IFD, then the values of its fields that do not fit in 4 bytes
  final ifdOffsets = <int>[];
  var offset = 8;
  for (final ifd in ifds) {
    ifdOffsets.add(offset);
    if (ifd.isEmpty) {
      continue;
    }
    offset += 2 + ifd.length * 12 + 4;
    for (final field in ifd) {
      final size = (_typeSizes[field.$2] ?? 1) * countOf(field);
      if (size > 4) {
        offset += size + (size & 1);
      }
    }
  }

  final out = ByteData(offset);
  out
    ..setUint8(0, littleEndian ? 0x49 : 0x4d)
    ..setUint8(1, littleEndian ? 0x49 : 0x4d)
    ..setUint16(2, 42, endian)
    ..setUint32(4, 8, endian);
  for (var index = 0; index < ifds.length; index++) {
    final ifd = ifds[index];
    if (ifd.isEmpty) {
      continue;
    }
    var at = ifdOffsets[index];
    var dataAt = at + 2 + ifd.length * 12 + 4;
    out.setUint16(at, ifd.length, endian);
    at += 2;
    for (final field in ifd) {
      final tag = field.$1;
      final value = switch (tag) {
        0x8769 => encode((tag, 4, [ifdOffsets[1]])),
        0x8825 => encode((tag, 4, [ifdOffsets[2]])),
        _ => encode(field),
      };
      out
        ..setUint16(at, tag, endian)
        ..setUint16(at + 2, field.$2, endian)
        ..setUint32(at + 4, countOf(field), endian);
      if (value.length <= 4) {
        for (var i = 0; i < value.length; i++) {
          out.setUint8(at + 8 + i, value[i]);
        }
      } else {
        out.setUint32(at + 8, dataAt, endian);
        for (var i = 0; i < value.length; i++) {
          out.setUint8(dataAt + i, value[i]);
        }
        dataAt += value.length + (value.length & 1);
      }
      at += 12;
    }
    out.setUint32(at, 0, endian);
  }
  return out.buffer.asUint8List();
}

/// Degrees, minutes and seconds as three RATIONALs
List<int> gpsDegrees(double degrees) {
  final whole = degrees.floor();
  final minutes = ((degrees - whole) * 60).floor();
  final seconds = ((degrees - whole) * 3600 - minutes * 60) * 1000;
  return [whole, 1, minutes, 1, seconds.round(), 1000];
}

List<int> _segment(int marker, List<int> payload) => [
  0xff,
  marker,
  (payload.length + 2) >> 8,
  (payload.length + 2) & 0xff,
  ...payload,
];

/// A JPEG head: an EXIF APP1 from [tiff], an XMP APP1 declaring [gpanoProjection], then the frame of [width] by
/// [height] and an empty scan
Uint8List jpegBytes({required int width, required int height, Uint8List? tiff, String? gpanoProjection}) {
  final xmp = gpanoProjection == null
      ? null
      : '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
            '<rdf:Description xmlns:GPano="http://ns.google.com/photos/1.0/panorama/" '
            'GPano:ProjectionType="$gpanoProjection" GPano:UsePanoramaViewer="True"/></rdf:RDF></x:xmpmeta>';
  return Uint8List.fromList([
    0xff, 0xd8,
    // APP0 JFIF
    ..._segment(0xe0, [...ascii.encode('JFIF'), 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]),
    if (tiff != null) ..._segment(0xe1, [...ascii.encode('Exif'), 0, 0, ...tiff]),
    if (xmp != null) ..._segment(0xe1, [...ascii.encode('http://ns.adobe.com/xap/1.0/'), 0, ...utf8.encode(xmp)]),
    // SOF0: precision, height, width, one component
    ..._segment(0xc0, [8, height >> 8, height & 0xff, width >> 8, width & 0xff, 1, 1, 0x11, 0]),
    // SOS then EOI: no picture data
    ..._segment(0xda, [1, 1, 0, 0, 63, 0]),
    0xff, 0xd9,
  ]);
}

List<int> _u32(int value) => [value >> 24 & 0xff, value >> 16 & 0xff, value >> 8 & 0xff, value & 0xff];
List<int> _u16(int value) => [value >> 8 & 0xff, value & 0xff];

/// A PNG head: the signature and IHDR, an acTL chunk when [animated]
Uint8List pngBytes({required int width, required int height, bool animated = false}) {
  List<int> chunk(String type, List<int> data) => [..._u32(data.length), ...ascii.encode(type), ...data, 0, 0, 0, 0];
  return Uint8List.fromList([
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
    ...chunk('IHDR', [..._u32(width), ..._u32(height), 8, 6, 0, 0, 0]),
    if (animated) ...chunk('acTL', [..._u32(2), ..._u32(0)]),
    ...chunk('IDAT', const []),
    ...chunk('IEND', const []),
  ]);
}

/// A WebP head with a VP8X chunk
Uint8List webpBytes({required int width, required int height, bool animated = false}) {
  final w = width - 1;
  final h = height - 1;
  final vp8x = [
    animated ? 0x02 : 0,
    0,
    0,
    0,
    w & 0xff,
    w >> 8 & 0xff,
    w >> 16 & 0xff,
    h & 0xff,
    h >> 8 & 0xff,
    h >> 16,
  ];
  final body = [...ascii.encode('WEBP'), ...ascii.encode('VP8X'), vp8x.length, 0, 0, 0, ...vp8x];
  return Uint8List.fromList([...ascii.encode('RIFF'), body.length & 0xff, body.length >> 8 & 0xff, 0, 0, ...body]);
}

/// A GIF head
Uint8List gifBytes({required int width, required int height}) => Uint8List.fromList([
  ...ascii.encode('GIF89a'),
  width & 0xff,
  width >> 8,
  height & 0xff,
  height >> 8,
  0,
  0,
  0,
  0x3b,
]);

List<int> box(String type, List<int> payload) => [..._u32(payload.length + 8), ...ascii.encode(type), ...payload];

List<int> fullBox(String type, int version, List<int> payload) => box(type, [version, 0, 0, 0, ...payload]);

// Seconds between 1904-01-01 and 1970-01-01
const _macEpochOffset = 2082844800;

/// An MP4 with one video track of [width] by [height] turned by [rotation] degrees, lasting [durationMs], made at
/// [created]; the movie box after the media data, as a camera writes it, when [moovAtEnd]
Uint8List mp4Bytes({
  required int width,
  required int height,
  required int durationMs,
  DateTime? created,
  int rotation = 0,
  bool moovAtEnd = true,
}) {
  final creation = created == null ? 0 : created.millisecondsSinceEpoch ~/ 1000 + _macEpochOffset;
  const timescale = 1000;
  final matrix = switch (rotation) {
    90 => [0, 0x10000, 0, -0x10000 & 0xffffffff, 0, 0, 0, 0, 0x40000000],
    270 => [0, -0x10000 & 0xffffffff, 0, 0x10000, 0, 0, 0, 0, 0x40000000],
    180 => [-0x10000 & 0xffffffff, 0, 0, 0, -0x10000 & 0xffffffff, 0, 0, 0, 0x40000000],
    _ => [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000],
  };
  final mvhd = fullBox('mvhd', 0, [
    ..._u32(creation),
    ..._u32(creation),
    ..._u32(timescale),
    ..._u32(durationMs),
    ..._u32(0x10000),
    ..._u16(0x100),
    ...List.filled(10, 0),
    for (final value in [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000]) ..._u32(value),
    ...List.filled(24, 0),
    ..._u32(2),
  ]);
  final tkhd = fullBox('tkhd', 0, [
    ..._u32(creation),
    ..._u32(creation),
    ..._u32(1),
    ..._u32(0),
    ..._u32(durationMs),
    ...List.filled(8, 0),
    ..._u16(0),
    ..._u16(0),
    ..._u16(0),
    ..._u16(0),
    for (final value in matrix) ..._u32(value),
    ..._u32(width << 16),
    ..._u32(height << 16),
  ]);
  final mdhd = fullBox('mdhd', 0, [
    ..._u32(creation),
    ..._u32(creation),
    ..._u32(timescale),
    ..._u32(durationMs),
    0,
    0,
    0,
    0,
  ]);
  final hdlr = fullBox('hdlr', 0, [
    0,
    0,
    0,
    0,
    ...ascii.encode('vide'),
    ...List.filled(12, 0),
    ...ascii.encode('Video'),
    0,
  ]);
  final moov = box('moov', [
    ...mvhd,
    ...box('trak', [
      ...tkhd,
      ...box('mdia', [...mdhd, ...hdlr]),
    ]),
  ]);
  final ftyp = box('ftyp', [...ascii.encode('isom'), 0, 0, 2, 0, ...ascii.encode('isom'), ...ascii.encode('mp41')]);
  final mdat = box('mdat', List.filled(64, 0x42));
  return Uint8List.fromList([...ftyp, if (!moovAtEnd) ...moov, ...mdat, if (moovAtEnd) ...moov]);
}

/// A HEIF head: a primary item of [width] by [height] turned by [quarterTurns] anticlockwise (irot), and an Exif item
/// holding [tiff] in the media data
Uint8List heifBytes({required int width, required int height, int quarterTurns = 0, Uint8List? tiff}) {
  final ftyp = box('ftyp', [...ascii.encode('heic'), 0, 0, 0, 0, ...ascii.encode('mif1'), ...ascii.encode('heic')]);
  final exifPayload = tiff == null ? const <int>[] : [..._u32(6), ...ascii.encode('Exif'), 0, 0, ...tiff];

  List<int> meta(int exifOffset) => fullBox('meta', 0, [
    ...fullBox('hdlr', 0, [0, 0, 0, 0, ...ascii.encode('pict'), ...List.filled(12, 0), 0]),
    ...fullBox('pitm', 0, _u16(1)),
    ...fullBox('iinf', 0, [
      ..._u16(tiff == null ? 1 : 2),
      ...fullBox('infe', 2, [..._u16(1), ..._u16(0), ...ascii.encode('hvc1'), 0]),
      if (tiff != null) ...fullBox('infe', 2, [..._u16(2), ..._u16(0), ...ascii.encode('Exif'), 0]),
    ]),
    if (tiff != null)
      ...fullBox('iloc', 0, [
        0x44,
        0x00,
        ..._u16(1),
        ..._u16(2),
        ..._u16(0),
        ..._u16(1),
        ..._u32(exifOffset),
        ..._u32(exifPayload.length),
      ]),
    ...box('iprp', [
      ...box('ipco', [
        ...fullBox('ispe', 0, [..._u32(width), ..._u32(height)]),
        ...box('irot', [quarterTurns & 3]),
      ]),
      ...fullBox('ipma', 0, [..._u32(1), ..._u16(1), 2, 0x81, 0x02]),
    ]),
  ]);

  final metaLength = meta(0).length;
  final exifOffset = ftyp.length + metaLength + 8;
  return Uint8List.fromList([...ftyp, ...meta(exifOffset), ...box('mdat', exifPayload)]);
}
