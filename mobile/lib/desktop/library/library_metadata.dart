// What the folder library reads in a photo or a video file, in place of what the gallery of a phone keeps: the size of
// the picture as it is shown, when it was taken, where, how long a video runs, and the projection a 360° photo
// declares. The width and the height matter beyond the grid: the 360° scan only reads the files whose shape or name
// hints at 360° (local_panorama.service.dart).
//
// Only the heads of the files are read, a few small reads each, and only for files that are new or changed since the
// last scan:
//  - JPEG: the segments up to the image data, for the EXIF (APP1 "Exif"), the XMP (APP1, GPano) and the frame size
//    (SOFn);
//  - TIFF and the raw formats built on it (DNG, CR2, NEF, ARW, ORF, RW2...): the EXIF of the first 256 KiB;
//  - HEIF and AVIF: the meta box (primary item, its ispe and irot properties, the Exif item);
//  - PNG, GIF, WebP, BMP: their headers;
//  - MP4 and MOV (the raw videos of 360° cameras included): mvhd for the duration and the date, the tkhd and hdlr of the
//    first video track for its size and rotation, walked a box header at a time, since cameras write moov at the end.
// Anything else, or a damaged file, gives what could be read and the file dates stand in for the date taken.
//
// Pure Dart over synchronous reads: the scanner runs it in its own isolate.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/library/folder_roots.dart';

/// What a media file tells about itself
class MediaMetadata {
  const MediaMetadata({
    this.width,
    this.height,
    this.orientation = 0,
    this.takenAt,
    this.latitude,
    this.longitude,
    this.durationMs = 0,
    this.projection,
    this.animated = false,
    this.readFailed = false,
  });

  /// Read, and nothing found: a damaged file, or a format without metadata
  static const none = MediaMetadata();

  /// The file could not be opened or read (a cloud file while its client is offline, a file another program holds):
  /// the scanner keeps it with the dates of the listing and reads it again at its next pass
  static const failedRead = MediaMetadata(readFailed: true);

  /// The size of the stored picture, before [orientation] turns it
  final int? width;
  final int? height;

  /// The EXIF orientation (1 to 8), or for a video 6 when it turns by 90° and 8 by 270° (3 for 180°); 0 unknown
  final int orientation;

  /// When it was taken (EXIF DateTimeOriginal, the creation time of a movie), in UTC
  final DateTime? takenAt;

  final double? latitude;
  final double? longitude;

  final int durationMs;

  /// The projection type of the GPano XMP of a photo ("equirectangular"), null without one
  final String? projection;

  /// An animated GIF, WebP or PNG
  final bool animated;

  /// See [failedRead]
  final bool readFailed;

  /// Whether the picture is shown turned by a quarter, its width and height swapped
  bool get turnsQuarter => orientation >= 5 && orientation <= 8;

  /// The size of the picture as it is shown, the way the Android gallery gives it
  int? get displayWidth => turnsQuarter ? height : width;
  int? get displayHeight => turnsQuarter ? width : height;

  @override
  String toString() =>
      'MediaMetadata(${width}x$height, orientation: $orientation, takenAt: $takenAt, '
      'gps: $latitude,$longitude, durationMs: $durationMs, projection: $projection, animated: $animated, '
      'readFailed: $readFailed)';
}

/// Reads up to [length] bytes from [offset]: fewer at the end, none past it
abstract class ByteSource {
  int get length;

  Uint8List read(int offset, int length);
}

/// A byte source over bytes in memory, for tests and small files
class BytesSource implements ByteSource {
  const BytesSource(this.bytes);

  final Uint8List bytes;

  @override
  int get length => bytes.length;

  @override
  Uint8List read(int offset, int length) {
    if (offset >= bytes.length || offset < 0 || length <= 0) {
      return Uint8List(0);
    }
    return Uint8List.sublistView(bytes, offset, math.min(bytes.length, offset + length));
  }
}

