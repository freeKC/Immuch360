// The summary of the self check on the macOS runner (.github/desktop/packaging/macos/self_check_summary.py): every
// check passes on the reports of a good run, and --strict fails the step when one of them did not. The y4m start: the
// 10 bit fixture of check_y4m.py over HTTP from 127.0.0.1, the stream the AV2 decoder serves, played by the app.

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

/// The report of the start without arguments with the y4m over HTTP as the video
Map<String, Object?> _y4mReport({Map<String, Object?>? video}) => {
  'platform': 'macos',
  'firstPage': 'welcome',
  'session': 'without a server, started',
  'pages': ['TabShellRoute'],
  'video':
      video ??
      {
        'bundled': true,
        'loaded': true,
        'file': 'http://127.0.0.1:50123/fixture-10bit.y4m',
        'playedSeconds': 4.8,
        'firstFrameMs': 240,
        'size': '320x180',
        'hwdec-current': 'no',
        'current-tracks/video/codec': 'rawvideo',
        'frame-drop-count': 0,
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

  void writeLater(String asset) => File(p.join(folder.path, 'finder.json.later')).writeAsStringSync(
    jsonEncode({
      'pages': ['TabShellRoute', 'AssetViewerRoute'],
      'asset': asset,
    }),
  );

  test('a good run passes every check', () {
    write('folder', _folderReport());
    write('video', _videoReport);
    write('finder', _videoReport);
    write('y4m', _y4mReport());
    writeLater('test-video.mp4');
    final run = runCiScript(_script, [folder.path, '--strict']);
    expect(run.exitCode, 0, reason: '$run');
    expect(run.output, isNot(contains('FAILED')));
    expect(run.output, contains('-34018'), reason: 'the data protection keychain is reported for the record');
    expect(run.output, contains('| The y4m of the AV2 decoder (10 bit, HTTP from 127.0.0.1) played by the app'));
  });

  test('a y4m the libmpv of the app does not read, or a start without its report, fails', () {
    write('folder', _folderReport());
    write('video', _videoReport);
    write('finder', _videoReport);
    writeLater('test-video.mp4');
    write(
      'y4m',
      _y4mReport(
        video: {
          'bundled': true,
          'loaded': true,
          'file': 'http://127.0.0.1:50123/fixture-10bit.y4m',
          'error': 'PlayerEvent.failed(Failed to recognize file format.)',
        },
      ),
    );
    final run = runCiScript(_script, [folder.path, '--strict']);
    expect(run.exitCode, 1);
    expect(run.output, contains('Failed to recognize file format.'));
    File(p.join(folder.path, 'y4m.json')).deleteSync();
    File(p.join(folder.path, 'y4m.state')).deleteSync();
    final missing = runCiScript(_script, [folder.path, '--strict']);
    expect(missing.exitCode, 1);
    expect(missing.output, contains('y4m: not started'));
  });

  test('a y4m played as something else than raw video fails', () {
    write('folder', _folderReport());
    write('video', _videoReport);
    write('finder', _videoReport);
    writeLater('test-video.mp4');
    final y4m = Map<String, Object?>.of(_y4mReport()['video']! as Map<String, Object?>);
    y4m['current-tracks/video/codec'] = 'h264';
    write('y4m', _y4mReport(video: y4m));
    final run = runCiScript(_script, [folder.path, '--strict']);
    expect(run.exitCode, 1);
    expect(run.output, contains('current-tracks/video/codec h264'));
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

  test('a video handed to the copy that runs and not shown fails', () {
    write('folder', _folderReport());
    write('video', _videoReport);
    write('finder', _videoReport);
    writeLater('test-photo.jpg');
    final run = runCiScript(_script, [folder.path, '--strict']);
    expect(run.exitCode, 1);
    expect(run.output, contains('asset test-photo.jpg'));
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
