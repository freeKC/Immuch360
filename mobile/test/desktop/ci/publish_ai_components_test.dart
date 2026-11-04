// The script that makes the prerelease ai-components-1 (.github/desktop/ai/publish_ai_components.py, lot A3b): tried
// dry on small archives served at file:// addresses, made like the official ones (a ZIP for Windows with CRLF texts,
// tarballs with links, the macOS ones with "./" before each name), against a copy of the catalogue of the app; then
// its publication against a fake GitHub, and its offline check on the catalogue and MODEL-LICENSES.md of the
// repository. Nothing here reaches the network.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

const _token = 'test-token-not-a-secret';
const _script = 'ai/publish_ai_components.py';

/// --check as the gates of the desktop workflow run it, on any branch: ai-components-4 is made (lot SP14), and the sums
/// of the AV2 decoder are those of the record of av2-decoder-1 (lot AD11)
ScriptRun _check(List<String> arguments) => runCiScript(_script, ['--check', ...arguments]);

/// On feat-av2, the branch of the test build AVT (lot AD6), whose catalogue carried the sums of the AV2 decoder before
/// av2-decoder-1 was made
const _onTestBuild = {'GITHUB_REF_NAME': 'feat-av2'};

final String _catalogue = p.join(
  repositoryRoot,
  'mobile',
  'lib',
  'domain',
  'models',
  'ai_immersive',
  'ai_components_manifest.dart',
);
final String _licences = p.join(repositoryRoot, 'licenses', 'ai-components', 'MODEL-LICENSES.md');

/// Writes the four archives and the two models of the tests in [folder], made by Python like the official ones; returns
/// the content of --sources (name -> url, size, sha256) and the bytes of each library by component id
Future<({Map<String, dynamic> sources, Map<String, List<int>> libraries})> _officialFiles(
  Directory folder, {
  String windowsNotices = 'Notices 1.31.0\r\nprotobuf: BSD-3-Clause\r\n',
}) async {
  final libraries = {
    'onnxruntime-1.31.0-win-x64': utf8.encode('MZ the dll of the tests ' * 50),
    'onnxruntime-1.31.0-linux-x64': utf8.encode('ELF the so of the tests ' * 60),
    'onnxruntime-1.31.0-osx-arm64': utf8.encode('Mach-O arm64 dylib of the tests ' * 40),
    'onnxruntime-1.23.2-osx-x86_64': utf8.encode('Mach-O x86_64 dylib of the tests ' * 30),
  };
  final spec = {
    'folder': folder.path,
    'libraries': {for (final entry in libraries.entries) entry.key: String.fromCharCodes(entry.value)},
    'windowsNotices': windowsNotices,
  };
  const make = r'''
import io, json, os, sys, tarfile, zipfile
spec = json.loads(sys.argv[1])
out = spec['folder']
lib = spec['libraries']
licence = 'MIT License\n\nCopyright (c) Microsoft Corporation\n'
notices = {'1.31.0': 'Notices 1.31.0\nprotobuf: BSD-3-Clause\n', '1.23.2': 'Notices 1.23.2\nabseil: Apache-2.0\n'}

def tgz(name, root, files, links, dot):
    with tarfile.open(os.path.join(out, name), 'w:gz') as bundle:
        for path, data in files.items():
            info = tarfile.TarInfo(('./' if dot else '') + root + '/' + path)
            info.size = len(data)
            bundle.addfile(info, io.BytesIO(data))
        for path, target in links.items():
            info = tarfile.TarInfo(('./' if dot else '') + root + '/' + path)
            info.type = tarfile.SYMTYPE
            info.linkname = target
            bundle.addfile(info)

with zipfile.ZipFile(os.path.join(out, 'onnxruntime-win-x64-1.31.0.zip'), 'w') as bundle:
    root = 'onnxruntime-win-x64-1.31.0/'
    bundle.writestr(root + 'lib/onnxruntime.dll', lib['onnxruntime-1.31.0-win-x64'].encode('latin-1'))
    bundle.writestr(root + 'lib/onnxruntime.pdb', b'debug symbols')
    bundle.writestr(root + 'LICENSE', licence.replace('\n', '\r\n'))
    bundle.writestr(root + 'ThirdPartyNotices.txt', spec['windowsNotices'])
tgz('onnxruntime-linux-x64-1.31.0.tgz', 'onnxruntime-linux-x64-1.31.0', {
    'lib/libonnxruntime.so.1.31.0': lib['onnxruntime-1.31.0-linux-x64'].encode('latin-1'),
    'LICENSE': licence.encode(), 'ThirdPartyNotices.txt': notices['1.31.0'].encode()},
    {'lib/libonnxruntime.so': 'libonnxruntime.so.1', 'lib/libonnxruntime.so.1': 'libonnxruntime.so.1.31.0'}, False)
tgz('onnxruntime-osx-arm64-1.31.0.tgz', 'onnxruntime-osx-arm64-1.31.0', {
    'lib/libonnxruntime.1.31.0.dylib': lib['onnxruntime-1.31.0-osx-arm64'].encode('latin-1'),
    'LICENSE': licence.encode(), 'ThirdPartyNotices.txt': notices['1.31.0'].encode()},
    {'lib/libonnxruntime.1.dylib': 'libonnxruntime.1.31.0.dylib'}, True)
tgz('onnxruntime-osx-x86_64-1.23.2.tgz', 'onnxruntime-osx-x86_64-1.23.2', {
    'lib/libonnxruntime.1.23.2.dylib': lib['onnxruntime-1.23.2-osx-x86_64'].encode('latin-1'),
    'LICENSE': licence.encode(), 'ThirdPartyNotices.txt': notices['1.23.2'].encode()},
    {'lib/libonnxruntime.dylib': 'libonnxruntime.1.23.2.dylib'}, True)
with open(os.path.join(out, 'model.onnx'), 'wb') as f:
    f.write(b'onnx model of the tests' * 100)
with open(os.path.join(out, 'depth_anything_v2_small.tflite'), 'wb') as f:
    f.write(b'tflite model of the tests' * 100)
''';
  final command = python!;
  final result = await Process.run(command.first, [...command.skip(1), '-c', make, jsonEncode(spec)]);
  expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');

  Map<String, dynamic> entry(String name) {
    final file = File(p.join(folder.path, name));
    final bytes = file.readAsBytesSync();
    return {'url': Uri.file(file.path).toString(), 'size': bytes.length, 'sha256': sha256.convert(bytes).toString()};
  }

  return (
    sources: {
      'archives': {
        for (final name in [
          'onnxruntime-win-x64-1.31.0.zip',
          'onnxruntime-linux-x64-1.31.0.tgz',
          'onnxruntime-osx-arm64-1.31.0.tgz',
          'onnxruntime-osx-x86_64-1.23.2.tgz',
        ])
          name: entry(name),
      },
      'models': {
        'depth-anything-v2-small-onnx': entry('model.onnx'),
        'depth-anything-v2-small-tflite': entry('depth_anything_v2_small.tflite'),
      },
    },
    libraries: libraries,
  );
}

