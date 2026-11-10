// .github/desktop/upstream_dry_merge.py: the weekly dry merge of upstream Immich (plan 23 section 4), run on a fixture
// repository whose two sides conflict in one file of each kind the heuristic tells apart.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

const _script = 'upstream_dry_merge.py';

final Object _skip = skipCiScripts != false
    ? skipCiScripts
    : !_runs('git', ['--version'])
    ? 'needs git'
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
    '-c',
    'tag.gpgsign=false',
    '-c',
    'core.autocrlf=false',
    ...arguments,
  ], workingDirectory: dir);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')}: ${result.stderr}');
  }
  return '${result.stdout}'.trim();
}

/// Writes [files] in [root] (null deletes), then commits all with [message]
void _commit(Directory root, String message, Map<String, String?> files) {
  for (final entry in files.entries) {
    final file = File(p.joinAll([root.path, ...entry.key.split('/')]));
    if (entry.value == null) {
      file.deleteSync();
    } else {
      file
        ..createSync(recursive: true)
        ..writeAsStringSync(entry.value!);
    }
  }
  _git(root.path, ['add', '-A']);
  _git(root.path, ['commit', '-q', '-m', message]);
}

const _lines = 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n';

/// The fork point, then upstream: a fix (tag v1.2.0), the commit that conflicts with ours (tag v1.10.0), a server fix,
/// a late mobile fix (tag v1.11.0-rc.0, upstream/main). Ours (checked out): the same changes its own way, the first fix
/// picked, and a v9.9.9 tag of the fork's own.
Directory _repository() {
  final root = Directory.systemTemp.createTempSync('immuch360_dry_merge_');
  _git(root.path, ['init', '-q']);
  _commit(root, 'base', {
    'i18n/en.json': '{\n  "a": "A",\n  "z": "Z"\n}\n',
    'mobile/lib/a.dart': 'int value() {\n  return 0;\n}\n',
    'mobile/lib/b.dart': "import 'x.dart';\n\nvoid b() {}\n",
    'mobile/lib/c.dart': 'void c() {\n  one();\n}\n',
    'mobile/lib/gone.dart': 'void gone() {}\n',
    'mobile/lib/clean.dart': _lines,
    'README.md': '# Fixture\n',
  });
  final base = _git(root.path, ['rev-parse', 'HEAD']);

  _git(root.path, ['checkout', '-q', '-b', 'upstream']);
  _commit(root, 'fix(mobile): pick me (#1)', {'mobile/lib/pick.dart': 'void pick() {}\n'});
  final pick = _git(root.path, ['rev-parse', 'HEAD']);
  _git(root.path, ['update-ref', 'refs/upstream-tags/v1.2.0', pick]);
  _commit(root, 'feat(mobile): the other side (#2)', {
    'i18n/en.json': '{\n  "a": "A",\n  "b": "B",\n  "z": "Z"\n}\n',
    'mobile/lib/a.dart': 'int value() {\n  return 2;\n}\n',
    'mobile/lib/b.dart': "import 'y.dart';\n\nvoid b() {}\n",
    'mobile/lib/c.dart': 'void c() {\n  one();\n  two();\n}\n',
    'mobile/lib/gone.dart': 'void gone() {\n  print(1);\n}\n',
    'mobile/lib/clean.dart': _lines.replaceFirst('one', 'ONE'),
  });
  _git(root.path, ['update-ref', 'refs/upstream-tags/v1.10.0', 'HEAD']);
  _commit(root, 'fix(server): server only (#3)', {'server/x.ts': 'export const x = 1;\n'});
  _commit(root, 'fix(mobile): late fix (#4)', {'mobile/lib/late.dart': 'void late() {}\n'});
  _git(root.path, ['update-ref', 'refs/upstream-tags/v1.11.0-rc.0', 'HEAD']);
  _git(root.path, ['update-ref', 'refs/remotes/upstream/main', 'HEAD']);

  _git(root.path, ['checkout', '-q', '-b', 'ours', base]);
  _commit(root, 'ours', {
    'i18n/en.json': '{\n  "a": "A",\n  "c": "C",\n  "z": "Z"\n}\n',
    'mobile/lib/a.dart': 'int value() {\n  return 1;\n}\n',
    'mobile/lib/b.dart': "import 'z.dart';\n\nvoid b() {}\n",
    'mobile/lib/c.dart': 'void c() {\n  one();\n  three();\n}\n',
    'mobile/lib/gone.dart': null,
    'mobile/lib/clean.dart': _lines.replaceFirst('ten', 'TEN'),
  });
  _git(root.path, ['cherry-pick', pick]);
  _git(root.path, ['tag', 'v9.9.9']);
  _git(root.path, ['branch', '-D', 'upstream']);
  return root;
}

