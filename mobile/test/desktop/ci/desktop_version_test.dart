import 'package:flutter_test/flutter_test.dart';

import 'ci_scripts.dart';

/// The key=value lines of desktop_version.py
Map<String, String> _values(ScriptRun run) => {
  for (final line in run.output.split('\n'))
    if (line.contains('=') && !line.startsWith('warning')) line.split('=').first.trim(): line.split('=').last.trim(),
};

ScriptRun _version(String pubspec, List<String> tags, {String? exactTag, String commit = 'abc1234'}) =>
    runCiScript('desktop_version.py', [
      '--pubspec-version',
      pubspec,
      '--tags',
      tags.join(','),
      if (exactTag != null) ...['--exact-tag', exactTag],
      '--commit',
      commit,
    ]);

void main() {
  group('desktop_version.py', () {
    const tags = ['v3.2.4', 'v3.3.0-rc.0', 'v3.3.0-rc.0-9', 'v3.3.0-rc.0-19', 'v3.3.0-rc.0-20'];

    test('a commit after a release takes its fork build, and the commit in the label', () {
      final run = _version('3.3.0-rc.0+3030018', tags);
      expect(run.exitCode, 0, reason: '$run');
      expect(_values(run), {
        'build_name': '3.3.0-rc.0',
        'build_number': '20',
        'file_version': '3.3.0.20',
        'label': '3.3.0-rc.0-20-abc1234',
        'msix_version': '3.3.20.0',
      });
    });

    test('a release tag gives its own build and a label without the commit', () {
      final run = _version('3.3.0-rc.0+3030019', tags, exactTag: 'v3.3.0-rc.0-21');
      expect(run.exitCode, 0, reason: '$run');
      expect(_values(run)['build_number'], '21');
      expect(_values(run)['label'], '3.3.0-rc.0-21');
    });

    test('upstream tags never count as fork builds', () {
      final run = _version('3.4.0+3040000', ['v3.2.4', 'v3.3.0-rc.0', 'v3.4.0']);
      expect(run.exitCode, 0, reason: '$run');
      expect(_values(run)['build_number'], '0');
      expect(run.output, contains('warning: no fork build tag'));
    });

    test('the Store version keeps its numbers under 65536, else stays empty', () {
      expect(_values(_version('3.4.2+1', ['v3.4.2-7']))['msix_version'], '3.4.2007.0');
      expect(_values(_version('3.66.0+1', ['v3.66.0-7']))['msix_version'], '3.66.7.0');
      expect(_values(_version('3.3.66+1', ['v3.3.66-600']))['msix_version'], isEmpty);
    });

    test('refuses a build number that a Windows version cannot hold', () {
      final run = _version('3.3.0+1', ['v3.3.0-70000']);
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('does not fit a Windows version number'));
    });

    test('refuses a version or a commit that could reach a command line', () {
      expect(_version(r'3.3.0$(id)+1', tags).exitCode, 1);
      expect(_version('3.3.0 ; id+1', tags).exitCode, 1);
      expect(_version('3.3.0+1', tags, commit: 'abc;id').exitCode, 1);
    });
  }, skip: skipCiScripts);
}
