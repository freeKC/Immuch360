// What the computers replace in the root ProviderScope (main.dart): the repositories that wrap a phone plugin rather
// than a pigeon API, which the factories of PlatformApis cannot reach.

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/components/ai_components_folder.dart';
import 'package:immich_mobile/desktop/ai/components/disk_space.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/files/open_files.dart';
import 'package:immich_mobile/desktop/files/opened_files.dart';
import 'package:immich_mobile/desktop/library/desktop_asset_media_repository.dart';
import 'package:immich_mobile/desktop/library/desktop_file_media_repository.dart';
import 'package:immich_mobile/desktop/library/desktop_storage_repository.dart';
import 'package:immich_mobile/desktop/library/folder_library_controller.dart';
import 'package:immich_mobile/desktop/platform/desktop_permission_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_spherical_video_api.dart';
import 'package:immich_mobile/desktop/window/desktop_shell.dart';
import 'package:immich_mobile/desktop/window/self_check.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/raw/raw_video.provider.dart';
import 'package:immich_mobile/providers/view_intent/view_intent_handler.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/file_media.repository.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';
import 'package:immich_mobile/repositories/share_handler.repository.dart';
import 'package:immich_mobile/repositories/widget.repository.dart';
import 'package:immich_mobile/routing/router.dart';

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
  // The 360° player is a route of the window: open pushes it on the router's navigator
  sphericalVideoApiProvider.overrideWith(
    (ref) => DesktopSphericalVideoApi(navigator: () => ref.read(appRouterProvider).navigatorKey),
  ),
  // home_widget has no computer implementation and throws at each call; the sign in writes the credentials of the
  // home screen widget, so it failed every time
  widgetRepositoryProvider.overrideWith((ref) => const _NoHomeWidgetRepository()),
  // The files given to the program (its command line, a later start, a drop on the window) rather than view intents
  viewIntentHandlerProvider.overrideWith((ref) => DesktopOpenFilesHandler(ref)),
  // The other file of an X3 pair opened with the program is next to it on the disk, not in the local tables
  openedFileSiblingProvider.overrideWithValue(OpenedFiles.sibling),
  // The AI components in a folder that does not roam with a Windows profile, the free space of its drive read before
  // an installation
  aiComponentsFolderProvider.overrideWithValue(desktopAiComponentsFolder),
  aiFreeSpaceProvider.overrideWithValue(systemFreeSpace),
  // The 3D conversions run with the engine on ONNX Runtime, the safe writer and the index of the folder library
  conversionToolsProvider.overrideWith(desktopConversionTools),
];

/// What wraps the app on a computer, inside MaterialApp (main.dart): the desktop keys and the window's close guard,
/// the folder library kept current while the app runs (its watcher, a rescan when the window comes back), the 360°
/// view of a 360° file opened with the program, and the self check of a CI runner when its variable is set
/// (self_check.dart)
Widget desktopAppShell(Widget app) => DesktopShell(
  child: FolderLibraryHost(child: DesktopOpenedFilesHost(child: DesktopSelfCheck.wrap(app))),
);

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