class _FileSource implements ByteSource {
  _FileSource(this._file) : length = _file.lengthSync();

  final RandomAccessFile _file;

  @override
  final int length;

  @override
  Uint8List read(int offset, int length) {
    if (offset >= this.length || offset < 0 || length <= 0) {
      return Uint8List(0);
    }
    _file.setPositionSync(offset);
    return _file.readSync(math.min(length, this.length - offset));
  }
}

/// The metadata of the file at [path], a photo or a video as [kind] says. Never throws for a damaged or unreadable
/// file: it gives what could be read, or [MediaMetadata.failedRead] when the file could not be opened or read.
MediaMetadata readMediaMetadataSync(String path, LibraryMediaKind kind) {
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    return readMediaMetadata(_FileSource(file), kind);
  } on FileSystemException {
    return MediaMetadata.failedRead;
  } finally {
    file?.closeSync();
  }
}

/// The metadata [source] holds, a photo or a video as [kind] says; the content decides the format, not the name
MediaMetadata readMediaMetadata(ByteSource source, LibraryMediaKind kind) {
  try {
    final head = source.read(0, 32);
    if (kind == LibraryMediaKind.video) {
      return _isoBmffBrand(head) != null || _looksLikeBoxes(head) ? _readMovie(source) : MediaMetadata.none;
    }
    if (head.length >= 3 && head[0] == 0xff && head[1] == 0xd8 && head[2] == 0xff) {
      return _readJpeg(source);
    }
    if (head.length >= 8 && _ascii(head, 1, 3) == 'PNG') {
      return _readPng(source);
    }
    if (head.length >= 10 && _ascii(head, 0, 3) == 'GIF') {
      return MediaMetadata(width: _u16le(head, 6), height: _u16le(head, 8), animated: true);
    }
    if (head.length >= 12 && _ascii(head, 0, 4) == 'RIFF' && _ascii(head, 8, 4) == 'WEBP') {
      return _readWebp(source);
    }
    if (head.length >= 26 && _ascii(head, 0, 2) == 'BM') {
      return _readBmp(source.read(0, 26));
    }
    if (head.length >= 8 && (_ascii(head, 0, 2) == 'II' || _ascii(head, 0, 2) == 'MM')) {
      final tiff = source.read(0, 256 * 1024);
      return _exifToMetadata(_parseTiff(tiff, 0));
    }
    final brand = _isoBmffBrand(head);
    if (brand != null) {
      return _readHeif(source);
    }
  } on RangeError {
    // A damaged or cut file
  } on FormatException {
    // Same
  }
  return MediaMetadata.none;
}

// --- Bytes -----------------------------------------------------------------------------------------------------------

String _ascii(Uint8List bytes, int offset, int length) =>
    offset + length > bytes.length ? '' : String.fromCharCodes(bytes, offset, offset + length);

int _u16le(Uint8List b, int o) => b[o] | b[o + 1] << 8;
int _u16be(Uint8List b, int o) => b[o] << 8 | b[o + 1];
int _u32be(Uint8List b, int o) => b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3];
int _u64be(Uint8List b, int o) => _u32be(b, o) * 0x100000000 + _u32be(b, o + 4);

// --- EXIF (TIFF) -----------------------------------------------------------------------------------------------------

class _Exif {
  int? orientation;
  int? width;
  int? height;
  String? dateTimeOriginal;
  String? dateTime;
  String? offsetTimeOriginal;
  String? offsetTime;
  double? latitude;
  double? longitude;
}

// TIFF field types and their sizes in bytes
const _typeSizes = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8};

