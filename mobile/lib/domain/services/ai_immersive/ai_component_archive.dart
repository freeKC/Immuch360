// The installation of an AI component that is an archive (design-final 2026-10-27, section 7.1, point 4): an engine of
// several files, stable-diffusion.cpp with its libraries, which our CI zips with the list of its files. The archive
// has already passed its own size and SHA-256 at the download; here each file inside is checked against the catalogue
// (its path, size and sum), unpacked into a folder beside the final one, made executable when the catalogue says it is
// a program, then the folder is renamed to its place under engines/. A path that is absolute, goes up, or uses "\" is
// refused before anything is written, and so is a file the catalogue does not list: nothing is ever written out of
// the folder of the engine. The bytes are written as they are, so the Authenticode signature of a Windows file stays.
//
// The zip is read here, without a package: the central directory, stored or deflated entries, no ZIP64 (an engine is
// tens of MB), no encryption. Used by the computers only; the Quest has no archive.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:path/path.dart' as p;

/// Whether [path] (with "/" between folders) stays inside the folder it is unpacked into
bool isSafeArchivePath(String path) =>
    path.isNotEmpty &&
    !path.startsWith('/') &&
    !path.contains(r'\') &&
    !RegExp(r'^[A-Za-z]:').hasMatch(path) &&
    path.split('/').every((part) => part.isNotEmpty && part != '.' && part != '..');

/// Makes [path] executable by its owner, its group and the others (mode 755); nothing on Windows
typedef AiSetExecutable = Future<void> Function(String path);

/// Unpacks [archive] into [folder], replacing what is there, each file checked against [files]; see the top of this
/// file. Throws an [AiDownloadException]: damaged for an archive that is not the one of the catalogue, diskFull or
/// writeFailed when a file cannot be written. On any failure the folder of the engine is left as it was.
Future<void> installAiArchive(
  File archive,
  Directory folder,
  List<AiArchiveFile> files, {
  AiSetExecutable setExecutable = setExecutableBit,
}) async {
  final bytes = await archive.readAsBytes();
  final entries = _readCentralDirectory(bytes);
  final expected = {for (final file in files) file.path: file};
  final seen = <String>{};
  for (final entry in entries) {
    if (entry.isFolder) {
      if (!isSafeArchivePath(entry.name.substring(0, entry.name.length - 1))) {
        throw AiDownloadException(AiDownloadFailure.damaged, 'the archive holds the folder ${entry.name}');
      }
      continue;
    }
    if (!isSafeArchivePath(entry.name)) {
      throw AiDownloadException(AiDownloadFailure.damaged, 'the archive holds ${entry.name}, out of its folder');
    }
    final file = expected[entry.name];
    if (file == null) {
      throw AiDownloadException(AiDownloadFailure.damaged, 'the archive holds ${entry.name}, not in the catalogue');
    }
    if (!seen.add(entry.name) || entry.size != file.size) {
      throw AiDownloadException(AiDownloadFailure.damaged, '${entry.name}: ${entry.size} bytes, not ${file.size}');
    }
  }
  final missing = expected.keys.toSet().difference(seen);
  if (missing.isNotEmpty) {
    throw AiDownloadException(AiDownloadFailure.damaged, 'the archive lacks ${missing.join(', ')}');
  }

  final staging = Directory('${folder.path}.new');
  try {
    await _deleteIfThere(staging);
    await staging.create(recursive: true);
    for (final entry in entries.where((entry) => !entry.isFolder)) {
      final file = expected[entry.name]!;
      final content = _contentOf(bytes, entry);
      final sum = sha256.convert(content).toString();
      if (content.length != file.size || sum != file.sha256) {
        throw AiDownloadException(
          AiDownloadFailure.damaged,
          '${entry.name}: ${content.length} bytes of SHA-256 $sum, the catalogue says ${file.size} bytes of '
          '${file.sha256}',
        );
      }
      final target = File(p.joinAll([staging.path, ...entry.name.split('/')]));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(content, flush: true);
      if (file.executable) {
        await setExecutable(target.path);
      }
    }
    await _deleteIfThere(folder);
    await folder.parent.create(recursive: true);
    await staging.rename(folder.path);
  } on FileSystemException catch (error) {
    await _deleteIfThere(staging).catchError((Object _) {});
    throw AiDownloadException(
      isDiskFull(error) ? AiDownloadFailure.diskFull : AiDownloadFailure.writeFailed,
      error.toString(),
    );
  } on Object {
    await _deleteIfThere(staging).catchError((Object _) {});
    rethrow;
  }
}

Future<void> _deleteIfThere(Directory folder) async {
  if (folder.existsSync()) {
    await folder.delete(recursive: true);
  }
}

/// One file or folder of the central directory of a zip
class _ZipEntry {
  const _ZipEntry(this.name, this.method, this.compressedSize, this.size, this.localHeader);

  final String name;
  final int method;
  final int compressedSize;
  final int size;
  final int localHeader;

  bool get isFolder => name.endsWith('/');
}

List<_ZipEntry> _readCentralDirectory(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  // The end of the central directory: 22 bytes, then a comment of at most 65535 bytes
  var end = -1;
  for (var at = bytes.length - 22; at >= 0 && at >= bytes.length - 22 - 0xFFFF; at--) {
    if (data.getUint32(at, Endian.little) == 0x06054b50) {
      end = at;
      break;
    }
  }
  if (end < 0) {
    throw const AiDownloadException(AiDownloadFailure.damaged, 'not a zip archive');
  }
  final count = data.getUint16(end + 10, Endian.little);
  var at = data.getUint32(end + 16, Endian.little);
  final entries = <_ZipEntry>[];
  for (var index = 0; index < count; index++) {
    if (at + 46 > bytes.length || data.getUint32(at, Endian.little) != 0x02014b50) {
      throw const AiDownloadException(AiDownloadFailure.damaged, 'a broken central directory');
    }
    final flags = data.getUint16(at + 8, Endian.little);
    final method = data.getUint16(at + 10, Endian.little);
    final compressedSize = data.getUint32(at + 20, Endian.little);
    final size = data.getUint32(at + 24, Endian.little);
    final nameLength = data.getUint16(at + 28, Endian.little);
    final extraLength = data.getUint16(at + 30, Endian.little);
    final commentLength = data.getUint16(at + 32, Endian.little);
    final localHeader = data.getUint32(at + 42, Endian.little);
    final name = String.fromCharCodes(bytes, at + 46, at + 46 + nameLength);
    if (flags & 1 != 0 || (method != 0 && method != 8) || [compressedSize, size, localHeader].contains(0xFFFFFFFF)) {
      throw AiDownloadException(AiDownloadFailure.damaged, '$name: encrypted, ZIP64 or of another method');
    }
    entries.add(_ZipEntry(name, method, compressedSize, size, localHeader));
    at += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

/// The bytes of [entry] in the archive [bytes], unpacked
List<int> _contentOf(Uint8List bytes, _ZipEntry entry) {
  final at = entry.localHeader;
  if (at + 30 > bytes.length || ByteData.sublistView(bytes).getUint32(at, Endian.little) != 0x04034b50) {
    throw AiDownloadException(AiDownloadFailure.damaged, '${entry.name}: a broken local header');
  }
  final header = ByteData.sublistView(bytes, at, at + 30);
  final start = at + 30 + header.getUint16(26, Endian.little) + header.getUint16(28, Endian.little);
  if (start + entry.compressedSize > bytes.length) {
    throw AiDownloadException(AiDownloadFailure.damaged, '${entry.name}: the archive ends too soon');
  }
  final stored = Uint8List.sublistView(bytes, start, start + entry.compressedSize);
  if (entry.method == 0) {
    return stored;
  }
  try {
    return ZLibDecoder(raw: true).convert(stored);
  } on FormatException catch (error) {
    throw AiDownloadException(AiDownloadFailure.damaged, '${entry.name}: ${error.message}');
  }
}

/// chmod 755 through the C library of the process (Linux and macOS); nothing on Windows
Future<void> setExecutableBit(String path) async {
  if (Platform.isWindows) {
    return;
  }
  final native = path.toNativeUtf8();
  try {
    final result = Platform.isMacOS
        ? DynamicLibrary.process()
              .lookupFunction<Int32 Function(Pointer<Utf8>, Uint16), int Function(Pointer<Utf8>, int)>('chmod')(
            native,
            0x1ED,
          )
        : DynamicLibrary.process()
              .lookupFunction<Int32 Function(Pointer<Utf8>, Uint32), int Function(Pointer<Utf8>, int)>('chmod')(
            native,
            0x1ED,
          );
    if (result != 0) {
      throw FileSystemException('chmod 755 failed', path);
    }
  } finally {
    malloc.free(native);
  }
}
