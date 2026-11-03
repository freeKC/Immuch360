// The work folder of one splat scene (plan 2026-11-01, sections 2.2 and 3, lot SP4; design risk-first of 1 November
// 2026, sections 2.7 and 6), where COLMAP and Brush read and write:
//   dataset/images/<group>/000001.jpg   the photos prepared or the frames taken (lot SP5), one folder per group of
//                                        cameras; COLMAP's --image_path, and the images/ Brush reads
//   colmap/database.db, colmap/sparse/<n>/   the points, the matches and the models of the mapper
//   colmap/pairs.txt                     the pairs of the frames of a long video, matched by matches_importer
//   dataset/sparse/0/                    the largest model, upright (model_orientation_aligner): what Brush reads
//   brush/export_<steps>.ply             what Brush writes
//   logs/colmap-*.log, logs/brush.log    every line of the programs; after a failure (a Cancel is none), the end of
//                                        each copied into the logs folder of the app as one file,
//                                        splat-<16 hexadecimal digits>-<date>.log, the five newest kept
//                                        ([keepSplatFailureLogs]), which "Save logs to a file" takes with the log: the
//                                        work folder may go with the failure (before the images were prepared, or
//                                        after a Cancel), its logs stay
// COLMAP takes its paths as narrow strings on Windows: our build fails on a folder named "été Łódź" and passes on "été"
// (lot SP4, measured on 1 November; the ANSI code page of that PC, 1252, holds é and not Ł). So the folder is given to
// COLMAP by an ASCII path: its own when it is one, else its short name (GetShortPathNameW, the 8.3 name, which a volume
// may not keep), else the job goes to another root whose path is ASCII ([asciiWorkRoot]); the names inside the folder
// are always ASCII. That other root is a folder of ProgramData, one per account, named by its security id: ProgramData
// lets every account of the computer read what it holds, so the folder of an account first gets a whole new list of
// rules, the account and SYSTEM alone ([windowsMakePrivate]: SetNamedSecurityInfoW, in one go, the rules of its own
// replaced too, what it holds following), and is never used when it cannot (the photos of the user are in it).
// A job's folder is named by the key of its photos and settings (splat-<16 hexadecimal digits>, lot SP6): kept a day
// after a failure once COLMAP found the poses, so that Retry starts again from them, and after a failure of COLMAP
// once the images were prepared (lot SPF1: Retry starts again from the images, and the frames, the database and the
// models stay for a diagnosis; FreeKC's frames of 3 November went with the failure), then deleted under each root by
// [deleteOldSplatWork] (the folders of other jobs keep the rule of an hour of their owner, managed_process.dart).

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:immich_mobile/desktop/ai/creator/write_failure.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
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

  /// The pairs of the frames of a long video, which matches_importer matches
  File get pairs => File(p.join(colmap.path, 'pairs.txt'));

  /// The largest model, upright
  Directory get aligned => Directory(p.join(dataset.path, 'sparse', '0'));

  /// Where Brush writes its export
  Directory get export => Directory(p.join(root.path, 'brush'));

  Directory get logs => Directory(p.join(root.path, 'logs'));

  /// The log of a program, "colmap-features", "brush"
  File logOf(String name) => File(p.join(logs.path, '$name.log'));
}

/// The name of the work folder of a splat scene of key [key] (hexadecimal digits): its first 16 after "splat-"
String splatWorkFolderName(String key) => '$splatWorkFolderPrefix${key.substring(0, 16)}';

/// How many logs of failed splat scenes the logs folder of the app keeps, the newest ([keepSplatFailureLogs])
const splatFailureLogsKept = 5;

/// The most of the end of each log of a program that the log of a failure takes: what came before the failure, without
/// the hundreds of lines of the images read one by one before it when the log is long
const splatFailureLogTail = 256 * 1024;

final _failureLogName = RegExp('^$splatWorkFolderPrefix[0-9a-f]{16}-.+\\.log\$');

