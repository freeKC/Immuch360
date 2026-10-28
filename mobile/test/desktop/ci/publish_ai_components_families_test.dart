// The script of the AI components (.github/desktop/ai/publish_ai_components.py) for the releases of the scenes and the
// panoramas (lot C2): small models served at file:// addresses in place of the real ones, a fake API of Hugging Face
// and of GitHub for the cards and the artifacts of the CI, parts cut small, then the offline check of the three
// releases on the catalogue and MODEL-LICENSES.md of the repository. Nothing here reaches the network.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

const _token = 'test-token-not-a-secret';
const _script = 'ai/publish_ai_components.py';

/// Parts of 1000 bytes for a file of 2048 bytes or more, in place of 1945 MiB and 2 GiB
const _small = ['--part-size', '1000', '--asset-limit', '2048'];

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

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

/// One model of the tests: its component, the repository and file the fake API answers for, its bytes
class _Model {
  _Model(this.component, this.repo, this.path, this.bytes, {this.licence = 'apache-2.0', this.url = true});

  final String component;
  final String repo;
  final String path;
  final List<int> bytes;
  final String licence;

  /// False for our export, which comes from the cache only
  final bool url;
}

List<int> _bytes(String text, int length) => utf8.encode(text * (length ~/ text.length + 1)).sublist(0, length);

final _weights = _bytes('weights of the tests ', 700);

/// The models of ai-components-2 and 3 the tests serve; two of them over 2048 bytes, cut into parts
final _models = [
  _Model(
    'moge-2-vits-normal-onnx-immuch360',
    'Ruicheng/moge-2-vits-normal',
    'model.pt',
    _bytes('our moge export ', 900),
    licence: 'mit',
    url: false,
  ),
  _Model('lama-onnx', 'Carve/LaMa-ONNX', 'lama_fp32.onnx', _bytes('lama of the tests ', 800)),
  _Model(
    'migan-512-places2-onnx',
    'andraniksargsyan/migan',
    'migan_pipeline_v2.onnx',
    _bytes('migan ', 300),
    licence: 'mit',
  ),
  _Model(
    'flux2-klein-base-4b-q4_0',
    'leejet/FLUX.2-klein-base-4B-GGUF',
    'flux-2-klein-base-4b-Q4_0.gguf',
    _bytes('klein q4 ', 2500),
  ),
  _Model('qwen3-4b-q4_k_m', 'unsloth/Qwen3-4B-GGUF', 'Qwen3-4B-Q4_K_M.gguf', _bytes('qwen3 ', 2100)),
  _Model(
    'flux2-vae',
    'black-forest-labs/FLUX.2-klein-base-4B',
    'vae/diffusion_pytorch_model.safetensors',
    _bytes('vae ', 400),
  ),
  _Model(
    'flux2-klein-4b-360-erp-lora-v1',
    'nomadoor/flux-2-klein-4B-360-erp-outpaint-lora',
    'flux-2-klein-4B-360-erp-outpaint-lora_V1.safetensors',
    _bytes('lora ', 200),
  ),
  _Model(
    'realesrgan-x4plus',
    'github:xinntao/Real-ESRGAN',
    'RealESRGAN_x4plus.pth',
    _bytes('esrgan ', 500),
    licence: 'BSD-3-Clause',
  ),
];

/// The revision the tables pin for each repository
const _revisions = {
  'Ruicheng/moge-2-vits-normal': '26b477f41595707c5db6770294c0d1721e8ed4ed',
  'Ruicheng/moge-2-vits-normal-onnx': 'e50ffda41565591092adea54c6ac83d6212e1e23',
  'Carve/LaMa-ONNX': 'c3c0c9e468934d62e79c329e35d82dd09ff8c444',
  'andraniksargsyan/migan': '406830d0fa60666da0071c342ad2fbc8f30c5c64',
  'leejet/FLUX.2-klein-base-4B-GGUF': 'd12671125306ca6b5f6db1b33ed4c80c8511a53f',
  'unsloth/Qwen3-4B-GGUF': '22c9fc8a8c7700b76a1789366280a6a5a1ad1120',
  'black-forest-labs/FLUX.2-klein-base-4B': 'a3b4f4849157f664bdbc776fd7453c2783562f4d',
  'nomadoor/flux-2-klein-4B-360-erp-outpaint-lora': '124129f3ebce357c007ffca177d19567246f8bff',
};

