// Writing a 3D photo without ever leaving a half file, or an empty one, under its final name (design-final 2026-10-26,
// section 2.5). The engine writes the whole JPEG into a hidden partial file where the photo goes,
// ".<final name>.<pid>-<n>.immuch360.part": the leading dot keeps it out of the scan of the library (folder_roots.dart)
// and out of the share browser. Its path is noted in desktop_ai_inflight.json of the support folder before the file
// exists and until it is gone, so that the next start deletes what a crash or a power cut left behind. The final name
// is reserved only at the end, by reserveFileIn of saved_files.dart, which never takes the name of an existing file,
// and the partial file is renamed over it.
//
// The writer only ever creates, renames and deletes its own files: the original of a job is never opened here, and a
// file of the user is replaced only when it is a 3D photo of ours made from the same original (collisions.dart). Every
// call on the folders of the user goes through CreatorFileSystem, so that a test sees each one: nothing is written nor
// tried in a network folder before the user said yes (destination.dart). Those calls are all asynchronous, on the
// threads of dart:io: a share out of reach (\\nas\photos away from home, an NFS mount whose server is off) keeps a
// call waiting, never the window.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/write_failure.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/files/saved_files.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

export 'package:immich_mobile/desktop/ai/creator/write_failure.dart';

final _log = Logger('SafeWriter');

/// The end of the name of every partial file of the creator
const partFileSuffix = '.immuch360.part';

final _partFileName = RegExp(r'^\..+\.(\d+)-\d+\.immuch360\.part$');

/// The hidden name of a partial file of the 3D photo to be named [finalName]:
/// ".salon_3D_LRF_Full_SBS.jpg.4242-1.immuch360.part"
String partFileName(String finalName, {required int processId, required int sequence}) =>
    '.$finalName.$processId-$sequence$partFileSuffix';

/// Whether [name] is the name of a partial file of the creator, the only files the start deletes
bool isPartFileName(String name) => _partFileName.hasMatch(name);

/// The process that wrote the partial file named [name], null for another name
int? partFileProcess(String name) {
  final match = _partFileName.firstMatch(name);
  return match == null ? null : int.parse(match.group(1)!);
}

/// A write of the creator that failed, and why
class CreatorWriteException implements Exception {
  const CreatorWriteException(this.failure, this.message, {this.path});

  /// [error] as the user is told (see [writeFailureOf])
  factory CreatorWriteException.of(Object error, {String? path, bool? windows}) =>
      CreatorWriteException(writeFailureOf(error, windows: windows), switch (error) {
        FileSystemException(:final message, osError: final osError) =>
          osError == null || osError.message.isEmpty ? message : '$message: ${osError.message}',
        _ => '$error',
      }, path: path);

  final WriteFailure failure;

  /// The words of the system, for the logs and the details of a job
  final String message;
  final String? path;

  @override
  String toString() => 'CreatorWriteException(${failure.name}): $message${path == null ? '' : ' ($path)'}';
}

/// The calls the creator makes on the folders of the user. Each one may throw a FileSystemException.
abstract interface class CreatorFileSystem {
  /// Whether [path] is a folder
  Future<bool> isFolder(String path);

  /// Creates the folder [path] and the folders above it that are missing
  Future<void> createFolder(String path);

  /// Creates the empty file [path]; fails when something is there
  Future<void> createNew(String path);

  /// Reserves [name] in [folder], or "name (1)", "name (2)" and so on when it is taken (reserveFileIn); the path of the
  /// empty file reserved
  Future<String> reserve(String folder, String name);

  /// Whether something is at [path]
  Future<bool> exists(String path);

  /// The first [length] bytes of the file [path], fewer when it is shorter
  Future<Uint8List> readHead(String path, int length);

  /// Moves the file [from] to [to], in place of the file at [to] when there is one
  Future<void> rename(String from, String to);

  /// Deletes the file [path]; nothing when it is already gone
  Future<void> delete(String path);
}

/// The file system of this computer
class IoCreatorFileSystem implements CreatorFileSystem {
  const IoCreatorFileSystem();

