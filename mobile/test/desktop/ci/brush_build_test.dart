// Brush built by our CI for the splat scenes (lot SP2): .github/desktop/ai/brush_build.py and brush.lock.json, run on
// fixtures before the jobs brush-windows and brush-linux depend on them. The script must refuse a binary that still
// holds the LPIPS weights, a graph with rerun, a network client or a window, a help text that moved away from the one
// the runner is frozen by, a patch that touches Cargo.lock and a tag that moved.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

const _script = 'ai/brush_build.py';

String get _aiDir => p.join(ciScriptsDir, 'ai');
String get _lockPath => p.join(_aiDir, 'brush.lock.json');
String get _licences => p.join(repositoryRoot, 'licenses', 'brush');
String get _helpFixture => p.join(repositoryRoot, 'mobile', 'test', 'fixtures', 'ai_immersive', 'brush_help.txt');

Map<String, dynamic> _lock() => jsonDecode(File(_lockPath).readAsStringSync()) as Map<String, dynamic>;

Uint8List _hex(String hex) =>
    Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);

/// Bytes that look like a program and hold none of the probes
Uint8List _filler(int length, int seed) => Uint8List.fromList([for (var i = 0; i < length; i++) (i * 31 + seed) % 251]);

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
    ...arguments,
  ], workingDirectory: dir);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')}: ${result.stderr}');
  }
  return '${result.stdout}'.trim();
}

