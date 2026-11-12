// Where a settings file comes from and goes to on each device. Android (phones, tablets, the Quest, the TVs): the
// system file picker and save dialog (DocumentTreeApi.pickFile and saveFile), and the share sheet. The computers: their
// file dialogs, and the share sheet on Windows and macOS. iOS: the share sheet, whose "Save to Files" saves it; a file
// is opened from the Files app with Share, Immuch360 (see SettingsFileShareIntent), as the app has no document picker
// for it yet.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/domain/models/settings_file/settings_file.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/platform/document_tree_api.g.dart';
import 'package:immich_mobile/providers/drone/drone_import.provider.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// The largest file read: a settings file is a few kilobytes; a large one is not one
const settingsFileMaxBytes = 4 * 1024 * 1024;

enum SettingsFileIoError {
  /// The device has no system file picker or save dialog (some TVs)
  noPicker,

  /// Larger than [settingsFileMaxBytes]
  tooLarge,

  failed,
}

class SettingsFileIoException implements Exception {
  const SettingsFileIoException(this.error, [this.detail]);

  final SettingsFileIoError error;
  final String? detail;

  @override
  String toString() => 'SettingsFileIoException(${error.name}${detail == null ? '' : ': $detail'})';
}

abstract interface class SettingsFileIo {
  /// Whether this device has a file picker the app can open (not iOS: the file comes through Share there)
  bool get canPick;

  /// Whether this device has a save dialog the app can open (iOS saves through the share sheet)
  bool get canSave;

  /// Whether this device has a share sheet (not Linux)
  bool get canShare;

  /// The text of the file the user picks, null when they go back
  Future<String?> pick();

  /// Saves [text] where the user chooses, under [fileName]: false when they go back
  Future<bool> save(String text, String fileName);

  /// Hands [text] to the share sheet as the file [fileName]; [origin] is where an iPad anchors its popover
  Future<void> share(String text, String fileName, {Rect? origin});
}

final settingsFileIoProvider = Provider<SettingsFileIo>(
  (ref) => PlatformSettingsFileIo(() => ref.read(documentTreeApiProvider)),
);

class PlatformSettingsFileIo implements SettingsFileIo {
  const PlatformSettingsFileIo(this._documentTree);

  /// Read on Android only: the computers never call the pigeon API
  final DocumentTreeApi Function() _documentTree;

  /// The folder of the cache the files go through: emptied before each new one, so that it holds the last only
  static const _folder = 'settings_file';

  @override
  bool get canPick => CurrentPlatform.isAndroid || CurrentPlatform.isDesktop;

  @override
  bool get canSave => CurrentPlatform.isAndroid || CurrentPlatform.isDesktop;

  @override
  bool get canShare => !CurrentPlatform.isLinux;

  @override
  Future<String?> pick() async {
    final String path;
    if (CurrentPlatform.isDesktop) {
      final picked = await filePickers.openFile(typeLabel: 'Immuch360', extensions: const ['json']);
      if (picked == null) {
        return null;
      }
      path = picked;
    } else if (CurrentPlatform.isAndroid) {
      final PickedFile? picked;
      try {
        picked = await _documentTree().pickFile(_folder, settingsFileMaxBytes);
      } on PlatformException catch (error) {
        throw SettingsFileIoException(_errorOf(error.code), error.message);
      }
      if (picked == null) {
        return null;
      }
      path = picked.path;
    } else {
      throw const SettingsFileIoException(SettingsFileIoError.noPicker);
    }
    final file = File(path);
    if (file.lengthSync() > settingsFileMaxBytes) {
      throw const SettingsFileIoException(SettingsFileIoError.tooLarge);
    }
    try {
      return await file.readAsString();
    } on FileSystemException catch (error) {
      throw SettingsFileIoException(SettingsFileIoError.failed, error.message);
    } finally {
      if (CurrentPlatform.isAndroid) {
        // The copy in the cache: the file stays where the user keeps it
        _deleteQuietly(file);
      }
    }
  }

  @override
  Future<bool> save(String text, String fileName) async {
    if (CurrentPlatform.isDesktop) {
      final path = await filePickers.saveLocation(
        suggestedName: fileName,
        typeLabel: 'JSON',
        extensions: const ['json'],
      );
      if (path == null) {
        return false;
      }
      await File(path).writeAsString(text, flush: true);
      return true;
    }
    if (!CurrentPlatform.isAndroid) {
      throw const SettingsFileIoException(SettingsFileIoError.noPicker);
    }
    final file = await _writeTemporary(text, fileName);
    try {
      return await _documentTree().saveFile(file.path, fileName, SettingsFile.mimeType);
    } on PlatformException catch (error) {
      throw SettingsFileIoException(_errorOf(error.code), error.message);
    } finally {
      _deleteQuietly(file);
    }
  }

  @override
  Future<void> share(String text, String fileName, {Rect? origin}) async {
    // Left in the cache for the app that receives it, which may read it later (an upload to a cloud drive); the next
    // export removes it
    final file = await _writeTemporary(text, fileName);
    await Share.shareXFiles([
      XFile(file.path, mimeType: SettingsFile.mimeType, name: fileName),
    ], sharePositionOrigin: origin);
  }

  static Future<File> _writeTemporary(String text, String fileName) async {
    final folder = Directory(p.join((await getTemporaryDirectory()).path, _folder));
    if (folder.existsSync()) {
      folder.deleteSync(recursive: true);
    }
    folder.createSync(recursive: true);
    final file = File(p.join(folder.path, fileName));
    await file.writeAsString(text, flush: true);
    return file;
  }

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) {
        file.deleteSync();
      }
    } on FileSystemException {
      // The cache is emptied by the system in time
    }
  }

  static SettingsFileIoError _errorOf(String code) => switch (code) {
    'no_picker' => SettingsFileIoError.noPicker,
    'too_large' => SettingsFileIoError.tooLarge,
    _ => SettingsFileIoError.failed,
  };
}
