// The EXIF of a splat photo (plan of 3 November 2026, section 2.2): the few tags a poster needs, so that Immich files
// the scene at its date and place, shows it upright, and so that the details pane of Windows writes a rating or a title
// in place (with room in the file, Windows writes into the padding; without, it saves the whole JPEG again and the
// scene after it is lost).
//
// Little endian TIFF, offsets from its header, the tags of each IFD in ascending order, each value longer than 4 bytes
// in the data after its IFD (padded to an even length): the padding first, right after the table, then the others in
// the order of their tags:
//
// * IFD0: Orientation 1, XResolution and YResolution 72, ResolutionUnit inches, Software, YCbCrPositioning centred,
//   the Exif IFD, the GPS IFD when a place is known, and Padding (0xEA1C, the tag Windows writes: 0x1C 0xEA 0 0 0 8
//   then zeros, [splatPhotoPadding] bytes);
// * Exif IFD: ExifVersion 0232, DateTimeOriginal and OffsetTimeOriginal when a date is known, ComponentsConfiguration,
//   FlashpixVersion 0100, ColorSpace sRGB, PixelXDimension and PixelYDimension;
// * GPS IFD: GPSVersionID 2.3.0.0, latitude and longitude in degrees, minutes and seconds (hundredths of a second as
//   10000ths).
//
// No thumbnail IFD. .github/desktop/ai/make_splat_photo_fixtures.py writes the same bytes, which the tests compare.

import 'dart:convert';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';

/// "Exif\0\0", the start of the APP1 segment of an EXIF
final exifSignature = latin1.encode('Exif\x00\x00');

/// A date with its offset from UTC as the EXIF and the packet write it: the wall clock of the place the scene was saved
/// or made in, and that place's offset
class SplatPhotoDate {
  const SplatPhotoDate(
    this.year,
    this.month,
    this.day,
    this.hour,
    this.minute,
    this.second, {
    required this.offsetMinutes,
  });

  /// The wall clock of [time] and its offset (the zone of this device for a local time, 0 for a UTC one)
  factory SplatPhotoDate.of(DateTime time) => SplatPhotoDate(
    time.year,
    time.month,
    time.day,
    time.hour,
    time.minute,
    time.second,
    offsetMinutes: time.timeZoneOffset.inMinutes,
  );

  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;
  final int offsetMinutes;

  static String _two(int value) => value.toString().padLeft(2, '0');

  /// "+01:00"
  String get offset {
    final minutes = offsetMinutes.abs();
    return '${offsetMinutes < 0 ? '-' : '+'}${_two(minutes ~/ 60)}:${_two(minutes % 60)}';
  }

  /// "2026:11:03 16:53:00", DateTimeOriginal
  String get exif =>
      '${year.toString().padLeft(4, '0')}:${_two(month)}:${_two(day)} ${_two(hour)}:${_two(minute)}:${_two(second)}';

  /// "2026-11-03T16:53:00+01:00", Immuch360:Created
  String get iso =>
      '${year.toString().padLeft(4, '0')}-${_two(month)}-${_two(day)}T${_two(hour)}:${_two(minute)}:${_two(second)}'
      '$offset';

  /// The moment in UTC, for the dates of the upload
  DateTime get utc => DateTime.utc(year, month, day, hour, minute, second).subtract(Duration(minutes: offsetMinutes));

  @override
  bool operator ==(Object other) => other is SplatPhotoDate && other.iso == iso;

  @override
  int get hashCode => iso.hashCode;

  @override
  String toString() => iso;
}

// The types of the TIFF fields
const _byte = 1;
const _ascii = 2;
const _short = 3;
const _long = 4;
const _rational = 5;
const _undefined = 7;

/// The padding tag of Windows
const _paddingTag = 0xEA1C;

class _Entry {
  _Entry(this.tag, this.type, this.count, this.value);

  final int tag;
  final int type;
  final int count;

  /// The bytes of the value, little endian, as long as count times the size of the type
  final Uint8List value;
}