/// The EXIF of the TIFF structure that starts at [start] in [data] (a JPEG APP1 after "Exif\0\0", a TIFF or raw file,
/// a HEIF Exif item). Fields that point past [data] are left out.
_Exif _parseTiff(Uint8List data, int start) {
  final exif = _Exif();
  if (start + 8 > data.length) {
    return exif;
  }
  final little = _ascii(data, start, 2) == 'II';
  if (!little && _ascii(data, start, 2) != 'MM') {
    return exif;
  }
  final bytes = ByteData.sublistView(data);
  final endian = little ? Endian.little : Endian.big;
  if (bytes.getUint16(start + 2, endian) != 42) {
    return exif;
  }

  // The value field of each tag of the IFD at [ifdOffset] (relative to the TIFF start): its type, count and where its
  // value lies (inline in the entry, or at an offset)
  Map<int, (int, int, int)> readIfd(int ifdOffset) {
    final entries = <int, (int, int, int)>{};
    final ifd = start + ifdOffset;
    if (ifdOffset < 8 || ifd + 2 > data.length) {
      return entries;
    }
    final count = bytes.getUint16(ifd, endian);
    for (var i = 0; i < count && i < 512; i++) {
      final entry = ifd + 2 + i * 12;
      if (entry + 12 > data.length) {
        break;
      }
      final tag = bytes.getUint16(entry, endian);
      final type = bytes.getUint16(entry + 2, endian);
      final valueCount = bytes.getUint32(entry + 4, endian);
      final size = (_typeSizes[type] ?? 1) * valueCount;
      final valueAt = size <= 4 ? entry + 8 : start + bytes.getUint32(entry + 8, endian);
      if (valueAt + size <= data.length) {
        entries[tag] = (type, valueCount, valueAt);
      }
    }
    return entries;
  }

  int? integer((int, int, int)? field) {
    if (field == null || field.$2 < 1) {
      return null;
    }
    return switch (field.$1) {
      1 || 7 => data[field.$3],
      3 => bytes.getUint16(field.$3, endian),
      4 => bytes.getUint32(field.$3, endian),
      _ => null,
    };
  }

  String? text((int, int, int)? field) {
    if (field == null || field.$1 != 2) {
      return null;
    }
    final chars = data.sublist(field.$3, field.$3 + field.$2).takeWhile((c) => c != 0).toList();
    return chars.isEmpty ? null : String.fromCharCodes(chars).trim();
  }

  double? rational((int, int, int) field, int index) {
    final at = field.$3 + index * 8;
    final denominator = bytes.getUint32(at + 4, endian);
    return denominator == 0 ? null : bytes.getUint32(at, endian) / denominator;
  }

  double? degrees((int, int, int)? field) {
    if (field == null || field.$1 != 5 || field.$2 < 3) {
      return null;
    }
    final d = rational(field, 0);
    final m = rational(field, 1);
    final s = rational(field, 2);
    return d == null || m == null || s == null ? null : d + m / 60 + s / 3600;
  }

  final ifd0 = readIfd(bytes.getUint32(start + 4, endian));
  exif
    ..orientation = integer(ifd0[0x0112])
    ..width = integer(ifd0[0x0100])
    ..height = integer(ifd0[0x0101])
    ..dateTime = text(ifd0[0x0132]);

  final exifPointer = integer(ifd0[0x8769]);
  if (exifPointer != null) {
    final exifIfd = readIfd(exifPointer);
    exif
      ..dateTimeOriginal = text(exifIfd[0x9003]) ?? text(exifIfd[0x9004])
      ..offsetTimeOriginal = text(exifIfd[0x9011])
      ..offsetTime = text(exifIfd[0x9010])
      ..width = integer(exifIfd[0xa002]) ?? exif.width
      ..height = integer(exifIfd[0xa003]) ?? exif.height;
  }

  final gpsPointer = integer(ifd0[0x8825]);
  if (gpsPointer != null) {
    final gps = readIfd(gpsPointer);
    final latitude = degrees(gps[2]);
    final longitude = degrees(gps[4]);
    if (latitude != null && longitude != null && !(latitude == 0 && longitude == 0)) {
      exif
        ..latitude = text(gps[1]) == 'S' ? -latitude : latitude
        ..longitude = text(gps[3]) == 'W' ? -longitude : longitude;
    }
  }
  return exif;
}

