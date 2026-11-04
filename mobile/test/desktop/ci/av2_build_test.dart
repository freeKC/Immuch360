// Runs .github/desktop/av2/av2_build.py and av2_serve_check.py, the scripts of the av2 jobs (lot AD2 of the AV2 plan of
// the 2nd of November 2026: immuch360-av2 on dav2d, built by our CI), on fixtures: the lock, the licences (a GPL
// entry must fail), the archive of each system with fake programs (only the system's libraries or imports, no string
// of GPL code), the check of an archive changed after the fact, the help against its fixture, and the temporal units
// the client reads from the fixtures of lot AD0.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

const _build = 'av2/av2_build.py';
const _client = 'av2/av2_serve_check.py';
const _commit = '30140b563596a1b14aef808ff021c90288948315';

/// What av2_build.py build records next to the program it built, for BUILD-INFO.txt
const _tools = {
  'compiler': 'msvc 19.44.35215 (Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35215 for x64)',
  'nasm': 'NASM version 2.16.03 compiled on Apr 17 2024',
  'meson': '1.7.0',
  'ninja': '1.13.0',
};

/// A 64 bit little endian ELF file reduced to what av2_build.py reads: the section headers, a string table and a
/// dynamic section that needs [needed]
Uint8List _elf(List<String> needed, {String extra = ''}) {
  final strings = BytesBuilder()..addByte(0);
  final offsets = <int>[];
  for (final name in needed) {
    offsets.add(strings.length);
    strings
      ..add(utf8.encode(name))
      ..addByte(0);
  }
  final stringBytes = strings.toBytes();
  const stringsAt = 0x100;
  final dynamicAt = stringsAt + ((stringBytes.length + 15) ~/ 16) * 16;
  final dynamicSize = (needed.length + 1) * 16;
  final sectionsAt = dynamicAt + dynamicSize;
  final extraBytes = utf8.encode(extra);
  final data = ByteData(sectionsAt + 3 * 64 + extraBytes.length);
  final bytes = data.buffer.asUint8List();
  bytes.setRange(0, 4, [0x7F, 0x45, 0x4C, 0x46]);
  data
    ..setUint8(4, 2)
    ..setUint8(5, 1)
    ..setUint64(0x28, sectionsAt, Endian.little)
    ..setUint16(0x3A, 64, Endian.little)
    ..setUint16(0x3C, 3, Endian.little);
  bytes.setRange(stringsAt, stringsAt + stringBytes.length, stringBytes);
  for (var i = 0; i < needed.length; i++) {
    data
      ..setInt64(dynamicAt + i * 16, 1, Endian.little)
      ..setUint64(dynamicAt + i * 16 + 8, offsets[i], Endian.little);
  }
  void section(int index, int type, int offset, int size, int link, int entsize) {
    final at = sectionsAt + index * 64;
    data
      ..setUint32(at + 4, type, Endian.little)
      ..setUint64(at + 24, offset, Endian.little)
      ..setUint64(at + 32, size, Endian.little)
      ..setUint32(at + 40, link, Endian.little)
      ..setUint64(at + 56, entsize, Endian.little);
  }

  section(1, 3, stringsAt, stringBytes.length, 0, 0);
  section(2, 6, dynamicAt, dynamicSize, 1, 16);
  bytes.setRange(sectionsAt + 3 * 64, bytes.length, extraBytes);
  return bytes;
}