Uint8List _shorts(List<int> values) {
  final data = ByteData(2 * values.length);
  for (var i = 0; i < values.length; i++) {
    data.setUint16(2 * i, values[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

Uint8List _longs(List<int> values) {
  final data = ByteData(4 * values.length);
  for (var i = 0; i < values.length; i++) {
    data.setUint32(4 * i, values[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

Uint8List _rationals(List<(int, int)> values) => _longs([
  for (final (n, d) in values) ...[n, d],
]);

_Entry _asciiEntry(int tag, String text) {
  final bytes = Uint8List.fromList([...latin1.encode(text), 0]);
  return _Entry(tag, _ascii, bytes.length, bytes);
}

/// The bytes of the padding tag, as Windows writes it
Uint8List splatPhotoPaddingValue([int length = splatPhotoPadding]) {
  final value = Uint8List(length);
  value.setAll(0, const [0x1C, 0xEA, 0x00, 0x00, 0x00, 0x08]);
  return value;
}

/// [degrees] as the GPS IFD writes them: degrees, minutes, seconds with 4 decimals
List<(int, int)> _dms(double degrees) {
  final value = degrees.abs();
  var whole = value.floor();
  var minutes = ((value - whole) * 60).floor();
  var seconds = (((value - whole) * 60 - minutes) * 60 * 10000).round();
  if (seconds >= 600000) {
    seconds -= 600000;
    minutes++;
  }
  if (minutes >= 60) {
    minutes -= 60;
    whole++;
  }
  return [(whole, 1), (minutes, 1), (seconds, 10000)];
}

int _typeSize(int type) => switch (type) {
  _short => 2,
  _long => 4,
  _rational => 8,
  _ => 1,
};

/// An IFD of [entries] at [offset] of the TIFF, with [next] as the offset of the next IFD: its bytes, values that do
/// not fit in an entry after it
Uint8List _ifd(List<_Entry> entries, int offset, {int next = 0}) {
  entries.sort((a, b) => a.tag.compareTo(b.tag));
  final tableLength = 2 + 12 * entries.length + 4;
  final table = ByteData(tableLength);
  // The values that do not fit in their entry: the padding first, right after the table (Windows grows the table into
  // it when it adds a tag in place, a rating or a title; a padding further away, measured on 4 November 2026, makes
  // it save the whole JPEG again), then the others in the order of their tags
  final data = BytesBuilder();
  final places = <int, int>{};
  for (final entry in [...entries.where((e) => e.tag == _paddingTag), ...entries.where((e) => e.tag != _paddingTag)]) {
    final size = entry.count * _typeSize(entry.type);
    if (entry.value.length != size) {
      throw ArgumentError('tag 0x${entry.tag.toRadixString(16)}: ${entry.value.length} bytes for $size');
    }
    if (size > 4) {
      places[entry.tag] = data.length;
      data.add(entry.value);
      if (size.isOdd) {
        data.addByte(0);
      }
    }
  }
  table.setUint16(0, entries.length, Endian.little);
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final at = 2 + 12 * i;
    table.setUint16(at, entry.tag, Endian.little);
    table.setUint16(at + 2, entry.type, Endian.little);
    table.setUint32(at + 4, entry.count, Endian.little);
    final size = entry.count * _typeSize(entry.type);
    if (size <= 4) {
      for (var b = 0; b < size; b++) {
        table.setUint8(at + 8 + b, entry.value[b]);
      }
    } else {
      table.setUint32(at + 8, offset + tableLength + places[entry.tag]!, Endian.little);
    }
  }
  table.setUint32(tableLength - 4, next, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(table.buffer.asUint8List())
        ..add(data.takeBytes()))
      .takeBytes();
}

/// The EXIF of a poster of [width] x [height] pixels (see the top of this file), from "Exif\0\0" on: the payload of its
/// APP1 segment. [taken] is the scene's date, [latitude] and [longitude] its place when known.
Uint8List splatPhotoExif({
  required int width,
  required int height,
  required String software,
  SplatPhotoDate? taken,
  double? latitude,
  double? longitude,
}) {
  final lat = latitude ?? double.nan;
  final lon = longitude ?? double.nan;
  final hasPlace = lat.isFinite && lon.isFinite && lat.abs() <= 90 && lon.abs() <= 180;
  // The offsets of each IFD depend on the sizes of the ones before: built in the order of the file
  const ifd0Offset = 8;
  List<_Entry> ifd0Entries(int exifOffset, int? gpsOffset) => [
    _Entry(0x0112, _short, 1, _shorts([1])),
    _Entry(0x011A, _rational, 1, _rationals([(72, 1)])),
    _Entry(0x011B, _rational, 1, _rationals([(72, 1)])),
    _Entry(0x0128, _short, 1, _shorts([2])),
    _asciiEntry(0x0131, software),
    _Entry(0x0213, _short, 1, _shorts([1])),
    _Entry(0x8769, _long, 1, _longs([exifOffset])),
    if (gpsOffset != null) _Entry(0x8825, _long, 1, _longs([gpsOffset])),
    _Entry(_paddingTag, _undefined, splatPhotoPadding, splatPhotoPaddingValue()),
  ];
  // First with placeholders, for the size of IFD0 (offsets do not change sizes)
  final ifd0Size = _ifd(ifd0Entries(0, hasPlace ? 0 : null), ifd0Offset).length;
  final exifOffset = ifd0Offset + ifd0Size;
  final exifEntries = [
    _Entry(0x9000, _undefined, 4, latin1.encode('0232')),
    if (taken != null) _asciiEntry(0x9003, taken.exif),
    if (taken != null) _asciiEntry(0x9011, taken.offset),
    _Entry(0x9101, _undefined, 4, Uint8List.fromList(const [1, 2, 3, 0])),
    _Entry(0xA000, _undefined, 4, latin1.encode('0100')),
    _Entry(0xA001, _short, 1, _shorts([1])),
    _Entry(0xA002, _long, 1, _longs([width])),
    _Entry(0xA003, _long, 1, _longs([height])),
  ];
  final exif = _ifd(exifEntries, exifOffset);
  final gpsOffset = hasPlace ? exifOffset + exif.length : null;
  final gps = hasPlace
      ? _ifd([
          _Entry(0x0000, _byte, 4, Uint8List.fromList(const [2, 3, 0, 0])),
          _asciiEntry(0x0001, lat >= 0 ? 'N' : 'S'),
          _Entry(0x0002, _rational, 3, _rationals(_dms(lat))),
          _asciiEntry(0x0003, lon >= 0 ? 'E' : 'W'),
          _Entry(0x0004, _rational, 3, _rationals(_dms(lon))),
        ], gpsOffset!)
      : null;
  final ifd0 = _ifd(ifd0Entries(exifOffset, gpsOffset), ifd0Offset);
  final out = BytesBuilder(copy: false)
    ..add(exifSignature)
    ..add(const [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
    ..add(ifd0)
    ..add(exif);
  if (gps != null) {
    out.add(gps);
  }
  return out.takeBytes();
}