final _exifDate = RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})');
final _exifOffset = RegExp(r'^([+-])(\d{2}):(\d{2})$');

/// An EXIF date ("2024:07:14 18:30:05"), in the time zone [offset] says ("+02:00"), else in the local time of this
/// computer, as a camera without an offset tag means; null for a blank or impossible date
DateTime? exifDateToUtc(String? date, String? offset) {
  final match = date == null ? null : _exifDate.firstMatch(date);
  if (match == null) {
    return null;
  }
  final parts = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
  if (parts[0] < 1900 || parts[0] > 2200 || parts[1] < 1 || parts[1] > 12 || parts[2] < 1 || parts[2] > 31) {
    return null;
  }
  final zone = offset == null ? null : _exifOffset.firstMatch(offset);
  if (zone != null) {
    final minutes = int.parse(zone.group(2)!) * 60 + int.parse(zone.group(3)!);
    final utc = DateTime.utc(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]);
    return utc.subtract(Duration(minutes: zone.group(1) == '-' ? -minutes : minutes));
  }
  return DateTime(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]).toUtc();
}

MediaMetadata _exifToMetadata(_Exif exif, {int? width, int? height, String? projection, bool animated = false}) {
  final orientation = exif.orientation;
  return MediaMetadata(
    width: width ?? exif.width,
    height: height ?? exif.height,
    orientation: orientation != null && orientation >= 1 && orientation <= 8 ? orientation : 0,
    takenAt:
        exifDateToUtc(exif.dateTimeOriginal, exif.offsetTimeOriginal ?? exif.offsetTime) ??
        exifDateToUtc(exif.dateTime, exif.offsetTime),
    latitude: exif.latitude,
    longitude: exif.longitude,
    projection: projection,
    animated: animated,
  );
}

// --- XMP -------------------------------------------------------------------------------------------------------------

final _gpanoAttribute = RegExp(r'GPano:ProjectionType\s*=\s*"([^"]*)"');
final _gpanoElement = RegExp(r'<GPano:ProjectionType>\s*([^<]*?)\s*</GPano:ProjectionType>');

/// The GPano projection type of an XMP packet, null without one
String? gpanoProjectionOf(String xmp) {
  final match = _gpanoAttribute.firstMatch(xmp) ?? _gpanoElement.firstMatch(xmp);
  final value = match?.group(1)?.trim();
  return value == null || value.isEmpty ? null : value;
}

// --- JPEG ------------------------------------------------------------------------------------------------------------

const _xmpNamespace = 'http://ns.adobe.com/xap/1.0/\u0000';

MediaMetadata _readJpeg(ByteSource source) {
  var offset = 2;
  _Exif? exif;
  String? projection;
  int? width;
  int? height;
  for (var segments = 0; segments < 256 && offset + 4 <= source.length; segments++) {
    final header = source.read(offset, 4);
    if (header.length < 4 || header[0] != 0xff) {
      break;
    }
    final marker = header[1];
    if (marker == 0xff) {
      // Fill byte before a marker
      offset++;
      continue;
    }
    if (marker == 0xd8 || marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      offset += 2;
      continue;
    }
    if (marker == 0xda || marker == 0xd9) {
      // The image data or its end: nothing of interest follows
      break;
    }
    final length = _u16be(header, 2);
    if (length < 2) {
      break;
    }
    final isFrame = marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc;
    if (isFrame && width == null) {
      final frame = source.read(offset + 4, 5);
      if (frame.length == 5) {
        height = _u16be(frame, 1);
        width = _u16be(frame, 3);
      }
    } else if (marker == 0xe1) {
      final payload = source.read(offset + 4, length - 2);
      if (exif == null && _ascii(payload, 0, 6) == 'Exif\u0000\u0000') {
        exif = _parseTiff(payload, 6);
      } else if (projection == null && _ascii(payload, 0, _xmpNamespace.length) == _xmpNamespace) {
        projection = gpanoProjectionOf(latin1.decode(payload.sublist(_xmpNamespace.length), allowInvalid: true));
      }
    }
    offset += 2 + length;
  }
  return _exifToMetadata(exif ?? _Exif(), width: width, height: height, projection: projection);
}