/// The cards of Hugging Face, the reads of GitHub and the artifacts of a run of the CI, in memory
class _FakeApis {
  late final HttpServer _server;
  final requests = <String>[];

  /// The headers each request came with, by path
  final authorizations = <String, String?>{};

  /// A licence to answer in place of the right one, by repository
  final licences = <String, String>{};

  /// The artifact of the run 77 for Windows, and whether it has expired
  List<int>? windowsArtifact;
  bool expired = false;

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add('${request.method} $path');
    authorizations[path] = request.headers.value('authorization');
    final response = request.response;
    Future<void> send(int status, [Object? json]) async {
      response.statusCode = status;
      if (json != null) {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(json));
      }
      await response.close();
    }

    final hf = RegExp(r'^/api/models/([^/]+/[^/]+)/(revision|tree)/([^/]+)(?:/(.*))?$').firstMatch(path);
    if (hf != null) {
      final repo = hf.group(1)!;
      if (_revisions[repo] != hf.group(3)) {
        return send(404, {'error': 'Revision Not Found'});
      }
      if (hf.group(2) == 'revision') {
        final model = _models.where((model) => model.repo == repo).firstOrNull;
        final licence = licences[repo] ?? model?.licence;
        return send(200, {
          'sha': hf.group(3),
          'cardData': {'license': licence},
        });
      }
      final folder = hf.group(4) ?? '';
      final entries = <Map<String, Object>>[];
      for (final model in _models.where((model) => model.repo == repo)) {
        final held = model.url ? model.bytes : _weights;
        if (p.posix.dirname(model.path) == (folder.isEmpty ? '.' : folder)) {
          entries.add({
            'type': 'file',
            'path': model.path,
            'size': held.length,
            'lfs': {'oid': _sha(held), 'size': held.length},
          });
        }
      }
      if (repo == 'Ruicheng/moge-2-vits-normal-onnx') {
        final export = _models.first.bytes;
        entries.add({
          'type': 'file',
          'path': 'model.onnx',
          'size': export.length,
          'lfs': {'oid': _sha(export), 'size': export.length},
        });
      }
      return send(200, entries);
    }
    final esrgan = _models.last;
    if (path == '/repos/xinntao/Real-ESRGAN/license') {
      return send(200, {
        'license': {'spdx_id': licences['github:xinntao/Real-ESRGAN'] ?? 'BSD-3-Clause'},
      });
    }
    if (path == '/repos/xinntao/Real-ESRGAN/releases/tags/v0.1.0') {
      return send(200, {
        'assets': [
          {'name': esrgan.path, 'size': esrgan.bytes.length},
        ],
      });
    }
    if (path.startsWith('/repos/owner/repo/actions/') && request.headers.value('authorization') != 'Bearer $_token') {
      return send(401, {'message': 'Bad credentials'});
    }
    if (path == '/repos/owner/repo/actions/runs/77/artifacts') {
      return send(200, {
        'artifacts': [
          if (windowsArtifact != null)
            {'id': 5, 'name': 'Immuch360-AI-sdcpp-0123abcd-windows-x64.zip', 'expired': expired},
          {'id': 6, 'name': 'Immuch360-Desktop-3.3.0-windows-x64', 'expired': false},
        ],
      });
    }
    if (path == '/repos/owner/repo/actions/artifacts/5/zip') {
      response.statusCode = HttpStatus.found;
      response.headers.set(HttpHeaders.locationHeader, '$base/storage/5.zip');
      return response.close();
    }
    if (path == '/storage/5.zip') {
      response.add(windowsArtifact!);
      return response.close();
    }
    return send(404, {'message': 'Not Found'});
  }
}