/// A 64 bit Mach-O file of one architecture (0x0100000C arm64, 0x01000007 x86_64) that loads [dylibs] with the load
/// command [command] (0xC LC_LOAD_DYLIB, 0x20 LC_LAZY_LOAD_DYLIB, 0x80000023 LC_LOAD_UPWARD_DYLIB...)
Uint8List _thinMachO(int cpu, List<String> dylibs, {int command = 0xC}) {
  final commands = BytesBuilder();
  for (final dylib in dylibs) {
    final name = utf8.encode(dylib);
    final size = ((24 + name.length + 1 + 7) ~/ 8) * 8;
    final load = ByteData(size)
      ..setUint32(0, command, Endian.little)
      ..setUint32(4, size, Endian.little)
      ..setUint32(8, 24, Endian.little);
    final bytes = load.buffer.asUint8List()..setRange(24, 24 + name.length, name);
    commands.add(bytes);
  }
  final body = commands.toBytes();
  final header = ByteData(32)
    ..setUint32(0, 0xFEEDFACF, Endian.little)
    ..setUint32(4, cpu, Endian.little)
    ..setUint32(12, 2, Endian.little)
    ..setUint32(16, dylibs.length, Endian.little)
    ..setUint32(20, body.length, Endian.little);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(body))
      .toBytes();
}

/// A universal Mach-O file of the given slices
Uint8List _fatMachO(List<(int, Uint8List)> slices) {
  final headerSize = 8 + 20 * slices.length;
  var at = ((headerSize + 4095) ~/ 4096) * 4096;
  final header = ByteData(headerSize)
    ..setUint32(0, 0xCAFEBABE)
    ..setUint32(4, slices.length);
  final out = BytesBuilder();
  final offsets = <int>[];
  for (var i = 0; i < slices.length; i++) {
    offsets.add(at);
    header
      ..setUint32(8 + i * 20, slices[i].$1)
      ..setUint32(8 + i * 20 + 8, at)
      ..setUint32(8 + i * 20 + 12, slices[i].$2.length)
      ..setUint32(8 + i * 20 + 16, 12);
    at = ((at + slices[i].$2.length + 4095) ~/ 4096) * 4096;
  }
  out.add(header.buffer.asUint8List());
  for (var i = 0; i < slices.length; i++) {
    out
      ..add(Uint8List(offsets[i] - out.length))
      ..add(slices[i].$2);
  }
  return out.toBytes();
}