/// The catalogue of the app with the sums of the models of the tests, so that the script accepts them
String _catalogueFor(Map<String, dynamic> sources) {
  var text = File(_catalogue).readAsStringSync();
  final models = sources['models'] as Map<String, dynamic>;
  const real = {
    'depth-anything-v2-small-onnx': (99060839, 'afb6a5c28f3b6bf1618c6e43f02073ef9dfdc70e937502d51603e57b0a1df10c'),
    'depth-anything-v2-small-tflite': (99530468, '651415f1774e02d06de946eccf2e6dbbc5f499a9e932d9de7ada3d59637d2e8e'),
  };
  for (final MapEntry(:key, :value) in real.entries) {
    final model = models[key] as Map<String, dynamic>;
    text = text
        .replaceFirst('size: ${value.$1},', 'size: ${model['size']},')
        .replaceFirst("sha256: '${value.$2}',", "sha256: '${model['sha256']}',");
  }
  return text;
}

/// The part of the GitHub API the script uses, in memory. As on GitHub, a draft has no tag yet: the list of the
/// releases shows it, GET /releases/tags does not
class _FakeGitHub {
  late final HttpServer _server;
  final requests = <String>[];
  final releases = <Map<String, dynamic>>[];
  final uploads = <String, List<int>>{};
  Map<String, dynamic>? created;
  final patches = <Map<String, dynamic>>[];

  /// The asset whose upload GitHub refuses (HTTP 500), and the one whose digest it answers wrong
  String? refusedUpload;
  String? wrongDigest;

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final body = await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
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