/// [text] with the component [id] given [size] and [sha256], and without its parts
/// [text] of the catalogue with the two engines of P2 as they were before the lot wrote them: no size, no sum, no file
/// (the run of a release that has no artifact of the CI yet, and the check that says them pending)
String _enginesPending(String catalogue) {
  // A checkout on Windows may hold CRLF line ends; the script reads either
  var text = catalogue.replaceAll('\r\n', '\n');
  for (final id in ['sd-cpp-vulkan-win-x64', 'sd-cpp-vulkan-linux-x64']) {
    final start = text.indexOf("  id: '$id',");
    final end = text.indexOf('\n);\n', start);
    var body = text.substring(start, end);
    body = body.replaceFirst(RegExp(r'  size: \d+,'), '  size: null,');
    body = body.replaceFirst(RegExp(r"  sha256: '[0-9a-f]{64}',"), '  sha256: null,');
    body = body.replaceFirst(RegExp(r'  archiveFiles: \[\n.*?\n  \],\n?', dotAll: true), '');
    text = text.replaceRange(start, end, body.endsWith('\n') ? body.substring(0, body.length - 1) : body);
  }
  return text;
}

String _withEntry(String text, String id, int size, String sha256) {
  final start = text.indexOf("  id: '$id',");
  final end = text.indexOf('\n);', start);
  var body = text.substring(start, end);
  body = body
      .replaceFirst(RegExp(r'\n  size: \d+,'), '\n  size: $size,')
      .replaceFirst(RegExp(r"\n  sha256: '[0-9a-f]+',"), "\n  sha256: '$sha256',")
      .replaceFirst(RegExp(r'\n  parts: \[\n.*?\n  \],', dotAll: true), '');
  return text.replaceRange(start, end, body);
}

/// Makes a zip at [target] with [files] (path to text), as an artifact of the CI holds them
void _zip(File target, Map<String, String> files) {
  const make = r'''
import json, sys, zipfile
files = json.loads(sys.argv[2])
with zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED) as bundle:
    for name, text in files.items():
        bundle.writestr(name, text.encode('latin-1'))
''';
  final command = python!;
  final result = Process.runSync(command.first, [...command.skip(1), '-c', make, target.path, jsonEncode(files)]);
  expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
}

/// The files of the Windows engine of the tests: a program and a library
const _windowsEngine = {'sd-cli.exe': 'MZ program of the tests', 'ggml-vulkan.dll': 'MZ library of the tests'};