/// The name of the log of a failure of the job of [work] at [at]: `splat-<16 hexadecimal digits>-<date and time>.log`,
/// without the colons Windows refuses
String splatFailureLogName(SplatWorkFolder work, DateTime at) {
  String two(int value) => '$value'.padLeft(2, '0');
  final date = '${at.year}-${two(at.month)}-${two(at.day)}T${two(at.hour)}-${two(at.minute)}-${two(at.second)}';
  return '${p.basename(work.root.path)}-$date.log';
}

/// After a failure of the job of [work] (a Cancel is none): the logs of its programs (logs/*.log, in the order they
/// were written, the last [tail] bytes of each that is longer) copied into [into], the logs folder of the app, as one
/// file after [header] (what failed and where), named by [splatFailureLogName]; then the oldest of those files beyond
/// [keep] deleted. The file written, null when the job wrote no log or the file could not be written (the failure is
/// told all the same).
Future<File?> keepSplatFailureLogs(
  SplatWorkFolder work,
  Directory into, {
  required String header,
  DateTime? now,
  int keep = splatFailureLogsKept,
  int tail = splatFailureLogTail,
}) async {
  final List<(File, DateTime)> logs;
  try {
    if (!work.logs.existsSync()) {
      return null;
    }
    logs = [
      for (final entry in work.logs.listSync())
        if (entry is File && p.extension(entry.path) == '.log') (entry, entry.lastModifiedSync()),
    ];
  } on FileSystemException {
    return null;
  }
  if (logs.isEmpty) {
    return null;
  }
  logs.sort((a, b) {
    final byTime = a.$2.compareTo(b.$2);
    return byTime != 0 ? byTime : a.$1.path.compareTo(b.$1.path);
  });
  final file = File(p.join(into.path, splatFailureLogName(work, now ?? DateTime.now())));
  try {
    into.createSync(recursive: true);
    final sink = file.openWrite();
    try {
      sink.write('$header\nWork folder: ${work.root.path}\n');
      for (final (log, _) in logs) {
        final length = log.lengthSync();
        final from = length > tail ? length - tail : 0;
        sink.write('\n===== ${p.basename(log.path)}, $length bytes${from > 0 ? ', the last $tail' : ''} =====\n');
        await sink.addStream(log.openRead(from));
      }
    } finally {
      await sink.close();
    }
  } on FileSystemException {
    return null;
  }
  try {
    final kept = [
      for (final entry in into.listSync())
        if (entry is File && _failureLogName.hasMatch(p.basename(entry.path))) (entry, entry.lastModifiedSync()),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    for (final (old, _) in kept.skip(keep)) {
      if (old.path != file.path) {
        old.deleteSync();
      }
    }
  } on FileSystemException {
    // The next failure tries again
  }
  return file;
}

/// Deletes under each of [roots] the work folders of splat scenes not used for SplatV1.workKept (aiWorkFolderLastUsed);
/// returns how many went. A folder that cannot be deleted now (a file a program still holds) stays for the next time,
/// the others go. The deletes run off the isolate that asks (the window's in the app).
Future<int> deleteOldSplatWork(List<SplatWorkRoot> roots, {DateTime? now}) async {
  final limit = (now ?? DateTime.now()).subtract(SplatV1.workKept);
  var deleted = 0;
  for (final root in roots) {
    final List<FileSystemEntity> entries;
    try {
      if (!root.folder.existsSync()) {
        continue;
      }
      entries = root.folder.listSync();
    } on FileSystemException {
      continue;
    }
    for (final entry in entries) {
      try {
        if (entry is Directory &&
            p.basename(entry.path).startsWith(splatWorkFolderPrefix) &&
            aiWorkFolderLastUsed(entry).isBefore(limit)) {
          await entry.delete(recursive: true);
          deleted++;
        }
      } on FileSystemException {
        // The next job tries again
      }
    }
  }
  return deleted;
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