  // Asynchronous on purpose: a share out of reach must keep a thread of dart:io waiting, not the window
  @override
  // ignore: avoid_slow_async_io
  Future<bool> isFolder(String path) => FileSystemEntity.isDirectory(path);

  @override
  Future<void> createFolder(String path) async {
    await Directory(path).create(recursive: true);
  }

  @override
  Future<void> createNew(String path) async {
    await File(path).create(exclusive: true);
  }

  @override
  Future<String> reserve(String folder, String name) async => (await reserveFileIn(Directory(folder), name)).path;

  @override
  Future<bool> exists(String path) async =>
      // ignore: avoid_slow_async_io
      await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.notFound;

  @override
  Future<Uint8List> readHead(String path, int length) async {
    final file = await File(path).open();
    try {
      return await file.read(length);
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    await File(from).rename(to);
  }

  @override
  Future<void> delete(String path) async {
    try {
      await File(path).delete();
    } on PathNotFoundException {
      // Already gone
    }
  }
}

/// desktop_ai_inflight.json in the support folder: the partial files being written, each with the time it was noted,
/// so that the next start deletes those a crash left. Written as a whole new file renamed over the old one, one change
/// after the other; removed when nothing is in flight.
class InflightJournal {
  InflightJournal({Future<Directory> Function()? settingsDirectory})
    : _settingsDirectory = settingsDirectory ?? getApplicationSupportDirectory;

  /// The name of the file in the support folder
  static const fileName = 'desktop_ai_inflight.json';

  final Future<Directory> Function() _settingsDirectory;
  Map<String, DateTime>? _entries;
  Future<void> _writing = Future.value();

  /// The partial files noted now
  Future<List<String>> paths() => _run(() async => List.of((await _load()).keys));

  /// The partial files noted now, and when each one was noted
  Future<Map<String, DateTime>> entries() => _run(() async => Map.of(await _load()));

  /// Notes [path], before the file exists
  Future<void> add(String path) => _run(() async {
    final entries = await _load();
    if (!entries.containsKey(path)) {
      entries[path] = DateTime.now().toUtc();
      await _save();
    }
  });

  /// Forgets [path], once the file is gone or renamed
  Future<void> remove(String path) => _run(() async {
    if ((await _load()).remove(path) != null) {
      await _save();
    }
  });