    if (request.headers.value('authorization') != 'Bearer $_token') {
      return send(401, {'message': 'Bad credentials'});
    }
    if (request.method == 'GET' && path == '/repos/owner/repo/releases/latest') {
      return send(200, {'tag_name': 'v3.3.0-rc.0-31'});
    }
    final tagged = RegExp(r'^/repos/owner/repo/releases/tags/(.+)$').firstMatch(path);
    if (request.method == 'GET' && tagged != null) {
      final tag = Uri.decodeComponent(tagged.group(1)!);
      final found = releases.where((release) => release['tag_name'] == tag && release['draft'] != true).toList();
      return found.isEmpty ? send(404, {'message': 'Not Found'}) : send(200, found.single);
    }
    if (request.method == 'GET' && path == '/repos/owner/repo/releases') {
      return send(200, releases);
    }
    if (request.method == 'POST' && path == '/repos/owner/repo/releases') {
      final json = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      created = Map.of(json);
      final release = {
        ...json,
        'id': 1,
        'url': '$base/repos/owner/repo/releases/1',
        'html_url': '$base/owner/repo/releases/tag/${json['tag_name']}',
        'upload_url': '$base/uploads/1/assets{?name,label}',
      };
      releases.add(release);
      return send(201, release);
    }
    if (request.method == 'POST' && path == '/uploads/1/assets') {
      final name = request.uri.queryParameters['name']!;
      if (name == refusedUpload) {
        return send(500, {'message': 'Server Error'});
      }
      uploads[name] = body;
      final digest = name == wrongDigest ? '0' * 64 : sha256.convert(body).toString();
      return send(201, {'name': name, 'size': body.length, 'digest': 'sha256:$digest'});
    }
    if (request.method == 'PATCH' && path == '/repos/owner/repo/releases/1') {
      final json = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      patches.add(json);
      releases.single.addAll(json);
      return send(200, releases.single);
    }
    return send(404, {'message': 'Not Found'});
  }
}

