import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

void main() {
  late Directory root;

  setUp(() {
    root = fixtureTree({
      'mobile/pigeon/sync_api.dart': '@HostApi()\nabstract class SyncApi {}\n\n@HostApi()\nabstract class TvApi {}\n',
      'mobile/lib/desktop/library/folder_sync.dart': 'class FolderSyncApi implements SyncApi {}\n',
      'mobile/lib/services/upload.service.dart':
          'final ok = CurrentPlatform.isDesktop || Platform.isIOS;\nfinal api = PlatformApis.nativeSync();\n',
      'mobile/lib/services/plain.service.dart': 'final a = 1;\n',
      'mobile/lib/widgets/back.dart': 'final icon = Platform.isIOS ? 1 : 2;\n',
    });
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  ScriptRun report(List<String> changed, {List<String> extra = const []}) {
    writeFiles(root, {'changed.txt': changed.join('\n')});
    return runCiScript('upstream_sync_report.py', [
      '--root',
      root.path,
      '--changed-from',
      p.join(root.path, 'changed.txt'),
      ...extra,
    ]);
  }

  group('upstream_sync_report.py', () {
    test('lists the contracts, the hand overs, the audited files and the pubspec a sync touched', () {
      final run = report([
        'mobile/pigeon/sync_api.dart',
        'mobile/ios/Runner/Core/URLSessionManager.swift',
        'mobile/lib/main.dart',
        'mobile/lib/services/upload.service.dart',
        'mobile/lib/services/plain.service.dart',
        'mobile/lib/widgets/back.dart',
        'mobile/lib/desktop/library/folder_sync.dart',
        'mobile/pubspec.lock',
        'server/src/app.module.ts',
      ]);
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('9 files changed.'));
      expect(run.output, contains('**Pigeon definitions**: read the diff of `mobile/pigeon/sync_api.dart`'));
      expect(run.output, contains('`SyncApi`: FolderSyncApi in mobile/lib/desktop/library/folder_sync.dart'));
      expect(run.output, contains('`TvApi`: no desktop class: see pigeon-not-on-desktop.json'));
      expect(
        run.output,
        contains('**HTTP clients and headers**: read the diff of `mobile/ios/Runner/Core/URLSessionManager.swift`'),
      );
      expect(run.output, contains('**Start of the app**: read the diff of `mobile/lib/main.dart`'));
      expect(run.output, contains('- [ ] `mobile/lib/services/upload.service.dart`: the guarded hand over'));
      expect(run.output, contains('- [ ] `mobile/lib/widgets/back.dart`: its rows in'));
      expect(run.output, isNot(contains('plain.service.dart`:')));
      expect(run.output, isNot(contains('folder_sync.dart`: the guarded')));
      expect(run.output, contains('The pubspec changed'));
    });

    test('says when nothing of the desktop is concerned', () {
      final run = report(['server/src/app.module.ts', 'web/src/app.html']);
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('None of them changed.'));
      expect(run.output, contains('The pubspec did not change.'));
    });

    test('appends the checklist to the run summary', () {
      writeFiles(root, {'summary.md': '# Before\n'});
      final run = report(['mobile/lib/main.dart'], extra: ['--summary', p.join(root.path, 'summary.md')]);
      expect(run.exitCode, 0, reason: '$run');
      final summary = File(p.join(root.path, 'summary.md')).readAsStringSync();
      expect(summary, startsWith('# Before\n'));
      expect(summary, contains('## Upstream sync checklist for Immuch360 Desktop'));
    });
  }, skip: skipCiScripts);
}
