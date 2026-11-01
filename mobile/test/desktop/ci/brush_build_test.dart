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

/// A 64 bit little endian ELF file reduced to what the ELF reader of sdcpp_build.py reads: the section headers, a
/// string table and a dynamic section that asks for the libraries [needed]
Uint8List _fakeElf(List<String> needed) {
  final strings = BytesBuilder()..addByte(0);
  final names = <int>[];
  for (final name in needed) {
    names.add(strings.length);
    strings
      ..add(utf8.encode(name))
      ..addByte(0);
  }
  final table = strings.toBytes();
  const dynamicAt = 64;
  final dynamicSize = (needed.length + 1) * 16;
  final stringsAt = dynamicAt + dynamicSize;
  final sectionsAt = (stringsAt + table.length + 7) & ~7;
  final data = ByteData(sectionsAt + 3 * 64);
  for (final (at, byte) in [(0, 0x7F), (1, 0x45), (2, 0x4C), (3, 0x46), (4, 2), (5, 1), (6, 1)]) {
    data.setUint8(at, byte);
  }
  data
    ..setUint16(0x10, 3, Endian.little)
    ..setUint16(0x12, 0x3E, Endian.little)
    ..setUint64(0x28, sectionsAt, Endian.little)
    ..setUint16(0x3A, 64, Endian.little)
    ..setUint16(0x3C, 3, Endian.little);
  for (var i = 0; i < needed.length; i++) {
    data
      ..setInt64(dynamicAt + i * 16, 1, Endian.little)
      ..setUint64(dynamicAt + i * 16 + 8, names[i], Endian.little);
  }
  for (var i = 0; i < table.length; i++) {
    data.setUint8(stringsAt + i, table[i]);
  }
  // Section 1, the strings (SHT_STRTAB); section 2, the dynamic section (SHT_DYNAMIC) linked to them
  data
    ..setUint32(sectionsAt + 64 + 4, 3, Endian.little)
    ..setUint64(sectionsAt + 64 + 24, stringsAt, Endian.little)
    ..setUint64(sectionsAt + 64 + 32, table.length, Endian.little)
    ..setUint32(sectionsAt + 128 + 4, 6, Endian.little)
    ..setUint64(sectionsAt + 128 + 24, dynamicAt, Endian.little)
    ..setUint64(sectionsAt + 128 + 32, dynamicSize, Endian.little)
    ..setUint32(sectionsAt + 128 + 40, 1, Endian.little)
    ..setUint64(sectionsAt + 128 + 56, 16, Endian.little);
  return data.buffer.asUint8List();
}

/// The interpreter of the Python that runs the scripts, by its full path
String get _pythonExecutable {
  final command = python!;
  final result = Process.runSync(command.first, [...command.skip(1), '-c', 'import sys; print(sys.executable)']);
  return '${result.stdout}'.trim();
}

