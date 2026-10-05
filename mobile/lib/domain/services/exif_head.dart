// The few EXIF tags of the head of a JPEG that tell which camera took it and how large the picture is: enough to tell
// an equirect photo a 360° camera stitched itself (GoPro MAX, DJI Osmo 360, Insta360) from a flat one when it carries
// no GPano tags, and to read the IMU sample an Insta360 camera writes in its MakerNote.
//
// It is read the way EXIF is: the APP1 segment of the JPEG that begins with "Exif\0\0", its TIFF header, then IFD0 with
// the Make (tag 0x010F), the Model (0x0110) and the Exif IFD it points to (0x8769), which holds the MakerNote (0x927C),
// the PixelXDimension and PixelYDimension (0xA002 and 0xA003) and the BodySerialNumber (0xA431). Cameras write these
// values within the first few KB of the file.
//
// Pure Dart: the caller reads the bytes, from a file on the device or with HTTP range requests.

import 'dart:typed_data';

/// Bytes of the head of a photo read for its EXIF
const exifHeadLength = 4 * 1024;

// EXIF tags
const _makeTag = 0x010f;
const _modelTag = 0x0110;
const _exifIfdTag = 0x8769;
const _makerNoteTag = 0x927c;
const _pixelWidthTag = 0xa002;
const _pixelHeightTag = 0xa003;
const _bodySerialNumberTag = 0xa431;

// TIFF field types of the pixel dimensions
const _shortType = 3;
const _longType = 4;

/// What the EXIF of the head of a photo says of its camera and its size. A tag the head does not have is null.
class ExifHead {
  const ExifHead({this.make, this.model, this.serial, this.makerNote, this.pixelWidth, this.pixelHeight});

  /// Make of IFD0 (tag 0x010F): "GoPro", "DJI", "Arashi Vision" (Insta360)
  final String? make;

  /// Model of IFD0 (tag 0x0110): "GoPro Max", "Osmo 360", "Insta360 X3"
  final String? model;

  /// BodySerialNumber of the Exif IFD (tag 0xA431)
  final String? serial;

  /// MakerNote of the Exif IFD (tag 0x927C), as printable ASCII up to its first NUL or control byte
  final String? makerNote;

  /// PixelXDimension and PixelYDimension of the Exif IFD (tags 0xA002 and 0xA003, SHORT or LONG)
  final int? pixelWidth;
  final int? pixelHeight;

  @override
  bool operator ==(Object other) =>
      other is ExifHead &&
      other.make == make &&
      other.model == model &&
      other.serial == serial &&
      other.makerNote == makerNote &&
      other.pixelWidth == pixelWidth &&
      other.pixelHeight == pixelHeight;

  @override
  int get hashCode => Object.hash(make, model, serial, makerNote, pixelWidth, pixelHeight);

  @override
  String toString() =>
      'ExifHead(make: $make, model: $model, serial: $serial, makerNote: $makerNote, '
      'pixels: $pixelWidth x $pixelHeight)';
}

