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

/// The part of the GitHub API the script uses, in memory
class _FakeGitHub {
  late final HttpServer _server;
  final requests = <String>[];
  final releases = <Map<String, dynamic>>[];
  final uploads = <String, List<int>>{};
  Map<String, dynamic>? created;
  final patches = <Map<String, dynamic>>[];

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
      final found = releases.where((release) => release['tag_name'] == tag).toList();
      return found.isEmpty ? send(404, {'message': 'Not Found'}) : send(200, found.single);
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
      uploads[name] = body;
      return send(201, {'name': name, 'size': body.length, 'digest': 'sha256:${sha256.convert(body)}'});
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
      final check = runCiScript(_script, [
        '--check',
        '--sources',
        sources.path,
        '--catalogue',
        catalogue.path,
        '--licences',
        licences.path,
      ]);
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
    test('the catalogue of the app and MODEL-LICENSES.md of the repository agree, every component complete', () {
      final run = runCiScript(_script, ['--check']);

      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('6 components, each complete'));
      expect(File(_licences).readAsStringSync(), contains('Date: '));
    }, skip: skipCiScripts);

    test('says what is missing: an incomplete component, a row of MODEL-LICENSES.md', () {
      final text = File(_catalogue).readAsStringSync();
      final start = text.indexOf("  id: 'onnxruntime-1.31.0-linux-x64',");
      final size = RegExp(r'  size: \d+,').firstMatch(text.substring(start))!;
      catalogue.writeAsStringSync(text.replaceRange(start + size.start, start + size.end, '  size: null,'));
      licences.writeAsStringSync(
        File(_licences).readAsStringSync().split('\n').where((line) => !line.contains('.tflite')).join('\n'),
      );

      final run = runCiScript(_script, ['--check', '--catalogue', catalogue.path, '--licences', licences.path]);

      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('onnxruntime-1.31.0-linux-x64: incomplete in the catalogue (size None'));
      expect(run.output, contains('MODEL-LICENSES.md lacks the row | `depth_anything_v2_small.tflite`'));
    }, skip: skipCiScripts);
  });
}