void main() {
  // Skipped without Python or without the scripts (the Windows mirror of the owner's PC), never because a file of the
  // lot is missing: then the tests fail
  final Object skip = skipCiScripts;

  group('brush.lock.json', () {
    test('pins the tag v0.3.0 at its commit, the toolchain of its CI, the patch and the licence tools', () {
      final lock = _lock();
      final brush = lock['brush'] as Map<String, dynamic>;
      expect(brush['repository'], 'https://github.com/ArthurBrussee/brush');
      expect(brush['tag'], 'v0.3.0');
      expect(brush['commit'], '3edecbb2fe79d3e2c87eeab85b15e0b1dd10d486');
      expect(brush['licence'], 'Apache-2.0');
      expect(lock['id'], matches(RegExp(r'^3edecbb-\d+$')));
      expect(lock['version'], matches(RegExp(r'^0\.3\.0-imm\d+$')));
      expect((lock['rust'] as Map)['toolchain'], '1.89.0');
      final cargo = lock['cargo'] as Map<String, dynamic>;
      expect(cargo['package'], 'brush-app');
      expect(cargo['bin'], 'brush_app');
      expect(cargo['arguments'], contains('--no-default-features'));
      for (final patch in lock['patches'] as List) {
        expect(File(p.join(_licences, 'patches', patch as String)).existsSync(), isTrue, reason: patch);
      }
      final tools = lock['tools'] as Map<String, dynamic>;
      for (final name in ['cargo-deny', 'cargo-about']) {
        for (final system in ['windows-x64', 'linux-x64']) {
          final tool = (tools[name] as Map)[system] as Map;
          expect(tool['url'], startsWith('https://github.com/EmbarkStudios/$name/releases/download/'));
          expect(tool['sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
        }
      }
    });

    test('holds the size, the SHA-256 and five probes of 64 bytes of the LPIPS weights, the first at 0', () {
      final lpips = _lock()['lpips'] as Map<String, dynamic>;
      expect(lpips['path'], 'crates/lpips/burn_mapped.bin');
      expect(lpips['size'], 29433386);
      expect(lpips['sha256'], 'abb257f9aa223154f3ed476674dbfc0b6daee5b2e07618bd208918ee9600e2e7');
      final probes = lpips['probes'] as Map<String, dynamic>;
      expect(probes.keys, hasLength(5));
      expect(probes.keys, contains('0'));
      for (final hex in probes.values) {
        expect(hex, matches(RegExp(r'^[0-9a-f]{128}$')));
      }
    });

    test('lock gives the id, the artifact and the target of a system', () {
      final run = runCiScript(_script, ['lock', '--system', 'windows-x64']);
      expect(run.exitCode, 0, reason: '$run');
      final id = _lock()['id'];
      expect(run.output, contains('artifact=Immuch360-AI-brush-$id-windows-x64.zip'));
      expect(run.output, contains('target=x86_64-pc-windows-msvc'));
      expect(run.output, contains('toolchain=1.89.0'));
      final linux = runCiScript(_script, ['lock', '--system', 'linux-x64']);
      expect(linux.output, contains('artifact=Immuch360-AI-brush-$id-linux-x64.zip'));
      expect(linux.output, contains('target=x86_64-unknown-linux-gnu'));
    });

    test('a lock whose id is not its commit, or without a full commit, is refused', () {
      final lock = _lock();
      for (final (change, message) in [
        ((Map<String, dynamic> l) => l['id'] = '1234567-1', 'does not start with the commit'),
        ((Map<String, dynamic> l) => (l['brush'] as Map)['commit'] = '3edecbb', 'not a full commit'),
        ((Map<String, dynamic> l) => (l['lpips'] as Map)['probes'] = {'0': 'abcd'}, 'probe'),
        ((Map<String, dynamic> l) => (l['tools'] as Map)['cargo-deny'] = {'version': '1'}, 'cargo-deny'),
      ]) {
        final copy = jsonDecode(jsonEncode(lock)) as Map<String, dynamic>;
        change(copy);
        final root = fixtureTree({'brush.lock.json': jsonEncode(copy)});
        addTearDown(() => root.deleteSync(recursive: true));
        final run = runCiScript(_script, [
          '--lock',
          p.join(root.path, 'brush.lock.json'),
          'lock',
          '--system',
          'linux-x64',
        ]);
        expect(run.exitCode, 1, reason: '$run');
        expect(run.output, contains(message));
      }
    });
  }, skip: skip);

  group('lpips', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('immuch360_brush_'));
    tearDown(() => root.deleteSync(recursive: true));

    ScriptRun check(Uint8List bytes) {
      final binary = File(p.join(root.path, 'brush_app.exe'))..writeAsBytesSync(bytes);
      return runCiScript(_script, ['lpips', '--binary', binary.path]);
    }

    test('a program without the weights passes', () {
      final run = check(_filler(1 << 20, 7));
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('none of the 5 probes of the LPIPS weights'));
    });

    test('a program holding the first 64 bytes of the weights, or any probe, is refused', () {
      final probes = (_lock()['lpips'] as Map)['probes'] as Map<String, dynamic>;
      for (final entry in probes.entries) {
        final bytes = BytesBuilder()
          ..add(_filler(4096, 3))
          ..add(_hex(entry.value as String))
          ..add(_filler(4096, 5));
        final run = check(bytes.toBytes());
        expect(run.exitCode, 1, reason: '$run');
        expect(
          run.output,
          contains(
            entry.key == '0' ? 'the first 64 bytes of the LPIPS weights' : 'at ${entry.key} of the LPIPS weights',
          ),
        );
      }
    });
  }, skip: skip);

  group('graph', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('immuch360_brush_'));
    tearDown(() => root.deleteSync(recursive: true));

    const clean = '''
brush-app v0.3.0 (/src/crates/brush-app)
anyhow v1.0.99
brush-cli v0.3.0 (/src/crates/brush-cli)
burn v0.19.0 (https://github.com/tracel-ai/burn#2f5a6fd1)
tokio v1.47.1
tokio v1.47.1 (*)
wgpu v26.0.1 (https://github.com/ArthurBrussee/wgpu?branch=v26#5ad9c6b0)
''';

    ScriptRun graph(String tree) {
      final file = File(p.join(root.path, 'tree.txt'))..writeAsStringSync(tree);
      return runCiScript(_script, ['graph', '--system', 'windows-x64', '--tree', file.path]);
    }

    test('a graph without rerun, network client, window or LPIPS passes, each crate counted once', () {
      final run = graph(clean);
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('6 crates'));
    });

    test('rerun, an HTTP client, the viewer, a file dialog or the LPIPS crate are refused by name', () {
      for (final line in [
        'rerun v0.24.1',
        're_grpc_client v0.24.1',
        'reqwest v0.12.23',
        'hyper v1.7.0',
        'ureq v2.12.1',
        'egui v0.32.3 (https://github.com/emilk/egui?rev=refs%2Fpull%2F7540%2Fhead#eb6e93d4)',
        'epaint_default_fonts v0.32.3',
        'winit v0.30.12',
        'rfd v0.15.4',
        'lpips v0.3.0 (/src/crates/lpips)',
      ]) {
        final run = graph('$clean$line\n');
        expect(run.exitCode, 1, reason: '$line: $run');
        expect(run.output, contains(line.split(' ').first));
      }
    });

    test('every crate deny.toml bans is refused by the graph check too', () {
      final deny = File(p.join(_licences, 'deny.toml')).readAsStringSync();
      final banned = RegExp(r'\{ name = "([\w-]+)"').allMatches(deny).map((match) => match.group(1)!).toList();
      expect(banned, containsAll(['lpips', 'rerun', 'reqwest', 'hyper', 'egui', 'eframe', 'winit']));
      for (final name in banned) {
        final run = graph('$clean$name v1.0.0\n');
        expect(run.exitCode, 1, reason: '$name: $run');
      }
    });
  }, skip: skip);

  group('the licence lists', () {
    List<String> listed(String file, String key) {
      final text = File(p.join(_licences, file)).readAsStringSync();
      final block = RegExp('^$key = \\[(.*?)\\]', multiLine: true, dotAll: true).firstMatch(text)!.group(1)!;
      return RegExp(r'"([^"]+)"').allMatches(block).map((match) => match.group(1)!).toList();
    }

    test('cargo deny and cargo about allow the same permissive licences, no copyleft, no font licence', () {
      final deny = listed('deny.toml', 'allow');
      final about = listed('about.toml', 'accepted');
      expect(deny.toSet(), about.toSet());
      expect(deny, containsAll(['Apache-2.0', 'MIT', 'BSD-3-Clause', 'Zlib']));
      for (final licence in deny) {
        expect(licence, isNot(matches(RegExp(r'GPL|OFL|Ubuntu|UFL|CDLA|bzip2|CC-BY|OpenSSL'))), reason: licence);
      }
      final text = File(p.join(_licences, 'deny.toml')).readAsStringSync();
      expect(text, isNot(contains('[[licenses.clarify]]')));
      expect(text, contains('unknown-git = "deny"'));
    });
  }, skip: skip);

  group('the patch', () {
    test('touches the manifests and sources of Brush only, never Cargo.lock, and marks each file it changes', () {
      for (final name in _lock()['patches'] as List) {
        final patch = File(p.join(_licences, 'patches', name as String)).readAsStringSync();
        final files = RegExp(r'^diff --git a/(\S+) b/', multiLine: true).allMatches(patch).map((m) => m.group(1)!);
        expect(files, isNotEmpty);
        for (final file in files) {
          expect(file, matches(RegExp(r'^crates/[\w-]+/(Cargo\.toml|src/[\w/]+\.rs)$')), reason: file);
          final section = patch.substring(patch.indexOf('diff --git a/$file '));
          expect(
            section,
            contains('+${file.endsWith('.rs') ? '//' : '#'} Modified for Immuch360 Desktop'),
            reason: file,
          );
        }
        expect(patch, isNot(contains('diff --git a/Cargo.lock')));
        expect(patch, isNot(contains('GIT binary patch')));
      }
    });
  }, skip: skip);

  group('help', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('immuch360_brush_'));
    tearDown(() => root.deleteSync(recursive: true));

    ScriptRun help(String text, {String version = 'brush-cli 0.3.0\n'}) {
      final output = File(p.join(root.path, 'help.txt'))..writeAsStringSync(text);
      final versionOutput = File(p.join(root.path, 'version.txt'))..writeAsStringSync(version);
      return runCiScript(_script, ['help', '--output', output.path, '--version-output', versionOutput.path]);
    }

    test('the help of Windows, with its .exe and CRLF, is the fixture the runner is frozen by', () {
      // The checkout of a Windows runner may have made the fixture CRLF already
      final fixture = File(_helpFixture).readAsStringSync().replaceAll('\r\n', '\n');
      expect(fixture, contains('Usage: brush_app [OPTIONS] [PATH_OR_URL]'));
      expect(fixture, contains('--max-splats <MAX_SPLATS>'));
      final windows = fixture.replaceFirst('Usage: brush_app ', 'Usage: brush_app.exe ').replaceAll('\n', '\r\n');
      final run = help(windows, version: 'brush-cli 0.3.0\r\n');
      expect(run.exitCode, 0, reason: '$run');
    });

    test('a renamed option or another version is refused', () {
      final fixture = File(_helpFixture).readAsStringSync();
      final renamed = help(fixture.replaceFirst('--total-steps <TOTAL_STEPS>', '--total-train-iters <ITERS>'));
      expect(renamed.exitCode, 1, reason: '$renamed');
      expect(renamed.output, contains('--total-train-iters'));
      final other = help(fixture, version: 'brush-cli 0.4.0\n');
      expect(other.exitCode, 1, reason: '$other');
      expect(other.output, contains('brush-cli 0.4.0'));
    });
  }, skip: skip);

  group('sources', () {
    late Directory root;
    late String commit;
    late Map<String, dynamic> lock;
    String path(String relative) => p.joinAll([root.path, ...relative.split('/')]);
    final weights = Uint8List.fromList([for (var i = 0; i < 9000; i++) (i * 7 + i ~/ 256) % 256]);
    const licence = 'Apache License, a fixture\n';

    String sha(List<int> bytes) => '${sha256.convert(bytes)}';

    setUp(() {
      root = Directory.systemTemp.createTempSync('immuch360_brush_src_');
      writeFiles(Directory(path('origin')), {
        'LICENSE': licence,
        'Cargo.lock': '# a fixture lock\n',
        'crates/brush-app/src/bin.rs': 'fn main() {}\n',
      });
      File(path('origin/crates/lpips/burn_mapped.bin'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(weights);
      _git(path('origin'), ['init', '-q']);
      _git(path('origin'), ['add', '-A']);
      _git(path('origin'), ['commit', '-q', '-m', 'v0.3.0']);
      _git(path('origin'), ['tag', 'v0.3.0']);
      commit = _git(path('origin'), ['rev-parse', 'HEAD']);
      writeFiles(Directory(path('patches')), {
        '0001-fixture.patch':
            'A fixture patch\n\n'
            'diff --git a/crates/brush-app/src/bin.rs b/crates/brush-app/src/bin.rs\n'
            '--- a/crates/brush-app/src/bin.rs\n'
            '+++ b/crates/brush-app/src/bin.rs\n'
            '@@ -1 +1,2 @@\n'
            '+// Modified for Immuch360 Desktop\n'
            ' fn main() {}\n',
        '0002-lock.patch':
            'diff --git a/Cargo.lock b/Cargo.lock\n'
            '--- a/Cargo.lock\n'
            '+++ b/Cargo.lock\n'
            '@@ -1 +1,2 @@\n'
            ' # a fixture lock\n'
            '+# changed\n',
      });
      lock = jsonDecode(File(_lockPath).readAsStringSync()) as Map<String, dynamic>;
      lock['id'] = '${commit.substring(0, 7)}-1';
      lock['brush'] = {
        ...(lock['brush'] as Map<String, dynamic>),
        'repository': Uri.directory(path('origin')).toString(),
        'commit': commit,
        'licenceSha256': sha(utf8.encode(licence)),
        'cargoLockSha256': sha(utf8.encode('# a fixture lock\n')),
      };
      lock['lpips'] = {
        'path': 'crates/lpips/burn_mapped.bin',
        'size': weights.length,
        'sha256': sha(weights),
        'probes': {
          for (final at in [0, 4096])
            '$at': [for (final b in weights.sublist(at, at + 64)) b.toRadixString(16).padLeft(2, '0')].join(),
        },
      };
      lock['patches'] = ['0001-fixture.patch'];
    });
    tearDown(() => root.deleteSync(recursive: true));

    ScriptRun sources() {
      File(path('brush.lock.json')).writeAsStringSync(jsonEncode(lock));
      return runCiScript(_script, [
        '--lock',
        path('brush.lock.json'),
        'sources',
        '--dir',
        path('src'),
        '--patches',
        path('patches'),
        '--weights-out',
        path('weights.bin'),
      ]);
    }

    test('the commit of the tag, patched, its LPIPS weights moved out of the tree and checked', () {
      final run = sources();
      expect(run.exitCode, 0, reason: '$run');
      expect(File(path('src/crates/brush-app/src/bin.rs')).readAsStringSync(), contains('Modified for Immuch360'));
      expect(File(path('src/crates/lpips/burn_mapped.bin')).existsSync(), isFalse);
      expect(File(path('weights.bin')).readAsBytesSync(), weights);
      expect(File(path('src/Cargo.lock')).readAsStringSync(), '# a fixture lock\n');
    });

    test('a patch that changes Cargo.lock is refused', () {
      lock['patches'] = ['0001-fixture.patch', '0002-lock.patch'];
      final run = sources();
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('Cargo.lock'));
    });

    test('a tag that moved, other weights or another licence are refused', () {
      _git(path('origin'), ['commit', '-q', '--allow-empty', '-m', 'later']);
      _git(path('origin'), ['tag', '-f', 'v0.3.0']);
      final moved = sources();
      expect(moved.exitCode, 1, reason: '$moved');
      expect(moved.output, contains('v0.3.0'));
      _git(path('origin'), ['tag', '-f', 'v0.3.0', commit]);

      (lock['lpips'] as Map)['sha256'] = '0' * 64;
      final weightsRun = sources();
      expect(weightsRun.exitCode, 1, reason: '$weightsRun');
      expect(weightsRun.output, contains('LPIPS weights'));
      (lock['lpips'] as Map)['sha256'] = sha(weights);

      (lock['brush'] as Map)['licenceSha256'] = '1' * 64;
      final licenceRun = sources();
      expect(licenceRun.exitCode, 1, reason: '$licenceRun');
      expect(licenceRun.output, contains('LICENSE'));
    });
  }, skip: skip != false ? skip : (_runs('git', ['--version']) ? false : 'needs git'));

  group('pack', () {
    late Directory root;
    String path(String relative) => p.joinAll([root.path, ...relative.split('/')]);

    setUp(() {
      root = Directory.systemTemp.createTempSync('immuch360_brush_pack_');
      writeFiles(root, {
        'source/LICENSE': File(p.join(_licences, 'brush-LICENSE.txt')).readAsStringSync(),
        'THIRD-PARTY.md': '# The code built into Brush\n',
      });
      Directory(path('crt')).createSync();
      Directory(path('system')).createSync();
      File(path('crt/VCRUNTIME140.dll')).writeAsBytesSync(fakePe(imports: ['KERNEL32.dll']));
      File(path('system/kernel32.dll')).writeAsBytesSync([0]);
    });
    tearDown(() => root.deleteSync(recursive: true));

    ScriptRun pack(Uint8List program, {String out = 'dist'}) {
      File(path('brush_app.exe')).writeAsBytesSync(program);
      return runCiScript(_script, [
        'pack',
        '--system',
        'windows-x64',
        '--source',
        path('source'),
        '--bin',
        path('brush_app.exe'),
        '--third-party',
        path('THIRD-PARTY.md'),
        '--out',
        path(out),
        '--crt-dir',
        path('crt'),
        '--system-dir',
        path('system'),
      ]);
    }

    Uint8List program() => fakePe(imports: ['KERNEL32.dll', 'VCRUNTIME140.dll', 'api-ms-win-crt-runtime-l1-1-0.dll']);

    test('the Windows archive: the program, the runtime it imports, the licences, the patch and BUILD-INFO.txt', () {
      final run = pack(program());
      expect(run.exitCode, 0, reason: '$run');
      final id = _lock()['id'];
      final archive = File(path('dist/Immuch360-AI-brush-$id-windows-x64.zip'));
      expect(archive.existsSync(), isTrue, reason: '$run');
      for (final name in [
        'brush_app.exe',
        'VCRUNTIME140.dll',
        'BUILD-INFO.txt',
        'licenses/README.md',
        'licenses/brush-LICENSE.txt',
        'licenses/THIRD-PARTY.md',
        'licenses/patches/0001-immuch360-headless-trainer.patch',
      ]) {
        expect(run.output, contains(name));
      }
      expect(run.output, isNot(contains('deny.toml')));

      // The patch as in the repository, LF, even from a checkout that made it CRLF (Windows runners)
      final patch = File(p.join(_licences, 'patches', '0001-immuch360-headless-trainer.patch')).readAsStringSync();
      final lf = sha256.convert(utf8.encode(patch.replaceAll('\r\n', '\n')));
      expect(run.output, contains('$lf  licenses/patches/0001-immuch360-headless-trainer.patch'));

      // The same files give the same bytes
      final again = pack(program(), out: 'again');
      expect(again.exitCode, 0, reason: '$again');
      expect(File(path('again/Immuch360-AI-brush-$id-windows-x64.zip')).readAsBytesSync(), archive.readAsBytesSync());
    });

    test('a program that still holds the LPIPS weights, or sources under another licence, is not packed', () {
      final head = _hex(((_lock()['lpips'] as Map)['probes'] as Map)['0'] as String);
      final run = pack(Uint8List.fromList([...program(), ...head]));
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('LPIPS'));

      File(path('source/LICENSE')).writeAsStringSync('another licence\n');
      final licence = pack(program());
      expect(licence.exitCode, 1, reason: '$licence');
      expect(licence.output, contains('brush-LICENSE.txt'));
    });
  }, skip: skip);
}