/// The EXIF of the JPEG whose first bytes are [head]; null for a file that is not a JPEG, or whose EXIF is not in
/// [head]. Tags past the end of [head] are null.
ExifHead? parseExifHead(Uint8List head) {
  final tiff = _exifTiffStart(head);
  if (tiff == null || tiff + 8 > head.length) {
    return null;
  }
  final data = ByteData.sublistView(head);
  final Endian endian;
  switch (String.fromCharCodes(head, tiff, tiff + 2)) {
    case 'II':
      endian = Endian.little;
    case 'MM':
      endian = Endian.big;
    default:
      return null;
  }
  if (data.getUint16(tiff + 2, endian) != 42) {
    return null;
  }
  String? text(int ifd, int tag) {
    final value = _ifdEntry(data, tiff, ifd, tag, endian);
    return value == null ? null : _exifText(head, data, tiff, value, endian);
  }

  int? integer(int ifd, int tag) {
    final value = _ifdEntry(data, tiff, ifd, tag, endian);
    if (value == null) {
      return null;
    }
    // The type sits 6 bytes before the value field, the count 4 bytes before it; a SHORT sits in the first 2 bytes of
    // the field, whatever the byte order
    final count = data.getUint32(value - 4, endian);
    final number = switch (data.getUint16(value - 6, endian)) {
      _shortType when count == 1 => data.getUint16(value, endian),
      _longType when count == 1 => data.getUint32(value, endian),
      _ => null,
    };
    return number == 0 ? null : number;
  }

  final ifd0 = data.getUint32(tiff + 4, endian);
  final exifEntry = _ifdEntry(data, tiff, ifd0, _exifIfdTag, endian);
  final exifIfd = exifEntry == null ? null : data.getUint32(exifEntry, endian);
  return ExifHead(
    make: text(ifd0, _makeTag),
    model: text(ifd0, _modelTag),
    serial: exifIfd == null ? null : text(exifIfd, _bodySerialNumberTag),
    makerNote: exifIfd == null ? null : text(exifIfd, _makerNoteTag),
    pixelWidth: exifIfd == null ? null : integer(exifIfd, _pixelWidthTag),
    pixelHeight: exifIfd == null ? null : integer(exifIfd, _pixelHeightTag),
  );
}

// Where the TIFF header of the EXIF of the JPEG [head] starts: the segments are walked from the start of the image to the
// APP1 segment that begins with "Exif\0\0". Null for a file that is not a JPEG, or without EXIF in [head].
int? _exifTiffStart(Uint8List head) {
  if (head.length < 4 || head[0] != 0xff || head[1] != 0xd8) {
    return null;
  }
  var offset = 2;
  while (offset + 4 <= head.length) {
    if (head[offset] != 0xff) {
      return null;
    }
    final marker = head[offset + 1];
    if (marker == 0xff) {
      // Fill byte before a marker
      offset++;
      continue;
    }
    // Start of the scan or end of the image: no EXIF before the picture data
    if (marker == 0xda || marker == 0xd9) {
      return null;
    }
    final length = head[offset + 2] << 8 | head[offset + 3];
    if (marker == 0xe1 && offset + 10 <= head.length && String.fromCharCodes(head, offset + 4, offset + 8) == 'Exif') {
      return offset + 10;
    }
    offset += 2 + length;
  }
  return null;
}

// The position of the value field (its last 4 bytes) of the entry [tag] of the IFD at [ifdOffset] from the TIFF header
// at [tiff], null when that IFD is not in [data] or has no such entry
int? _ifdEntry(ByteData data, int tiff, int ifdOffset, int tag, Endian endian) {
  final ifd = tiff + ifdOffset;
  if (ifdOffset < 8 || ifd + 2 > data.lengthInBytes) {
    return null;
  }
  final count = data.getUint16(ifd, endian);
  for (var i = 0; i < count; i++) {
    final entry = ifd + 2 + 12 * i;
    if (entry + 12 > data.lengthInBytes) {
      return null;
    }
    if (data.getUint16(entry, endian) == tag) {
      return entry + 8;
    }
  }
  return null;
}

// The text of the EXIF entry whose value field is at [value] (see [_ifdEntry]): its printable ASCII up to the first NUL
// or other control byte, trimmed; null when it is empty or not in [head]
String? _exifText(Uint8List head, ByteData data, int tiff, int value, Endian endian) {
  final count = data.getUint32(value - 4, endian);
  // A value of more than 4 bytes sits at the offset the entry gives, from the TIFF header
  final start = count <= 4 ? value : tiff + data.getUint32(value, endian);
  if (start >= head.length) {
    return null;
  }
  var stop = start;
  while (stop < head.length && stop < start + count && head[stop] >= 0x20 && head[stop] < 0x7f) {
    stop++;
  }
  final text = String.fromCharCodes(head, start, stop).trim();
  return text.isEmpty ? null : text;
}
