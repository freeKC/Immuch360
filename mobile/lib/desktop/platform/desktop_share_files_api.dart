import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/library/desktop_storage_repository.dart';
import 'package:immich_mobile/desktop/network/computer_share_files.dart';
import 'package:immich_mobile/platform/phone_share_api.g.dart';

/// PhoneShareApi on the computers, for "Share this computer on the network": the files of the folder library are
/// served in place (lib/desktop/network/computer_share_files.dart), so a file needs no temporary copy, and a computer
/// needs no foreground service to keep the share alive: it runs while the app runs.
class DesktopShareFilesApi implements PhoneShareApi {
  DesktopShareFilesApi({ComputerShareFiles? files})
    : _files = files ?? ComputerShareFiles(fileOf: DesktopStorageRepository().getFileForAsset);

  final ComputerShareFiles _files;

  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  @override
  Future<void> startKeepAlive(String title, String text, String stopLabel) async {}

  @override
  Future<void> updateKeepAlive(String text) async {}

  @override
  Future<void> stopKeepAlive() async {}

  @override
  Future<List<PhoneShareFileInfo>> fileInfos(List<String> assetIds) => _files.fileInfos(assetIds);

  @override
  Future<PhoneShareOpenedFile?> openFile(String assetId) => _files.openFile(assetId);

  /// Nothing is copied on a computer
  @override
  Future<void> releaseTemporaryFiles() async {}
}
