// A settings file on a network share already set up in the app (SMB or WebDAV, the files of a NAS or a computer): the
// way of a device without a system file picker or save dialog (Google TV and most Android TVs), and a way inside the
// app on iOS, whose other import goes through Share in the Files app. The file is read through the kept connection of
// the share; it is written through the ShareWriter of the versions of the computers, which never writes over a file
// (a taken name becomes "name (1)"). Library, "Settings file" card (lot settings tile, release 51).

import 'dart:convert';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/network/share_writer.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/settings_file/settings_file_io.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('SettingsFileShare');

/// The shares a settings file can be saved on or opened from: those of files, not the media servers nor the cameras
final settingsFileSharesProvider = Provider<List<NetworkSource>>(
  (ref) => [
    for (final source in ref.watch(networkSourcesProvider))
      if (isWritableShareType(source.type)) source,
  ],
);

/// Set once the system file picker or save dialog answered that this device has none: their buttons then make way for
/// the network shares until the app starts again
final settingsFileNoPickerProvider = StateProvider<bool>((ref) => false);

/// Whether the system file picker and save dialog may be offered here: not once the device said it has none
final settingsFileSystemPickerProvider = Provider<bool>((ref) => !ref.watch(settingsFileNoPickerProvider));

/// Whether the Library shows its "Settings file" card: everywhere, except on a TV (or a device that said it has no
/// file picker) without any share to save the file on or open it from, where both actions would end on "no file
/// picker". The entry of Settings stays there in every case.
final settingsFileCardProvider = Provider.autoDispose<bool>((ref) {
  final mayLackPicker = ref.watch(tvDeviceProvider).isTelevision || ref.watch(settingsFileNoPickerProvider);
  return !mayLackPicker || ref.watch(settingsFileSharesProvider).isNotEmpty;
});

abstract interface class SettingsFileShareIo {
  /// The folders then the files of [path] on the share [sourceId], as its file system lists them
  Future<List<NetworkEntry>> list(String sourceId, String path);

  /// The text of the file at [path]; a [SettingsFileIoException] (too large) for a file larger than a settings file
  Future<String> read(String sourceId, String path);

  /// Writes [text] as [fileName] in [folder] of the share [sourceId], under the first free name: the path written
  Future<String> save(String text, String fileName, {required String sourceId, required String folder});
}

/// The text of the file at [path] of [fileSystem]; a [SettingsFileIoException] (too large) for a file larger than a
/// settings file, told by one byte more than the largest one, without reading it all
Future<String> readSettingsFileOnShare(NetworkFileSystem fileSystem, String path) async {
  final bytes = await fileSystem.readRange(path, 0, settingsFileMaxBytes + 1);
  if (bytes.length > settingsFileMaxBytes) {
    throw const SettingsFileIoException(SettingsFileIoError.tooLarge);
  }
  // A file that is not text is no settings file: the parse says so
  return utf8.decode(bytes, allowMalformed: true);
}

final settingsFileShareIoProvider = Provider<SettingsFileShareIo>(NetworkSettingsFileShareIo.new);

class NetworkSettingsFileShareIo implements SettingsFileShareIo {
  const NetworkSettingsFileShareIo(this._ref);

  final Ref _ref;

  /// The folder of the cache the file goes through on its way to a share, apart from the one of SettingsFileIo
  static const _folder = 'settings_file_share';

  @override
  Future<List<NetworkEntry>> list(String sourceId, String path) async =>
      (await _ref.read(networkConnectionsProvider).fileSystem(sourceId)).list(path);

  @override
  Future<String> read(String sourceId, String path) async =>
      readSettingsFileOnShare(await _ref.read(networkConnectionsProvider).fileSystem(sourceId), path);

  @override
  Future<String> save(String text, String fileName, {required String sourceId, required String folder}) async {
    final writer = await _ref.read(shareWriterOpenerProvider)(sourceId);
    if (writer == null) {
      throw const ShareWriteException(ShareWriteFailure.readOnly);
    }
    final directory = Directory(p.join((await getTemporaryDirectory()).path, _folder));
    final file = File(p.join(directory.path, fileName));
    try {
      directory.createSync(recursive: true);
      await file.writeAsString(text, flush: true);
      final written = await publishShareVersion(writer, file, folder: folder, name: fileName);
      return written ?? sharePathIn(folder, fileName);
    } finally {
      try {
        await writer.close();
      } catch (error) {
        _log.warning('The writer of the share did not close: $error');
      }
      try {
        if (file.existsSync()) {
          file.deleteSync();
        }
      } on FileSystemException {
        // The cache is emptied by the system in time
      }
    }
  }
}
