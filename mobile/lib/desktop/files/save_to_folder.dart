// Files the user keeps on a computer: "Save to a folder" where Linux has no share sheet, and "Save logs to a file",
// which also gathers the crash reports of the native code. The folder or the file is chosen with the system's
// dialogs (file_pickers.dart).

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/desktop/files/saved_files.dart';
import 'package:immich_mobile/desktop/files/zip_writer.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('SaveToFolder');

/// The last folder files were saved to in this session, where the next dialog opens
String? _lastFolder;

/// Copies [paths] into a folder the user picks, under their own names (the first free "name (n)" when one is taken);
/// the number of files saved, 0 when the user gave up. [announce] tells the user how many were saved.
Future<int> saveFilesToFolder(List<String> paths, {bool announce = true}) async {
  if (paths.isEmpty) {
    return 0;
  }
  final String? picked;
  try {
    picked = await filePickers.folder(
      initialDirectory: _lastFolder,
      confirmButtonText: StaticTranslations.instance.desktop_save_to_folder,
    );
  } on PlatformException catch (error) {
    // The callers do not wait for this (the share flow): a dialog that fails says so here rather than nowhere
    _log.warning('The folder dialog failed: ${error.message}');
    if (announce) {
      snackbar.error(StaticTranslations.instance.scaffold_body_error_occurred);
    }
    return 0;
  }
  if (picked == null) {
    return 0;
  }
  final folder = _lastFolder = picked;

  var saved = 0;
  for (final path in paths) {
    try {
      await copyIntoFolder(File(path), Directory(folder), safeFileName(p.basename(path)));
      saved++;
    } on FileSystemException catch (error) {
      _log.warning('A file could not be saved into the folder: ${error.message}');
    }
  }

  if (announce) {
    if (saved > 0) {
      snackbar.success(
        StaticTranslations.instance.desktop_save_to_folder_done(count: saved),
        action: SnackbarAction(label: StaticTranslations.instance.open, onPressed: () => openFolder(folder)),
      );
    } else {
      snackbar.error(StaticTranslations.instance.scaffold_body_error_occurred);
    }
  }
  return saved;
}

/// The folder where the Windows runner writes a minidump when the native code crashes (windows/runner/main.cpp): the
/// cache folder of the app. Linux and macOS leave crash reports to the system.
Future<Directory> crashDumpDirectory() async =>
    Directory(p.join((await getApplicationCacheDirectory()).path, 'crash_dumps'));

/// How many crash reports go with the logs, the latest ones: older crashes rarely help and only weigh the file down
const maxCrashDumpsSaved = 10;

/// The minidumps of [folder], newest first, at most [maxCrashDumpsSaved]
Future<List<File>> latestCrashDumps(Directory folder) async {
  final dumps = <(File, DateTime)>[];
  try {
    await for (final entity in folder.list(followLinks: false)) {
      if (entity is File && p.extension(entity.path).toLowerCase() == '.dmp') {
        dumps.add((entity, entity.statSync().modified));
      }
    }
  } on FileSystemException {
    // no crash report folder: nothing crashed, or not Windows
  }
  dumps.sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final (file, _) in dumps.take(maxCrashDumpsSaved)) file];
}

/// Keeps [logFile], written by ImmichLogger, as a file the user picks the place of: the log itself, or a ZIP archive
/// of the log and the latest crash reports when there are some. False when the user gave up or the file could not be
/// written. [announce] tells the user it is done.
Future<bool> saveLogFile(File logFile, {Directory? crashDumps, bool announce = true}) async {
  final dumps = await latestCrashDumps(crashDumps ?? await crashDumpDirectory());
  final baseName = p.basenameWithoutExtension(logFile.path);
  final extension = dumps.isEmpty ? 'log' : 'zip';
  final String? chosen;
  try {
    chosen = await filePickers.saveLocation(
      suggestedName: '$baseName.$extension',
      initialDirectory: _lastFolder,
      typeLabel: dumps.isEmpty ? 'Log' : 'ZIP',
      extensions: [extension],
    );
  } on PlatformException catch (error) {
    _log.warning('The save dialog failed: ${error.message}');
    if (announce) {
      snackbar.error(StaticTranslations.instance.scaffold_body_error_occurred);
    }
    return false;
  }
  if (chosen == null) {
    return false;
  }
  // A name typed without its extension gets it, so that the system opens the file with the right program
  final path = p.extension(chosen).isEmpty ? '$chosen.$extension' : chosen;
  _lastFolder = p.dirname(path);

  try {
    final target = File(path);
    if (dumps.isEmpty) {
      await _writeThroughPartial(target, await logFile.readAsBytes());
    } else {
      final entries = [
        ZipEntry(name: p.basename(logFile.path), bytes: await logFile.readAsBytes(), modified: DateTime.now()),
        for (final dump in dumps)
          ZipEntry(
            name: 'crash_dumps/${p.basename(dump.path)}',
            bytes: await dump.readAsBytes(),
            modified: dump.statSync().modified,
          ),
      ];
      await _writeThroughPartial(target, zipFiles(entries));
    }
  } on FileSystemException catch (error) {
    _log.warning('The logs could not be saved: ${error.message}');
    if (announce) {
      snackbar.error(StaticTranslations.instance.scaffold_body_error_occurred);
    }
    return false;
  }

  if (announce) {
    snackbar.success(StaticTranslations.instance.desktop_save_logs_done);
  }
  return true;
}

/// [bytes] into [target] by a file beside it renamed over it: the user chose that name in the save dialog, which
/// already asked before replacing a file of the same name
Future<void> _writeThroughPartial(File target, List<int> bytes) async {
  final partial = File('${target.path}.part');
  try {
    await partial.writeAsBytes(bytes, flush: true);
    await partial.rename(target.path);
  } catch (_) {
    try {
      await partial.delete();
    } on FileSystemException {
      // never written
    }
    rethrow;
  }
}

/// A date for a file name: Windows refuses the colons of an ISO 8601 time
String fileNameDate(DateTime date) => date.toIso8601String().replaceAll(':', '-');