// --- PNG, WebP, BMP --------------------------------------------------------------------------------------------------

MediaMetadata _readPng(ByteSource source) {
  final ihdr = source.read(8, 25);
  if (ihdr.length < 16 || _ascii(ihdr, 4, 4) != 'IHDR') {
    return MediaMetadata.none;
  }
  final width = _u32be(ihdr, 8);
  final height = _u32be(ihdr, 12);
  var animated = false;
  _Exif? exif;
  // The chunks before the image data: acTL makes an animated PNG, eXIf carries EXIF
  var offset = 8;
  for (var chunks = 0; chunks < 64 && offset + 8 <= source.length; chunks++) {
    final header = source.read(offset, 8);
    if (header.length < 8) {
      break;
    }
    final length = _u32be(header, 0);
    final type = _ascii(header, 4, 4);
    if (type == 'IDAT' || type == 'IEND') {
      break;
    }
    if (type == 'acTL') {
      animated = true;
    } else if (type == 'eXIf' && length < 1024 * 1024) {
      exif = _parseTiff(source.read(offset + 8, length), 0);
    }
    offset += 12 + length;
  }
  return _exifToMetadata(exif ?? _Exif(), width: width, height: height, animated: animated);
}

MediaMetadata _readWebp(ByteSource source) {
  int? width;
  int? height;
  var animated = false;
  _Exif? exif;
  String? projection;
  var offset = 12;
  for (var chunks = 0; chunks < 32 && offset + 8 <= source.length; chunks++) {
    final header = source.read(offset, 8);
    if (header.length < 8) {
      break;
    }
    final type = _ascii(header, 0, 4);
    final length = header[4] | header[5] << 8 | header[6] << 16 | header[7] << 24;
    final data = offset + 8;
    switch (type) {
      case 'VP8X':
        final chunk = source.read(data, 10);
        if (chunk.length == 10) {
          animated = chunk[0] & 0x02 != 0;
          width = (chunk[4] | chunk[5] << 8 | chunk[6] << 16) + 1;
          height = (chunk[7] | chunk[8] << 8 | chunk[9] << 16) + 1;
        }
      case 'VP8 ':
        final chunk = source.read(data, 10);
        if (width == null && chunk.length == 10 && chunk[3] == 0x9d && chunk[4] == 0x01 && chunk[5] == 0x2a) {
          width = _u16le(chunk, 6) & 0x3fff;
          height = _u16le(chunk, 8) & 0x3fff;
        }
      case 'VP8L':
        final chunk = source.read(data, 5);
        if (width == null && chunk.length == 5 && chunk[0] == 0x2f) {
          final bits = chunk[1] | chunk[2] << 8 | chunk[3] << 16 | chunk[4] << 24;
          width = (bits & 0x3fff) + 1;
          height = ((bits >> 14) & 0x3fff) + 1;
        }
      case 'EXIF' when length < 1024 * 1024:
        final chunk = source.read(data, length);
        exif = _parseTiff(chunk, _ascii(chunk, 0, 6) == 'Exif\u0000\u0000' ? 6 : 0);
      case 'XMP ' when length < 1024 * 1024:
        projection = gpanoProjectionOf(latin1.decode(source.read(data, length), allowInvalid: true));
    }
    offset = data + length + (length & 1);
  }
  return _exifToMetadata(exif ?? _Exif(), width: width, height: height, projection: projection, animated: animated);
}

MediaMetadata _readBmp(Uint8List head) {
  final header = ByteData.sublistView(head);
  final size = header.getUint32(14, Endian.little);
  if (size == 12) {
    return MediaMetadata(width: header.getUint16(18, Endian.little), height: header.getUint16(20, Endian.little));
  }
  return MediaMetadata(
    width: header.getInt32(18, Endian.little).abs(),
    height: header.getInt32(22, Endian.little).abs(),
  );
}

