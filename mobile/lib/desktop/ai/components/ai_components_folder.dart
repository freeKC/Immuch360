// Where a computer keeps the AI components (design-final 2026-10-26, section 2.2): a folder that neither roams nor
// gets emptied by the system. Windows: the local app data, %LOCALAPPDATA%\com.aprogsys\Immuch360 Desktop\ai-components
// (getApplicationCacheDirectory of path_provider_windows), not the support folder, which is in the roaming profile with
// the database; the installer deletes this folder at uninstall ([UninstallDelete] of immuch360.iss, lot A3b). Linux
// and macOS: the support folder, where the rest of the data of the app is (the database, desktop_files.json,
// desktop_ai.json), not the caches, which cleaning tools and macOS empty. On macOS ~/Library/Application
// Support/com.aprogsys.immuch360.desktop/ai-components. On Linux ~/.local/share/immuch360/ai-components on most
// systems, ~/.local/share/com.aprogsys.immuch360/ai-components on the others (linuxSupportFolderNames says why), as the
// guide says for the data of the app.
//
// "Move the AI components" (design-final 2026-10-27, section 7.4): the user picks a folder, the components go into its
// ai-components folder (AiComponentsService.moveTo copies and checks them), and that folder is kept as
// componentsFolder in desktop_ai.json, which this folder reads first. Moved back into the folder of the app, the
// setting is forgotten. The Windows uninstaller deletes the folder of the app only, not a folder the user chose.

import 'dart:io';

import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('AiComponentsFolder');

/// The two names of the support folder of the app on Linux. path_provider_linux names it after the application id,
/// com.aprogsys.immuch360, when it can ask GIO for that id, which takes libgio-2.0.so, a link that only the development
/// packages install; after the executable, immuch360, otherwise, the usual case. Where it can read the id, it still
/// keeps an immuch360 folder that exists while no com.aprogsys.immuch360 one does.
const linuxSupportFolderNames = ['immuch360', 'com.aprogsys.immuch360'];

/// The components folder of this computer: the one the user moved them to, else the folder of the app; [windows],
/// [linux], [localAppData] and [support] only in the tests
Future<Directory> desktopAiComponentsFolder({
  bool? windows,
  bool? linux,
  Future<Directory> Function() localAppData = getApplicationCacheDirectory,
  Future<Directory> Function() support = getApplicationSupportDirectory,
}) async {
  // desktop_ai.json is in the support folder; the store of the app, whose reads wait for its writes, when it is that one
  final store = support == getApplicationSupportDirectory
      ? DesktopAiSettingsStore.instance
      : DesktopAiSettingsStore(settingsDirectory: support);
  try {
    final moved = (await store.read()).componentsFolder;
    if (moved != null && moved.isNotEmpty) {
      return Directory(moved);
    }
  } on FileSystemException catch (error) {
    _log.warning('desktop_ai.json could not be read, the components are looked for in the folder of the app: $error');
  }
  return _homeFolder(windows: windows, linux: linux, localAppData: localAppData, support: support);
}

/// The folder of the app for the components, where they are until the user moves them
Future<Directory> _homeFolder({
  bool? windows,
  bool? linux,
  required Future<Directory> Function() localAppData,
  required Future<Directory> Function() support,
}) async {
  final onWindows = windows ?? CurrentPlatform.isWindows;
  final parent = onWindows ? await localAppData() : await support();
  final folder = Directory(p.join(parent.path, aiComponentsFolderName));
  if (!onWindows && (linux ?? CurrentPlatform.isLinux)) {
    await _adoptComponentsOfOtherName(folder);
  }
  return folder;
}

/// Moves the components into the ai-components folder of [chosen], a folder the user picked, and keeps it in
/// desktop_ai.json; back into the folder of the app ([home], by default the one of this computer), the setting is
/// forgotten. [store] and [home] only in the tests.
Future<AiMoveResult> moveAiComponents(
  AiComponentsService service,
  String chosen, {
  DesktopAiSettingsStore? store,
  Directory? home,
  void Function(int done, int total)? onProgress,
}) async {
  final settings = store ?? DesktopAiSettingsStore.instance;
  final own =
      home ?? await _homeFolder(localAppData: getApplicationCacheDirectory, support: getApplicationSupportDirectory);
  return service.moveTo(
    Directory(p.join(chosen, aiComponentsFolderName)),
    onProgress: onProgress,
    remember: (folder) async {
      final back = p.equals(folder.path, own.path);
      await settings.update((kept) => kept.copyWith(componentsFolder: () => back ? null : folder.path));
    },
  );
}

/// On Linux, the components installed while the support folder had its other name, moved into [folder] when it does
/// not exist yet: the support folder changes name when libgio-2.0.so comes or goes, and the components would
/// otherwise stay on the disk unused and be downloaded again. Nothing moves when [folder] exists or when the other
/// folder has no installed.json; a move that fails leaves the components where they are, to be downloaded again.
Future<void> _adoptComponentsOfOtherName(Directory folder) async {
  final support = folder.parent;
  final name = p.basename(support.path);
  if (!linuxSupportFolderNames.contains(name)) {
    return;
  }
  final otherName = linuxSupportFolderNames.firstWhere((candidate) => candidate != name);
  final other = Directory(p.join(support.parent.path, otherName, aiComponentsFolderName));
  try {
    if (folder.existsSync() || !File(p.join(other.path, AiComponentsService.installedFileName)).existsSync()) {
      return;
    }
    await other.rename(folder.path);
    _log.info('AI components moved from ${other.path} to ${folder.path}');
  } on FileSystemException catch (error) {
    _log.warning('AI components left in ${other.path}: ${error.message}');
  }
}
