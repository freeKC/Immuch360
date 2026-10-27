// Where a computer keeps the AI components (design-final 2026-10-26, section 2.2): a folder that neither roams nor
// gets emptied by the system. Windows: the local app data, %LOCALAPPDATA%\com.aprogsys\Immuch360 Desktop\ai-components
// (getApplicationCacheDirectory of path_provider_windows), not the support folder, which is in the roaming profile with
// the database; the installer deletes this folder at uninstall ([UninstallDelete] of immuch360.iss, lot A3b). Linux
// and macOS: the support folder, ~/.local/share/com.aprogsys.immuch360/ai-components and ~/Library/Application
// Support/com.aprogsys.immuch360.desktop/ai-components, not the caches, which cleaning tools and macOS empty.

import 'dart:io';

import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The components folder of this computer; [windows], [localAppData] and [support] only in the tests
Future<Directory> desktopAiComponentsFolder({
  bool? windows,
  Future<Directory> Function() localAppData = getApplicationCacheDirectory,
  Future<Directory> Function() support = getApplicationSupportDirectory,
}) async {
  final parent = (windows ?? CurrentPlatform.isWindows) ? await localAppData() : await support();
  return Directory(p.join(parent.path, aiComponentsFolderName));
}
