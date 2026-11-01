// The work folder of one splat scene (plan 2026-11-01, sections 2.2 and 3, lot SP4; design risk-first of 1 November
// 2026, sections 2.7 and 6), where COLMAP and Brush read and write:
//   dataset/images/<group>/000001.jpg   the photos prepared or the frames taken (lot SP5), one folder per group of
//                                        cameras; COLMAP's --image_path, and the images/ Brush reads
//   colmap/database.db, colmap/sparse/<n>/   the points, the matches and the models of the mapper
//   dataset/sparse/0/                    the largest model, upright (model_orientation_aligner): what Brush reads
//   brush/export_<steps>.ply             what Brush writes
//   logs/colmap-*.log, logs/brush.log    every line of the programs, kept with the folder after a failure
// COLMAP takes its paths as narrow strings on Windows: our build fails on a folder named "été Łódź" and passes on "été"
// (lot SP4, measured on 1 November; the ANSI code page of that PC, 1252, holds é and not Ł). So the folder is given to
// COLMAP by an ASCII path: its own when it is one, else its short name (GetShortPathNameW, the 8.3 name, which a volume
// may not keep), else the job goes to another root whose path is ASCII ([asciiWorkRoot]); the names inside the folder
// are always ASCII. That other root is a folder of ProgramData, one per account, named by its security id: ProgramData
// lets every account of the computer read what it holds, so the folder of an account first gets a whole new list of
// rules, the account and SYSTEM alone ([windowsMakePrivate]: SetNamedSecurityInfoW, in one go, the rules of its own
// replaced too, what it holds following), and is never used when it cannot (the photos of the user are in it).
// Removing the folders left there by an app that died is the work of the queue (lot SP6), with the rule of the
// temporary folder.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:immich_mobile/desktop/ai/creator/write_failure.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
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

/// A root of the work folders: [folder], and whether other accounts of the computer may read what it holds as it comes
/// ([shared], under ProgramData), so that it is made private before it is used
class SplatWorkRoot {
  const SplatWorkRoot(this.folder, {this.shared = false});

  final Directory folder;
  final bool shared;
}

/// The first of [roots] that exists, or can be made, that is private ([makePrivate] for a shared one,
/// [windowsMakePrivate] by default) and has an ASCII path ([asciiPathOf]), as that path; null when none has.
Directory? asciiWorkRoot(
  List<SplatWorkRoot> roots, {
  bool? isWindows,
  String? Function(String path)? shortPathOf,
  bool Function(Directory folder)? makePrivate,
}) {
  for (final root in roots) {
    try {
      root.folder.createSync(recursive: true);
    } on FileSystemException {
      continue;
    }
    if (root.shared && !(makePrivate ?? (folder) => windowsMakePrivate(folder))(root.folder)) {
      continue;
    }
    final path = asciiPathOf(root.folder, isWindows: isWindows, shortPathOf: shortPathOf);
    if (path != null) {
      return Directory(path);
    }
  }
  return null;
}

/// The roots the app tries for its splat work folders, in order: `<temp>/immuch360-ai`, then on Windows
/// `%ProgramData%/Immuch360/ai-work/<security id of the account>` ([userSid], [windowsUserSid] by default), shared
/// until made private; none of ProgramData when the account is not known
List<SplatWorkRoot> splatWorkRoots({
  Map<String, String>? environment,
  bool? isWindows,
  Directory? temp,
  String? Function()? userSid,
}) {
  final env = environment ?? Platform.environment;
  final programData = env['ProgramData'] ?? env['PROGRAMDATA'];
  final windows = isWindows ?? Platform.isWindows;
  final sid = windows && programData != null && programData.isNotEmpty ? (userSid ?? windowsUserSid)() : null;
  return [
    SplatWorkRoot(Directory(p.join((temp ?? Directory.systemTemp).path, 'immuch360-ai'))),
    if (sid != null) SplatWorkRoot(Directory(p.join(programData!, 'Immuch360', 'ai-work', sid)), shared: true),
  ];
}

final _sid = RegExp(r'S-1-\d+(?:-\d+)+');

/// The security id in what `whoami /user /fo csv /nh` wrote ("domain\user","S-1-5-21-...-1001"); null without one
String? sidOfWhoami(String output) => _sid.firstMatch(output)?.group(0);