/// The files of a ZIP archive, read by the Python of the tests (the app has no ZIP package of its own)
Map<String, List<int>> _unzip(String path) {
  const script =
      'import base64, json, sys, zipfile\n'
      'with zipfile.ZipFile(sys.argv[1]) as z:\n'
      '    print(json.dumps({i.filename: base64.b64encode(z.read(i)).decode() for i in z.infolist()}))';
  final command = python!;
  final result = Process.runSync(command.first, [...command.skip(1), '-c', script, path]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  final names = jsonDecode('${result.stdout}'.trim()) as Map<String, dynamic>;
  return {for (final entry in names.entries) entry.key: base64Decode(entry.value as String)};
}

/// [path] written again to [target] with [changes]: a name to its new text, or to null to leave it out
void _rezip(String path, String target, Map<String, String?> changes) {
  const script =
      'import json, sys, zipfile\n'
      'changes = json.loads(sys.argv[3])\n'
      'with zipfile.ZipFile(sys.argv[1]) as z, zipfile.ZipFile(sys.argv[2], "w") as out:\n'
      '    for i in z.infolist():\n'
      '        if i.filename not in changes:\n'
      '            out.writestr(i, z.read(i))\n'
      '    for name, text in changes.items():\n'
      '        if text is not None:\n'
      '            out.writestr(name, text)';
  final command = python!;
  final result = Process.runSync(command.first, [...command.skip(1), '-c', script, path, target, jsonEncode(changes)]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
}

void main() {
  final folders = <Directory>[];
  final licences = Directory(p.join(repositoryRoot, 'licenses', 'av2'));
  final fixtures = Directory(p.join(repositoryRoot, 'mobile', 'test', 'fixtures', 'av2'));

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

  ScriptRun build(List<String> arguments) => runCiScript(_build, arguments);

  Map<String, dynamic> repositoryLock() =>
      jsonDecode(File(p.join(ciScriptsDir, 'av2', 'av2.lock.json')).readAsStringSync()) as Map<String, dynamic>;

  String writeLock(Directory root, Map<String, dynamic> lock) {
    final file = File(p.join(root.path, 'av2.lock.json'))..writeAsStringSync(jsonEncode(lock));
    return file.path;
  }

  /// The files of dav2d the licences come from, made of the texts of licenses/av2 (as the lock says they are)
  Directory sources() {
    final root = tree({});
    final asm = '${File(p.join(licences.path, 'x86inc-ISC.txt')).readAsStringSync()}\n; This is a header file\n';
    for (final (name, bytes) in [
      ('COPYING', File(p.join(licences.path, 'dav2d-COPYING.txt')).readAsBytesSync()),
      ('doc/PATENTS', File(p.join(licences.path, 'AOM-PATENTS.txt')).readAsBytesSync()),
      ('src/ext/x86/x86inc.asm', utf8.encode(asm)),
    ]) {
      File(p.joinAll([root.path, ...name.split('/')]))
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
    }
    return root;
  }

  group('av2_build.py', () {
    test('the lock of the repository names dav2d, the tools and the artifacts of the three systems', () {
      for (final system in ['windows-x64', 'linux-x64', 'macos-universal']) {
        final run = build(['lock', '--system', system]);
        expect(run.exitCode, 0, reason: '$run');
        expect(run.output, contains('id=30140b5-1'));
        expect(run.output, contains('artifact=Immuch360-av2-decoder-30140b5-1-$system.zip'));
        expect(run.output, contains('commit=$_commit'));
        expect(run.output, contains('meson=1.7.0'));
        expect(run.output, contains('nasm_version=2.16.03'));
        expect(
          run.output,
          contains(
            system == 'windows-x64'
                ? 'nasm_url=https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/win64/nasm-2.16.03-win64.zip'
                : 'nasm_url=https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/nasm-2.16.03.tar.xz',
          ),
        );
        expect(
          run.output,
          contains(
            system == 'windows-x64'
                ? 'nasm_sha256=3ee4782247bcb874378d02f7eab4e294a84d3d15f3f6ee2de2f47a46aa7226e6'
                : 'nasm_sha256=1412a1c760bbd05db026b6c0d1657affd6631cd0a63cddb6f73cc6d4aa616148',
          ),
        );
      }
      final lock = repositoryLock();
      expect((lock['dav2d'] as Map)['repository'], 'https://code.videolan.org/videolan/dav2d.git');
      expect(lock['meson'], containsPair('windows-x64', ['-Db_vscrt=mt']));
    });

    test('a lock without a full commit, with the id of another commit or without a sum of nasm is refused', () {
      for (final (change, message) in [
        ((Map<String, dynamic> lock) => (lock['dav2d'] as Map)['commit'] = '30140b56', 'not a full commit'),
        ((Map<String, dynamic> lock) => lock['id'] = 'abcdef0-1', 'is not <short commit of dav2d>-<build>'),
        (
          (Map<String, dynamic> lock) => (((lock['tools'] as Map)['nasm'] as Map)['windows-x64'] as Map)['sha256'] = '',
          'the nasm of Windows has no https address or SHA-256',
        ),
        (
          (Map<String, dynamic> lock) => (((lock['tools'] as Map)['nasm'] as Map)['source'] as Map)['sha256'] = '',
          'the source of nasm, built on Linux and macOS, has no https address or SHA-256',
        ),
        (
          (Map<String, dynamic> lock) =>
              (((lock['tools'] as Map)['nasm'] as Map)['source'] as Map)['url'] = 'http://www.nasm.us/nasm.tar.xz',
          'the source of nasm, built on Linux and macOS, has no https address or SHA-256',
        ),
      ]) {
        final lock = repositoryLock();
        change(lock);
        final root = tree({});
        final run = build(['--lock', writeLock(root, lock), 'lock', '--system', 'linux-x64']);
        expect(run.exitCode, 1, reason: '$run');
        expect(run.output, contains(message));
      }
    });

    test('the licences of the lock are permissive and their texts those of the sources', () {
      final run = build(['licences', '--source', sources().path]);
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('dav2d (BSD-2-Clause)'));
      expect(run.output, contains('immuch360-av2 (AGPL-3.0-only)'));
    });

    test('a GPL entry fails, whether alone, in an AND or in the permissive list; a permissive choice passes', () {
      final source = sources().path;
      Map<String, dynamic> withComponent(String licence) {
        final lock = repositoryLock();
        (lock['components'] as List).add({
          'name': 'x264',
          'licence': licence,
          'text': 'dav2d-COPYING.txt',
          'source': 'COPYING',
        });
        return lock;
      }

      for (final licence in ['GPL-2.0-or-later', 'GPL-3.0-only', 'LGPL-2.1-or-later', 'MIT AND GPL-2.0-only']) {
        final root = tree({});
        final run = build(['--lock', writeLock(root, withComponent(licence)), 'licences', '--source', source]);
        expect(run.exitCode, 1, reason: '$licence: $run');
        expect(run.output, contains('x264: $licence is not a permissive licence of the lock'));
      }
      final choice = build([
        '--lock',
        writeLock(tree({}), withComponent('GPL-2.0-only OR MIT')),
        'licences',
        '--source',
        source,
      ]);
      expect(choice.exitCode, 0, reason: '$choice');

      final permissive = repositoryLock();
      (permissive['permissive'] as List).add('GPL-2.0-only');
      final listed = build(['--lock', writeLock(tree({}), permissive), 'licences', '--source', source]);
      expect(listed.exitCode, 1, reason: '$listed');
      expect(listed.output, contains('the permissive list of the lock holds GPL-2.0-only'));

      final own = repositoryLock();
      ((own['components'] as List).firstWhere((c) => (c as Map)['name'] == 'immuch360-av2') as Map)['licence'] =
          'GPL-3.0-only';
      final ours = build(['--lock', writeLock(tree({}), own), 'licences', '--source', source]);
      expect(ours.exitCode, 1, reason: '$ours');
      expect(ours.output, contains('immuch360-av2: GPL-3.0-only, not AGPL-3.0-only, the licence of our own code'));
    });

    test('our own licences are pinned by the script: changed in the lock too, or claimed for dav2d, they fail', () {
      final source = sources().path;
      Map<String, dynamic> component(Map<String, dynamic> lock, String name) =>
          (lock['components'] as List).firstWhere((c) => (c as Map)['name'] == name) as Map<String, dynamic>;

      for (final (name, licence) in [('immuch360-av2', 'GPL-3.0-only'), ('immuch360-run', 'GPL-2.0-only')]) {
        final both = repositoryLock();
        component(both, name)['licence'] = licence;
        (both['own'] as Map)[name] = licence;
        final run = build(['--lock', writeLock(tree({}), both), 'licences', '--source', source]);
        expect(run.exitCode, 1, reason: '$name: $run');
        expect(run.output, contains('$name: $licence, not '));
      }

      final claimed = repositoryLock();
      component(claimed, 'dav2d')
        ..['own'] = 'LICENSE'
        ..['licence'] = 'GPL-2.0-or-later';
      (claimed['own'] as Map)['dav2d'] = 'GPL-2.0-or-later';
      final run = build(['--lock', writeLock(tree({}), claimed), 'licences', '--source', source]);
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('dav2d: marked as our own code, which only immuch360-av2 and immuch360-run are'));
    });

    test('a licence text that differs from the sources fails', () {
      final copy = tree({});
      for (final file in licences.listSync().whereType<File>()) {
        file.copySync(p.join(copy.path, p.basename(file.path)));
      }
      File(p.join(copy.path, 'dav2d-COPYING.txt')).writeAsStringSync('Copyright someone else\n');
      final run = build(['--licences', copy.path, 'licences', '--source', sources().path]);
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('licenses/av2/dav2d-COPYING.txt differs from COPYING of the sources built'));
    });

    group('pack and check', () {
      String program(Directory root, String name, List<int> bytes) {
        final file = File(p.join(root.path, name))..writeAsBytesSync(bytes);
        final tools = File(p.join(root.path, 'tools.json'));
        if (!tools.existsSync()) {
          tools.writeAsStringSync(jsonEncode(_tools));
        }
        return file.path;
      }

      ScriptRun pack(String system, String programPath, {String? launcher, required Directory out}) => build([
        'pack',
        '--system',
        system,
        '--source',
        sources().path,
        '--program',
        programPath,
        '--out',
        out.path,
        '--source-commit',
        '0123456789abcdef0123456789abcdef01234567',
        if (launcher != null) ...['--launcher', launcher],
      ]);

      test('Windows: the program imports only DLLs of Windows, the archive holds its licences and sums', () {
        final root = tree({});
        final exe = program(root, 'immuch360-av2.exe', fakePe(imports: ['KERNEL32.dll', 'WS2_32.dll', 'SHELL32.dll']));
        final out = Directory(p.join(root.path, 'dist'));
        final run = pack('windows-x64', exe, out: out);
        expect(run.exitCode, 0, reason: '$run');
        final archive = File(p.join(out.path, 'Immuch360-av2-decoder-30140b5-1-windows-x64.zip'));
        final first = archive.readAsBytesSync();
        final files = _unzip(archive.path);
        expect(files.keys.toList()..sort(), [
          'BUILD-INFO.txt',
          'SHA256SUMS.txt',
          'immuch360-av2.exe',
          'licenses/AOM-PATENTS.txt',
          'licenses/README.md',
          'licenses/dav2d-COPYING.txt',
          'licenses/immuch360-av2-AGPL-3.0.txt',
          'licenses/immuch360-av2-SOURCE.txt',
          'licenses/x86inc-ISC.txt',
        ]);
        final source = utf8.decode(files['licenses/immuch360-av2-SOURCE.txt']!);
        expect(source, contains('/tree/0123456789abcdef0123456789abcdef01234567/mobile/native/av2'));
        final info = utf8.decode(files['BUILD-INFO.txt']!);
        expect(info, contains('C compiler: ${_tools['compiler']}'));
        expect(info, contains('nasm: ${_tools['nasm']}'));
        expect(info, contains('Meson 1.7.0, Ninja 1.13.0'));
        expect(pack('windows-x64', exe, out: out).exitCode, 0);
        expect(archive.readAsBytesSync(), first, reason: 'the same files give the same bytes');

        final check = build(['check', '--system', 'windows-x64', '--archive', archive.path]);
        expect(check.exitCode, 0, reason: '$check');
        expect(check.output, contains('sums, licences, libraries and strings as they should be'));
      });

      test('a program assembled by another nasm than that of the lock is neither packed nor accepted', () {
        final root = tree({});
        final out = Directory(p.join(root.path, 'dist'));
        final exe = program(root, 'immuch360-av2.exe', fakePe(imports: ['KERNEL32.dll']));
        expect(pack('windows-x64', exe, out: out).exitCode, 0);
        final archive = p.join(out.path, 'Immuch360-av2-decoder-30140b5-1-windows-x64.zip');
        final info = utf8.decode(_unzip(archive)['BUILD-INFO.txt']!);

        // Homebrew's NASM 3.02 in the tools of the build: not packed
        final other = Directory(p.join(root.path, 'other'))..createSync();
        File(
          p.join(other.path, 'tools.json'),
        ).writeAsStringSync(jsonEncode({..._tools, 'nasm': 'NASM version 3.02 compiled on Oct 10 2026'}));
        final otherExe = File(p.join(other.path, 'immuch360-av2.exe'))
          ..writeAsBytesSync(fakePe(imports: ['KERNEL32.dll']));
        final refused = pack('windows-x64', otherExe.path, out: Directory(p.join(root.path, 'dist-other')));
        expect(refused.exitCode, 1, reason: '$refused');
        expect(refused.output, contains('NASM version 3.02 compiled on Oct 10 2026, not the 2.16.03 of the lock'));

        // An archive whose BUILD-INFO.txt names it: not accepted
        final changed = Directory(p.join(root.path, 'changed'))..createSync();
        final file = p.join(changed.path, p.basename(archive));
        _rezip(archive, file, {'BUILD-INFO.txt': info.replaceFirst('NASM version 2.16.03', 'NASM version 3.02')});
        final check = build(['check', '--system', 'windows-x64', '--archive', file]);
        expect(check.exitCode, 1, reason: '$check');
        expect(check.output, contains('nasm NASM version 3.02 compiled on Apr 17 2024, not the 2.16.03 of the lock'));
      });

      test('a build that recorded no tools next to its program is not packed', () {
        final root = tree({});
        final bare = Directory(p.join(root.path, 'bare'))..createSync();
        final exe = File(p.join(bare.path, 'immuch360-av2.exe'))..writeAsBytesSync(fakePe(imports: ['KERNEL32.dll']));
        final run = pack('windows-x64', exe.path, out: Directory(p.join(root.path, 'dist')));
        expect(run.exitCode, 1, reason: '$run');
        expect(run.output, contains('no tools.json next to the program'));
      });

      test('the scripts write no Python cache next to themselves, even when Python would', () {
        final caches = [
          Directory(p.join(ciScriptsDir, '__pycache__')),
          Directory(p.join(ciScriptsDir, 'av2', '__pycache__')),
        ];
        Set<String> files() => {
          for (final cache in caches)
            if (cache.existsSync()) ...cache.listSync().map((f) => '${f.path} ${f.statSync().modified}'),
        };
        final existed = [for (final cache in caches) cache.existsSync()];
        final before = files();
        final root = tree({});
        final out = Directory(p.join(root.path, 'dist'));
        final exe = program(root, 'immuch360-av2.exe', fakePe(imports: ['KERNEL32.dll']));
        const writes = {'PYTHONDONTWRITEBYTECODE': ''};
        final packed = runCiScript(_build, [
          'pack',
          '--system',
          'windows-x64',
          '--source',
          sources().path,
          '--program',
          exe,
          '--out',
          out.path,
        ], environment: writes);
        final checked = runCiScript(_build, [
          'check',
          '--system',
          'windows-x64',
          '--archive',
          p.join(out.path, 'Immuch360-av2-decoder-30140b5-1-windows-x64.zip'),
        ], environment: writes);
        final written = files().difference(before);
        for (var i = 0; i < caches.length; i++) {
          if (!existed[i] && caches[i].existsSync()) {
            caches[i].deleteSync(recursive: true);
          }
        }
        expect(packed.exitCode, 0, reason: '$packed');
        expect(checked.exitCode, 0, reason: '$checked');
        expect(written, isEmpty);
      });

      test('Windows: a Visual C++ runtime import or a string of GPL code fails the archive', () {
        final root = tree({});
        final out = Directory(p.join(root.path, 'dist'));
        final runtime = pack(
          'windows-x64',
          program(root, 'a.exe', fakePe(imports: ['KERNEL32.dll', 'VCRUNTIME140.dll'])),
          out: out,
        );
        expect(runtime.exitCode, 1, reason: '$runtime');
        expect(runtime.output, contains('imports VCRUNTIME140.dll: only DLLs of Windows itself'));
        final gpl = pack(
          'windows-x64',
          program(root, 'b.exe', [
            ...fakePe(imports: ['KERNEL32.dll']),
            ...utf8.encode('under the terms of the GNU General Public License'),
          ]),
          out: out,
        );
        expect(gpl.exitCode, 1, reason: '$gpl');
        expect(gpl.output, contains('holds "GNU General Public License": GPL code in the program'));
        expect(out.existsSync() && out.listSync().isNotEmpty, isFalse);
      });

      test('Linux: only the C library of the system, immuch360-run next to the program', () {
        final root = tree({});
        final out = Directory(p.join(root.path, 'dist'));
        final launcher = program(root, 'immuch360-run', _elf(['libc.so.6']));
        final good = pack(
          'linux-x64',
          program(root, 'immuch360-av2', _elf(['libm.so.6', 'libc.so.6'])),
          launcher: launcher,
          out: out,
        );
        expect(good.exitCode, 0, reason: '$good');
        final archive = p.join(out.path, 'Immuch360-av2-decoder-30140b5-1-linux-x64.zip');
        expect(_unzip(archive).keys, containsAll(['immuch360-run', 'licenses/immuch360-run-MIT.txt', 'immuch360-av2']));
        final check = build(['check', '--system', 'linux-x64', '--archive', archive]);
        expect(check.exitCode, 0, reason: '$check');

        final noLauncher = pack('linux-x64', program(root, 'c', _elf(['libc.so.6'])), out: out);
        expect(noLauncher.exitCode, 1, reason: '$noLauncher');
        expect(noLauncher.output, contains('needs --launcher'));
        for (final library in ['libstdc++.so.6', 'libx264.so.164']) {
          final run = pack('linux-x64', program(root, 'd', _elf(['libc.so.6', library])), launcher: launcher, out: out);
          expect(run.exitCode, 1, reason: '$library: $run');
          expect(run.output, contains('needs $library, not a library of the system'));
        }
        final banner = pack(
          'linux-x64',
          program(root, 'e', _elf(['libc.so.6'], extra: 'x264 - core 164')),
          launcher: launcher,
          out: out,
        );
        expect(banner.exitCode, 1, reason: '$banner');
        expect(banner.output, contains('holds "x264 - core"'));
      });

      test('macOS: arm64 and x86_64 that load libSystem only', () {
        final root = tree({});
        final out = Directory(p.join(root.path, 'dist'));
        const system = '/usr/lib/libSystem.B.dylib';
        final universal = _fatMachO([
          (0x0100000C, _thinMachO(0x0100000C, [system])),
          (0x01000007, _thinMachO(0x01000007, [system])),
        ]);
        final good = pack('macos-universal', program(root, 'immuch360-av2', universal), out: out);
        expect(good.exitCode, 0, reason: '$good');
        final check = build([
          'check',
          '--system',
          'macos-universal',
          '--archive',
          p.join(out.path, 'Immuch360-av2-decoder-30140b5-1-macos-universal.zip'),
        ]);
        expect(check.exitCode, 0, reason: '$check');

        final thin = pack('macos-universal', program(root, 'a', _thinMachO(0x0100000C, [system])), out: out);
        expect(thin.exitCode, 1, reason: '$thin');
        expect(thin.output, contains('not arm64 and x86_64'));
        final brewed = pack(
          'macos-universal',
          program(
            root,
            'b',
            _fatMachO([
              (0x0100000C, _thinMachO(0x0100000C, [system, '/opt/homebrew/lib/libx265.dylib'])),
              (0x01000007, _thinMachO(0x01000007, [system])),
            ]),
          ),
          out: out,
        );
        expect(brewed.exitCode, 1, reason: '$brewed');
        expect(brewed.output, contains('(arm64) loads /opt/homebrew/lib/libx265.dylib, not a library of the system'));

        for (final (command, name) in [(0x20, 'lazy'), (0x80000023, 'upward')]) {
          final loaded = pack(
            'macos-universal',
            program(
              root,
              name,
              _fatMachO([
                (0x0100000C, _thinMachO(0x0100000C, [system])),
                (0x01000007, _thinMachO(0x01000007, ['/usr/local/lib/libx265.dylib'], command: command)),
              ]),
            ),
            out: out,
          );
          expect(loaded.exitCode, 1, reason: '$name: $loaded');
          expect(loaded.output, contains('(x86_64) loads /usr/local/lib/libx265.dylib, not a library of the system'));
        }
      });

      test('an archive changed after the pack fails its check', () {
        final root = tree({});
        final out = Directory(p.join(root.path, 'dist'));
        expect(
          pack('windows-x64', program(root, 'immuch360-av2.exe', fakePe(imports: ['KERNEL32.dll'])), out: out).exitCode,
          0,
        );
        final path = p.join(out.path, 'Immuch360-av2-decoder-30140b5-1-windows-x64.zip');

        ScriptRun changed(String folder, Map<String, String?> changes) {
          final target = Directory(p.join(root.path, folder))..createSync();
          final file = p.join(target.path, p.basename(path));
          _rezip(path, file, changes);
          return build(['check', '--system', 'windows-x64', '--archive', file]);
        }

        final licence = changed('licence', {'licenses/dav2d-COPYING.txt': 'Copyright someone else\n'});
        expect(licence.exitCode, 1, reason: '$licence');
        expect(licence.output, contains('licenses/dav2d-COPYING.txt is missing from the archive or differs'));
        expect(licence.output, contains('SHA256SUMS.txt does not give the sums'));
        final extra = changed('extra', {'libx264-164.dll': 'MZ'});
        expect(extra.exitCode, 1, reason: '$extra');
        expect(extra.output, contains('libx264-164.dll: a file the archive should not hold'));
        final info = changed('info', {'BUILD-INFO.txt': 'dav2d $_commit\n'});
        expect(info.exitCode, 1, reason: '$info');
        expect(info.output, contains('BUILD-INFO.txt does not name the C compiler and the nasm of the build'));
      });
    });

    test('the help of the program against its fixture', () {
      final fixture = File(p.join(fixtures.path, 'immuch360_av2_help.txt')).readAsStringSync();
      expect(fixture, contains('immuch360-av2 serve --token TOKEN'));
      expect(fixture, contains('the environment variable IMMUCH360_AV2_TOKEN'));
      final root = tree({'same.txt': fixture, 'other.txt': fixture.replaceFirst('--depth 8', '--depth 6')});
      final same = build(['help', '--output', p.join(root.path, 'same.txt')]);
      expect(same.exitCode, 0, reason: '$same');
      final other = build(['help', '--output', p.join(root.path, 'other.txt')]);
      expect(other.exitCode, 1, reason: '$other');
      expect(other.output, contains('-  --depth 8'));
    });
  });

  group('av2_serve_check.py', () {
    Map<String, dynamic> index(String name) {
      final run = runCiScript(_client, ['index', '--file', p.join(fixtures.path, name)]);
      expect(run.exitCode, 0, reason: '$run');
      return jsonDecode(run.output.trim().split('\n').last) as Map<String, dynamic>;
    }

    test('the fixtures of AD0: 12 temporal units, random access at 0 and 6, as fixtures.json says', () {
      final made = jsonDecode(File(p.join(fixtures.path, 'fixtures.json')).readAsStringSync()) as Map<String, dynamic>;
      final files = made['files'] as Map<String, dynamic>;
      for (final name in [
        'av2-256x144-8bit.ivf',
        'av2-256x144-8bit.obu',
        'av2-256x144-10bit.ivf',
        'av2-256x144-10bit.obu',
      ]) {
        final read = index(name);
        expect(read['units'], (files[name] as Map)['frames'], reason: name);
        expect(read['raps'], [0, 6], reason: name);
        expect(read['fps'], [30, 1], reason: name);
      }
      final ivf = index('av2-256x144-8bit.ivf');
      final units = ((files['av2-256x144-8bit.obu'] as Map)['index'] as Map)['units'] as List;
      expect(ivf['sizes'], [for (final unit in units) (unit as Map)['size']]);
    });

    test('the fixtures name no folder of the computer they were made on', () {
      final home = RegExp(r'/home/|/Users/|[A-Za-z]:\\Users\\');
      for (final file in fixtures.listSync().whereType<File>()) {
        if (file.path.endsWith('.ivf') || file.path.endsWith('.obu')) {
          continue;
        }
        expect(home.hasMatch(file.readAsStringSync()), isFalse, reason: p.basename(file.path));
      }
    });

    test('a file cut in a unit keeps its whole units; an AV1 IVF is refused', () {
      expect(index('av2-256x144-8bit-cut.ivf')['units'], 8);
      final av1 = runCiScript(_client, ['index', '--file', p.join(fixtures.path, 'av1-256x144-8bit.ivf')]);
      expect(av1.exitCode, 1, reason: '$av1');
      expect(av1.output, contains('not AV2'));
    });
  });
}