// --- ISO base media (HEIF, AVIF, MP4, MOV) ---------------------------------------------------------------------------

/// The major brand of an ISO base media file ("heic", "avif", "isom", "qt  "), null for anything else
String? _isoBmffBrand(Uint8List head) => head.length >= 12 && _ascii(head, 4, 4) == 'ftyp' ? _ascii(head, 8, 4) : null;

// A QuickTime file may start without ftyp, with its moov, mdat or wide box
bool _looksLikeBoxes(Uint8List head) =>
    head.length >= 8 && const {'moov', 'mdat', 'wide', 'free', 'skip'}.contains(_ascii(head, 4, 4));

typedef _Box = ({String type, int start, int end, int content});

/// The boxes of [source] between [from] and [to], read a header at a time
List<_Box> _boxesOf(ByteSource source, int from, int to, {int limit = 256}) {
  final boxes = <_Box>[];
  var offset = from;
  while (offset + 8 <= to && boxes.length < limit) {
    final header = source.read(offset, 16);
    if (header.length < 8) {
      break;
    }
    var size = _u32be(header, 0);
    final type = _ascii(header, 4, 4);
    if (!type.codeUnits.every((c) => c >= 0x20 && c < 0x7f)) {
      // Not a box: the bare trailer some cameras append
      break;
    }
    var headerLength = 8;
    if (size == 1) {
      if (header.length < 16) {
        break;
      }
      size = _u64be(header, 8);
      headerLength = 16;
    } else if (size == 0) {
      size = to - offset;
    }
    if (size < headerLength) {
      break;
    }
    final end = math.min(offset + size, to);
    boxes.add((type: type, start: offset, end: end, content: offset + headerLength));
    offset += size;
  }
  return boxes;
}

/// The boxes inside [data] between [from] and [to], all in memory
List<_Box> _boxesIn(Uint8List data, int from, int to) => _boxesOf(BytesSource(data), from, math.min(to, data.length));

// Seconds between 1904-01-01 (the epoch of QuickTime and ISO base media times) and 1970-01-01
const _macEpochOffset = 2082844800;

MediaMetadata _readMovie(ByteSource source) {
  final top = _boxesOf(source, 0, source.length, limit: 64);
  final moov = top.where((box) => box.type == 'moov').firstOrNull;
  if (moov == null) {
    return MediaMetadata.none;
  }
  int? durationMs;
  DateTime? created;
  int? width;
  int? height;
  var orientation = 0;
  for (final child in _boxesOf(source, moov.content, moov.end)) {
    if (child.type == 'mvhd') {
      final mvhd = source.read(child.content, 32);
      final version = mvhd.isEmpty ? 0 : mvhd[0];
      final (creation, timescale, duration) = version == 1 && mvhd.length >= 32
          ? (_u64be(mvhd, 4), _u32be(mvhd, 20), _u64be(mvhd, 24))
          : mvhd.length >= 20
          ? (_u32be(mvhd, 4), _u32be(mvhd, 12), _u32be(mvhd, 16))
          : (0, 0, 0);
      if (timescale > 0 && duration > 0 && duration != 0xffffffff) {
        durationMs = duration * 1000 ~/ timescale;
      }
      created = _movieTime(creation);
    } else if (child.type == 'trak' && width == null) {
      final track = _readTrack(source, child);
      if (track != null) {
        (width, height, orientation) = track;
      }
    }
  }
  return MediaMetadata(
    width: width,
    height: height,
    orientation: orientation,
    takenAt: created,
    durationMs: durationMs ?? 0,
  );
}