/// A command [name] in [bin] that runs the Python [script] with its arguments, found on the PATH as cargo would be:
/// an executable file on Linux and macOS, a .cmd on Windows. Returns its path.
String _fakeCommand(Directory bin, String name, String script) {
  if (Platform.isWindows) {
    final source = File(p.join(bin.path, '$name.py'))..writeAsStringSync(script);
    final command = File(p.join(bin.path, '$name.cmd'))
      ..writeAsStringSync('@"$_pythonExecutable" "${source.path}" %*\r\n');
    return command.path;
  }
  final file = File(p.join(bin.path, name))..writeAsStringSync('#!$_pythonExecutable\n$script');
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

/// The variables that put [bin] first on the PATH, under the name the system gives it (Path on Windows)
Map<String, String> _pathFirst(Directory bin) {
  final key = Platform.environment.keys.firstWhere((name) => name.toUpperCase() == 'PATH', orElse: () => 'PATH');
  return {key: '${bin.path}${Platform.isWindows ? ';' : ':'}${Platform.environment[key] ?? ''}'};
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

    test('EXTRA-NOTICES.md: each text is the licence file of its SHA-256, with the copyright line of its crate', () {
      final text = File(p.join(_licences, 'EXTRA-NOTICES.md')).readAsStringSync().replaceAll('\r\n', '\n');
      final entries = RegExp(
        r'^## (\S+ \S+)\n\n[^\n]* at ([0-9a-f]{40}), file `[^`]+`, SHA-256 ([0-9a-f]{64})\n\n````text\n(.*?\n)````$',
        multiLine: true,
        dotAll: true,
      ).allMatches(text).toList();
      expect(entries.map((entry) => entry.group(1)), [
        'ball-tree 0.5.1',
        'number_prefix 0.4.0',
        'tokio_with_wasm 0.8.7',
        'tokio_with_wasm_proc 0.8.7',
      ]);
      for (final entry in entries) {
        final licence = entry.group(4)!;
        expect('${sha256.convert(utf8.encode(licence))}', entry.group(3), reason: entry.group(1));
        expect(licence, startsWith('MIT License\n\nCopyright (c) 20'), reason: entry.group(1));
        expect(licence, isNot(contains('<year>')), reason: entry.group(1));
      }
    });

    test('cargo about takes the licence of libm from its LICENSE.txt, with the notices of musl and of its sources', () {
      final about = File(p.join(_licences, 'about.toml')).readAsStringSync();
      expect(about, contains('[libm.clarify]'));
      expect(about, contains('path = "LICENSE.txt"'));
      expect(about, contains('checksum = "3823dda7cf046602f4b4e77ec8e227863dc4736037cc85bb33d9f19febe16bb7"'));
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

    test('a LPIPS weight above 0 is refused by brush_app right after its arguments, before any card is used', () {
      final patch = File(
        p.join(_licences, 'patches', '0001-immuch360-headless-trainer.patch'),
      ).readAsStringSync().replaceAll('\r\n', '\n');
      String section(String file) {
        final start = patch.indexOf('diff --git a/$file ');
        final end = patch.indexOf('diff --git a/', start + 1);
        return patch.substring(start, end < 0 ? patch.length : end);
      }

      expect(section('crates/brush-app/Cargo.toml'), contains('+lpips = ["brush-train/lpips"]'));
      final bin = section('crates/brush-app/src/bin.rs');
      const refusal = 'anyhow::bail!("this build of Brush has no LPIPS weights: --lpips-loss-weight must stay 0");';
      expect(
        bin,
        contains('+    #[cfg(not(feature = "lpips"))]\n+    if args.process.train_config.lpips_loss_weight > 0.0 {'),
      );
      expect(bin, contains('+        $refusal'));
      expect(bin.indexOf(refusal), lessThan(bin.indexOf('burn_init_setup')));
      // The trainer keeps its own guard
      expect(section('crates/brush-train/src/train.rs'), contains('+            config.lpips_loss_weight <= 0.0,'));
      // And the texts say what the program does
      expect(patch, isNot(contains('refused at the start')));
      expect(patch, contains('refused by brush_app before it reads the data'));
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

  // What our build of Brush says on the Intel UHD of the owner's PC (lot SP2, 01/11/2026), for the gate and the runner
  // (lots SP4 and SP6): it trains there when the autotune cache of cubecl (target/autotune under its working folder,
  // keyed by "default device", not by card) is its own, and fails at its first kernel with the cache the NVIDIA card
  // left in the same folder, as the official v0.3.0 did in the measurement of that morning
  group('the outputs of brush_app on an integrated card', () {
    String fixture(String name) =>
        File(p.join(repositoryRoot, 'mobile', 'test', 'fixtures', 'ai_immersive', name)).readAsStringSync();

    test('with the cache of the NVIDIA card: the adapter, then the plane instructions panic', () {
      final stdout = fixture('brush_igpu_plane_failure_stdout.txt');
      final stderr = fixture('brush_igpu_plane_failure_stderr.txt');
      expect(stdout, contains('Using adapter AdapterInfo { name: "Intel(R) RaptorLake-S Mobile Graphics Controller"'));
      expect(stdout, contains('device_type: IntegratedGpu'));
      expect(stdout, isNot(contains('Refine iter')));
      expect(stderr, contains('Should run when selected by autotune.'));
      expect(
        stderr,
        contains(
          'Trying to launch a kernel using plane instructions, but the min and max plane dimensions are different.',
        ),
      );
    });

    test('with its own cache: 1,000 steps trained and evaluated', () {
      final stdout = fixture('brush_igpu_fresh_cache_stdout.txt');
      expect(stdout, contains('device_type: IntegratedGpu'));
      expect(stdout, contains('Refine iter 801, '));
      expect(stdout, contains('Eval iter 1000: PSNR '));
      expect(stdout, contains('Done training! Took FormattedDuration('));
    });
  });

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

    test('an empty folder, or the checkout of an earlier run, is used again', () {
      Directory(path('src')).createSync();
      final first = sources();
      expect(first.exitCode, 0, reason: '$first');
      final again = sources();
      expect(again.exitCode, 0, reason: '$again');
      expect(File(path('src/crates/brush-app/src/bin.rs')).readAsStringSync(), contains('Modified for Immuch360'));
    });

    test('a folder that is not a checkout of Brush made by this script is never removed (--dir . or ~ by mistake)', () {
      writeFiles(Directory(path('src')), {'notes.txt': 'keep me\n'});
      final mine = sources();
      expect(mine.exitCode, 1, reason: '$mine');
      expect(mine.output, contains('not a checkout of Brush'));
      expect(File(path('src/notes.txt')).readAsStringSync(), 'keep me\n');

      // Another repository, even with files of the same names, is not one either
      File(path('src/notes.txt')).deleteSync();
      writeFiles(Directory(path('src')), {'LICENSE': licence, 'Cargo.lock': '# a fixture lock\n'});
      _git(path('src'), ['init', '-q']);
      _git(path('src'), ['add', '-A']);
      _git(path('src'), ['commit', '-q', '-m', 'another project']);
      final other = sources();
      expect(other.exitCode, 1, reason: '$other');
      expect(File(path('src/LICENSE')).existsSync(), isTrue);
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
        'licenses/EXTRA-NOTICES.md',
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

    test(
      'the Linux archive: brush_app and immuch360-run, which need only the base of a distribution, and the licences',
      () {
        ScriptRun linux(List<String> needed) {
          File(path('brush_app')).writeAsBytesSync([..._fakeElf(needed), ..._filler(4096, 9)]);
          File(path('immuch360-run')).writeAsBytesSync(_fakeElf(['libc.so.6']));
          return runCiScript(_script, [
            'pack',
            '--system',
            'linux-x64',
            '--source',
            path('source'),
            '--bin',
            path('brush_app'),
            '--third-party',
            path('THIRD-PARTY.md'),
            '--launcher',
            path('immuch360-run'),
            '--out',
            path('linux'),
          ]);
        }

        final run = linux(['libgcc_s.so.1', 'libm.so.6', 'libc.so.6', 'ld-linux-x86-64.so.2']);
        expect(run.exitCode, 0, reason: '$run');
        final id = _lock()['id'];
        expect(File(path('linux/Immuch360-AI-brush-$id-linux-x64.zip')).existsSync(), isTrue, reason: '$run');
        expect(run.output, contains('brush_app imports: libgcc_s.so.1, libm.so.6, libc.so.6, ld-linux-x86-64.so.2'));
        for (final name in [
          'brush_app  (program)',
          'immuch360-run  (program)',
          'BUILD-INFO.txt',
          'licenses/README.md',
          'licenses/brush-LICENSE.txt',
          'licenses/EXTRA-NOTICES.md',
          'licenses/THIRD-PARTY.md',
          'licenses/patches/0001-immuch360-headless-trainer.patch',
        ]) {
          expect(run.output, contains(name));
        }
        expect(run.output, isNot(contains('.dll')));

        final torch = linux(['libc.so.6', 'libtorch_cpu.so']);
        expect(torch.exitCode, 1, reason: '$torch');
        expect(
          torch.output,
          contains('brush_app needs libtorch_cpu.so, which the base of a distribution does not have'),
        );

        final noLauncher = runCiScript(_script, [
          'pack',
          '--system',
          'linux-x64',
          '--source',
          path('source'),
          '--bin',
          path('brush_app'),
          '--third-party',
          path('THIRD-PARTY.md'),
          '--out',
          path('linux'),
        ]);
        expect(noLauncher.exitCode, 2, reason: '$noLauncher');
        expect(noLauncher.output, contains('--launcher'));
      },
    );
  }, skip: skip);

  // THIRD-PARTY.md of the archives (lot SP2, fix round of the review): cargo and cargo about are fakes found on the PATH
  // that print a fixture tree and metadata and write a fixture output; the git dependencies sit in a fake cargo home as
  // cargo leaves them, the whole repository checked out under git/checkouts/<name>-<hash>/<short commit>/ with
  // .cargo-ok at its root and each crate in a folder of it
  group('about', () {
    late Directory root;
    late Directory bin;
    late String generated;
    late List<Map<String, Object?>> packages;
    late List<String> tree;
    String path(String relative) => p.joinAll([root.path, ...relative.split('/')]);
    const cubecl = 'https://github.com/ArthurBrussee/cubecl?branch=sg-size';
    const cubeclCommit = '43580a8c294f3a8140921c26f6378a12aef82881';
    const tracel = 'https://github.com/tracel-ai/cubecl?rev=d6b53441c0578287212ad8cb4b816253c42bc46e';
    const tracelCommit = 'd6b53441c0578287212ad8cb4b816253c42bc46e';
    const burn = 'https://github.com/tracel-ai/burn';
    const burnCommit = 'dd2a02903f8c1e9a1a4b3c4c3a3b9b0a6b8e2f4d';
    const registry = 'registry+https://github.com/rust-lang/crates.io-index';
    const checkouts = 'home/git/checkouts';
    const crates = 'home/registry/src/index.crates.io-1949cf8c6b5b557f';
    const peterHall = 'Copyright (c) 2021 Peter Hall';

    /// A crate of the fixture: its manifest written under [folder], its package in the metadata, its line in the tree
    void crate(String name, String version, String folder, {String? source, String? treeSource, bool inTree = true}) {
      writeFiles(root, {'$folder/Cargo.toml': '[package]\nname = "$name"\nversion = "$version"\n'});
      final id = source == null
          ? 'path+${Uri.directory(path(folder))}#$version'
          : '${source.split('#').first}#$name@$version';
      packages.add({
        'name': name,
        'version': version,
        'id': id,
        'source': source,
        'manifest_path': path('$folder/Cargo.toml'),
      });
      if (inTree) {
        tree.add('$name v$version${treeSource == null ? '' : ' ($treeSource)'}');
      }
    }

    setUp(() {
      root = Directory.systemTemp.createTempSync('immuch360_brush_about_');
      bin = Directory(path('bin'))..createSync();
      packages = [];
      tree = [];
      generated =
          '# The code built into Brush\n\n'
          '`brush_app` of Brush is built by the CI of Immuch360.\n\n'
          '## Licences\n\n* MIT License (MIT): 1 crates\n\n'
          '## Crates, by licence\n\n'
          '### MIT License (MIT), text 0\n\n* anyhow 1.0.99, https://github.com/dtolnay/anyhow\n\n'
          '````text\nMIT License\n\nCopyright (c) David Tolnay\n\n````\n\n';
      writeFiles(root, {
        'src/Cargo.toml': '[workspace]\n',
        '$checkouts/cubecl-01990d4f7f2c358d/43580a8/.cargo-ok': '{"v":1}',
        '$checkouts/cubecl-01990d4f7f2c358d/43580a8/NOTICE.md':
            '# NOTICES\n\n## type_hash\n\nMIT License\n\n$peterHall\n',
        '$checkouts/cubecl-01990d4f7f2c358d/43580a8/crates/cubecl-quant/NOTICE': 'the copy of cubecl not compiled in\n',
        '$checkouts/cubecl-058c47895211d464/d6b5344/.cargo-ok': '{"v":1}',
        '$checkouts/cubecl-058c47895211d464/d6b5344/NOTICE.md': 'The notices of tracel-ai/cubecl\n',
        '$checkouts/burn-6c277d792b0d5d7a/dd2a029/.cargo-ok': '{"v":1}',
        '$checkouts/burn-6c277d792b0d5d7a/dd2a029/NOTICES.md': 'Code from num-traits, MIT\n',
        '$crates/noticed-1.0.0/NOTICE': 'noticed: a notice next to the manifest\n',
        '$crates/cfg_aliases-0.2.1/NOTICE': 'cfg_aliases: a build dependency\n',
      });
      crate('brush-app', '0.3.0', 'src/crates/brush-app', treeSource: path('src/crates/brush-app'));
      crate('anyhow', '1.0.99', '$crates/anyhow-1.0.99', source: registry);
      crate('noticed', '1.0.0', '$crates/noticed-1.0.0', source: registry);
      crate('cfg_aliases', '0.2.1', '$crates/cfg_aliases-0.2.1', source: registry, inTree: false);
      crate(
        'burn-tensor',
        '0.19.0',
        '$checkouts/burn-6c277d792b0d5d7a/dd2a029/crates/burn-tensor',
        source: 'git+$burn#$burnCommit',
        treeSource: '$burn#${burnCommit.substring(0, 8)}',
      );
      for (final name in ['cubecl-ir', 'cubecl-core']) {
        crate(
          name,
          '0.7.0',
          '$checkouts/cubecl-01990d4f7f2c358d/43580a8/crates/$name',
          source: 'git+$cubecl#$cubeclCommit',
          treeSource: '$cubecl#${cubeclCommit.substring(0, 8)}',
        );
      }
      crate(
        'cubecl-quant',
        '0.7.0',
        '$checkouts/cubecl-058c47895211d464/d6b5344/crates/cubecl-quant',
        source: 'git+$tracel#$tracelCommit',
        treeSource: '$tracel#${tracelCommit.substring(0, 8)}',
      );
      // The same name and version from the other copy of cubecl, last in the metadata, not compiled in
      crate(
        'cubecl-quant',
        '0.7.0',
        '$checkouts/cubecl-01990d4f7f2c358d/43580a8/crates/cubecl-quant',
        source: 'git+$cubecl#$cubeclCommit',
        inTree: false,
      );
      _fakeCommand(bin, 'cargo', '''
import pathlib, sys
here = pathlib.Path(__file__).resolve().parent
with open(here / 'calls.txt', 'a', encoding='utf-8') as calls:
    calls.write(' '.join(sys.argv[1:]) + '\\n')
if sys.argv[1] == 'tree':
    sys.stdout.write((here / 'tree.txt').read_text(encoding='utf-8'))
elif sys.argv[1] == 'metadata':
    sys.stdout.write((here / 'metadata.json').read_text(encoding='utf-8'))
else:
    sys.exit('fake cargo: no ' + sys.argv[1])
''');
    });
    tearDown(() => root.deleteSync(recursive: true));

    ScriptRun about() {
      File(p.join(bin.path, 'tree.txt')).writeAsStringSync('${tree.join('\n')}\n');
      File(
        p.join(bin.path, 'metadata.json'),
      ).writeAsStringSync(jsonEncode({'packages': packages, 'workspace_root': path('src'), 'version': 1}));
      File(p.join(bin.path, 'generated.md')).writeAsStringSync(generated);
      final cargoAbout = _fakeCommand(bin, 'cargo-about', '''
import pathlib, sys
here = pathlib.Path(__file__).resolve().parent
out = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
out.write_text((here / 'generated.md').read_text(encoding='utf-8'), encoding='utf-8')
''');
      return runCiScript(_script, [
        'about',
        '--system',
        'linux-x64',
        '--source',
        path('src'),
        '--cargo-about',
        cargoAbout,
        '--out',
        path('out/THIRD-PARTY.md'),
      ], environment: _pathFirst(bin));
    }

    String written() => File(path('out/THIRD-PARTY.md')).readAsStringSync();

    test('the NOTICE files at the root of the git copies, once per repository and commit, and next to the crates', () {
      final run = about();
      expect(run.exitCode, 0, reason: '$run');
      final text = written();
      expect(text, isNot(contains('\r')));
      expect(peterHall.allMatches(text), hasLength(1), reason: text);
      expect(text, contains('$cubecl at $cubeclCommit, NOTICE.md'));
      expect(text, contains('cubecl-core 0.7.0, cubecl-ir 0.7.0'));
      expect(text, contains('Code from num-traits, MIT'));
      expect(text, contains('$burn at $burnCommit, NOTICES.md'));
      expect(text, contains('The notices of tracel-ai/cubecl'));
      expect(text, contains('noticed: a notice next to the manifest'));
      expect(text, isNot(contains('cfg_aliases: a build dependency')));
      expect(text, isNot(contains('the copy of cubecl not compiled in')));
      expect(text, isNot(contains('No crate compiled into brush_app carries a NOTICE file')));
      // The head of the file says what was built, after its title
      expect(
        text,
        startsWith(
          '# The code built into Brush\n\nBrush v0.3.0 (3edecbb2fe79d3e2c87eeab85b15e0b1dd10d486), '
          'https://github.com/ArthurBrussee/brush, lock ${_lock()['id']}, x86_64-unknown-linux-gnu, toolchain 1.89.0\n',
        ),
      );
      final calls = File(p.join(bin.path, 'calls.txt')).readAsStringSync();
      expect(calls, contains('tree --frozen -p brush-app --no-default-features --target x86_64-unknown-linux-gnu'));
      expect(calls, contains('-e normal --prefix none'));
    });

    test('without a NOTICE file anywhere, THIRD-PARTY.md says so', () {
      for (final notice in [
        '$checkouts/cubecl-01990d4f7f2c358d/43580a8/NOTICE.md',
        '$checkouts/cubecl-058c47895211d464/d6b5344/NOTICE.md',
        '$checkouts/burn-6c277d792b0d5d7a/dd2a029/NOTICES.md',
        '$crates/noticed-1.0.0/NOTICE',
      ]) {
        File(path(notice)).deleteSync();
      }
      final run = about();
      expect(run.exitCode, 0, reason: '$run');
      expect(written(), contains('No crate compiled into brush_app carries a NOTICE file'));
    });

    test('a git copy without its root, or a crate of the tree that cargo metadata does not know, fails the job', () {
      File(path('$checkouts/burn-6c277d792b0d5d7a/dd2a029/.cargo-ok')).deleteSync();
      final rootless = about();
      expect(rootless.exitCode, 1, reason: '$rootless');
      expect(rootless.output, contains('burn-tensor 0.19.0'));
      File(path('$checkouts/burn-6c277d792b0d5d7a/dd2a029/.cargo-ok')).writeAsStringSync('{"v":1}');

      tree.add('ghost v9.9.9');
      final unknown = about();
      expect(unknown.exitCode, 1, reason: '$unknown');
      expect(unknown.output, contains('ghost v9.9.9'));
    });

    test('a licence given as its template is refused, unless EXTRA-NOTICES.md holds the notices of its crates', () {
      String template(List<String> crates) =>
          '### MIT License (MIT), text 1\n\n${crates.map((crate) => '* $crate\n').join()}\n'
          '````text\nMIT License\n\nCopyright (c) <year> <copyright holders>\n\nPermission is hereby granted\n\n````\n\n';
      final base = generated;
      generated = base + template(['mystery 1.0.0, https://example.invalid/mystery', 'ball-tree 0.5.1']);
      final unknown = about();
      expect(unknown.exitCode, 1, reason: '$unknown');
      expect(unknown.output, contains('mystery 1.0.0'));
      expect(unknown.output, isNot(contains('ball-tree 0.5.1,')));

      generated = '${base}Copyright (c) <year> <copyright holders> outside of a licence\n';
      final loose = about();
      expect(loose.exitCode, 1, reason: '$loose');

      generated =
          base +
          template([
            'ball-tree 0.5.1, https://github.com/grantslatton/ball-tree',
            'tokio_with_wasm 0.8.7, https://github.com/cunarist/tokio-with-wasm',
          ]);
      final covered = about();
      expect(covered.exitCode, 0, reason: '$covered');
      expect(
        written(),
        contains(
          '* tokio_with_wasm 0.8.7, https://github.com/cunarist/tokio-with-wasm\n\n'
          'These crates carry no licence file: cargo about gives the template of their licence, without its copyright '
          'line; their copyright notices are in EXTRA-NOTICES.md, next to this file.\n\n````text\n',
        ),
      );
    });
  }, skip: skip);

  // The brush jobs of the desktop workflow: what they ask of the program they build (lot SP2, fix round of the review)
  group('the brush jobs', () {
    String job(String name) {
      final workflow = File(
        p.join(repositoryRoot, '.github', 'workflows', 'immuch360-desktop.yml'),
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final start = workflow.indexOf('\n  $name:\n');
      expect(start, isNot(-1), reason: name);
      final end = RegExp(r'\n  [\w-]+:\n').firstMatch(workflow.substring(start + 1))!.start;
      return workflow.substring(start, start + 1 + end);
    }

    test('both jobs check that a LPIPS weight above 0 is refused with its message', () {
      for (final name in ['brush-windows', 'brush-linux']) {
        final steps = job(name);
        expect(steps, contains('"\$PROGRAM" . --lpips-loss-weight 0.5'), reason: name);
        expect(steps, contains('grep -q "no LPIPS weights"'), reason: name);
      }
    });
  }, skip: skip);
}
