// Reads back the ZIP archives of zip_writer.dart for the tests, from the central directory as an unzip tool does,
// checking each entry against its local header and its CRC-32.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/files/zip_writer.dart';

/// The entries of [archive] in their order, by name
Map<String, Uint8List> readZip(Uint8List archive) {
  final data = ByteData.sublistView(archive);
  final end = archive.length - 22;
  if (data.getUint32(end, Endian.little) != 0x06054b50) {
    throw const FormatException('no end of central directory record');
  }
  final count = data.getUint16(end + 10, Endian.little);
  var offset = data.getUint32(end + 16, Endian.little);
  final entries = <String, Uint8List>{};
  for (var index = 0; index < count; index++) {
    if (data.getUint32(offset, Endian.little) != 0x02014b50) {
      throw const FormatException('bad central directory header');
    }
    final flags = data.getUint16(offset + 8, Endian.little);
    final method = data.getUint16(offset + 10, Endian.little);
    final crc = data.getUint32(offset + 16, Endian.little);
    final compressed = data.getUint32(offset + 20, Endian.little);
    final size = data.getUint32(offset + 24, Endian.little);
    final nameLength = data.getUint16(offset + 28, Endian.little);
    final extraLength = data.getUint16(offset + 30, Endian.little);
    final commentLength = data.getUint16(offset + 32, Endian.little);
    final local = data.getUint32(offset + 42, Endian.little);
    final name = utf8.decode(archive.sublist(offset + 46, offset + 46 + nameLength));
    if (flags & 0x0800 == 0 || method != 8) {
      throw FormatException('unexpected flags $flags or method $method for $name');
    }

    if (data.getUint32(local, Endian.little) != 0x04034b50 ||
        data.getUint32(local + 14, Endian.little) != crc ||
        data.getUint32(local + 18, Endian.little) != compressed) {
      throw FormatException('local header of $name differs from the central one');
    }
    final start = local + 30 + data.getUint16(local + 26, Endian.little) + data.getUint16(local + 28, Endian.little);
    final bytes = Uint8List.fromList(ZLibDecoder(raw: true).convert(archive.sublist(start, start + compressed)));
    if (bytes.length != size || crc32(bytes) != crc) {
      throw FormatException('$name does not match its size or CRC');
    }
    entries[name] = bytes;
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}
