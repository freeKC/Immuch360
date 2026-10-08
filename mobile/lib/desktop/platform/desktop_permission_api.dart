import 'package:flutter/services.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/platform/permission_api.g.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';

/// PermissionApi on the computers: the battery optimisation and the media management permission are Android's, and a
/// computer has nothing to ask
class DesktopPermissionApi implements PermissionApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  @override
  Future<PermissionStatus> isIgnoringBatteryOptimizations() async => PermissionStatus.granted;

  @override
  Future<bool> hasManageMediaPermission() async => true;

  @override
  Future<bool> requestManageMediaPermission() async => true;

  @override
  Future<bool> manageMediaPermission() async => true;
}

/// The device permissions on the computers. The phone repository asks permission_handler and reads the Android
/// version, neither of which a computer has: the photos are those of the folders the user chose, which is the
/// consent. So the photos and videos read as granted once a folder is chosen, and as denied before, which shows the
/// banner of a session without a server that leads to the folders page; nothing else is ever asked.
class DesktopPermissionRepository extends DevicePermissionRepository {
  const DesktopPermissionRepository(super.permissionApi, {this.hasFolders = _libraryHasFolders});

  /// Whether the folder library has at least one folder
  final Future<bool> Function() hasFolders;

  static Future<bool> _libraryHasFolders() async => (await FolderLibrary.shared()).hasRoots;

  Future<DevicePermissionStatus> _status(DevicePermission permission) async {
    if (permission != DevicePermission.photos && permission != DevicePermission.videos) {
      return DevicePermissionStatus.granted;
    }
    try {
      return await hasFolders() ? DevicePermissionStatus.granted : DevicePermissionStatus.denied;
    } catch (_) {
      // The index cannot be read: the folders page, which the banner leads to, says so
      return DevicePermissionStatus.denied;
    }
  }

  @override
  Future<DevicePermissionStatus> getStatus(DevicePermission permission) => _status(permission);

  /// Nothing to ask: the folders page is where the user gives the folders
  @override
  Future<DevicePermissionStatus> request(DevicePermission permission) => _status(permission);

  @override
  Future<int> getAndroidSdkVersion() => Future.error(UnsupportedError('Not an Android device'));

  @override
  Future<bool> hasLocationWhenInUsePermission() async => false;

  @override
  Future<bool> requestLocationWhenInUsePermission() async => false;

  @override
  Future<bool> hasLocationAlwaysPermission() async => false;

  @override
  Future<bool> requestLocationAlwaysPermission() async => false;

  @override
  Future<bool> openSettings() async => false;
}
