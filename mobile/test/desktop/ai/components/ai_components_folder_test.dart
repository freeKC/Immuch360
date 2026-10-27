// Where a computer keeps the AI components: the local app data on Windows (not the roaming support folder), the
// support folder on Linux and macOS (not the caches)

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/components/ai_components_folder.dart';
import 'package:path/path.dart' as p;

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
}
