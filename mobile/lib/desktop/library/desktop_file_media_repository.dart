import 'dart:io';

import 'package:immich_mobile/desktop/files/download_folder.dart';
import 'package:immich_mobile/desktop/files/saved_files.dart';
import 'package:immich_mobile/repositories/file_media.repository.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

/// Where "Download" saves on the computers. The phone repository hands the file to the system gallery through
/// photo_manager, which has no Windows or Linux implementation, and DownloadService deletes the downloaded file in a
/// finally block whatever happened: here the file is moved (or copied, across drives) into the download folder of
/// the computer before returning, so that only the temporary copy can go. The Android folder (DCIM/Immich) means
/// nothing on a computer and is ignored.
///
/// The answer is an AssetEntity built in Dart (its constructor is plain Dart): the download service only checks that
/// there is one; null when the downloaded file is missing.
class DesktopFileMediaRepository extends FileMediaRepository {
  const DesktopFileMediaRepository({this.folder, this.announce = true});

  /// The download folder setting; the app's own when null
  final DownloadFolder? folder;

  /// Tells the user where the files went, once per burst of downloads
  final bool announce;

  static final _log = Logger('DesktopFileMediaRepository');

  DownloadFolder get _downloads => folder ?? DownloadFolder.instance;

  @override
  Future<AssetEntity?> saveImageWithFile(String filePath, {String? title, String? relativePath}) async {
    final kept = await _keep(File(filePath), title);
    return kept == null ? null : _entity(kept, AssetType.image);
  }

  @override
  Future<AssetEntity?> saveVideo(File file, {required String title, String? relativePath}) async {
    final kept = await _keep(file, title);
    return kept == null ? null : _entity(kept, AssetType.video);
  }

  /// The photo and the video of an Apple live photo, side by side under the same name, as the camera made them
  @override
  Future<AssetEntity?> saveLivePhoto({required File image, required File video, required String title}) async {
    final keptImage = await _keep(image, title);
    if (keptImage == null) {
      return null;
    }
    final videoName = '${p.basenameWithoutExtension(p.basename(keptImage.path))}${p.extension(video.path)}';
    await _keep(video, videoName);
    return _entity(keptImage, AssetType.image);
  }

  /// Moves [source] into the download folder under [title] (or its own name), the first free "name (n)" when the
  /// name is taken; the kept file, or null when there was nothing to keep
  Future<File?> _keep(File source, String? title) async {
    // ignore: avoid_slow_async_io
    if (!await source.exists()) {
      _log.warning('Nothing to keep: the downloaded file is missing');
      return null;
    }
    final folder = await _downloads.prepare();
    final name = safeFileName(title == null || title.isEmpty ? p.basename(source.path) : title);
    final kept = await moveIntoFolder(source, folder, name);
    await _removeTaskFolderOf(source);
    if (announce) {
      announceSavedFolder(folder.path);
    }
    return kept;
  }

  /// The folder of the download task under the staging folder (desktopDownloadTask), empty once its file moved; never
  /// a folder outside it
  Future<void> _removeTaskFolderOf(File source) async {
    final staging = await _downloads.stagingDirectory();
    final parent = source.parent;
    if (!p.isWithin(staging.path, parent.path)) {
      return;
    }
    try {
      await parent.delete();
    } on FileSystemException {
      // Still holds the downloader's own temporary file for a moment (when the temporary folder was not writable):
      // an empty folder in the temporary folder is all that stays
    }
  }

  AssetEntity _entity(File kept, AssetType type) {
    final name = p.basename(kept.path);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Only its presence matters to the download service; the path stays out of the id all the same
    return AssetEntity(
      id: name,
      typeInt: type.index,
      width: 0,
      height: 0,
      title: name,
      createDateSecond: now,
      modifiedDateSecond: now,
    );
  }
}