void main() {
  late Directory temp;
  late Directory official;
  late Directory out;
  late Directory cache;
  late File catalogue;
  late File licences;
  late File sources;
  late Map<String, List<int>> libraries;
  late Map<String, dynamic> sourceTable;

  setUp(() async {
    if (skipCiScripts != false) {
      return;
    }
    temp = Directory.systemTemp.createTempSync('publish_ai_components_test');
    official = Directory(p.join(temp.path, 'official'))..createSync();
    out = Directory(p.join(temp.path, 'out'));
    cache = Directory(p.join(temp.path, 'cache'));
    final made = await _officialFiles(official);
    libraries = made.libraries;
    sourceTable = made.sources;
    sources = File(p.join(temp.path, 'sources.json'))..writeAsStringSync(jsonEncode(sourceTable));
    catalogue = File(p.join(temp.path, 'ai_components_manifest.dart'))..writeAsStringSync(_catalogueFor(sourceTable));
    licences = File(p.join(temp.path, 'MODEL-LICENSES.md'));
  });

  tearDown(() {
    if (skipCiScripts == false) {
      temp.deleteSync(recursive: true);
    }
  });

  List<String> arguments({bool write = false, List<String> extra = const []}) => [
    '--out',
    out.path,
    '--cache',
    cache.path,
    '--sources',
    sources.path,
    '--catalogue',
    catalogue.path,
    '--licences',
    licences.path,
    '--date',
    '2026-10-27',
    if (write) '--write',
    ...extra,
  ];

  /// The entry of [id] in the catalogue copy, from its first line to its end
  String entryOf(String id) {
    final text = catalogue.readAsStringSync();
    final start = text.indexOf("  id: '$id',");
    return text.substring(start, text.indexOf('\n);', start));
  }

  group('publish_ai_components.py, dry', () {
    test('makes the files of the release from the official archives and writes the catalogue entries', () {
      final run = runCiScript(_script, arguments(write: true));
      expect(run.exitCode, 0, reason: '$run');

      // Each library, gzip compressed without name nor date, unpacks to the bytes of its archive
      const assets = {
        'onnxruntime-1.31.0-win-x64': 'onnxruntime-1.31.0-win-x64.dll.gz',
        'onnxruntime-1.31.0-linux-x64': 'onnxruntime-1.31.0-linux-x64.so.gz',
        'onnxruntime-1.31.0-osx-arm64': 'onnxruntime-1.31.0-osx-arm64.dylib.gz',
        'onnxruntime-1.23.2-osx-x86_64': 'onnxruntime-1.23.2-osx-x86_64.dylib.gz',
      };
      for (final MapEntry(key: id, value: asset) in assets.entries) {
        final packed = File(p.join(out.path, asset)).readAsBytesSync();
        expect(gzip.decode(packed), libraries[id], reason: asset);
        expect(packed.sublist(3, 8), [0, 0, 0, 0, 0], reason: '$asset: no name, no date');
        final library = libraries[id]!;
        final entry = entryOf(id);
        expect(entry, contains('  size: ${library.length},\n'));
        expect(entry, contains("  sha256: '${sha256.convert(library)}',\n"));
        expect(entry, contains('  downloadSize: ${packed.length},\n'));
        expect(run.output, contains('${library.length} bytes, SHA-256 ${sha256.convert(library)}'));
      }

      // The texts of each version, the LF copy; the notices named in the catalogue with their size and sum
      final notices1310 = File(p.join(out.path, 'onnxruntime-1.31.0-ThirdPartyNotices.txt')).readAsStringSync();
      expect(notices1310, 'Notices 1.31.0\nprotobuf: BSD-3-Clause\n');
      final licence = File(p.join(out.path, 'onnxruntime-1.23.2-LICENSE.txt')).readAsStringSync();
      expect(licence, startsWith('MIT License\n'));
      final text = catalogue.readAsStringSync();
      expect(
        text,
        contains("  assetName: 'onnxruntime-1.31.0-ThirdPartyNotices.txt',\n  size: ${notices1310.length},"),
      );
      expect(text, contains("  sha256: '${sha256.convert(utf8.encode(notices1310))}',"));

      // The models copied as they are; SHA256SUMS names every file of the release
      expect(
        File(p.join(out.path, 'depth_anything_v2_small.onnx')).readAsBytesSync(),
        File(p.join(official.path, 'model.onnx')).readAsBytesSync(),
      );
      final sums = File(p.join(out.path, 'SHA256SUMS')).readAsLinesSync();
      final released = out.listSync().whereType<File>().map((file) => p.basename(file.path)).toSet()
        ..remove('SHA256SUMS');
      expect(sums.map((line) => line.split('  ').last).toSet(), released);
      for (final line in sums) {
        final [sum, name] = line.split('  ');
        expect(sha256.convert(File(p.join(out.path, name)).readAsBytesSync()).toString(), sum, reason: name);
      }
      expect(released, hasLength(11));

      // MODEL-LICENSES.md, dated, in the repository and in the release
      expect(licences.readAsStringSync(), File(p.join(out.path, 'MODEL-LICENSES.md')).readAsStringSync());
      expect(licences.readAsStringSync(), contains('Date: 2026-10-27.'));
      expect(licences.readAsStringSync(), contains('CC-BY-NC-4.0'));

      // The archives went to the cache; nothing was published
      expect(File(p.join(cache.path, 'onnxruntime-win-x64-1.31.0.zip')).existsSync(), isTrue);
      expect(run.output, contains('not published: ai-components-1 is created only with --publish'));

      // The offline check agrees with what was written
      final check = _check(['--sources', sources.path, '--catalogue', catalogue.path, '--licences', licences.path]);
      expect(check.exitCode, 0, reason: '$check');
    }, skip: skipCiScripts);

    test('a second run finds the official files in the cache, makes the same bytes and finds the catalogue right', () {
      expect(runCiScript(_script, arguments(write: true)).exitCode, 0);
      final first = File(p.join(out.path, 'SHA256SUMS')).readAsStringSync();
      final before = catalogue.readAsStringSync();
      for (final file in official.listSync().whereType<File>()) {
        file.deleteSync();
      }

      final run = runCiScript(_script, arguments());

      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('onnxruntime-linux-x64-1.31.0.tgz: found in'));
      expect(run.output, contains('the catalogue and MODEL-LICENSES.md of the repository agree with these files'));
      expect(File(p.join(out.path, 'SHA256SUMS')).readAsStringSync(), first);
      expect(catalogue.readAsStringSync(), before);
    }, skip: skipCiScripts);

    test('without --write the catalogue is only compared, and the difference said', () {
      final before = catalogue.readAsStringSync();

      final run = runCiScript(_script, arguments());

      expect(run.exitCode, 0, reason: '$run');
      final library = libraries['onnxruntime-1.31.0-win-x64']!;
      expect(run.output, contains('onnxruntime-1.31.0-win-x64: the catalogue says size '));
      expect(run.output, contains('the files give ${library.length}, ${sha256.convert(library)}'));
      expect(run.output, contains('run with --write'));
      expect(catalogue.readAsStringSync(), before);
      expect(licences.existsSync(), isFalse);
    }, skip: skipCiScripts);

    test('an archive with another SHA-256 than the official one stops everything and is not kept', () {
      File(p.join(official.path, 'onnxruntime-osx-arm64-1.31.0.tgz')).writeAsStringSync('an error page');

      final run = runCiScript(_script, arguments(write: true));

      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('onnxruntime-osx-arm64-1.31.0.tgz: 13 bytes'));
      expect(run.output, contains('Deleted.'));
      expect(
        cache.listSync().map((entity) => p.basename(entity.path)),
        isNot(contains(startsWith('onnxruntime-osx-arm64'))),
      );
      expect(catalogue.readAsStringSync(), _catalogueFor(sourceTable));
      expect(licences.existsSync(), isFalse);
    }, skip: skipCiScripts);

    test('notices that differ between two archives of a version stop the run', () async {
      final made = await _officialFiles(official, windowsNotices: 'Other notices\r\n');
      sources.writeAsStringSync(jsonEncode(made.sources));

      final run = runCiScript(_script, arguments(write: true));

      expect(run.exitCode, 1, reason: '$run');
      expect(
        run.output,
        contains('its ThirdPartyNotices.txt differs from the one of onnxruntime-linux-x64-1.31.0.tgz'),
      );
    }, skip: skipCiScripts);

    test('a model whose sums are not those of the catalogue stops the run', () {
      catalogue.writeAsStringSync(File(_catalogue).readAsStringSync());

      final run = runCiScript(_script, arguments(write: true));

      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('depth-anything-v2-small-onnx: the catalogue says 99060839 bytes'));
    }, skip: skipCiScripts);
  });

  group('publish_ai_components.py --publish', () {
    late _FakeGitHub github;

    setUp(() async {
      github = _FakeGitHub();
      await github.start();
    });

    tearDown(() => github.stop());

    List<String> publishing({bool write = true}) =>
        arguments(write: write, extra: ['--publish', '--repo', 'owner/repo', '--api', github.base]);

    test('makes a draft, uploads every file, then publishes it as a prerelease that is never the latest', () async {
      final run = await runCiScriptAsync(_script, publishing(), environment: {'GH_TOKEN': _token});

      expect(run.exitCode, 0, reason: '$run');
      expect(github.created, containsPair('tag_name', 'ai-components-1'));
      expect(github.created, containsPair('draft', true));
      expect(github.created, containsPair('prerelease', true));
      expect(github.created, containsPair('make_latest', 'false'));
      expect(github.patches.single, {'draft': false, 'prerelease': true, 'make_latest': 'false'});
      final files = out.listSync().whereType<File>().map((file) => p.basename(file.path)).toSet();
      expect(github.uploads.keys.toSet(), files);
      for (final name in files) {
        expect(github.uploads[name], File(p.join(out.path, name)).readAsBytesSync(), reason: name);
      }
      // The draft is published only once every file is there, and the latest release checked after
      expect(
        github.requests.indexOf('PATCH /repos/owner/repo/releases/1'),
        greaterThan(github.requests.lastIndexOf('POST /uploads/1/assets')),
      );
      expect(github.requests.last, 'GET /repos/owner/repo/releases/latest');
      expect(run.output, contains('published as a prerelease'));
      expect(run.output, isNot(contains(_token)));
    }, skip: skipCiScripts);

    test('a release that exists already is never touched', () async {
      expect((await runCiScriptAsync(_script, publishing(), environment: {'GH_TOKEN': _token})).exitCode, 0);
      github.requests.clear();

      final run = await runCiScriptAsync(_script, publishing(), environment: {'GH_TOKEN': _token});

      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('ai-components-1 exists already on owner/repo: nothing is changed'));
      expect(github.requests, ['GET /repos/owner/repo/releases/tags/ai-components-1']);
    }, skip: skipCiScripts);

    test('GitHub holding another digest stops it: no publication, the draft stays and its address is said', () async {
      github.wrongDigest = 'depth_anything_v2_small.onnx';

      final run = await runCiScriptAsync(_script, publishing(), environment: {'GH_TOKEN': _token});

      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('depth_anything_v2_small.onnx: GitHub holds '));
      expect(run.output, contains('sha256:${'0' * 64}'));
      expect(run.output, contains('A draft is left at ${github.base}/owner/repo/releases/tag/ai-components-1'));
      expect(github.patches, isEmpty);
      expect(github.releases.single['draft'], isTrue);
      expect(github.requests, isNot(contains('GET /repos/owner/repo/releases/latest')));
    }, skip: skipCiScripts);

    test('an upload refused leaves a draft, said with its address; the next run makes no second draft', () async {
      github.refusedUpload = 'SHA256SUMS';

      final first = await runCiScriptAsync(_script, publishing(), environment: {'GH_TOKEN': _token});

      expect(first.exitCode, 1, reason: '$first');
      expect(first.output, contains('HTTP 500'));
      final draft = '${github.base}/owner/repo/releases/tag/ai-components-1';
      expect(first.output, contains('A draft is left at $draft: delete it by hand before the next run.'));
      expect(github.patches, isEmpty);

      github
        ..refusedUpload = null
        ..requests.clear();
      final second = await runCiScriptAsync(_script, publishing(), environment: {'GH_TOKEN': _token});

      expect(second.exitCode, 1, reason: '$second');
      expect(second.output, contains('a draft of ai-components-1 exists already on owner/repo: $draft.'));
      expect(github.requests, [
        'GET /repos/owner/repo/releases/tags/ai-components-1',
        'GET /repos/owner/repo/releases',
      ]);
      expect(github.releases, hasLength(1));
    }, skip: skipCiScripts);

    test('refused, without a request, when the catalogue does not name these files', () async {
      final run = await runCiScriptAsync(_script, publishing(write: false), environment: {'GH_TOKEN': _token});

      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('not published: ai-components-1 must carry the files the catalogue names'));
      expect(github.requests, isEmpty);
    }, skip: skipCiScripts);

    test('refused without a token, before anything is made', () async {
      final run = await runCiScriptAsync(_script, publishing(), environment: {'GH_TOKEN': '', 'GITHUB_TOKEN': ''});

      expect(run.exitCode, 2, reason: '$run');
      expect(run.output, contains('no token'));
      expect(out.existsSync(), isFalse);
      expect(github.requests, isEmpty);
    }, skip: skipCiScripts);
  });

  group('publish_ai_components.py --check', () {
    test('refuses a component whose licence this project does not allow', () {
      final text = File(_catalogue).readAsStringSync();
      final start = text.indexOf("  id: 'depth-anything-v2-small-onnx',");
      final licence = text.indexOf("  licence: 'Apache-2.0',", start);
      catalogue.writeAsStringSync(text.replaceRange(licence, licence + 24, "  licence: 'CC-BY-NC-4.0',"));

      final run = _check(['--catalogue', catalogue.path]);

      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('depth-anything-v2-small-onnx: licence CC-BY-NC-4.0 is not one this project allows'));
    }, skip: skipCiScripts);

    test('the catalogue of the app and MODEL-LICENSES.md of the repository agree, every component complete', () {
      final run = _check([]);

      expect(run.exitCode, 0, reason: '$run');
      expect(
        run.output,
        contains('20 components in ai-components-1, ai-components-2, ai-components-3, ai-components-4, each complete'),
      );
      // The archives of av2-decoder-1, as its record gives them (publish_av2_decoder.py --write, lot AD11)
      expect(
        run.output,
        contains(
          'the AV2 decoder carries the archives of av2-decoder-1 as its record gives them (run 41877478541, commit '
          '592c66c4fe16b147f29386106c2af760be08e5d5)',
        ),
      );
      expect(File(_licences).readAsStringSync(), contains('Date: '));
    }, skip: skipCiScripts);

    test('holds the AV2 decoder to the rules of an archive: all its sums or none, its release, BSD-2-Clause', () {
      final text = File(_catalogue).readAsStringSync();
      final linux = text.indexOf("  id: 'av2-decoder-linux-x64',");
      final mac = text.indexOf("  id: 'av2-decoder-macos-universal',");
      // From the end of the file back, so that each place found stays where it is
      final changes = [
        (
          text.indexOf('  releaseTag: av2DecoderReleaseTag,', mac),
          '  releaseTag: av2DecoderReleaseTag,',
          "  releaseTag: 'ai-components-3',",
        ),
        (
          text.indexOf("  licence: 'BSD-2-Clause',", linux),
          "  licence: 'BSD-2-Clause',",
          "  licence: 'GPL-2.0-or-later',",
        ),
        // The sum of the Linux archive taken out, its size and files left
        (
          text.indexOf("  sha256: 'c3cc7d80a5a3c2e32aa32fc1977631d938a8bd8c0945a67b293de1c3edcd2832',", linux),
          "  sha256: 'c3cc7d80a5a3c2e32aa32fc1977631d938a8bd8c0945a67b293de1c3edcd2832',",
          '  sha256: null,',
        ),
      ];
      var changed = text;
      for (final (at, old, replacement) in changes) {
        expect(at, greaterThan(linux));
        changed = changed.replaceRange(at, at + old.length, replacement);
      }
      catalogue.writeAsStringSync(changed);

      final run = _check(['--catalogue', catalogue.path]);

      expect(run.exitCode, 1, reason: '$run');
      expect(
        run.output,
        contains('av2-decoder-linux-x64: incomplete in the catalogue (size 953204, sha256 None, 11 files)'),
      );
      expect(
        run.output,
        contains('av2-decoder-linux-x64: licence GPL-2.0-or-later, the AV2 decoder is under BSD-2-Clause'),
      );
      expect(
        run.output,
        contains('av2-decoder-macos-universal: in ai-components-3, the AV2 decoder is in av2-decoder-1'),
      );
    }, skip: skipCiScripts);

    test('the sums of the AV2 decoder are refused but on the branch of its test build until the record of '
        'av2-decoder-1, then pass on every branch', () {
      const decoders = 'av2-decoder-linux-x64, av2-decoder-macos-universal, av2-decoder-windows-x64';
      // The catalogue of the app with no record of the release, as before publish_av2_decoder.py --write
      final noRecord = ['--av2-record', p.join(catalogue.parent.path, 'no-av2-decoder-1.json')];
      // Merged into the phone and desktop branch
      final merged = runCiScript(
        _script,
        ['--check', ...noRecord, '--test-build', 'feat-av2'],
        environment: const {'GITHUB_REF_NAME': 'immuch360'},
      );
      expect(merged.exitCode, 1, reason: '$merged');
      expect(
        merged.output,
        contains('the AV2 decoder carries sums on immuch360: only feat-av2 may, before av2-decoder-1 is made'),
      );
      // Taken by a branch made from the test build
      final taken = runCiScript(
        _script,
        ['--check', ...noRecord, '--test-build', 'feat-av2'],
        environment: const {'GITHUB_REF_NAME': 'feat-av2-ad7'},
      );
      expect(taken.exitCode, 1, reason: '$taken');
      expect(taken.output, contains('the AV2 decoder carries sums on feat-av2-ad7'));
      // On the branch itself, but without the gates saying it is the test build, or naming another branch
      final unnamed = runCiScript(_script, ['--check', ...noRecord], environment: _onTestBuild);
      expect(unnamed.exitCode, 1, reason: '$unnamed');
      expect(unnamed.output, contains('the AV2 decoder carries sums ($decoders) with no --test-build'));
      final other = runCiScript(_script, [
        '--check',
        ...noRecord,
        '--test-build',
        'immuch360',
      ], environment: _onTestBuild);
      expect(other.exitCode, 1, reason: '$other');
      expect(other.output, contains('with --test-build immuch360'));
      // As the gates ran it on the branch of the test build
      final onTestBuild = runCiScript(_script, [
        '--check',
        ...noRecord,
        '--test-build',
        'feat-av2',
      ], environment: _onTestBuild);
      expect(onTestBuild.exitCode, 0, reason: '$onTestBuild');

      // With the record of av2-decoder-1 the same sums pass on every branch, the gates naming the test build or not
      for (final arguments in [
        ['--check', '--test-build', 'feat-av2'],
        ['--check'],
      ]) {
        for (final branch in ['immuch360', 'desktop', 'feat-av2-ad7']) {
          final recorded = runCiScript(_script, arguments, environment: {'GITHUB_REF_NAME': branch});
          expect(recorded.exitCode, 0, reason: '$branch $arguments $recorded');
          expect(recorded.output, contains('carries the archives of av2-decoder-1 as its record gives them'));
        }
      }

      // Without sums, as on immuch360 until av2-decoder-1 is made, the check passes on any branch
      final text = File(_catalogue).readAsStringSync().replaceAll('\r\n', '\n');
      var bare = text;
      for (final id in ['av2-decoder-windows-x64', 'av2-decoder-linux-x64', 'av2-decoder-macos-universal']) {
        final start = bare.indexOf("  id: '$id',");
        final end = bare.indexOf('\n);\n', start);
        final entry = bare
            .substring(start, end)
            .replaceFirst(RegExp(r'  size: \d+,'), '  size: null,')
            .replaceFirst(RegExp(r"  sha256: '[0-9a-f]{64}',"), '  sha256: null,')
            .replaceFirst(RegExp(r'\n  archiveFiles: \[.*\n  \],', dotAll: true), '');
        bare = bare.replaceRange(start, end, entry);
      }
      catalogue.writeAsStringSync(bare);
      final immuch360 = runCiScript(
        _script,
        ['--check', '--catalogue', catalogue.path, ...noRecord],
        environment: const {'GITHUB_REF_NAME': 'immuch360'},
      );
      expect(immuch360.exitCode, 0, reason: '$immuch360');
      expect(immuch360.output, contains('the AV2 decoder waits for av2-decoder-1: $decoders'));
    }, skip: skipCiScripts);

    test('says what is missing: an incomplete component, a row of MODEL-LICENSES.md', () {
      final text = File(_catalogue).readAsStringSync();
      final start = text.indexOf("  id: 'onnxruntime-1.31.0-linux-x64',");
      final size = RegExp(r'  size: \d+,').firstMatch(text.substring(start))!;
      catalogue.writeAsStringSync(text.replaceRange(start + size.start, start + size.end, '  size: null,'));
      licences.writeAsStringSync(
        File(_licences).readAsStringSync().split('\n').where((line) => !line.contains('.tflite')).join('\n'),
      );

      final run = _check(['--catalogue', catalogue.path, '--licences', licences.path]);

      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('onnxruntime-1.31.0-linux-x64: incomplete in the catalogue (size None'));
      expect(run.output, contains('MODEL-LICENSES.md lacks the row | `depth_anything_v2_small.tflite`'));
    }, skip: skipCiScripts);

    test('ai-components-4 made, a catalogue that offers the splat scenes passes on any branch', () {
      for (final branch in ['immuch360', 'desktop', 'feat-splat-maker', 'feat-splat-maker-sp9']) {
        final run = runCiScript(_script, ['--check'], environment: {'GITHUB_REF_NAME': branch});
        expect(run.exitCode, 0, reason: '$branch: $run');
        expect(
          run.output,
          contains('20 components in ai-components-1, ai-components-2, ai-components-3, ai-components-4'),
        );
      }
    }, skip: skipCiScripts);

    test('the components of the splat scenes, the four archives of ai-components-4 complete and named in '
        'MODEL-LICENSES.md, a licence allowed; held again by the app, still complete', () {
      final run = _check(['--release', 'ai-components-4']);

      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('4 components in ai-components-4, each complete'));
      // A checkout on Windows may hold CRLF line ends
      final licencesText = File(_licences).readAsStringSync().replaceAll('\r\n', '\n');
      expect(licencesText, contains('<!-- ai-components-4 -->\n## ai-components-4: splat scenes'));
      for (final asset in [
        'colmap-cpu-win-x64.zip',
        'colmap-cpu-linux-x64.zip',
        'brush-vulkan-win-x64.zip',
        'brush-vulkan-linux-x64.zip',
      ]) {
        expect(licencesText, contains('| `$asset` | `${asset.replaceAll('.zip', '')}` |'), reason: asset);
      }

      // A checkout on Windows may hold CRLF line ends; the script reads either
      final text = File(_catalogue).readAsStringSync().replaceAll('\r\n', '\n');
      const lifted = 'const aiHeldFeatureGroups = <AiFeatureGroup>{};';
      expect(text, contains(lifted));

      // The hold put back by the app: the components stay those of the release, complete
      catalogue.writeAsStringSync(
        text.replaceFirst(lifted, 'const aiHeldFeatureGroups = <AiFeatureGroup>{AiFeatureGroup.splats};'),
      );
      final held = _check(['--catalogue', catalogue.path]);
      expect(held.exitCode, 0, reason: '$held');

      // Lifted, a licence this project does not allow, and an archive given without its files
      var changed = text;
      final colmap = changed.indexOf("  id: 'colmap-cpu-win-x64',");
      final licence = changed.indexOf("  licence: 'BSD-3-Clause',", colmap);
      changed = changed.replaceRange(licence, licence + 26, "  licence: 'GPL-3.0',");
      final brush = changed.indexOf("  id: 'brush-vulkan-win-x64',");
      final files = changed.indexOf('  archiveFiles: [', brush);
      final filesEnd = changed.indexOf('\n  ],\n', files) + '\n  ],\n'.length;
      changed = changed.replaceRange(files, filesEnd, '');
      catalogue.writeAsStringSync(changed);
      final refused = _check(['--catalogue', catalogue.path]);
      expect(refused.exitCode, 1, reason: '$refused');
      expect(refused.output, contains('colmap-cpu-win-x64: licence GPL-3.0 is not one this project allows'));
      expect(refused.output, contains('brush-vulkan-win-x64: incomplete in the catalogue (size 16364150, sha256 '));
    }, skip: skipCiScripts);
  });
}
