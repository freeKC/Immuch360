// Where a computer keeps the AI components (design-final 2026-10-26, section 2.2): a folder that neither roams nor
// gets emptied by the system. Windows: the local app data, %LOCALAPPDATA%\com.aprogsys\Immuch360 Desktop\ai-components
// (getApplicationCacheDirectory of path_provider_windows), not the support folder, which is in the roaming profile with
// the database; the installer deletes this folder at uninstall ([UninstallDelete] of immuch360.iss, lot A3b). Linux
// and macOS: the support folder, where the rest of the data of the app is (the database, desktop_files.json,
// desktop_ai.json), not the caches, which cleaning tools and macOS empty. On macOS ~/Library/Application
// Support/com.aprogsys.immuch360.desktop/ai-components. On Linux ~/.local/share/immuch360/ai-components on most
// systems, ~/.local/share/com.aprogsys.immuch360/ai-components on the others (linuxSupportFolderNames says why), as the
// guide says for the data of the app.

import 'dart:io';

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

/// The components folder of this computer; [windows], [linux], [localAppData] and [support] only in the tests
Future<Directory> desktopAiComponentsFolder({
  bool? windows,
  bool? linux,
  Future<Directory> Function() localAppData = getApplicationCacheDirectory,
  Future<Directory> Function() support = getApplicationSupportDirectory,
}) async {
  final onWindows = windows ?? CurrentPlatform.isWindows;
  final parent = onWindows ? await localAppData() : await support();
  final folder = Directory(p.join(parent.path, aiComponentsFolderName));
  if (!onWindows && (linux ?? CurrentPlatform.isLinux)) {
    await _adoptComponentsOfOtherName(folder);
  }
  return folder;
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
