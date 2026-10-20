// The summary of the self check on the macOS runner (.github/desktop/packaging/macos/self_check_summary.py): every
// check passes on the reports of a good run, and --strict fails the step when one of them did not.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

const _script = 'packaging/macos/self_check_summary.py';

Map<String, Object?> _folderReport({Map<String, Object?>? storage, Map<String, Object?>? video}) => {
  'platform': 'macos',
  'firstPage': 'welcome',
  'session': 'without a server, started',
  'pages': ['TabShellRoute', 'OpenedFilesRoute'],
  'secureStorage':
      storage ??
      {
        'app': {'ok': true, 'readBack': true, 'deleted': true},
        'dataProtectionKeychain': {'ok': false, 'failedAt': 'write', 'error': 'Code: -34018'},
      },
  'video':
      video ??
      {
        'bundled': true,
        'loaded': true,
        'mpvVersion': 'mpv v0.41.0',
        'playedSeconds': 4.9,
        'firstFrameMs': 180,
        'size': '1280x720',
        'hwdec-current': 'videotoolbox',
      },
};

const Map<String, Object?> _videoReport = {
  'platform': 'macos',
  'firstPage': 'timeline',
  'session': 'without a server, already open',
  'pages': ['TabShellRoute', 'AssetViewerRoute'],
};

void main() {
  group('self check summary', _tests, skip: skipCiScripts);
}

void _tests() {
  late Directory folder;

  setUp(() => folder = Directory.systemTemp.createTempSync('self_check_summary'));
  tearDown(() => folder.deleteSync(recursive: true));

  void write(String name, Map<String, Object?> report) {
    File(p.join(folder.path, '$name.json')).writeAsStringSync(jsonEncode(report));
    File(p.join(folder.path, '$name.state')).writeAsStringSync('$name: still running');
    File(p.join(folder.path, 'plain.state')).writeAsStringSync('plain: still running after 30 seconds');
  }

  test('a good run passes every check', () {
    write('folder', _folderReport());
    write('video', _videoReport);
    write('finder', _videoReport);
    final run = runCiScript(_script, [folder.path, '--strict']);
    expect(run.exitCode, 0, reason: '$run');
    expect(run.output, isNot(contains('FAILED')));
    expect(run.output, contains('-34018'), reason: 'the data protection keychain is reported for the record');
  });

  test('a photo that Launch Services did not hand over fails', () {
    write('folder', _folderReport());
    write('video', _videoReport);
    write('finder', {
      ..._videoReport,
      'pages': ['TabShellRoute'],
    });
    final run = runCiScript(_script, [folder.path, '--strict']);
    expect(run.exitCode, 1);
    expect(
      run.output,
      contains('| The photo handed over by Launch Services opened in the viewer | FAILED | TabShellRoute |'),
    );
  });

  test('a secure storage that gave nothing back fails with --strict only', () {
    write(
      'folder',
      _folderReport(
        storage: {
          'app': {'ok': false, 'failedAt': 'write', 'error': 'Code: -25308'},
        },
      ),
    );
    write('video', _videoReport);
    expect(runCiScript(_script, [folder.path]).exitCode, 0);
    final run = runCiScript(_script, [folder.path, '--strict']);
    expect(run.exitCode, 1);
    expect(run.output, contains('-25308'));
  });

  test('a crash report fails, and names the report', () {
    write('folder', _folderReport());
    write('video', _videoReport);
    File(p.join(folder.path, 'Immuch360 Desktop-2026-10-20-114458.ips')).writeAsStringSync('{}');
    final run = runCiScript(_script, [folder.path, '--strict']);
    expect(run.exitCode, 1);
    expect(run.output, contains('Immuch360 Desktop-2026-10-20-114458.ips'));
  });

  test('a start that ended before the last step: its partial report is read, and the start fails', () {
    write('video', _videoReport);
    final partial = Map<String, Object?>.of(_folderReport())..remove('video');
    File(p.join(folder.path, 'folder.json.partial')).writeAsStringSync(jsonEncode(partial));
    File(p.join(folder.path, 'folder.state')).writeAsStringSync('folder: ended by itself (exit 133)');
    final run = runCiScript(_script, [folder.path, '--strict']);
    expect(run.exitCode, 1);
    expect(run.output, contains('partial report only'));
    expect(
      run.output,
      contains('| Secure storage as the app uses it (login keychain): write, read back, delete | passed |'),
      reason: 'the steps before the end are reported',
    );
  });

  test('a video that did not play, or no report at all, fails', () {
    write('folder', _folderReport(video: {'bundled': true, 'loaded': true, 'playedSeconds': 0.4}));
    final run = runCiScript(_script, [folder.path, '--strict']);
    expect(run.exitCode, 1);
    expect(run.output, contains('video: not started'));
  });
}
