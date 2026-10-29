// The free space of the drive that holds the AI components (design-final 2026-10-27, section 7.1, point 6): read
// before the first byte of an installation, so that 7 GB of panorama components are refused at once on a drive that
// cannot hold them, with the drive named and the move of the components offered, rather than after an hour of
// download on a full disk. Windows: GetDiskFreeSpaceExW (the space this user may take, quotas included). Linux and
// macOS: statvfs (the blocks free for a user that is not root), the drive named by the folder it is mounted on. A
// folder not made yet is read on the drive of its nearest folder that exists. Nothing is written.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('DiskSpace');

/// The free space of the drive of [folder], null when it cannot be read (the check then refuses nothing)
Future<AiFreeSpace?> systemFreeSpace(Directory folder) async {
  try {
    final existing = _nearestExisting(folder.absolute.path);
    if (existing == null) {
      return null;
    }
    return Platform.isWindows ? _windows(existing) : _statvfsDrive(existing);
  } catch (error) {
    _log.warning('The free space of ${folder.path} could not be read: $error');
    return null;
  }
}

String? _nearestExisting(String path) {
  var current = p.normalize(path);
  while (!Directory(current).existsSync()) {
    final parent = p.dirname(current);
    if (parent == current) {
      return null;
    }
    current = parent;
  }
  return current;
}

typedef _GetDiskFreeSpaceExNative =
    Int32 Function(Pointer<Utf16> directory, Pointer<Uint64> available, Pointer<Uint64> total, Pointer<Uint64> free);
typedef _GetDiskFreeSpaceEx =
    int Function(Pointer<Utf16> directory, Pointer<Uint64> available, Pointer<Uint64> total, Pointer<Uint64> free);

AiFreeSpace? _windows(String path) {
  final call = DynamicLibrary.open(
    'kernel32.dll',
  ).lookupFunction<_GetDiskFreeSpaceExNative, _GetDiskFreeSpaceEx>('GetDiskFreeSpaceExW');
  final directory = path.toNativeUtf16();
  final numbers = calloc<Uint64>(3);
  try {
    if (call(directory, numbers, numbers + 1, numbers + 2) == 0) {
      return null;
    }
    // "C:\" gives "C:", a share "\\server\share\" its name
    final root = p.rootPrefix(path);
    final volume = root.endsWith(r'\') && root.length > 1 ? root.substring(0, root.length - 1) : root;
    return AiFreeSpace(free: numbers[0], total: numbers[1], volume: volume);
  } finally {
    calloc.free(directory);
    calloc.free(numbers);
  }
}

typedef _StatvfsNative = Int32 Function(Pointer<Utf8> path, Pointer<Uint8> buffer);
typedef _Statvfs = int Function(Pointer<Utf8> path, Pointer<Uint8> buffer);

/// What statvfs gives of a path: the free and total bytes, and the id of its file system
({int free, int total, int fsid})? _statvfs(String path) {
  final call = DynamicLibrary.process().lookupFunction<_StatvfsNative, _Statvfs>('statvfs');
  final native = path.toNativeUtf8();
  // struct statvfs is 112 bytes with glibc on x86_64 and 64 bytes on macOS
  final buffer = calloc<Uint8>(512);
  try {
    if (call(native, buffer) != 0) {
      return null;
    }
    final words = buffer.cast<Uint64>();
    final fragment = words[1];
    if (Platform.isMacOS) {
      // f_bsize, f_frsize, then 32 bit counts: f_blocks, f_bfree, f_bavail, f_files, f_ffree, f_favail, then f_fsid
      final counts = (buffer + 16).cast<Uint32>();
      return (free: counts[2] * fragment, total: counts[0] * fragment, fsid: words[5]);
    }
    // f_bsize, f_frsize, f_blocks, f_bfree, f_bavail, f_files, f_ffree, f_favail, f_fsid
    return (free: words[4] * fragment, total: words[2] * fragment, fsid: words[8]);
  } finally {
    calloc.free(native);
    calloc.free(buffer);
  }
}

AiFreeSpace? _statvfsDrive(String path) {
  final space = _statvfs(path);
  if (space == null) {
    return null;
  }
  // The drive is named by the folder it is mounted on: the highest folder of the path on the same file system
  var mount = path;
  while (true) {
    final parent = p.dirname(mount);
    if (parent == mount || _statvfs(parent)?.fsid != space.fsid) {
      break;
    }
    mount = parent;
  }
  return AiFreeSpace(free: space.free, total: space.total, volume: mount);
}