  Future<T> _run<T>(Future<T> Function() step) {
    final next = _writing.then((_) => step());
    _writing = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  Future<File> _file() async => File(p.join((await _settingsDirectory()).path, fileName));

  Future<Map<String, DateTime>> _load() async {
    final loaded = _entries;
    if (loaded != null) {
      return loaded;
    }
    final entries = <String, DateTime>{};
    try {
      final decoded = jsonDecode(await (await _file()).readAsString());
      if (decoded is Map && decoded['parts'] is List) {
        final now = DateTime.now().toUtc();
        for (final part in decoded['parts'] as List) {
          switch (part) {
            // A path without its time: taken as noted now
            case final String path:
              entries[path] = now;
            case {'path': final String path}:
              entries[path] = DateTime.tryParse('${part['noted']}')?.toUtc() ?? now;
          }
        }
      }
    } on PathNotFoundException {
      // Nothing in flight
    } on FormatException catch (error) {
      _log.warning('The journal of the partial files cannot be read: ${error.message}');
    }
    return _entries = entries;
  }

  Future<void> _save() async {
    final file = await _file();
    final entries = _entries ?? const <String, DateTime>{};
    if (entries.isEmpty) {
      try {
        await file.delete();
      } on PathNotFoundException {
        // Already gone
      }
      return;
    }
    await file.parent.create(recursive: true);
    // A whole new file renamed over the old one: a crash while writing never loses the paths noted before
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'parts': [
          for (final MapEntry(key: path, value: noted) in entries.entries)
            {'path': path, 'noted': noted.toIso8601String()},
        ],
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}

/// The partial file of a 3D photo: where it is, and the name the photo takes at the end
class PartFile {
  const PartFile({required this.folder, required this.finalName, required this.path});

  /// The folder of the 3D photo
  final String folder;

  /// The name it takes, or the first free "name (n)" of it
  final String finalName;

  /// The hidden partial file the engine writes
  final String path;

  @override
  String toString() => 'PartFile($path)';
}

/// What became of a 3D photo at the end of its job
enum SaveOutcome {
  /// Under its name, or the first free "name (n)" of it
  saved,

  /// In place of an earlier 3D photo of ours
  replaced,

  /// Not kept: the name was taken and the user chose to skip
  skipped,
}

/// The file a job ended with
class SavedVersion {
  const SavedVersion({required this.path, required this.outcome});

  /// The 3D photo; for a skipped one, the file that was already there
  final String path;
  final SaveOutcome outcome;
}

/// Creates the partial files of the 3D photos, puts them under their final names, and deletes them
class SafeWriter {
  SafeWriter({this.files = const IoCreatorFileSystem(), InflightJournal? journal, int? processId})
    : _journal = journal ?? InflightJournal(),
      _processId = processId ?? pid;

  /// The one the app uses
  static final instance = SafeWriter();

  final CreatorFileSystem files;
  final InflightJournal _journal;
  final int _processId;
  static var _sequence = 0;

  /// How long a partial file whose folder stays out of reach is looked for at each start
  static const forgetUnreachableAfter = Duration(days: 30);

  /// The empty partial file of the 3D photo to be named [finalName] in [folder], noted in the journal before it exists.
  /// This is also how a folder is found read only: no test file is ever written (see WriteProbe). Throws a
  /// [CreatorWriteException] when the folder refuses it, or with [WriteFailure.other] when the journal in the support
  /// folder cannot be written: that is no refusal of [folder], and nothing is tried there then.
  Future<PartFile> createPart(String folder, String finalName) async {
    final name = partFileName(finalName, processId: _processId, sequence: ++_sequence);
    final part = PartFile(folder: folder, finalName: finalName, path: p.join(folder, name));
    try {
      await _journal.add(part.path);
    } on Exception catch (error) {
      final cause = CreatorWriteException.of(error);
      throw CreatorWriteException(
        WriteFailure.other,
        'The list of the partial files cannot be written: ${cause.message}',
        path: error is FileSystemException ? error.path : null,
      );
    }
    try {
      await files.createNew(part.path);
    } on FileSystemException catch (error) {
      await _forget(part.path);
      throw CreatorWriteException.of(error, path: part.path);
    }
    return part;
  }

  /// The version of [kind] of [original] written in [part] put under its final name, as [whenExists] says when that
  /// name is taken: keepBoth reserves the first free "name (n)", at this moment only; replace takes the place of the
  /// file there only when it is a version of ours of the same kind made from [original], read again just before, else
  /// both are kept; skip leaves the existing file and deletes the partial one. [replacing] is another version the queue
  /// found, its name or its path: it is replaced only in the folder of [part], a version elsewhere stays where it is
  /// (the final name is looked at instead). The file of [original] is never replaced. Throws a
  /// [CreatorWriteException], the partial file then deleted.
  Future<SavedVersion> commit(
    PartFile part, {
    required OriginalIdentity original,
    AiWhenExists whenExists = AiWhenExists.keepBoth,
    String? replacing,
    ImmersiveKind kind = ImmersiveKind.stereoPhoto,
  }) async {
    try {
      final target = whenExists == AiWhenExists.replace
          ? _replaceTarget(part, replacing)
          : p.join(part.folder, part.finalName);
      final taken = await files.exists(target);
      final originalPath = original.path;
      final isOriginal = originalPath != null && _samePath(originalPath, target);
      final action = collisionAction(
        whenExists: whenExists,
        taken: taken,
        // The original is not even read: it is never replaced
        head: taken && !isOriginal && whenExists == AiWhenExists.replace ? await _headOf(target) : null,
        original: original,
        isOriginal: isOriginal,
        kind: kind,
      );
      if (action == CollisionAction.skip) {
        await discard(part);
        return SavedVersion(path: target, outcome: SaveOutcome.skipped);
      }
      if (action == CollisionAction.replace) {
        await files.rename(part.path, target);
        await _forget(part.path);
        return SavedVersion(path: target, outcome: SaveOutcome.replaced);
      }
      final reserved = await files.reserve(part.folder, part.finalName);
      try {
        await files.rename(part.path, reserved);
      } on FileSystemException {
        await _deleteQuietly(reserved);
        rethrow;
      }
      await _forget(part.path);
      return SavedVersion(path: reserved, outcome: SaveOutcome.saved);
    } on FileSystemException catch (error) {
      await discard(part);
      throw CreatorWriteException.of(error, path: part.path);
    }
  }

  /// The file a replace may take: [replacing] when it is a name, or a path in the folder of [part]; else the final name
  String _replaceTarget(PartFile part, String? replacing) {
    if (replacing != null) {
      final name = p.basename(replacing);
      final inFolder = name == replacing || _samePath(p.dirname(replacing), part.folder);
      if (inFolder && name.isNotEmpty && name != '.' && name != '..') {
        return p.join(part.folder, name);
      }
    }
    return p.join(part.folder, part.finalName);
  }

  /// Deletes [part] and forgets it: a job failed or was cancelled, a dialog closed without launching. A partial file
  /// that cannot be deleted now stays noted, for the next start.
  Future<void> discard(PartFile part) async {
    try {
      await files.delete(part.path);
    } on FileSystemException catch (error) {
      _log.warning('A partial file stays until the next start: ${error.message}');
      return;
    }
    await _forget(part.path);
  }

  /// At the start of the app: deletes the partial files an earlier session noted and left (a crash, a power cut). A
  /// file whose folder cannot be reached now (a drive unplugged, a share gone) stays noted for the next start, for
  /// [forgetUnreachableAfter] at most; a path that is not a partial file of the creator is only forgotten, never
  /// deleted. How many files were deleted.
  Future<int> cleanUpAtStart() async {
    var deleted = 0;
    final now = DateTime.now().toUtc();
    for (final MapEntry(key: path, value: noted) in (await _journal.entries()).entries) {
      final name = p.basename(path);
      final process = partFileProcess(name);
      if (process == _processId) {
        // Written by this session
        continue;
      }
      if (process == null) {
        await _journal.remove(path);
        continue;
      }
      try {
        if (!await files.isFolder(p.dirname(path))) {
          if (now.difference(noted) > forgetUnreachableAfter) {
            // A drive or a share gone for a month: no longer looked for at each start
            _log.info('A partial file of a folder out of reach since ${noted.toIso8601String()} is forgotten');
            await _journal.remove(path);
          }
          continue;
        }
        if (await files.exists(path)) {
          await files.delete(path);
          deleted++;
        }
        await _journal.remove(path);
      } on FileSystemException catch (error) {
        _log.warning('A partial file of an earlier session stays: ${error.message}');
      }
    }
    return deleted;
  }

  /// [path] out of the journal once the partial file is gone or renamed; a journal that cannot be written only costs a
  /// look at that path at the next start
  Future<void> _forget(String path) async {
    try {
      await _journal.remove(path);
    } on FileSystemException catch (error) {
      _log.warning('The journal of the partial files was not updated: ${error.message}');
    }
  }

  Future<Uint8List?> _headOf(String path) async {
    try {
      return await files.readHead(path, versionHeadLength);
    } on FileSystemException {
      // Not readable now: not taken for one of ours
      return null;
    }
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      await files.delete(path);
    } on FileSystemException {
      // The empty reservation stays; it holds no picture
    }
  }
}

bool _samePath(String a, String b) {
  final caseFold = Platform.isWindows || Platform.isMacOS;
  final left = p.normalize(p.absolute(a));
  final right = p.normalize(p.absolute(b));
  return caseFold ? left.toLowerCase() == right.toLowerCase() : left == right;
}

/// Deletes the partial files an earlier session of the app left, at its start; never fails
Future<void> cleanUpPartFilesAtStart({SafeWriter? writer}) async {
  try {
    final deleted = await (writer ?? SafeWriter.instance).cleanUpAtStart();
    if (deleted > 0) {
      _log.info('$deleted partial files of an earlier session deleted');
    }
  } catch (error, stack) {
    _log.warning('The partial files of an earlier session were not cleaned up', error, stack);
  }
}
