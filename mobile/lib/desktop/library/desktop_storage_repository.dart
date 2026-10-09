import 'dart:io';

import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/placeholder_check.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:photo_manager/photo_manager.dart';

/// The files behind the local assets on the computers. The phone repository asks photo_manager, which has no Windows
/// or Linux implementation; here a local asset is a file of the folder library, read in place. Uploads build their
/// AssetEntity in Dart from it (its constructor is plain Dart), so the upload code stays the phones'.
///
/// A file kept online only (OneDrive) or on a drive that is not connected has no file here: nothing reads it, and the
/// upload reports it as not found on this computer.
class DesktopStorageRepository extends StorageRepository {
  DesktopStorageRepository({Future<FolderLibrary> Function()? library, FileAttributesReader? attributes})
    : _library = library ?? FolderLibrary.shared,
      _readAttributes = attributes;

  final Future<FolderLibrary> Function() _library;
  final FileAttributesReader? _readAttributes;

  Future<LibraryFile?> _readable(String assetId) async {
    try {
      final file = (await _library()).file(assetId);
      if (file == null || !file.readable) {
        return null;
      }
      // The cloud client may have freed the file's space since the last scan
      if (isCloudPlaceholderFile(file.path, reader: _readAttributes)) {
        return null;
      }
      // ignore: avoid_slow_async_io
      return await File(file.path).exists() ? file : null;
    } catch (error, stackTrace) {
      log.warning('Cannot find the file of $assetId in the folder library', error, stackTrace);
      return null;
    }
  }

  @override
  Future<File?> getFileForAsset(String assetId) async {
    final file = await _readable(assetId);
    return file == null ? null : File(file.path);
  }

  /// Live photos made of two files are a later addition: a picture of the library has no motion part
  @override
  Future<File?> getMotionFileForAsset(LocalAsset asset) async => null;

  @override
  Future<AssetEntity?> getAssetEntityForAsset(LocalAsset asset) async {
    final file = await _readable(asset.id);
    if (file == null) {
      return null;
    }
    return AssetEntity(
      id: asset.id,
      typeInt: file.kind.assetType,
      width: file.width ?? 0,
      height: file.height ?? 0,
      // photo_manager counts the duration of a video in seconds
      duration: file.kind == LibraryMediaKind.video ? file.durationMs ~/ 1000 : 0,
      title: file.name,
      createDateSecond: file.createdSeconds,
      modifiedDateSecond: file.modifiedMs ~/ 1000,
      mimeType: file.mimeType,
    );
  }

  @override
  Future<bool> isAssetAvailableLocally(String assetId) async => await _readable(assetId) != null;

  /// Cloud downloads are an iOS matter (iCloud); placeholders of OneDrive are never read without the user's choice
  @override
  Future<File?> loadFileFromCloud(String assetId, {PMProgressHandler? progressHandler}) async => null;

  @override
  Future<File?> loadMotionFileFromCloud(String assetId, {PMProgressHandler? progressHandler}) async => null;

  /// photo_manager keeps no file cache on a computer
  @override
  Future<void> clearCache() async {}
}