void main() {
  late Directory root;

  setUp(() => root = _repository());

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  ScriptRun dryMerge(List<String> extra) =>
      runCiScript(_script, ['--repo', root.path, '--ours', 'ours', '--main', 'upstream/main', ...extra]);

  group('upstream_dry_merge.py', () {
    test('counts the conflicts and tells the semantic files from the mechanical ones', () {
      final report = p.join(root.path, '..', '${p.basename(root.path)}-report.md');
      addTearDown(() => File(report).existsSync() ? File(report).deleteSync() : null);
      final run = dryMerge(['--report', report]);
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('main upstream/main'));
      expect(
        run.output,
        contains('4 commits behind, 5 files in conflict, 4 hunks, 8 lines, 2 semantic, 2 mobile fixes'),
      );
      // The newest release tag by its numbers, not by its text, and neither the rc nor the fork's own v9.9.9
      expect(run.output, contains('release v1.10.0'));
      expect(
        run.output,
        contains('2 commits behind, 5 files in conflict, 4 hunks, 8 lines, 2 semantic, 1 mobile fixes'),
      );

      final text = File(report).readAsStringSync();
      expect(text, contains('| Commits behind (in mobile/) | 4 (3) | 2 (2) |'));
      expect(text, contains('| Semantic files (hunks) | 2 (1) | 2 (1) |'));
      expect(text, contains('| Upstream mobile fixes (already in ours) | 2 (1) | 1 (1) |'));
      expect(text, contains('| Both sides changed, merged cleanly (in mobile/) | 1 (1) | 1 (1) |'));
      expect(text, contains('| i18n | 1 | 1 | 2 |'));
      expect(text, contains('| mobile | 4 | 3 | 6 |'));
      expect(text, contains('| lib | 4 | 3 | 6 |'));
      expect(text, contains('| `mobile/lib/a.dart` | semantic | source | 1 | 1 | 1 | rewrite |'));
      expect(text, contains('| `mobile/lib/gone.dart` | semantic | source | 0 | 0 | 0 | modify/delete |'));
      expect(text, contains('| `mobile/lib/b.dart` | mechanical | source | 1 | 1 | 1 | imports |'));
      expect(text, contains('| `mobile/lib/c.dart` | mechanical | source | 1 | 1 | 1 | union |'));
      expect(text, contains('- `mobile/lib/c.dart`: union'));
      expect(text, contains('| `i18n/en.json` | 1 | 1 | 1 |'));
      expect(text, contains('- `mobile/lib/clean.dart`'));
      expect(text, contains('fix(mobile): pick me (#1) | yes |'));
      expect(text, contains('fix(mobile): late fix (#4) |  |'));
      expect(text, isNot(contains('server only')));
      expect(text, contains('#### Upstream sync checklist for Immuch360 Desktop'));
    });

    test('writes nothing to the repository', () {
      List<String> state() => [
        _git(root.path, ['for-each-ref']),
        _git(root.path, ['count-objects', '-v']),
        _git(root.path, ['status', '--porcelain']),
      ];
      final before = state();
      final run = dryMerge([]);
      expect(run.exitCode, 0, reason: '$run');
      expect(state(), before);
    });

    test('appends the report to the run summary and writes the numbers', () {
      final summary = File(p.join(root.path, '..', '${p.basename(root.path)}-summary.md'))
        ..writeAsStringSync('# Before\n');
      final numbers = File(p.join(root.path, '..', '${p.basename(root.path)}.json'));
      addTearDown(() {
        for (final file in [summary, numbers]) {
          if (file.existsSync()) {
            file.deleteSync();
          }
        }
      });
      final run = dryMerge(['--summary', summary.path, '--json', numbers.path]);
      expect(run.exitCode, 0, reason: '$run');
      expect(summary.readAsStringSync(), startsWith('# Before\n# Upstream dry merge of '));
      final json = jsonDecode(numbers.readAsStringSync()) as Map<String, dynamic>;
      final targets = (json['targets'] as List).cast<Map<String, dynamic>>();
      expect(targets.map((t) => t['ref']), ['upstream/main', 'v1.10.0']);
      expect((targets.first['conflicts'] as List).length, 5);
      expect((targets.first['fixes'] as List).map((f) => f['in_ours']), [false, true]);
    });

    test('a missing ref or no release tag is an error of the run, not a report', () {
      final missing = runCiScript(_script, ['--repo', root.path, '--ours', 'ours', '--main', 'upstream/nothing']);
      expect(missing.exitCode, 2, reason: '$missing');
      expect(missing.output, contains('upstream/nothing is not a commit of the clone'));
      final untagged = dryMerge(['--tags', 'refs/none/']);
      expect(untagged.exitCode, 2, reason: '$untagged');
      expect(untagged.output, contains('no release tag vX.Y.Z under refs/none/'));
    });

    test('its doctests pass', () {
      final command = python!;
      final result = Process.runSync(
        command.first,
        [...command.skip(1), '-B', '-m', 'doctest', p.join(ciScriptsDir, _script)],
        environment: {'PYTHONIOENCODING': 'utf-8'},
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    });
  }, skip: _skip);
}