DateTime? _movieTime(int seconds) {
  if (seconds <= _macEpochOffset) {
    return null;
  }
  final time = DateTime.fromMillisecondsSinceEpoch((seconds - _macEpochOffset) * 1000, isUtc: true);
  // Cameras with no clock set write 1904, 1970 or a date in the future
  return time.year < 1990 || time.isAfter(DateTime.now().add(const Duration(days: 2))) ? null : time;
}

/// The size and the orientation of the track [trak] if it is a video track
(int, int, int)? _readTrack(ByteSource source, _Box trak) {
  int? width;
  int? height;
  var orientation = 0;
  var isVideo = false;
  for (final child in _boxesOf(source, trak.content, trak.end, limit: 32)) {
    if (child.type == 'tkhd') {
      final tkhd = source.read(child.content, 96);
      if (tkhd.isEmpty) {
        continue;
      }
      final matrixAt = tkhd[0] == 1 ? 52 : 40;
      if (tkhd.length < matrixAt + 44) {
        continue;
      }
      final matrix = ByteData.sublistView(tkhd, matrixAt, matrixAt + 36);
      final a = matrix.getInt32(0);
      final b = matrix.getInt32(4);
      final c = matrix.getInt32(12);
      final d = matrix.getInt32(16);
      orientation = switch ((a, b, c, d)) {
        (0, 0x10000, -0x10000, 0) => 6,
        (0, -0x10000, 0x10000, 0) => 8,
        (-0x10000, 0, 0, -0x10000) => 3,
        _ => 1,
      };
      width = _u32be(tkhd, matrixAt + 36) >> 16;
      height = _u32be(tkhd, matrixAt + 40) >> 16;
    } else if (child.type == 'mdia') {
      for (final media in _boxesOf(source, child.content, child.end, limit: 16)) {
        if (media.type == 'hdlr') {
          final hdlr = source.read(media.content, 12);
          isVideo = _ascii(hdlr, 8, 4) == 'vide';
        }
      }
    }
  }
  if (!isVideo || width == null || height == null || width == 0 || height == 0) {
    return null;
  }
  return (width, height, orientation);
}

MediaMetadata _readHeif(ByteSource source) {
  final meta = _boxesOf(source, 0, math.min(source.length, 1024 * 1024), limit: 32).where((box) => box.type == 'meta');
  if (meta.isEmpty) {
    return MediaMetadata.none;
  }
  final box = meta.first;
  if (box.end - box.start > 4 * 1024 * 1024) {
    return MediaMetadata.none;
  }
  final data = source.read(box.start, box.end - box.start);
  // meta is a full box: version and flags before its children
  final children = _boxesIn(data, box.content - box.start + 4, data.length);
  int? primary;
  int? exifItem;
  final locations = <int, (int, int)>{};
  final properties = <_Box>[];
  final associations = <int, List<int>>{};
  for (final child in children) {
    switch (child.type) {
      case 'pitm':
        primary = data[child.content] == 0 ? _u16be(data, child.content + 4) : _u32be(data, child.content + 4);
      case 'iinf':
        exifItem = _exifItemOf(data, child);
      case 'iloc':
        locations.addAll(_itemLocations(data, child));
      case 'iprp':
        for (final inner in _boxesIn(data, child.content, child.end)) {
          if (inner.type == 'ipco') {
            properties.addAll(_boxesIn(data, inner.content, inner.end));
          } else if (inner.type == 'ipma') {
            associations.addAll(_itemProperties(data, inner));
          }
        }
    }
  }
  int? width;
  int? height;
  var rotation = 0;
  for (final index in associations[primary] ?? const <int>[]) {
    if (index < 1 || index > properties.length) {
      continue;
    }
    final property = properties[index - 1];
    if (property.type == 'ispe' && property.content + 12 <= data.length) {
      width = _u32be(data, property.content + 4);
      height = _u32be(data, property.content + 8);
    } else if (property.type == 'irot' && property.content < data.length) {
      rotation = data[property.content] & 3;
    }
  }
  var exif = _Exif();
  final location = exifItem == null ? null : locations[exifItem];
  if (location != null && location.$2 > 4 && location.$2 < 1024 * 1024) {
    final item = source.read(location.$1, location.$2);
    if (item.length > 4) {
      exif = _parseTiff(item, 4 + _u32be(item, 0));
    }
  }
  // irot turns anticlockwise by quarters; the EXIF of a HEIF only repeats it, so irot wins
  final orientation = switch (rotation) {
    1 => 8,
    2 => 3,
    3 => 6,
    _ => 1,
  };
  return _exifToMetadata(exif..orientation = orientation, width: width, height: height);
}

