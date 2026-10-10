import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

/// The two phone plugin lists of a plugin baseline, and the desktop ones of a plugins file
const _android = ['connectivity_plus', 'path_provider_android', 'photo_manager'];
const _ios = ['connectivity_plus', 'path_provider_foundation', 'photo_manager'];

String _pluginsFile({List<String> android = _android, List<String> ios = _ios, List<String> windows = const []}) {
  List<Map<String, Object>> entries(List<String> names) => [
    for (final name in names) {'name': name, 'path': '/pub/$name/', 'dependencies': <String>[]},
  ];
  return jsonEncode({
    'plugins': {
      'android': entries(android),
      'ios': entries(ios),
      'windows': entries(windows),
      'linux': [],
      'macos': [],
    },
  });
}

const _goodWorkflow = '''
name: Fixture
on:
  pull_request:
permissions:
  contents: read
jobs:
  windows:
    runs-on: windows-2022
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2 # v2.23.0
        with:
          flutter-version: 3.47.2
      - run: flutter build windows
''';

const _mise = '''
[tools]
java = "21.0.2"

[tools."aqua:flutter/flutter"]
version = "3.47.2"
''';

void main() {
  final folders = <Directory>[];

  Directory tree(Map<String, String> files) {
    final root = fixtureTree(files);
    folders.add(root);
    return root;
  }

  tearDown(() {
    for (final folder in folders) {
      if (folder.existsSync()) {
        folder.deleteSync(recursive: true);
      }
    }
    folders.clear();
  });

  group('check_plugin_baseline.py', () {
    ScriptRun check(Directory root, String plugins, {List<String> extra = const []}) {
      writeFiles(root, {'plugins.json': plugins});
      return runCiScript('check_plugin_baseline.py', [
        '--plugins',
        p.join(root.path, 'plugins.json'),
        '--baseline',
        p.join(root.path, 'baseline.json'),
        ...extra,
      ]);
    }

    test('passes when the Android and iOS lists equal the baseline', () {
      final root = tree({
        'baseline.json': jsonEncode({'android': _android, 'ios': _ios}),
      });
      final run = check(root, _pluginsFile());
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('android: 3 plugins, as the baseline'));
    });

    test('fails when a package joins the Android build, and names it', () {
      final root = tree({
        'baseline.json': jsonEncode({'android': _android, 'ios': _ios}),
      });
      final run = check(root, _pluginsFile(android: [..._android, 'window_manager']));
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains("android: plugins added ['window_manager'], removed []"));
    });

    test('fails when a plugin leaves the iOS build', () {
      final root = tree({
        'baseline.json': jsonEncode({'android': _android, 'ios': _ios}),
      });
      final run = check(root, _pluginsFile(ios: _ios.sublist(1)));
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains("removed ['connectivity_plus']"));
    });

    test('lets the desktop lists grow', () {
      final root = tree({
        'baseline.json': jsonEncode({'android': _android, 'ios': _ios}),
      });
      final run = check(root, _pluginsFile(windows: ['window_manager', 'screen_retriever_windows']));
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('windows 2'));
    });

    test('asks for pub get when the plugin file is missing', () {
      final root = tree({'baseline.json': '{}'});
      final run = runCiScript('check_plugin_baseline.py', [
        '--plugins',
        p.join(root.path, 'missing.json'),
        '--baseline',
        p.join(root.path, 'baseline.json'),
      ]);
      expect(run.exitCode, 2, reason: '$run');
      expect(run.output, contains('flutter pub get'));
    });

    test('--update writes the phone lists only, which then pass', () {
      final root = tree({'baseline.json': '{}'});
      expect(check(root, _pluginsFile(windows: ['window_manager']), extra: ['--update']).exitCode, 0);
      final baseline = jsonDecode(File(p.join(root.path, 'baseline.json')).readAsStringSync()) as Map<String, dynamic>;
      expect(baseline.keys, unorderedEquals(['android', 'ios']));
      expect(baseline['android'], _android);
      expect(check(root, _pluginsFile()).exitCode, 0);
    });
  }, skip: skipCiScripts);

  group('check_platform_ternaries.py', () {
    ScriptRun check(Directory root, Map<String, int> allowed) {
      writeFiles(root, {'allowlist.json': jsonEncode(allowed)});
      return runCiScript('check_platform_ternaries.py', [
        '--root',
        root.path,
        '--allowlist',
        p.join(root.path, 'allowlist.json'),
      ]);
    }

    test('passes with the ternaries of the allow list', () {
      final root = tree({'mobile/lib/a.dart': 'final dir = Platform.isIOS ? "Documents" : "DCIM";\n'});
      final run = check(root, {'mobile/lib/a.dart': 1});
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('1 iOS or Android ternaries in 1 files, none new'));
    });

    test('fails on a new one, also when the question mark is on the next line', () {
      final root = tree({
        'mobile/lib/a.dart':
            'final a = Platform.isIOS ? 1 : 2;\nfinal b = CurrentPlatform.isAndroid\n    ? 3\n    : 4;\n',
      });
      final run = check(root, {'mobile/lib/a.dart': 1});
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('mobile/lib/a.dart: 2 iOS or Android ternaries, 1 allowed'));
    });

    test('fails on a ternary in a file the list does not name', () {
      final root = tree({'mobile/lib/new.dart': 'final a = Platform.isAndroid ? 1 : 2;\n'});
      expect(check(root, {}).exitCode, 1);
    });

    test('does not count ?? and ?. nor generated files', () {
      final root = tree({
        'mobile/lib/a.dart': 'final a = flag(Platform.isIOS ?? false);\nfinal b = maybe?.isIOS;\n',
        'mobile/lib/a.g.dart': 'final a = Platform.isIOS ? 1 : 2;\n',
        'mobile/lib/b.freezed.dart': 'final a = Platform.isAndroid ? 1 : 2;\n',
      });
      expect(check(root, {}).exitCode, 0);
    });

    test('says when a file has fewer than allowed, without failing', () {
      final root = tree({'mobile/lib/a.dart': 'final a = 1;\n'});
      final run = check(root, {'mobile/lib/a.dart': 1});
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('fewer ternaries than allowed in: mobile/lib/a.dart'));
    });
  }, skip: skipCiScripts);

  group('check_desktop_imports.py', () {
    ScriptRun check(Directory root) => runCiScript('check_desktop_imports.py', ['--root', root.path]);

    test('lets lib/desktop import the desktop packages', () {
      final root = tree({
        'mobile/lib/desktop/window/window_setup.dart': "import 'package:window_manager/window_manager.dart';\n",
        'mobile/lib/desktop/video/player.dart': "import 'package:media_kit/media_kit.dart';\n",
      });
      final run = check(root);
      expect(run.exitCode, 0, reason: '$run');
    });

    test('lets a shared file hand over to lib/desktop', () {
      final root = tree({
        'mobile/lib/main.dart': "import 'package:immich_mobile/desktop/platform/desktop_apis.dart';\n",
        'mobile/lib/other.dart': "import 'package:media_kit_extra/thing.dart';\n",
        // The darwin side of a plugin serves iOS too
        'mobile/lib/auth.dart': "import 'package:local_auth_darwin/local_auth_darwin.dart';\n",
      });
      final run = check(root);
      expect(run.exitCode, 0, reason: '$run');
    });

    test('fails on a desktop package imported or exported by a shared file, main_desktop.dart included', () {
      final root = tree({
        'mobile/lib/main_desktop.dart': "import 'package:window_manager/window_manager.dart';\n",
        'mobile/lib/services/video.dart': "export 'package:media_kit/media_kit.dart' show Player;\n",
        'mobile/lib/utils/win.dart': "import\n    'package:win32/win32.dart';\n",
      });
      final run = check(root);
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('mobile/lib/main_desktop.dart: imports package:window_manager'));
      expect(run.output, contains('mobile/lib/services/video.dart: imports package:media_kit'));
      expect(run.output, contains('mobile/lib/utils/win.dart: imports package:win32'));
    });

    test('fails on the desktop side of a federated plugin imported by a shared file', () {
      final root = tree({
        'mobile/lib/utils/files.dart': "import 'package:path_provider_windows/path_provider_windows.dart';\n",
        'mobile/lib/utils/picker.dart': "import 'package:file_selector_linux/file_selector_linux.dart';\n",
        'mobile/lib/desktop/library/roots.dart': "import 'package:path_provider_windows/path_provider_windows.dart';\n",
      });
      final run = check(root);
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('mobile/lib/utils/files.dart: imports package:path_provider_windows'));
      expect(run.output, contains('mobile/lib/utils/picker.dart: imports package:file_selector_linux'));
      expect(run.output, isNot(contains('roots.dart')));
    });
  }, skip: skipCiScripts);

  group('check_platform_audit.py', () {
    String audit(List<String> rows) => [
      '# Platform audit',
      '',
      '| Line (build 20) | What the line decides | Windows, Linux, macOS |',
      '|---|---|---|',
      for (final row in rows) '| `$row` | something | right |',
      '',
      '## Desktop gates added outside these lines',
      '',
      '| File | Hand over |',
      '|---|---|',
      '| `lib/main.dart` | the start |',
    ].join('\n');

    ScriptRun check(Directory root) => runCiScript('check_platform_audit.py', ['--root', root.path]);

    const twoLines = 'if (Platform.isAndroid) {}\nfinal ios = CurrentPlatform.isIOS;\n';

    test('passes when each platform line of a file has a row', () {
      final root = tree({
        'mobile/lib/a.dart': twoLines,
        'mobile/lib/desktop/platform/PLATFORM-AUDIT.md': audit(['lib/a.dart:1', 'lib/a.dart:2']),
      });
      final run = check(root);
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('2 platform lines in 1 files'));
    });

    test('fails on a platform line without a row, and names the file', () {
      final root = tree({
        'mobile/lib/a.dart': '$twoLines\nfinal x = Platform.isIOS && true;\n',
        'mobile/lib/b.dart': 'final y = Platform.isAndroid;\n',
        'mobile/lib/desktop/platform/PLATFORM-AUDIT.md': audit(['lib/a.dart:1', 'lib/a.dart:2']),
      });
      final run = check(root);
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('mobile/lib/a.dart: 3 platform lines, 2 rows'));
      expect(run.output, contains('mobile/lib/b.dart: 1 platform lines, 0 rows'));
    });

    test('leaves out lib/desktop, generated files and lines without a platform test', () {
      final root = tree({
        'mobile/lib/desktop/x.dart': 'final a = Platform.isIOS;\n',
        'mobile/lib/a.g.dart': 'final a = Platform.isAndroid;\n',
        'mobile/lib/c.dart': 'final a = Platform.isWindows || CurrentPlatform.isDesktop;\n',
        'mobile/lib/desktop/platform/PLATFORM-AUDIT.md': audit([]),
      });
      expect(check(root).exitCode, 0);
    });

    test('says which rows lost their line, without failing', () {
      final root = tree({
        'mobile/lib/a.dart': 'final a = 1;\n',
        'mobile/lib/desktop/platform/PLATFORM-AUDIT.md': audit(['lib/a.dart:1']),
      });
      final run = check(root);
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('the table can drop them): lib/a.dart'));
    });

    test('stops when the table is missing', () {
      final root = tree({'mobile/lib/a.dart': twoLines});
      expect(check(root).exitCode, 2);
    });
  }, skip: skipCiScripts);

  group('check_pigeon_desktop.py', () {
    ScriptRun check(Directory root, Map<String, String> reasons) {
      writeFiles(root, {'not-on-desktop.json': jsonEncode(reasons)});
      return runCiScript('check_pigeon_desktop.py', [
        '--root',
        root.path,
        '--not-on-desktop',
        p.join(root.path, 'not-on-desktop.json'),
      ]);
    }

    const pigeon = '''
@HostApi()
abstract class SyncApi {
  void sync();
}

@HostApi(dartHostTestHandler: 'TestTvApi')
abstract class TvApi {
  bool isTv();
}

@FlutterApi()
abstract class SyncEvents {
  void done();
}
''';

    test('passes when each host API has a desktop class or a reason', () {
      final root = tree({
        'mobile/pigeon/sync_api.dart': pigeon,
        'mobile/lib/desktop/library/folder_sync.dart':
            'class FolderSyncApi extends Base<int> implements SyncApi {\n  void sync() {}\n}\n',
      });
      final run = check(root, {'TvApi': 'Android TV only'});
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('SyncApi: FolderSyncApi in mobile/lib/desktop/library/folder_sync.dart'));
      expect(run.output, contains('TvApi: not on the computers, Android TV only'));
      expect(run.output, isNot(contains('SyncEvents')));
    });

    test('fails on a host API with neither, a class named in a comment not counting', () {
      final root = tree({
        'mobile/pigeon/sync_api.dart': pigeon,
        'mobile/lib/desktop/library/folder_sync.dart': '// This class keeps what the class SyncApi {} asked\n',
      });
      final run = check(root, {'TvApi': 'Android TV only'});
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('SyncApi (mobile/pigeon/sync_api.dart): no desktop class'));
    });

    test('says when a reason is no longer needed', () {
      final root = tree({
        'mobile/pigeon/sync_api.dart': pigeon,
        'mobile/lib/desktop/sync.dart': 'class A implements SyncApi {}\nclass B implements TvApi {}\n',
      });
      final run = check(root, {'TvApi': 'Android TV only', 'GoneApi': 'removed upstream'});
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('TvApi now has a desktop class'));
      expect(run.output, contains('GoneApi is no longer a pigeon host API'));
    });
  }, skip: skipCiScripts);

  group('check_phone_projects.py', () {
    ScriptRun check(List<String> changed) {
      final root = tree({'changed.txt': changed.join('\n')});
      return runCiScript('check_phone_projects.py', ['--changed-from', p.join(root.path, 'changed.txt')]);
    }

    test('passes when the phone projects are left alone', () {
      final run = check(['mobile/lib/main.dart', 'mobile/windows/runner/main.cpp', 'README.md', 'mobile/ios_notes.md']);
      expect(run.exitCode, 0, reason: '$run');
    });

    test('fails on a file under mobile/android or mobile/ios, and names it', () {
      final run = check(['mobile/lib/main.dart', 'mobile/android/app/build.gradle', 'mobile/ios/Runner/Info.plist']);
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('changed: mobile/android/app/build.gradle'));
      expect(run.output, contains('changed: mobile/ios/Runner/Info.plist'));
    });

    test('counts the native code of a vendored package, not its Dart side', () {
      final dart = check([
        'mobile/packages/background_downloader/lib/src/desktop/desktop_downloader.dart',
        'mobile/packages/flutter_secure_storage_windows/lib/src/dpapi.dart',
      ]);
      expect(dart.exitCode, 0, reason: '$dart');

      final native = check([
        'mobile/packages/background_downloader/android/src/main/kotlin/TaskWorker.kt',
        'mobile/packages/dart_smb2/ios/dart_smb2.podspec',
        'mobile/packages/some_plugin/darwin/Classes/Plugin.swift',
      ]);
      expect(native.exitCode, 1, reason: '$native');
      expect(native.output, contains('changed: mobile/packages/background_downloader/android/src/main/kotlin/'));
      expect(native.output, contains('changed: mobile/packages/dart_smb2/ios/dart_smb2.podspec'));
      expect(native.output, contains('changed: mobile/packages/some_plugin/darwin/Classes/Plugin.swift'));
    });
  }, skip: skipCiScripts);

  group('check_phone_packages.py', () {
    String entry(String name, {String version = '1.0.0', String sha = 'a1', String dependency = 'transitive'}) =>
        '''
  $name:
    dependency: $dependency
    description:
      name: $name
      sha256: "$sha"
      url: "https://pub.dev"
    source: hosted
    version: "$version"
''';

    String lock(List<String> entries, {String flutter = '3.47.2'}) =>
        '# Generated by pub\npackages:\n${entries.join()}sdks:\n  dart: ">=3.9.0 <4.0.0"\n  flutter: "$flutter"\n';

    final base = lock([entry('path_provider', version: '2.1.5'), entry('wakelock_plus', version: '1.3.3')]);

    ScriptRun check(String now) {
      final root = tree({
        'base.lock': base,
        'now.lock': now,
        'desktop.json': jsonEncode({'window_manager': 'the window of the computers'}),
      });
      return runCiScript('check_phone_packages.py', [
        '--base-lock',
        p.join(root.path, 'base.lock'),
        '--lock',
        p.join(root.path, 'now.lock'),
        '--desktop-packages',
        p.join(root.path, 'desktop.json'),
      ]);
    }

    test('passes when the packages are those of the phone branch', () {
      final run = check(base);
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('2 packages'));
    });

    test('lets a desktop package in, and a package change from transitive to direct', () {
      final run = check(
        lock([
          entry('path_provider', version: '2.1.5', dependency: '"direct main"'),
          entry('wakelock_plus', version: '1.3.3'),
          entry('window_manager', version: '0.5.2'),
        ], flutter: '>=3.47.0'),
      );
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('desktop only, not compared: window_manager'));
      expect(run.output, contains('for the record, SDK constraints'));
    });

    test('fails when a package of the phones moves to another version, and names it', () {
      final run = check(lock([entry('path_provider', version: '2.1.5'), entry('wakelock_plus', version: '1.3.4')]));
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('wakelock_plus: changed, 1.3.3 to 1.3.4'));
      expect(run.output, isNot(contains('path_provider')));
    });

    test('fails on the same version from another source', () {
      final run = check(
        lock([entry('path_provider', version: '2.1.5', sha: 'b2'), entry('wakelock_plus', version: '1.3.3')]),
      );
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('path_provider: changed, same version, other source or checksum'));
    });

    test('fails when a package outside the desktop list joins or leaves', () {
      final added = check(
        lock([entry('path_provider', version: '2.1.5'), entry('wakelock_plus', version: '1.3.3'), entry('media_kit')]),
      );
      expect(added.exitCode, 1, reason: '$added');
      expect(added.output, contains('media_kit: added (1.0.0)'));

      final removed = check(lock([entry('wakelock_plus', version: '1.3.3')]));
      expect(removed.exitCode, 1, reason: '$removed');
      expect(removed.output, contains('path_provider: removed (was 2.1.5)'));
    });

    test('refuses a file that is no lock', () {
      final run = check('name: immich_mobile\n');
      expect(run.exitCode, 2, reason: '$run');
    });
  }, skip: skipCiScripts);

  group('check_apk_sizes.py', () {
    ScriptRun check(Map<String, int> apks) {
      final root = tree({
        'reference.json': jsonEncode({'arm64-v8a': 100000, 'universal': 200000, 'quest': 100000, 'aab': 150000}),
      });
      for (final entry in apks.entries) {
        File(p.join(root.path, entry.key)).writeAsBytesSync(List.filled(entry.value, 0));
      }
      return runCiScript('check_apk_sizes.py', [
        '--reference-json',
        p.join(root.path, 'reference.json'),
        for (final name in apks.keys) p.join(root.path, name),
      ]);
    }

    test('passes when each kind stays within 1 % of the reference, whatever the naming', () {
      final run = check({
        'app-arm64-v8a-phone-release.apk': 100900,
        'Immuch360-v3.3.0-rc.0-21-release.apk': 199000,
        'app-quest-release.apk': 100000,
        'app-phone-release.aab': 150100,
        'app-x86_64-phone-release.apk': 5000,
      });
      expect(run.exitCode, 0, reason: '$run');
      expect(
        run.output,
        contains('app-arm64-v8a-phone-release.apk: arm64-v8a, 100900 bytes against 100000 (+0.900 %)'),
      );
      expect(run.output, contains('Immuch360-v3.3.0-rc.0-21-release.apk: universal'));
      expect(run.output, contains('app-x86_64-phone-release.apk: x86_64, 5000 bytes, nothing to compare with'));
    });

    test('fails on a package that grew or shrank by more than 1 %', () {
      final run = check({'app-arm64-v8a-phone-release.apk': 101100, 'app-quest-release.apk': 98000});
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('(+1.100 %), more than 1 %'));
      expect(run.output, contains('(-2.000 %), more than 1 %'));
    });
  }, skip: skipCiScripts);

  group('check_workflow.py', () {
    ScriptRun check(String workflow, {String mise = _mise}) {
      final root = tree({'workflow.yml': workflow, 'mise.toml': mise});
      return runCiScript('check_workflow.py', [
        '--workflow',
        p.join(root.path, 'workflow.yml'),
        '--mise',
        p.join(root.path, 'mise.toml'),
      ]);
    }

    test('passes a pinned workflow without secrets', () {
      final run = check(_goodWorkflow);
      expect(run.exitCode, 0, reason: '$run');
    });

    test('fails on a moving runner label', () {
      final run = check(_goodWorkflow.replaceFirst('windows-2022', 'windows-latest'));
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('runner windows-latest is not a pinned label'));
    });

    test('fails on an action pinned to a tag only, or without its version comment', () {
      expect(check(_goodWorkflow.replaceFirst(RegExp(r'checkout@\w+ # v7.0.1'), 'checkout@v7')).exitCode, 1);
      final run = check(_goodWorkflow.replaceFirst(' # v2.23.0', ''));
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('has no version comment'));
    });

    test('fails when the Windows Flutter differs from mise.toml', () {
      final run = check(_goodWorkflow, mise: _mise.replaceFirst('3.47.2', '3.48.0'));
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('Flutter 3.47.2, mobile/mise.toml has 3.48.0'));
    });

    test('an Xcode named by XCODE_VERSION passes; the newest a pattern finds, or none named, fails', () {
      const macos = '''
  macos:
    runs-on: macos-15
    env:
      XCODE_VERSION: '26.3'
    steps:
      - run: |
          xcode="/Applications/Xcode_\$XCODE_VERSION.app"
          sudo xcode-select -s "\$xcode/Contents/Developer"
''';
      final named = check('$_goodWorkflow$macos');
      expect(named.exitCode, 0, reason: '$named');

      // A weekly image update may add a beta that sorts after the releases
      final newest = check(
        '$_goodWorkflow$macos'.replaceFirst(
          r'xcode="/Applications/Xcode_$XCODE_VERSION.app"',
          r'xcode=$(ls -d /Applications/Xcode_26.*.app | sort -V | tail -1)',
        ),
      );
      expect(newest.exitCode, 1, reason: '$newest');
      expect(newest.output, contains('an Xcode found by a pattern'));

      final unnamed = check('$_goodWorkflow$macos'.replaceFirst("      XCODE_VERSION: '26.3'\n", ''));
      expect(unnamed.exitCode, 1, reason: '$unnamed');
      expect(unnamed.output, contains('xcode-select without an XCODE_VERSION'));
    });

    test('fails on a secret, a write access, a kept token or pull_request_target', () {
      expect(
        check(_goodWorkflow.replaceFirst('run: flutter', r'run: echo ${{ secrets.KEY_JKS }} && flutter')).exitCode,
        1,
      );
      expect(check(_goodWorkflow.replaceFirst('contents: read', 'contents: read\n  packages: write')).exitCode, 1);
      expect(check(_goodWorkflow.replaceFirst('persist-credentials: false', 'fetch-depth: 0')).exitCode, 1);
      expect(check(_goodWorkflow.replaceFirst('  pull_request:', '  pull_request_target:')).exitCode, 1);
      expect(check(_goodWorkflow.replaceFirst('permissions:\n  contents: read\n', '')).exitCode, 1);
    });
  }, skip: skipCiScripts);

  // The gates on the repository itself, as the gates job runs them
  group('this repository', () {
    test('desktop packages are imported under lib/desktop only', () {
      final run = runCiScript('check_desktop_imports.py', []);
      expect(run.exitCode, 0, reason: '$run');
    });

    test('no new iOS or Android ternary', () {
      final run = runCiScript('check_platform_ternaries.py', []);
      expect(run.exitCode, 0, reason: '$run');
    });

    test('every platform line has a verdict in PLATFORM-AUDIT.md', () {
      final run = runCiScript('check_platform_audit.py', []);
      expect(run.exitCode, 0, reason: '$run');
    });

    test('every pigeon host API is answered on the computers', () {
      final run = runCiScript('check_pigeon_desktop.py', []);
      expect(run.exitCode, 0, reason: '$run');
    });

    test('the desktop workflow is pinned and without secrets', () {
      final run = runCiScript('check_workflow.py', []);
      expect(run.exitCode, 0, reason: '$run');
    });

    test(
      'the Android and iOS plugin lists equal the baseline',
      () {
        final run = runCiScript('check_plugin_baseline.py', []);
        expect(run.exitCode, 0, reason: '$run');
      },
      // A skip of its own replaces the group's, so the group's reason is kept here: without the scripts (the Windows
      // mirror holds mobile/ only) the test would run and fail
      skip: skipCiScripts != false
          ? skipCiScripts
          : File(p.join(repositoryRoot, 'mobile', '.flutter-plugins-dependencies')).existsSync()
          ? false
          : 'no .flutter-plugins-dependencies (flutter pub get)',
    );
  }, skip: skipCiScripts);
}