/// The security id of the account the app runs under, by whoami; null when it cannot be read
String? windowsUserSid() {
  try {
    final result = Process.runSync('whoami', ['/user', '/fo', 'csv', '/nh']);
    return result.exitCode == 0 ? sidOfWhoami('${result.stdout}') : null;
  } on ProcessException {
    return null;
  }
}

/// The rules of a folder of the account [sid] and SYSTEM alone, in SDDL: protected from those of its parent, full
/// control to both, inherited by its folders and its files
String windowsPrivateDacl(String sid) => 'D:P(A;OICI;FA;;;$sid)(A;OICI;FA;;;SY)';

typedef _SddlNative = Int32 Function(Pointer<Utf16>, Uint32, Pointer<Pointer<Void>>, Pointer<Uint32>);
typedef _Sddl = int Function(Pointer<Utf16>, int, Pointer<Pointer<Void>>, Pointer<Uint32>);
typedef _DaclNative = Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Pointer<Void>>, Pointer<Int32>);
typedef _Dacl = int Function(Pointer<Void>, Pointer<Int32>, Pointer<Pointer<Void>>, Pointer<Int32>);
typedef _SetSecurityNative =
    Uint32 Function(Pointer<Utf16>, Int32, Uint32, Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _SetSecurity =
    int Function(Pointer<Utf16>, int, int, Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);

/// SE_FILE_OBJECT, and DACL_SECURITY_INFORMATION with PROTECTED_DACL_SECURITY_INFORMATION
const _fileObject = 1;
const _protectedDacl = 0x80000004;

/// Gives [folder] the rules of the account ([sid], [windowsUserSid] by default) and SYSTEM alone ([windowsPrivateDacl])
/// in one go, by SetNamedSecurityInfoW of advapi32: the rules it inherited and those of its own replaced, what it holds
/// inheriting the new ones; whether it did
bool windowsMakePrivate(Directory folder, {String? sid}) {
  final account = sid ?? windowsUserSid();
  if (account == null) {
    return false;
  }
  final advapi = DynamicLibrary.open('advapi32.dll');
  final toDescriptor = advapi.lookupFunction<_SddlNative, _Sddl>(
    'ConvertStringSecurityDescriptorToSecurityDescriptorW',
  );
  final daclOf = advapi.lookupFunction<_DaclNative, _Dacl>('GetSecurityDescriptorDacl');
  final setSecurity = advapi.lookupFunction<_SetSecurityNative, _SetSecurity>('SetNamedSecurityInfoW');
  final localFree = DynamicLibrary.open('kernel32.dll').lookupFunction<_LocalFreeNative, _LocalFreeNative>('LocalFree');
  final sddl = windowsPrivateDacl(account).toNativeUtf16();
  final path = folder.path.toNativeUtf16();
  final descriptor = calloc<Pointer<Void>>();
  final dacl = calloc<Pointer<Void>>();
  final present = calloc<Int32>();
  final defaulted = calloc<Int32>();
  try {
    // SDDL_REVISION_1
    if (toDescriptor(sddl, 1, descriptor, nullptr) == 0) {
      return false;
    }
    try {
      if (daclOf(descriptor.value, present, dacl, defaulted) == 0 || present.value == 0) {
        return false;
      }
      return setSecurity(path, _fileObject, _protectedDacl, nullptr, nullptr, dacl.value, nullptr) == 0;
    } finally {
      localFree(descriptor.value);
    }
  } finally {
    calloc.free(sddl);
    calloc.free(path);
    calloc.free(descriptor);
    calloc.free(dacl);
    calloc.free(present);
    calloc.free(defaulted);
  }
}

/// A file of the work folder that [program] could not make, read or remove ([error]) as the failure of its step:
/// diskFull when the disk is full, else [otherwise]
BackendException splatFileFailure(
  FileSystemException error,
  String program,
  ImmersiveErrorCode otherwise, {
  bool? windows,
}) {
  final full = writeFailureOf(error, windows: windows) == WriteFailure.diskFull;
  final os = error.osError == null ? '' : ' (${error.osError!.message})';
  return BackendException(
    full ? ImmersiveErrorCode.diskFull : otherwise,
    'The work folder of $program refused a file: ${error.message}, ${error.path}$os',
  );
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
