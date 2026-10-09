// The pins of the libmpv build (.github/desktop/libmpv/sources.lock and pin_sources.sh): a run of
// immuch360-libmpv.yml builds the commits of the lock, never the head a branch has on the day of the run.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

final String _libmpvDir = p.join(ciScriptsDir, 'libmpv');
final String _script = p.join(_libmpvDir, 'pin_sources.sh');

/// The script runs in the Linux container of the workflow; on Windows "bash" may be WSL's launcher, with other paths
final Object _skipScript = Platform.isWindows
    ? 'pin_sources.sh runs on Linux'
    : !File(_script).existsSync()
    ? 'no $_script'
    : !_runs('bash', ['--version']) || !_runs('git', ['--version'])
    ? 'needs bash and git'
    : false;

bool _runs(String command, List<String> arguments) {
  try {
    return Process.runSync(command, arguments).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

String _git(String dir, List<String> arguments) {
  final result = Process.runSync('git', [
    '-c',
    'user.name=Immuch360 test',
    '-c',
    'user.email=test@immuch360.invalid',
    '-c',
    'init.defaultBranch=main',
    '-c',
    'commit.gpgsign=false',
    ...arguments,
  ], workingDirectory: dir);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')}: ${result.stderr}');
  }
  return '${result.stdout}'.trim();
}

void main() {
  group('sources.lock', () {
    // Read in the tests, not here: a missing file must skip the group, not fail the whole file
    List<String> lines() => File(
      p.join(_libmpvDir, 'sources.lock'),
    ).readAsLinesSync().map((line) => line.trim()).where((line) => line.isNotEmpty && !line.startsWith('#')).toList();
    List<String> packages() => lines().map((line) => line.split(RegExp(r'\s+')).first).toList();

    test('one commit per package, each named once', () {
      for (final line in lines()) {
        expect(line, matches(RegExp(r'^[a-z0-9_.+-]+ [0-9a-f]{40}$')), reason: line);
      }
      expect(packages().toSet().length, packages().length);
    });

    test('pins the toolchain and the libraries, not FFmpeg and mpv, which the workflow inputs pin', () {
      final names = packages();
      expect(names, containsAll(['llvm', 'mingw-w64', 'cppwinrt', 'libxml2', 'dav1d', 'libass', 'freetype2']));
      expect(names, isNot(contains('ffmpeg')));
      expect(names, isNot(contains('mpv')));
    });
  }, skip: File(p.join(_libmpvDir, 'sources.lock')).existsSync() ? false : 'no sources.lock in $_libmpvDir');

  group('pin_sources.sh', () {
    late Directory root;
    late List<String> commits;

    String path(String relative) => p.joinAll([root.path, ...relative.split('/')]);

    ProcessResult pin(String mode, List<String> packages) =>
        Process.runSync('bash', [_script, path('sources.lock'), path('src'), mode, ...packages]);

    void writeLock(Map<String, String> pins) => File(
      path('sources.lock'),
    ).writeAsStringSync('# package commit\n${pins.entries.map((e) => '${e.key} ${e.value}').join('\n')}\n');

    setUp(() {
      root = Directory.systemTemp.createTempSync('immuch360_pins_');
      // A repository of three commits, then a clone of it per package, as the recipe's download step leaves them
      Directory(path('origin')).createSync();
      _git(path('origin'), ['init', '-q']);
      commits = [];
      for (final n in [1, 2, 3]) {
        File(path('origin/file.txt')).writeAsStringSync('$n');
        _git(path('origin'), ['add', 'file.txt']);
        _git(path('origin'), ['commit', '-q', '-m', 'commit $n']);
        commits.add(_git(path('origin'), ['rev-parse', 'HEAD']));
      }
      for (final name in ['dav1d', 'libass', 'ffmpeg']) {
        _git(root.path, ['clone', '-q', path('origin'), path('src/$name')]);
      }
      // An archive package: no git data, pinned by its SHA-256 in the recipe
      File(path('src/libiconv/configure')).createSync(recursive: true);
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('checks every package out at its pin and prints the lock lines of what it left', () {
      writeLock({'dav1d': commits[0], 'libass': commits[2]});
      final run = pin('pinned', ['dav1d', 'libass', 'ffmpeg', 'libiconv']);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(_git(path('src/dav1d'), ['rev-parse', 'HEAD']), commits[0]);
      expect(File(path('src/dav1d/file.txt')).readAsStringSync(), '1');
      expect('${run.stdout}'.trim().split('\n'), ['dav1d ${commits[0]}', 'libass ${commits[2]}']);
      expect('${run.stderr}', contains('dav1d: ${commits[2]} -> ${commits[0]}'));
      // FFmpeg is left where the workflow input put it, the archive is not a git package
      expect(_git(path('src/ffmpeg'), ['rev-parse', 'HEAD']), commits[2]);
    });

    test('stops on a git package without a pin and prints the line to add', () {
      writeLock({'dav1d': commits[1]});
      final run = pin('pinned', ['dav1d', 'libass']);
      expect(run.exitCode, 1);
      expect('${run.stderr}', contains('Not pinned'));
      expect('${run.stderr}', contains('libass ${commits[2]}'));
    });

    test('stops on a pin that is not a commit of the repository', () {
      writeLock({'dav1d': 'f' * 40});
      final run = pin('pinned', ['dav1d']);
      expect(run.exitCode, isNot(0));
      expect(_git(path('src/dav1d'), ['rev-parse', 'HEAD']), commits[2]);
    });

    test('heads: moves nothing and prints the lines of the heads, for a review of the lock', () {
      writeLock({'dav1d': commits[0]});
      final run = pin('heads', ['dav1d', 'libass', 'mpv']);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect('${run.stdout}'.trim().split('\n'), ['dav1d ${commits[2]}', 'libass ${commits[2]}']);
      expect(_git(path('src/dav1d'), ['rev-parse', 'HEAD']), commits[2]);
    });

    test('refuses an unknown mode and a missing lock', () {
      writeLock({});
      expect(pin('latest', ['dav1d']).exitCode, 2);
      File(path('sources.lock')).deleteSync();
      expect(pin('pinned', ['dav1d']).exitCode, 2);
    });
  }, skip: _skipScript);
}
