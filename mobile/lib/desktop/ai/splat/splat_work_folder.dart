// The work folder of one splat scene (plan 2026-11-01, sections 2.2 and 3, lot SP4; design risk-first of 1 November
// 2026, sections 2.7 and 6), where COLMAP and Brush read and write:
//   dataset/images/<group>/000001.jpg   the photos prepared or the frames taken (lot SP5), one folder per group of
//                                        cameras; COLMAP's --image_path, and the images/ Brush reads
//   colmap/database.db, colmap/sparse/<n>/   the points, the matches and the models of the mapper
//   dataset/sparse/0/                    the largest model, upright (model_orientation_aligner): what Brush reads
//   brush/export_<steps>.ply             what Brush writes
//   logs/colmap-*.log, logs/brush.log    every line of the programs, kept with the folder after a failure
// COLMAP takes its paths as narrow strings on Windows: a folder whose path is not ASCII (a user name with an accent in
// %TEMP%) may not open there. Known of COLMAP, not measured here. So the folder is given to COLMAP by an ASCII path:
// its own when it is one, else its short name (GetShortPathNameW, the 8.3 name, which a volume may not keep), else the
// job goes to another root whose path is ASCII ([asciiWorkRoot]); the names inside the folder are always ASCII.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// The paths of the work folder of one splat scene (see the top of this file)
class SplatWorkFolder {
  SplatWorkFolder(this.root);

  final Directory root;

  /// What Brush reads: images/ and sparse/0
  Directory get dataset => Directory(p.join(root.path, 'dataset'));

  /// The photos or the frames, one folder per group of cameras
  Directory get images => Directory(p.join(dataset.path, 'images'));

  Directory get colmap => Directory(p.join(root.path, 'colmap'));
  File get database => File(p.join(colmap.path, 'database.db'));

  /// Where the mapper writes its models, 0, 1...
  Directory get sparse => Directory(p.join(colmap.path, 'sparse'));

  /// The largest model, upright
  Directory get aligned => Directory(p.join(dataset.path, 'sparse', '0'));

  /// Where Brush writes its export
  Directory get export => Directory(p.join(root.path, 'brush'));

  Directory get logs => Directory(p.join(root.path, 'logs'));

  /// The log of a program, "colmap-features", "brush"
  File logOf(String name) => File(p.join(logs.path, '$name.log'));
}

/// Whether every character of [path] is ASCII
bool isAsciiPath(String path) => path.codeUnits.every((unit) => unit < 0x80);

/// A path of the existing [folder] made of ASCII characters only: its own, else its short name on Windows
/// ([shortPathOf], GetShortPathNameW by default); null when it has none
String? asciiPathOf(Directory folder, {bool? isWindows, String? Function(String path)? shortPathOf}) {
  final path = folder.absolute.path;
  if (isAsciiPath(path)) {
    return path;
  }
  if (!(isWindows ?? Platform.isWindows)) {
    return null;
  }
  final short = (shortPathOf ?? windowsShortPath)(path);
  return short != null && isAsciiPath(short) ? short : null;
}

/// The first of [roots] that exists, or can be made, and has an ASCII path ([asciiPathOf]), as that path; null when
/// none has. The app gives the folder of its work folders under the temporary folder of the system first, then a folder
/// of ProgramData on Windows, whose path is ASCII on every Windows of a Latin script.
Directory? asciiWorkRoot(List<Directory> roots, {bool? isWindows, String? Function(String path)? shortPathOf}) {
  for (final root in roots) {
    try {
      root.createSync(recursive: true);
    } on FileSystemException {
      continue;
    }
    final path = asciiPathOf(root, isWindows: isWindows, shortPathOf: shortPathOf);
    if (path != null) {
      return Directory(path);
    }
  }
  return null;
}

/// The folders the app tries for its splat work folders, in order: `<temp>/immuch360-ai`, then on Windows
/// `%ProgramData%/Immuch360/ai-work`
List<Directory> splatWorkRoots({Map<String, String>? environment, bool? isWindows, Directory? temp}) {
  final env = environment ?? Platform.environment;
  final programData = env['ProgramData'] ?? env['PROGRAMDATA'];
  return [
    Directory(p.join((temp ?? Directory.systemTemp).path, 'immuch360-ai')),
    if ((isWindows ?? Platform.isWindows) && programData != null && programData.isNotEmpty)
      Directory(p.join(programData, 'Immuch360', 'ai-work')),
  ];
}

typedef _ShortPathNative = Uint32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _ShortPath = int Function(Pointer<Utf16>, Pointer<Utf16>, int);

_ShortPath? _shortPathFunction;

/// The short (8.3) path of the existing [path] by GetShortPathNameW of kernel32; the long path itself when the volume
/// keeps no short names; null when Windows refused (the path does not exist)
String? windowsShortPath(String path) {
  final shortPath = _shortPathFunction ??= DynamicLibrary.open(
    'kernel32.dll',
  ).lookupFunction<_ShortPathNative, _ShortPath>('GetShortPathNameW');
  const capacity = 32768;
  final long = path.toNativeUtf16();
  final buffer = calloc<Uint16>(capacity).cast<Utf16>();
  try {
    final length = shortPath(long, buffer, capacity);
    return length == 0 || length >= capacity ? null : buffer.toDartString(length: length);
  } finally {
    calloc.free(long);
    calloc.free(buffer);
  }
}
