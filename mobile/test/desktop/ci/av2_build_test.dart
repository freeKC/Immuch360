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

/// The GitHub API of publish_av2_decoder.py, in memory: a run, its artifacts (redirected to a storage that must get
/// no token), and the releases of owner/repo
class _FakeGitHub {
  _FakeGitHub(this.token);

  final String token;
  late final HttpServer _server;
  final requests = <String>[];
  Map<String, List<int>> artifacts = {};
  String headSha = '';
  final storageAuthorizations = <String?>[];
  Map<String, dynamic>? created;
  Map<String, dynamic>? patched;
  final uploaded = <String, int>{};
  bool published = false;

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add('${request.method} $path');
    final response = request.response;
    Future<void> send(int status, [Object? json]) async {
      response.statusCode = status;
      if (json != null) {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(json));
      }
      await response.close();
    }

    if (path.startsWith('/storage/')) {
      storageAuthorizations.add(request.headers.value('authorization'));
      response.add(artifacts.values.elementAt(int.parse(path.split('/').last)));
      return response.close();
    }
    if (request.headers.value('authorization') != 'Bearer $token') {
      return send(401, {'message': 'Bad credentials'});
    }
    final bytes = await request.fold<BytesBuilder>(BytesBuilder(), (held, chunk) => held..add(chunk));
    final raw = bytes.takeBytes();
    String body() => utf8.decode(raw);
    if (path == '/repos/owner/repo/actions/runs/77') {
      return send(200, {
        'name': 'Immuch360 Desktop release',
        'head_branch': 'feat-av2',
        'head_sha': headSha,
        'event': 'workflow_dispatch',
        'status': 'completed',
        'conclusion': 'success',
      });
    }
    if (path == '/repos/owner/repo/actions/runs/77/artifacts') {
      final named = artifacts.keys.toList();
      return send(200, {
        'artifacts': [
          for (var i = 0; i < named.length; i++) {'id': i, 'name': named[i], 'expired': false},
          {'id': 99, 'name': 'Immuch360-av2-decoder-windows-x64-signed-SHA256SUMS', 'expired': false},
        ],
      });
    }
    final artifact = RegExp(r'^/repos/owner/repo/actions/artifacts/(\d+)/zip$').firstMatch(path);
    if (artifact != null) {
      response.statusCode = HttpStatus.found;
      response.headers.set(HttpHeaders.locationHeader, '$base/storage/${artifact.group(1)}');
      return response.close();
    }
    if (path == '/repos/owner/repo/releases/tags/av2-decoder-1') {
      return published ? send(200, {'tag_name': 'av2-decoder-1'}) : send(404, {'message': 'Not Found'});
    }
    if (path == '/repos/owner/repo/releases' && request.method == 'GET') {
      return send(200, []);
    }
    if (path == '/repos/owner/repo/releases/latest') {
      return send(200, {'tag_name': 'v3.3.0-rc.0-32'});
    }
    if (path == '/repos/owner/repo/releases' && request.method == 'POST') {
      created = jsonDecode(body()) as Map<String, dynamic>;
      return send(201, {
        'url': '$base/repos/owner/repo/releases/5',
        'html_url': 'https://github.com/owner/repo/releases/tag/av2-decoder-1',
        'upload_url': '$base/uploads/5{?name,label}',
      });
    }
    if (path == '/uploads/5') {
      final name = request.uri.queryParameters['name']!;
      uploaded[name] = raw.length;
      return send(201, {'name': name, 'size': raw.length});
    }
    if (path == '/repos/owner/repo/releases/5' && request.method == 'PATCH') {
      patched = jsonDecode(body()) as Map<String, dynamic>;
      published = true;
      return send(200, {'draft': false, 'prerelease': true, 'html_url': 'https://github.com/owner/repo/releases/5'});
    }
    return send(404, {'message': 'Not Found'});
  }
}

