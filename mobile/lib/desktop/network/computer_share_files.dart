// The files of "Share this computer on the network", what PhoneShareApi answers on the computers (fileInfos and
// openFile). The share's tree reads the local albums and assets of the main database, which the folder library fills
// as the gallery fills them on a phone; the file of an asset comes from the folder library
// (DesktopStorageRepository.getFileForAsset) and is served in place: a computer needs no temporary copy, which
// Android makes when a content URI has no readable path.
//
// A file that a cloud client (OneDrive) keeps online only is listed, since its size and dates are known without
// reading it, but never opened: reading it would download it, possibly onto a disk that cannot hold the library.

import 'dart:io';

import 'package:immich_mobile/desktop/library/placeholder_check.dart';
import 'package:immich_mobile/platform/phone_share_api.g.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('ComputerShareFiles');

/// The MIME type a client of the share is told for the file at [path]; a computer gives none with a path, so it comes
/// from the extension, the camera formats of the fork included (.insp photos, .insv, .lrv, .360 and .osv videos)
String computerShareMimeTypeOf(String path) => switch (p.extension(path).toLowerCase()) {
  '.jpg' || '.jpeg' || '.jpe' || '.insp' => 'image/jpeg',
  '.png' => 'image/png',
  '.gif' => 'image/gif',
  '.webp' => 'image/webp',
  '.bmp' => 'image/bmp',
  '.tif' || '.tiff' => 'image/tiff',
  '.heic' => 'image/heic',
  '.heif' => 'image/heif',
  '.avif' => 'image/avif',
  '.jxl' => 'image/jxl',
  '.dng' => 'image/x-adobe-dng',
  '.mp4' || '.m4v' || '.insv' || '.lrv' || '.360' || '.osv' => 'video/mp4',
  '.mov' => 'video/quicktime',
  '.mkv' => 'video/x-matroska',
  '.webm' => 'video/webm',
  '.avi' => 'video/x-msvideo',
  '.3gp' => 'video/3gpp',
  '.mts' || '.m2ts' => 'video/mp2t',
  '.mpg' || '.mpeg' => 'video/mpeg',
  '.wmv' => 'video/x-ms-wmv',
  _ => 'application/octet-stream',
};

/// See the top of this file
class ComputerShareFiles {
  const ComputerShareFiles({required this.fileOf, this.isPlaceholder = isCloudPlaceholderFile});

  /// The file of a local asset in the folder library, null when the asset is not (or no longer) there
  final Future<File?> Function(String assetId) fileOf;

  /// Whether the file at a path is kept online only by a cloud client right now
  final bool Function(String path) isPlaceholder;

  /// The size, MIME type, name and date of each of [assetIds] whose file exists; the others are left out
  Future<List<PhoneShareFileInfo>> fileInfos(List<String> assetIds) async {
    final infos = await Future.wait(assetIds.map(_infoOf));
    return infos.nonNulls.toList();
  }

  Future<PhoneShareFileInfo?> _infoOf(String assetId) async {
    try {
      final file = await fileOf(assetId);
      if (file == null) {
        return null;
      }
      // A stat reads the attributes, not the content: a placeholder is not downloaded by it
      final stat = file.statSync();
      if (stat.type != FileSystemEntityType.file) {
        return null;
      }
      return PhoneShareFileInfo(
        assetId: assetId,
        size: stat.size,
        mimeType: computerShareMimeTypeOf(file.path),
        fileName: p.basename(file.path),
        modifiedMs: stat.modified.millisecondsSinceEpoch,
      );
    } catch (error) {
      _log.fine('Computer share: no file for $assetId: $error');
      return null;
    }
  }

  /// The file of [assetId], read in place; null when it is gone or kept online only
  Future<PhoneShareOpenedFile?> openFile(String assetId) async {
    try {
      final file = await fileOf(assetId);
      if (file == null) {
        return null;
      }
      if (isPlaceholder(file.path)) {
        _log.info('Computer share: $assetId is kept online only, not downloaded for a client');
        return null;
      }
      final stat = file.statSync();
      if (stat.type != FileSystemEntityType.file) {
        return null;
      }
      return PhoneShareOpenedFile(path: file.path, size: stat.size, isTemporary: false);
    } catch (error) {
      _log.fine('Computer share: $assetId cannot be opened: $error');
      return null;
    }
  }
}
