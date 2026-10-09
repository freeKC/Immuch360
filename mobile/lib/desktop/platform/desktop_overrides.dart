// What the computers replace in the root ProviderScope (main.dart): the repositories that wrap a phone plugin rather
// than a pigeon API, which the factories of PlatformApis cannot reach.

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/library/desktop_asset_media_repository.dart';
import 'package:immich_mobile/desktop/library/desktop_file_media_repository.dart';
import 'package:immich_mobile/desktop/library/desktop_storage_repository.dart';
import 'package:immich_mobile/desktop/library/folder_library_controller.dart';
import 'package:immich_mobile/desktop/platform/desktop_permission_api.dart';
import 'package:immich_mobile/desktop/window/desktop_shell.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/file_media.repository.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';
import 'package:immich_mobile/repositories/share_handler.repository.dart';
import 'package:immich_mobile/repositories/widget.repository.dart';

/// The overrides of the computers, added to the root scope by main.dart on Windows, macOS and Linux only
List<Override> desktopOverrides() => [
  // photo_manager has no Windows or Linux implementation: the files of the folder library instead
  storageRepositoryProvider.overrideWith((ref) => DesktopStorageRepository()),
  // File names and deletion without photo_manager
  assetMediaRepositoryProvider.overrideWith(
    (ref) => DesktopAssetMediaRepository(ref.watch(nativeSyncApiProvider), ref.watch(storageRepositoryProvider)),
  ),
  // "Download" saves into a folder of the computer instead of the system gallery
  fileMediaRepositoryProvider.overrideWith((ref) => const DesktopFileMediaRepository()),
  // permission_handler and the Android version behind the gallery permission
  permissionRepositoryProvider.overrideWith((ref) => DesktopPermissionRepository(ref.watch(permissionApiProvider))),
  // Files shared to the app come from the share sheet of a phone; a computer has none
  shareHandlerRepositoryProvider.overrideWith((ref) => _NoShareHandlerRepository()),
  // home_widget has no computer implementation and throws at each call; the sign in writes the credentials of the
  // home screen widget, so it failed every time
  widgetRepositoryProvider.overrideWith((ref) => const _NoHomeWidgetRepository()),
];

/// What wraps the app on a computer, inside MaterialApp (main.dart): the desktop keys and the window's close guard,
/// and the folder library kept current while the app runs (its watcher, a rescan when the window comes back)
Widget desktopAppShell(Widget app) => DesktopShell(child: FolderLibraryHost(child: app));

class _NoShareHandlerRepository extends ShareHandlerRepository {
  @override
  Future<void> init() async {}
}

/// A computer has no home screen widget to keep signed in
class _NoHomeWidgetRepository extends WidgetRepository {
  const _NoHomeWidgetRepository();

  @override
  Future<void> saveData(String key, String value) async {}

  @override
  Future<void> refresh(String iosName, String androidName) async {}

  @override
  Future<void> setAppGroupId() async {}
}
