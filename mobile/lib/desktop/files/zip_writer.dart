// A ZIP archive of a few small files, for "Save logs to a file" when crash reports of the native code sit next to the
// logs: one file to attach to an issue rather than a log and a folder of minidumps. The app has no archive package of
// its own, and what is needed here is small: deflated entries, their CRC-32, the central directory, no ZIP64 (the
// logs and minidumps are far below 4 GB).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One file of a [zipFiles] archive
class ZipEntry {
  /// The name inside the archive, with / between folders
  final String name;
  final Uint8List bytes;
  final DateTime modified;

  const ZipEntry({required this.name, required this.bytes, required this.modified});
}

/// The bytes of a ZIP archive holding [entries], deflated
Uint8List zipFiles(List<ZipEntry> entries) {
  final out = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  for (final entry in entries) {
    final name = utf8.encode(entry.name);
    final deflated = Uint8List.fromList(ZLibEncoder(raw: true, level: 6).convert(entry.bytes));
    final crc = crc32(entry.bytes);
    final (time, date) = _dosDateTime(entry.modified);
    final offset = out.length;

    out.add(
      _header(
        signature: 0x04034b50,
        fields: [_u16(20), _u16(_utf8NamesFlag), _u16(8), _u16(time), _u16(date)],
        crc: crc,
        compressed: deflated.length,
        size: entry.bytes.length,
        name: name,
        trailer: [_u16(0)],
      ),
    );
    out.add(deflated);

    central.add(
      _header(
        signature: 0x02014b50,
        fields: [_u16(20), _u16(20), _u16(_utf8NamesFlag), _u16(8), _u16(time), _u16(date)],
        crc: crc,
        compressed: deflated.length,
        size: entry.bytes.length,
        name: name,
        // extra length, comment length, disk number, internal attributes, external attributes, local header offset
        trailer: [_u16(0), _u16(0), _u16(0), _u16(0), _u32(0), _u32(offset)],
      ),
    );
  }

  final centralOffset = out.length;
  final centralBytes = central.takeBytes();
  out.add(centralBytes);
  out.add(
    Uint8List.fromList([
      ..._u32(0x06054b50),
      ..._u16(0),
      ..._u16(0),
      ..._u16(entries.length),
      ..._u16(entries.length),
      ..._u32(centralBytes.length),
      ..._u32(centralOffset),
      ..._u16(0),
    ]),
  );
  return out.takeBytes();
}

/// Bit 11 of the general purpose flags: the names are UTF-8
const _utf8NamesFlag = 0x0800;

/// A local or central header: signature, the fields before the CRC, CRC and sizes, name length, then the fields
/// after the name length and the name itself
Uint8List _header({
  required int signature,
  required List<List<int>> fields,
  required int crc,
  required int compressed,
  required int size,
  required Uint8List name,
  required List<List<int>> trailer,
}) => Uint8List.fromList([
  ..._u32(signature),
  for (final field in fields) ...field,
  ..._u32(crc),
  ..._u32(compressed),
  ..._u32(size),
  ..._u16(name.length),
  for (final field in trailer) ...field,
  ...name,
]);

List<int> _u16(int value) => [value & 0xFF, (value >> 8) & 0xFF];

List<int> _u32(int value) => [value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF, (value >> 24) & 0xFF];

/// The MS-DOS time and date of [moment] in local time, as ZIP stores them: two seconds of precision, 1980 at the
/// earliest
(int, int) _dosDateTime(DateTime moment) {
  final local = moment.toLocal();
  if (local.year < 1980) {
    // 1980-01-01 00:00
    return (0, (1 << 5) | 1);
  }
  final time = (local.hour << 11) | (local.minute << 5) | (local.second ~/ 2);
  final date = ((local.year - 1980) << 9) | (local.month << 5) | local.day;
  return (time, date);
}

final _crcTable = List<int>.generate(256, (index) {
  var value = index;
  for (var bit = 0; bit < 8; bit++) {
    value = (value & 1) != 0 ? 0xEDB88320 ^ (value >> 1) : value >> 1;
  }
  return value;
}, growable: false);

/// The CRC-32 of [bytes], the checksum ZIP keeps per entry
int crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}
