// Where a computer keeps the AI components: the local app data on Windows (not the roaming support folder), the
// support folder on Linux and macOS (not the caches); and the Windows uninstaller, which deletes that folder and
// nothing else of the user

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/components/ai_components_folder.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:path/path.dart' as p;

import '../../ci/ci_scripts.dart';

void main() {
  final local = Directory(p.join('C:', 'Users', 'u', 'AppData', 'Local', 'com.aprogsys', 'Immuch360 Desktop'));
  final roaming = Directory(p.join('C:', 'Users', 'u', 'AppData', 'Roaming', 'com.aprogsys', 'Immuch360 Desktop'));

  test('Windows: in the local app data, which does not roam', () async {
    final folder = await desktopAiComponentsFolder(
      windows: true,
      localAppData: () async => local,
      support: () async => roaming,
    );

    expect(folder.path, p.join(local.path, 'ai-components'));
  });

  test('Linux and macOS: in the support folder, which no cleaning empties', () async {
    final support = Directory(p.join('home', 'u', '.local', 'share', 'com.aprogsys.immuch360'));
    final folder = await desktopAiComponentsFolder(
      windows: false,
      localAppData: () async => throw StateError('the cache folder is not for the components'),
      support: () async => support,
    );

    expect(folder.path, p.join(support.path, 'ai-components'));
  });

  test(
    'the Windows uninstaller deletes that folder of the release build, and nothing else of the user',
    () {
      // The names path_provider_windows reads from the version resource of immuch360.exe in a release build
      final identity = File(p.join('windows', 'runner', 'app_identity.h')).readAsStringSync();
      final company = RegExp(r'#define IMMUCH360_COMPANY_NAME "([^"]+)"').firstMatch(identity)!.group(1);
      final products = RegExp(r'#define IMMUCH360_PRODUCT_NAME "([^"]+)"').allMatches(identity).map((m) => m.group(1));
      expect(products, contains('Immuch360 Desktop'));
      final script = File(p.join(ciScriptsDir, 'packaging', 'windows', 'immuch360.iss')).readAsStringSync();
      final section = RegExp(
        r'^\[UninstallDelete\]\r?\n([\s\S]*?)(?=^\[)',
        multiLine: true,
      ).firstMatch(script)!.group(1)!;
      final entries = section
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith(';'));

      expect(entries, [
        'Type: filesandordirs; Name: "{localappdata}\\$company\\Immuch360 Desktop\\$aiComponentsFolderName"',
      ]);
    },
    skip: File(p.join(ciScriptsDir, 'packaging', 'windows', 'immuch360.iss')).existsSync()
        ? false
        : 'no CI scripts here',
  );
}
