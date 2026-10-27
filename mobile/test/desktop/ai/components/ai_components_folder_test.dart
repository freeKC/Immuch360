// Where a computer keeps the AI components: the local app data on Windows (not the roaming support folder), the
// support folder on Linux and macOS (not the caches), the components found under the other name of the support folder
// of Linux moved in; and the Windows uninstaller, which deletes that folder and nothing else of the user

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
    final support = Directory(p.join('home', 'u', '.local', 'share', 'immuch360'));
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

  group('Linux: the support folder has two names', () {
    late Directory data;

    setUp(() => data = Directory.systemTemp.createTempSync('ai_components_folder_'));
    tearDown(() => data.deleteSync(recursive: true));

    /// Components installed in the support folder named [supportName], under the data folder of the user
    Directory installedUnder(String supportName) {
      final folder = Directory(p.join(data.path, supportName, aiComponentsFolderName))..createSync(recursive: true);
      File(p.join(folder.path, AiComponentsService.installedFileName)).writeAsStringSync('{"version":1}');
      File(p.join(folder.path, 'models', 'model.onnx'))
        ..createSync(recursive: true)
        ..writeAsStringSync('model');
      return folder;
    }

    for (final (from, to) in [('com.aprogsys.immuch360', 'immuch360'), ('immuch360', 'com.aprogsys.immuch360')]) {
      test('the components installed in $from are moved into $to, where the app looks now', () async {
        installedUnder(from);
        final support = Directory(p.join(data.path, to))..createSync();

        final folder = await desktopAiComponentsFolder(windows: false, linux: true, support: () async => support);

        expect(folder.path, p.join(support.path, aiComponentsFolderName));
        expect(File(p.join(folder.path, AiComponentsService.installedFileName)).readAsStringSync(), '{"version":1}');
        expect(File(p.join(folder.path, 'models', 'model.onnx')).readAsStringSync(), 'model');
        expect(Directory(p.join(data.path, from, aiComponentsFolderName)).existsSync(), isFalse);
      });
    }

    test('nothing moves once the support folder of the app has its own components folder', () async {
      final theirs = installedUnder('com.aprogsys.immuch360');
      final ours = Directory(p.join(data.path, 'immuch360', aiComponentsFolderName))..createSync(recursive: true);

      final folder = await desktopAiComponentsFolder(windows: false, linux: true, support: () async => ours.parent);

      expect(folder.path, ours.path);
      expect(ours.listSync(), isEmpty);
      expect(File(p.join(theirs.path, AiComponentsService.installedFileName)).existsSync(), isTrue);
    });

    test('nothing moves without installed.json, off Linux, or for a support folder of another name', () async {
      final support = Directory(p.join(data.path, 'immuch360'))..createSync();
      final unfinished = Directory(p.join(data.path, 'com.aprogsys.immuch360', aiComponentsFolderName, 'tmp'))
        ..createSync(recursive: true);

      await desktopAiComponentsFolder(windows: false, linux: true, support: () async => support);

      expect(Directory(p.join(support.path, aiComponentsFolderName)).existsSync(), isFalse);
      expect(unfinished.existsSync(), isTrue);

      final theirs = installedUnder('com.aprogsys.immuch360');
      await desktopAiComponentsFolder(windows: false, linux: false, support: () async => support);
      final macOS = Directory(p.join(data.path, 'com.aprogsys.immuch360.desktop'))..createSync();
      await desktopAiComponentsFolder(windows: false, linux: true, support: () async => macOS);

      expect(Directory(p.join(support.path, aiComponentsFolderName)).existsSync(), isFalse);
      expect(Directory(p.join(macOS.path, aiComponentsFolderName)).existsSync(), isFalse);
      expect(File(p.join(theirs.path, AiComponentsService.installedFileName)).existsSync(), isTrue);
    });
  });
}
