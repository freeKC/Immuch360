// Where "Download" puts the photos and videos of the server on a computer: Downloads/Immuch360 by default, or a
// folder the user chose ("This computer" in the settings), one of the folders of the library for example, in which
// case the next scan shows the files there.
//
// The transfers themselves stay those of the phones (background_downloader, then DownloadService, which hands each
// finished file to the file media repository and deletes it in a finally block). Two things differ on a computer:
// the file must be kept by copying or moving it into this folder before that deletion
// (DesktopFileMediaRepository), and the transfer must not land in the user's own Documents folder, which is what the
// downloader's default base directory is outside the phones' sandboxes: a file of the user with the same name would
// be overwritten, then deleted with the temporary copy. Hence the staging folder below, private to each task.

import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The folder under the system temporary folder where the downloads of the server land before they are kept, one
/// subfolder per task so that two files of the same name never meet
const desktopDownloadStagingFolder = 'immuch360-downloads';

/// [task] as the computers run it: in its own folder under the temporary folder rather than in the documents of the
/// user (see the header of this file)
DownloadTask desktopDownloadTask(DownloadTask task) => task.copyWith(
  baseDirectory: BaseDirectory.temporary,
  directory: p.join(desktopDownloadStagingFolder, task.taskId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')),
);

/// The download folder setting and the default it falls back on
class DownloadFolder {
  DownloadFolder({
    Future<Directory> Function()? settingsDirectory,
    Future<Directory?> Function()? downloadsDirectory,
    Future<Directory> Function()? temporaryDirectory,
  }) : _settingsDirectory = settingsDirectory ?? getApplicationSupportDirectory,
       _downloadsDirectory = downloadsDirectory ?? getDownloadsDirectory,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  /// The one the app uses
  static final instance = DownloadFolder();

  /// The name of the default folder, under the user's Downloads folder
  static const defaultFolderName = 'Immuch360';

  static const _settingsFile = 'desktop_files.json';
  static const _downloadFolderKey = 'downloadFolder';
  static final _log = Logger('DownloadFolder');

  final Future<Directory> Function() _settingsDirectory;
  final Future<Directory?> Function() _downloadsDirectory;
  final Future<Directory> Function() _temporaryDirectory;

  /// The folder chosen by the user, null for the default; tells the settings tile of a change
  final chosen = ValueNotifier<String?>(null);
  Future<void>? _loaded;

  /// Downloads/Immuch360, in the user's Downloads folder (a known folder on Windows, XDG_DOWNLOAD_DIR on Linux,
  /// ~/Downloads on macOS), or the home folder's Downloads when the system names none
  Future<String> defaultPath() async {
    final downloads = await _downloadsDirectory();
    final base =
        downloads?.path ??
        p.join(Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.', 'Downloads');
    return p.join(base, defaultFolderName);
  }

  /// The folder downloads go to now: the chosen one, or the default
  Future<String> currentPath() async {
    await _load();
    return chosen.value ?? await defaultPath();
  }

  /// The folder to keep a download in, created if needed. A chosen folder that cannot be created (a drive that is
  /// not connected) gives the default one for this download, so that nothing is lost; the setting stays.
  Future<Directory> prepare() async {
    await _load();
    final picked = chosen.value;
    if (picked != null) {
      try {
        return await Directory(picked).create(recursive: true);
      } on FileSystemException catch (error) {
        _log.warning('The download folder cannot be used, the default one is used instead: ${error.message}');
      }
    }
    return Directory(await defaultPath()).create(recursive: true);
  }

  /// Keeps [path] as the download folder; null goes back to the default
  Future<void> choose(String? path) async {
    await _load();
    final value = path == null || path.trim().isEmpty ? null : p.normalize(path);
    final file = File(p.join((await _settingsDirectory()).path, _settingsFile));
    final settings = await _readSettings(file);
    if (value == null) {
      settings.remove(_downloadFolderKey);
    } else {
      settings[_downloadFolderKey] = value;
    }
    await file.parent.create(recursive: true);
    // A whole new file renamed over the old one: a crash while writing never leaves half a setting
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(settings), flush: true);
    await temporary.rename(file.path);
    chosen.value = value;
  }

  /// The staging folder of the downloads (see [desktopDownloadTask])
  Future<Directory> stagingDirectory() async =>
      Directory(p.join((await _temporaryDirectory()).path, desktopDownloadStagingFolder));

  Future<void> _load() => _loaded ??= () async {
    final file = File(p.join((await _settingsDirectory()).path, _settingsFile));
    final value = (await _readSettings(file))[_downloadFolderKey];
    chosen.value = value is String && value.isNotEmpty ? value : null;
  }();

  Future<Map<String, Object?>> _readSettings(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, Object?> ? Map.of(decoded) : {};
    } on PathNotFoundException {
      return {};
    } on FormatException catch (error) {
      _log.warning('The desktop file settings cannot be read, the defaults are used: ${error.message}');
      return {};
    }
  }
}