void main() {
  late Directory temp;
  late Directory out;
  late Directory cache;
  late File catalogue;
  late File licences;
  late File sources;
  late _FakeApis apis;

  setUp(() async {
    if (skipCiScripts != false) {
      return;
    }
    temp = Directory.systemTemp.createTempSync('publish_ai_families_test');
    final official = Directory(p.join(temp.path, 'official'))..createSync();
    out = Directory(p.join(temp.path, 'out'));
    cache = Directory(p.join(temp.path, 'cache'))..createSync();
    final upstream = <String, Object?>{};
    var text = File(_catalogue).readAsStringSync();
    for (final model in _models) {
      final file = File(p.join(official.path, p.posix.basename(model.path)))..writeAsBytesSync(model.bytes);
      upstream[model.component] = {
        'url': model.url ? Uri.file(file.path).toString() : null,
        'size': model.bytes.length,
        'sha256': _sha(model.bytes),
        if (!model.url) 'weights': [_weights.length, _sha(_weights)],
      };
      text = _withEntry(text, model.component, model.bytes.length, _sha(model.bytes));
    }
    // Our export, made beforehand, waits in the cache under its asset name
    File(p.join(cache.path, 'moge_2_vits_normal_immuch360.onnx')).writeAsBytesSync(_models.first.bytes);
    sources = File(p.join(temp.path, 'sources.json'))..writeAsStringSync(jsonEncode({'upstream': upstream}));
    catalogue = File(p.join(temp.path, 'ai_components_manifest.dart'))..writeAsStringSync(_enginesPending(text));
    licences = File(p.join(temp.path, 'MODEL-LICENSES.md'))..writeAsStringSync(File(_licences).readAsStringSync());
    apis = _FakeApis();
    await apis.start();
  });

  tearDown(() async {
    if (skipCiScripts == false) {
      await apis.stop();
      temp.deleteSync(recursive: true);
    }
  });

  List<String> arguments(String release, {bool write = false, List<String> extra = const []}) => [
    '--release',
    release,
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
    '2026-10-28',
    '--api',
    apis.base,
    '--hf-api',
    apis.base,
    '--repo',
    'owner/repo',
    ..._small,
    if (write) '--write',
    ...extra,
  ];

  ScriptRun checkCopy(String release) => runCiScript(_script, [
    '--check',
    '--release',
    release,
    '--sources',
    sources.path,
    '--catalogue',
    catalogue.path,
    '--licences',
    licences.path,
    ..._small,
  ]);

  Set<String> released() => out.listSync().whereType<File>().map((file) => p.basename(file.path)).toSet();

  group('publish_ai_components.py, the scenes', () {
    test('reads every card, takes our export from the cache, makes the release and its section', () async {
      final run = await runCiScriptAsync(_script, arguments('ai-components-2', write: true));

      expect(run.exitCode, 0, reason: '$run');
      expect(released(), {'moge_2_vits_normal_immuch360.onnx', 'lama_fp32.onnx', 'MODEL-LICENSES.md', 'SHA256SUMS'});
      expect(File(p.join(out.path, 'lama_fp32.onnx')).readAsBytesSync(), _models[1].bytes);
      // The cards and files of each source at its revision, the weights of our export and its published twin
      expect(
        apis.requests,
        contains('GET /api/models/Carve/LaMa-ONNX/revision/c3c0c9e468934d62e79c329e35d82dd09ff8c444'),
      );
      expect(
        apis.requests,
        contains('GET /api/models/Ruicheng/moge-2-vits-normal/tree/26b477f41595707c5db6770294c0d1721e8ed4ed'),
      );
      expect(
        apis.requests,
        contains('GET /api/models/Ruicheng/moge-2-vits-normal-onnx/tree/e50ffda41565591092adea54c6ac83d6212e1e23'),
      );
      expect(apis.requests.where((request) => request.contains('migan')), isEmpty, reason: 'not in this release');
      // The sums cover every file; the section of the scenes is written, the others kept
      final sums = File(p.join(out.path, 'SHA256SUMS')).readAsLinesSync();
      expect(sums.map((line) => line.split('  ').last).toSet(), released()..remove('SHA256SUMS'));
      final text = licences.readAsStringSync();
      expect(text, File(p.join(out.path, 'MODEL-LICENSES.md')).readAsStringSync());
      expect(text, contains('Date: 2026-10-28.'));
      expect(text, contains('| `lama_fp32.onnx` | `lama-onnx` | 800 | `${_sha(_models[1].bytes)}` | Apache-2.0 |'));
      expect(text, contains('our export of https://huggingface.co/Ruicheng/moge-2-vits-normal, revision `26b477f4`'));
      expect(text, contains('<!-- ai-components-1 -->\n## ai-components-1: 3D photos'));
      expect(run.output, contains('the catalogue and MODEL-LICENSES.md of the repository agree with these files'));
      expect(run.output, contains('not published: ai-components-2 is created only with --publish'));
      expect(checkCopy('ai-components-2').exitCode, 0);
    }, skip: skipCiScripts);

    test('a card that gives another licence stops everything before a download', () async {
      apis.licences['Carve/LaMa-ONNX'] = 'cc-by-nc-4.0';

      final run = await runCiScriptAsync(_script, arguments('ai-components-2', write: true));

      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('lama-onnx: the card of Carve/LaMa-ONNX at c3c0c9e4 gives the licence cc-by-nc-4.0'));
      expect(out.existsSync() ? released() : <String>{}, isEmpty);
    }, skip: skipCiScripts);

    test('our export missing from the cache stops the run: it has no other source', () async {
      File(p.join(cache.path, 'moge_2_vits_normal_immuch360.onnx')).deleteSync();

      final run = await runCiScriptAsync(_script, arguments('ai-components-2'));

      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('our export is in no --cache folder; make it with export_moge_onnx.py'));
    }, skip: skipCiScripts);
  });

  group('publish_ai_components.py, the panoramas', () {
    test('cuts the large files into parts, writes them into the catalogue; the engines stay pending', () async {
      final run = await runCiScriptAsync(_script, arguments('ai-components-3', write: true));

      expect(run.exitCode, 0, reason: '$run');
      final klein = _models[3].bytes;
      expect(released(), containsAll(['flux-2-klein-base-4b-Q4_0.gguf.001', 'flux-2-klein-base-4b-Q4_0.gguf.003']));
      expect(released(), isNot(contains('flux-2-klein-base-4b-Q4_0.gguf')));
      expect([
        for (var i = 1; i <= 3; i++) ...File(p.join(out.path, 'flux-2-klein-base-4b-Q4_0.gguf.00$i')).readAsBytesSync(),
      ], klein);
      final text = catalogue.readAsStringSync();
      expect(
        text,
        contains(
          "  parts: [\n    AiComponentPart(\n      assetName: 'flux-2-klein-base-4b-Q4_0.gguf.001',\n"
          "      size: 1000,\n      sha256: '${_sha(klein.sublist(0, 1000))}',\n    ),",
        ),
      );
      expect(text, contains("      assetName: 'Qwen3-4B-Q4_K_M.gguf.003',\n      size: 100,"));
      expect(run.output, contains('pending: sd-cpp-vulkan-win-x64, sd-cpp-vulkan-linux-x64'));
      expect(licences.readAsStringSync(), contains('`sd-cpp-vulkan-win-x64`: pending'));
      expect(
        licences.readAsStringSync(),
        contains('| `flux-2-klein-base-4b-Q4_0.gguf.002` | 2 of 3 of `flux-2-klein-base-4b-Q4_0.gguf` | 1000 |'),
      );
      final check = checkCopy('ai-components-3');
      expect(check.exitCode, 0, reason: '$check');
      expect(check.output, contains('pending for lot P2: sd-cpp-vulkan-linux-x64, sd-cpp-vulkan-win-x64'));

      // Published only once nothing is pending
      final publishing = await runCiScriptAsync(
        _script,
        arguments('ai-components-3', extra: ['--publish']),
        environment: {'GH_TOKEN': _token},
      );
      expect(publishing.exitCode, 1, reason: '$publishing');
      expect(publishing.output, contains('not published: ai-components-3 waits for sd-cpp-vulkan-win-x64'));
      expect(
        apis.requests.where((request) => request.contains('/releases') && !request.contains('Real-ESRGAN')),
        isEmpty,
      );
    }, skip: skipCiScripts);

    test('the artifact of a run of the CI becomes our archive: its files, sums and program in the catalogue', () async {
      final artifact = File(p.join(temp.path, 'artifact.zip'));
      _zip(artifact, _windowsEngine);
      apis.windowsArtifact = artifact.readAsBytesSync();

      final run = await runCiScriptAsync(
        _script,
        arguments('ai-components-3', write: true, extra: ['--from-run', '77']),
        environment: {'GH_TOKEN': _token},
      );

      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, isNot(contains(_token)));
      // The token goes to the API, never to the storage it redirects to
      expect(apis.authorizations['/repos/owner/repo/actions/artifacts/5/zip'], 'Bearer $_token');
      expect(apis.authorizations['/storage/5.zip'], isNull);
      final archive = File(p.join(out.path, 'sd-cpp-vulkan-win-x64.zip')).readAsBytesSync();
      final text = catalogue.readAsStringSync();
      expect(text, contains("  installPath: 'engines/sd-cpp-vulkan-win-x64',\n  size: ${archive.length},\n"));
      expect(text, contains("  sha256: '${_sha(archive)}',"));
      expect(
        text,
        contains(
          "  archiveFiles: [\n    AiArchiveFile(\n      path: 'ggml-vulkan.dll',\n      size: 23,\n"
          "      sha256: '${_sha(utf8.encode(_windowsEngine['ggml-vulkan.dll']!))}',\n    ),\n"
          "    AiArchiveFile(\n      path: 'sd-cli.exe',\n      size: 23,\n"
          "      sha256: '${_sha(utf8.encode(_windowsEngine['sd-cli.exe']!))}',\n      executable: true,\n    ),\n  ],",
        ),
      );
      expect(run.output, contains('pending: sd-cpp-vulkan-linux-x64'));
      expect(licences.readAsStringSync(), contains('| `sd-cli.exe` | 23 |'));
      expect(checkCopy('ai-components-3').exitCode, 0);

      // Made again from the same artifact: the same bytes
      final again = await runCiScriptAsync(
        _script,
        arguments('ai-components-3', extra: ['--from-run', '77']),
        environment: {'GH_TOKEN': _token},
      );
      expect(again.exitCode, 0, reason: '$again');
      expect(File(p.join(out.path, 'sd-cpp-vulkan-win-x64.zip')).readAsBytesSync(), archive);
      expect(again.output, contains('the catalogue and MODEL-LICENSES.md of the repository agree with these files'));
    }, skip: skipCiScripts);

    test('an artifact with a path that goes up is refused', () async {
      _zip(File(p.join(cache.path, 'Immuch360-AI-sdcpp-0123abcd-windows-x64.zip')), {
        'sd-cli.exe': 'MZ program',
        '../evil.dll': 'MZ',
      });

      final run = await runCiScriptAsync(_script, arguments('ai-components-3'));

      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains("the engine holds '../evil.dll': not a relative path inside it"));
    }, skip: skipCiScripts);

    test('--from-run needs a token, asked before anything is made', () async {
      final run = await runCiScriptAsync(
        _script,
        arguments('ai-components-3', extra: ['--from-run', '77']),
        environment: {'GH_TOKEN': '', 'GITHUB_TOKEN': ''},
      );

      expect(run.exitCode, 2, reason: '$run');
      expect(run.output, contains('no token'));
      expect(apis.requests, isEmpty);
    }, skip: skipCiScripts);
  });

  group('publish_ai_components.py --check, the three releases', () {
    test('the catalogue of the app and MODEL-LICENSES.md agree; the engines of P2 are written, nothing pending', () {
      final run = runCiScript(_script, ['--check']);

      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('16 components in ai-components-1, ai-components-2, ai-components-3, each complete'));
      // Pending before lot P2 wrote them: the run of the panoramas above starts from such a catalogue
      expect(run.output, isNot(contains('pending')));
      for (final release in ['ai-components-1', 'ai-components-2', 'ai-components-3']) {
        expect(runCiScript(_script, ['--check', '--release', release]).exitCode, 0, reason: release);
      }
    }, skip: skipCiScripts);

    test('says what is wrong: a component in the release of another family, parts that do not add up, a section', () {
      // A checkout on Windows may hold CRLF line ends; the script reads either
      var text = File(_catalogue).readAsStringSync().replaceAll('\r\n', '\n');
      text = text.replaceFirst(
        "  features: {AiFeature.scene},\n  releaseTag: aiComponentsScenesReleaseTag,",
        "  features: {AiFeature.scene},\n  releaseTag: aiComponentsPanoramasReleaseTag,",
      );
      text = text.replaceFirst('      size: 457800992,', '      size: 457800991,');
      catalogue.writeAsStringSync(text);

      final run = runCiScript(_script, ['--check', '--catalogue', catalogue.path]);

      expect(run.exitCode, 1, reason: '$run');
      expect(
        text,
        contains(
          '  releaseTag: aiComponentsPanoramasReleaseTag,\n  officialUrls: [\n    \'https://huggingface.co/Carve',
        ),
      );
      expect(run.output, contains('lama-onnx: in ai-components-3, its family is in ai-components-2'));
      expect(run.output, contains('qwen3-4b-q4_k_m: 2497281312 bytes, so parts of 2039480320 bytes'));
      expect(
        run.output,
        contains('the section of ai-components-3 in MODEL-LICENSES.md is not what the catalogue gives'),
      );
    }, skip: skipCiScripts);

    test('an engine half written by hand is incomplete, not pending', () {
      final text = _enginesPending(File(_catalogue).readAsStringSync().replaceAll('\r\n', '\n'));
      final start = text.indexOf("  id: 'sd-cpp-vulkan-linux-x64',");
      final size = text.indexOf('  size: null,', start);
      catalogue.writeAsStringSync(text.replaceRange(size, size + 13, '  size: 1000,'));

      final run = runCiScript(_script, ['--check', '--catalogue', catalogue.path]);

      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('sd-cpp-vulkan-linux-x64: incomplete in the catalogue (size 1000, sha256 None'));
    }, skip: skipCiScripts);
  });
}