int? _exifItemOf(Uint8List data, _Box iinf) {
  final version = data[iinf.content];
  final first = iinf.content + 4 + (version == 0 ? 2 : 4);
  for (final infe in _boxesIn(data, first, iinf.end)) {
    if (infe.type != 'infe') {
      continue;
    }
    final infeVersion = data[infe.content];
    if (infeVersion < 2) {
      continue;
    }
    final idLength = infeVersion == 2 ? 2 : 4;
    final id = idLength == 2 ? _u16be(data, infe.content + 4) : _u32be(data, infe.content + 4);
    final type = _ascii(data, infe.content + 4 + idLength + 2, 4);
    if (type == 'Exif') {
      return id;
    }
  }
  return null;
}

/// Where each item of the iloc box lies in the file: offset and length of its first extent (file offsets only)
Map<int, (int, int)> _itemLocations(Uint8List data, _Box iloc) {
  final locations = <int, (int, int)>{};
  var at = iloc.content;
  final version = data[at];
  at += 4;
  final offsetSize = data[at] >> 4;
  final lengthSize = data[at] & 0xf;
  final baseOffsetSize = data[at + 1] >> 4;
  final indexSize = version == 1 || version == 2 ? data[at + 1] & 0xf : 0;
  at += 2;
  int read(int size) {
    final value = switch (size) {
      0 => 0,
      4 => _u32be(data, at),
      8 => _u64be(data, at),
      _ => throw const FormatException('iloc field size'),
    };
    at += size;
    return value;
  }

  final itemCount = version < 2 ? _u16be(data, at) : _u32be(data, at);
  at += version < 2 ? 2 : 4;
  for (var i = 0; i < itemCount && i < 4096 && at < iloc.end; i++) {
    final id = version < 2 ? _u16be(data, at) : _u32be(data, at);
    at += version < 2 ? 2 : 4;
    var constructionMethod = 0;
    if (version == 1 || version == 2) {
      constructionMethod = _u16be(data, at) & 0xf;
      at += 2;
    }
    at += 2; // data_reference_index
    final baseOffset = read(baseOffsetSize);
    final extentCount = _u16be(data, at);
    at += 2;
    for (var e = 0; e < extentCount; e++) {
      read(indexSize);
      final offset = read(offsetSize);
      final length = read(lengthSize);
      if (e == 0 && constructionMethod == 0) {
        locations[id] = (baseOffset + offset, length);
      }
    }
  }
  return locations;
}

/// The properties (1 based indexes into ipco) of each item of the ipma box
Map<int, List<int>> _itemProperties(Uint8List data, _Box ipma) {
  final result = <int, List<int>>{};
  final version = data[ipma.content];
  final wideIndexes = data[ipma.content + 3] & 1 != 0;
  var at = ipma.content + 4;
  final count = _u32be(data, at);
  at += 4;
  for (var i = 0; i < count && i < 4096 && at < ipma.end; i++) {
    final id = version < 1 ? _u16be(data, at) : _u32be(data, at);
    at += version < 1 ? 2 : 4;
    final associationCount = data[at++];
    final indexes = <int>[];
    for (var a = 0; a < associationCount; a++) {
      if (wideIndexes) {
        indexes.add(_u16be(data, at) & 0x7fff);
        at += 2;
      } else {
        indexes.add(data[at++] & 0x7f);
      }
    }
    result[id] = indexes;
  }
  return result;
}