/// [unsigned], a PE file of [fakePe], as signtool leaves it once signed: the file padded to 8 bytes, a certificate
/// table appended, the certificate directory of the optional header pointing at it and a checksum written.
/// [changed] also changes a byte of the program, which a signature never does
Uint8List _signedPe(Uint8List unsigned, {bool changed = false}) {
  final padded = (unsigned.length + 7) ~/ 8 * 8;
  final certificate = utf8.encode('WIN_CERTIFICATE of APROGSYS, issued by Microsoft ID Verified CS EOC CA 03');
  final bytes = Uint8List(padded + certificate.length)
    ..setRange(0, unsigned.length, unsigned)
    ..setRange(padded, padded + certificate.length, certificate);
  final data = ByteData.sublistView(bytes);
  final optional = data.getUint32(0x3C, Endian.little) + 24;
  final directories = optional + 112;
  data
    ..setUint32(optional + 64, 0x0012ABCD, Endian.little)
    ..setUint32(directories + 4 * 8, padded, Endian.little)
    ..setUint32(directories + 4 * 8 + 4, certificate.length, Endian.little);
  if (changed) {
    bytes[0x200] ^= 0xFF;
  }
  return bytes;
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

      // Lot AD11: the sign-windows job of the release workflow signs the program of the archive, then puts it back
      test(
        'Windows: the signed program goes back into the archive with new sums, and the archive passes its check',
        () {
          final root = tree({});
          final unsigned = fakePe(imports: ['KERNEL32.dll', 'WS2_32.dll']);
          final out = Directory(p.join(root.path, 'dist'));
          expect(pack('windows-x64', program(root, 'immuch360-av2.exe', unsigned), out: out).exitCode, 0);
          final archive = p.join(out.path, 'Immuch360-av2-decoder-30140b5-1-windows-x64.zip');
          final before = _unzip(archive);

          final extracted = Directory(p.join(root.path, 'to-sign'));
          final taken = build(['program', '--system', 'windows-x64', '--archive', archive, '--out', extracted.path]);
          expect(taken.exitCode, 0, reason: '$taken');
          final exe = File(p.join(extracted.path, 'immuch360-av2.exe'));
          expect(exe.readAsBytesSync(), unsigned);
          exe.writeAsBytesSync(_signedPe(unsigned));

          final signedOut = Directory(p.join(root.path, 'signed'));
          ScriptRun sign() => build([
            'signed',
            '--system',
            'windows-x64',
            '--archive',
            archive,
            '--program',
            exe.path,
            '--out',
            signedOut.path,
          ]);
          final run = sign();
          expect(run.exitCode, 0, reason: '$run');
          final signedArchive = File(p.join(signedOut.path, p.basename(archive)));
          final bytes = signedArchive.readAsBytesSync();
          final files = _unzip(signedArchive.path);
          expect(files.keys.toSet(), before.keys.toSet());
          expect(files['immuch360-av2.exe'], _signedPe(unsigned));
          for (final name in before.keys.where((name) => !name.endsWith('.txt') || name.startsWith('licenses/'))) {
            if (name != 'immuch360-av2.exe') {
              expect(files[name], before[name], reason: name);
            }
          }
          final info = utf8.decode(files['BUILD-INFO.txt']!);
          expect(info, startsWith(utf8.decode(before['BUILD-INFO.txt']!)));
          expect(info, contains('Signed: immuch360-av2.exe by APROGSYS with Azure Artifact Signing'));
          final sums = utf8.decode(files['SHA256SUMS.txt']!);
          expect(sums, isNot(utf8.decode(before['SHA256SUMS.txt']!)));
          final digest = RegExp(r'^([0-9a-f]{64})  immuch360-av2\.exe$', multiLine: true).firstMatch(sums)!.group(1);
          final hashed = Process.runSync(python!.first, [
            ...python!.skip(1),
            '-c',
            'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())',
            exe.path,
          ]);
          expect('${hashed.stdout}'.trim(), digest);
          final listed = File(p.join(signedOut.path, 'SHA256SUMS')).readAsStringSync();
          expect(listed, matches(RegExp(r'^[0-9a-f]{64}  Immuch360-av2-decoder-30140b5-1-windows-x64\.zip\n$')));
          final check = build(['check', '--system', 'windows-x64', '--archive', signedArchive.path]);
          expect(check.exitCode, 0, reason: '$check');
          // The same signed program gives the same archive
          expect(sign().exitCode, 0);
          expect(signedArchive.readAsBytesSync(), bytes);
        },
      );

      test('a program not signed, changed beyond its signature, or signed twice is not put into the archive', () {
        final root = tree({});
        final unsigned = fakePe(imports: ['KERNEL32.dll']);
        final out = Directory(p.join(root.path, 'dist'));
        expect(pack('windows-x64', program(root, 'immuch360-av2.exe', unsigned), out: out).exitCode, 0);
        final archive = p.join(out.path, 'Immuch360-av2-decoder-30140b5-1-windows-x64.zip');
        ScriptRun sign(List<int> exe, String archivePath, String folder) {
          final file = File(p.join(root.path, '$folder.exe'))..writeAsBytesSync(exe);
          return build([
            'signed',
            '--system',
            'windows-x64',
            '--archive',
            archivePath,
            '--program',
            file.path,
            '--out',
            p.join(root.path, folder),
          ]);
        }

        final same = sign(unsigned, archive, 'same');
        expect(same.exitCode, 1, reason: '$same');
        expect(same.output, contains('is the program of the archive as it is: not signed'));
        final changed = sign(_signedPe(unsigned, changed: true), archive, 'changed');
        expect(changed.exitCode, 1, reason: '$changed');
        expect(
          changed.output,
          contains(
            'is not the program of Immuch360-av2-decoder-30140b5-1-windows-x64.zip with a '
            'signature added',
          ),
        );
        expect(sign(_signedPe(unsigned), archive, 'once').exitCode, 0);
        final twice = sign(
          _signedPe(_signedPe(unsigned)),
          p.join(root.path, 'once', 'Immuch360-av2-decoder-30140b5-1-windows-x64.zip'),
          'twice',
        );
        expect(twice.exitCode, 1, reason: '$twice');
        final linux = build(['program', '--system', 'linux-x64', '--archive', archive, '--out', root.path]);
        expect(linux.exitCode, 1);
        expect(linux.output, contains('only the Windows program is signed'));
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

  // Lot AD11: the prerelease av2-decoder-1 from the three archives of one run, ready but made by FreeKC's session only
  group('publish_av2_decoder.py', () {
    const commit = '0123456789abcdef0123456789abcdef01234567';
    const token = 'test-token';
    const names = {
      'windows-x64': 'Immuch360-av2-decoder-30140b5-1-windows-x64.zip',
      'linux-x64': 'Immuch360-av2-decoder-30140b5-1-linux-x64.zip',
      'macos-universal': 'Immuch360-av2-decoder-30140b5-1-macos-universal.zip',
    };
    const systemLibrary = '/usr/lib/libSystem.B.dylib';

    /// The three archives as the run of the release workflow with with_av2 leaves them, in a folder of their own:
    /// the Windows one signed unless [signed] is false, all built from [commit] but Linux from [linuxCommit]
    Directory archives({bool signed = true, String linuxCommit = commit}) {
      final root = tree({});
      final cache = Directory(p.join(root.path, 'cache'))..createSync();
      void pack(String system, String name, List<int> bytes, {String? launcher, String from = commit}) {
        final folder = Directory(p.join(root.path, system))..createSync();
        final file = File(p.join(folder.path, name))..writeAsBytesSync(bytes);
        File(p.join(folder.path, 'tools.json')).writeAsStringSync(jsonEncode(_tools));
        final run = build([
          'pack',
          '--system',
          system,
          '--source',
          sources().path,
          '--program',
          file.path,
          '--out',
          system == 'windows-x64' && signed ? folder.path : cache.path,
          '--source-commit',
          from,
          if (launcher != null) ...['--launcher', launcher],
        ]);
        expect(run.exitCode, 0, reason: '$run');
      }

      final exe = fakePe(imports: ['KERNEL32.dll', 'WS2_32.dll']);
      pack('windows-x64', 'immuch360-av2.exe', exe);
      if (signed) {
        final signedExe = File(p.join(root.path, 'immuch360-av2.exe'))..writeAsBytesSync(_signedPe(exe));
        final run = build([
          'signed',
          '--system',
          'windows-x64',
          '--archive',
          p.join(root.path, 'windows-x64', names['windows-x64']),
          '--program',
          signedExe.path,
          '--out',
          cache.path,
        ]);
        expect(run.exitCode, 0, reason: '$run');
        File(p.join(cache.path, 'SHA256SUMS')).deleteSync();
      }
      final launcher = File(p.join(root.path, 'immuch360-run'))..writeAsBytesSync(_elf(['libc.so.6']));
      pack(
        'linux-x64',
        'immuch360-av2',
        _elf(['libc.so.6', 'libpthread.so.0']),
        launcher: launcher.path,
        from: linuxCommit,
      );
      pack(
        'macos-universal',
        'immuch360-av2',
        _fatMachO([
          (0x0100000C, _thinMachO(0x0100000C, [systemLibrary])),
          (0x01000007, _thinMachO(0x01000007, [systemLibrary])),
        ]),
      );
      return cache;
    }

    /// A copy of the catalogue of the app and the place of a record, for --write
    (String, String) catalogueCopy() {
      final root = tree({});
      final catalogue = p.join(root.path, 'ai_components_manifest.dart');
      File(
        p.join(repositoryRoot, 'mobile', 'lib', 'domain', 'models', 'ai_immersive', 'ai_components_manifest.dart'),
      ).copySync(catalogue);
      return (catalogue, p.join(root.path, 'av2-decoder-1.json'));
    }

    Future<ScriptRun> publish(
      Directory cache,
      String out, {
      required (String, String) copy,
      List<String> extra = const [],
      Map<String, String> environment = const {},
    }) => runCiScriptAsync('av2/publish_av2_decoder.py', [
      '--cache',
      cache.path,
      '--out',
      out,
      '--catalogue',
      copy.$1,
      '--record',
      copy.$2,
      '--date',
      '2026-11-04',
      ...extra,
    ], environment: environment);

    test('makes the files of av2-decoder-1 from the three archives and prints the entries of the catalogue', () async {
      final cache = archives();
      final out = p.join(tree({}).path, 'release');
      final copy = catalogueCopy();
      final run = await publish(cache, out, copy: copy);
      expect(run.exitCode, 0, reason: '$run');
      for (final name in names.values) {
        expect(run.output, contains('$name: '));
        expect(File(p.join(out, name)).readAsBytesSync(), File(p.join(cache.path, name)).readAsBytesSync());
      }
      expect(run.output, contains('Files of av2-decoder-1 in $out, built from $commit:'));
      expect(run.output, contains('The entries of the catalogue (ai_components_manifest.dart):'));
      expect(run.output, contains('av2-decoder-windows-x64:\n  size: '));
      expect(run.output, contains("      path: 'immuch360-av2.exe',"));
      // The catalogue of the branch carries the archives of lot AD2, not these, and there is no record yet
      expect(run.output, contains('the catalogue or the record differs from these files: run with --write'));
      expect(run.output, contains('not published: av2-decoder-1 is created only with --publish'));
      final sums = File(p.join(out, 'SHA256SUMS')).readAsLinesSync();
      expect(
        [for (final line in sums) line.substring(66)],
        ['AV2-DECODER-LICENSES.md', ...(names.values.toList()..sort())],
      );
      final notices = File(p.join(out, 'AV2-DECODER-LICENSES.md')).readAsStringSync();
      expect(notices, contains('# av2-decoder-1: the AV2 decoder of Immuch360 Desktop'));
      expect(notices, contains('Built from https://github.com/freeKC/Immuch360/tree/$commit'));
      expect(notices, contains('| `Immuch360-av2-decoder-30140b5-1-linux-x64.zip` | `av2-decoder-linux-x64` |'));
      expect(notices, contains('### immuch360-run-MIT.txt'));
      expect(notices, contains('### AOM-PATENTS.txt'));
      expect(notices, isNot(contains(' - ')));
    });

    test(
      '--write puts the entries into the catalogue and writes the record, which the gate then takes anywhere',
      () async {
        final cache = archives();
        final out = p.join(tree({}).path, 'release');
        final copy = catalogueCopy();
        final run = await publish(cache, out, copy: copy, extra: ['--write']);
        expect(run.exitCode, 0, reason: '$run');
        expect(run.output, contains('the catalogue and the record of the release agree with these files'));
        final record = jsonDecode(File(copy.$2).readAsStringSync()) as Map<String, dynamic>;
        expect(record['tag'], 'av2-decoder-1');
        expect(record['commit'], commit);
        final archivesOf = record['archives'] as Map<String, dynamic>;
        expect(archivesOf.keys.toSet(), {
          'av2-decoder-windows-x64',
          'av2-decoder-linux-x64',
          'av2-decoder-macos-universal',
        });
        final catalogue = File(copy.$1).readAsStringSync();
        for (final entry in archivesOf.values.cast<Map<String, dynamic>>()) {
          expect(catalogue, contains("  sha256: '${entry['sha256']}',"));
          expect(catalogue, contains('  size: ${entry['size']},'));
        }
        // The gate of the catalogue, on the phone branch: sums equal to the record pass, others fail
        ScriptRun gate(String record) => runCiScript(
          'ai/publish_ai_components.py',
          ['--check', '--catalogue', copy.$1, '--av2-record', record],
          environment: {'GITHUB_REF_NAME': 'immuch360'},
        );
        final passed = gate(copy.$2);
        expect(passed.exitCode, 0, reason: '$passed');
        expect(
          passed.output,
          contains('the AV2 decoder carries the archives of av2-decoder-1 as its record gives them'),
        );
        final other = File(p.join(tree({}).path, 'other.json'))
          ..writeAsStringSync(
            jsonEncode({
              ...record,
              'archives': {
                ...archivesOf,
                'av2-decoder-linux-x64': {...archivesOf['av2-decoder-linux-x64'] as Map<String, dynamic>, 'size': 1},
              },
            }),
          );
        final refused = gate(other.path);
        expect(refused.exitCode, 1, reason: '$refused');
        expect(refused.output, contains('av2-decoder-linux-x64: the catalogue has'));
        // Without a record, as on this branch until av2-decoder-1 is made: the sums are refused there
        final none = gate(p.join(tree({}).path, 'none.json'));
        expect(none.exitCode, 1, reason: '$none');
        expect(none.output, contains('the AV2 decoder carries sums'));
      },
    );

    test('an unsigned Windows program, or archives of two commits, are never published', () async {
      final copy = catalogueCopy();
      final unsigned = await publish(
        archives(signed: false),
        p.join(tree({}).path, 'release'),
        copy: copy,
        extra: ['--write', '--publish'],
        environment: {'GH_TOKEN': token},
      );
      expect(unsigned.exitCode, 1, reason: '$unsigned');
      expect(unsigned.output, contains('its program is not signed'));
      expect(unsigned.output, isNot(contains('draft made')));
      final mixed = await publish(
        archives(linuxCommit: 'fedcba9876543210fedcba9876543210fedcba98'),
        p.join(tree({}).path, 'release'),
        copy: catalogueCopy(),
      );
      expect(mixed.exitCode, 1, reason: '$mixed');
      expect(mixed.output, contains('not one commit'));
    });

    test('--dry-run reads GitHub only; --publish makes a prerelease that is never latest, once', () async {
      final github = _FakeGitHub(token);
      await github.start();
      addTearDown(github.stop);
      final cache = archives();
      final copy = catalogueCopy();
      final out = p.join(tree({}).path, 'release');
      final environment = {'GH_TOKEN': token};
      final api = ['--api', github.base, '--repo', 'owner/repo'];
      expect((await publish(cache, out, copy: copy, extra: ['--write'])).exitCode, 0);

      final dry = await publish(cache, out, copy: copy, extra: [...api, '--dry-run'], environment: environment);
      expect(dry.exitCode, 0, reason: '$dry');
      expect(dry.output, contains('dry run: --publish would send, on owner/repo:'));
      expect(dry.output, contains('"tag_name": "av2-decoder-1", "target_commitish": "$commit"'));
      expect(dry.output, contains('dry run: nothing was written to GitHub'));
      expect(github.requests.where((request) => !request.startsWith('GET ')), isEmpty);

      final made = await publish(cache, out, copy: copy, extra: [...api, '--publish'], environment: environment);
      expect(made.exitCode, 0, reason: '$made');
      expect(made.output, contains('published as a prerelease'));
      expect(github.created!['prerelease'], isTrue);
      expect(github.created!['draft'], isTrue);
      expect(github.created!['make_latest'], 'false');
      expect(github.created!['target_commitish'], commit);
      expect(github.uploaded.keys.toSet(), {...names.values, 'AV2-DECODER-LICENSES.md', 'SHA256SUMS'});
      expect(github.patched, {'draft': false, 'prerelease': true, 'make_latest': 'false'});
      expect(made.output, isNot(contains(token)));

      final again = await publish(cache, out, copy: copy, extra: [...api, '--publish'], environment: environment);
      expect(again.exitCode, 1, reason: '$again');
      expect(again.output, contains('av2-decoder-1 exists already on owner/repo'));
    });

    test('--from-run takes the three archives of the run through the API, the token sent to the API only', () async {
      final github = _FakeGitHub(token);
      await github.start();
      addTearDown(github.stop);
      final cache = archives();
      github.artifacts = {for (final name in names.values) name: File(p.join(cache.path, name)).readAsBytesSync()};
      github.headSha = commit;
      final run = await publish(
        Directory(p.join(tree({}).path, 'empty'))..createSync(),
        p.join(tree({}).path, 'release'),
        copy: catalogueCopy(),
        extra: ['--api', github.base, '--repo', 'owner/repo', '--from-run', '77'],
        environment: {'GH_TOKEN': token},
      );
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('run 77: Immuch360 Desktop release on feat-av2 at $commit'));
      for (final name in names.values) {
        expect(run.output, contains('$name: '));
      }
      expect(github.storageAuthorizations, everyElement(isNull));
      expect(github.storageAuthorizations, hasLength(3));
      // A run at another commit than its archives is refused
      github.headSha = 'fedcba9876543210fedcba9876543210fedcba98';
      final moved = await publish(
        Directory(p.join(tree({}).path, 'empty'))..createSync(),
        p.join(tree({}).path, 'release'),
        copy: catalogueCopy(),
        extra: ['--api', github.base, '--repo', 'owner/repo', '--from-run', '77'],
        environment: {'GH_TOKEN': token},
      );
      expect(moved.exitCode, 1, reason: '$moved');
      expect(moved.output, contains('its archives were built from $commit'));
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
