import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

const _token = 'test-token-not-a-secret';

/// The part of the GitHub releases API that desktop_release.py uses, kept in memory: releases by tag, assets with the
/// digest GitHub gives them (or none, as for assets uploaded before GitHub kept digests), and their downloads
class _FakeGitHub {
  late final HttpServer _server;
  final releases = <Map<String, dynamic>>[];
  final _bytes = <int, List<int>>{};
  int _nextId = 1;

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Map<String, dynamic> addRelease(String tag, {String name = '', String body = ''}) {
    final id = _nextId++;
    final release = <String, dynamic>{
      'id': id,
      'tag_name': tag,
      'name': name,
      'body': body,
      'prerelease': true,
      'url': '$base/repos/owner/repo/releases/$id',
      'html_url': '$base/owner/repo/releases/tag/$tag',
      'upload_url': '$base/uploads/$id/assets{?name,label}',
      'assets': <Map<String, dynamic>>[],
    };
    releases.add(release);
    return release;
  }

  Map<String, dynamic> addAsset(Map<String, dynamic> release, String name, List<int> bytes, {bool digest = true}) {
    final id = _nextId++;
    _bytes[id] = bytes;
    final asset = <String, dynamic>{
      'id': id,
      'name': name,
      'size': bytes.length,
      'url': '$base/repos/owner/repo/releases/assets/$id',
      'browser_download_url': '$base/download/$id',
      'digest': digest ? 'sha256:${sha256.convert(bytes)}' : null,
    };
    (release['assets'] as List).add(asset);
    return asset;
  }

  List<String> assetNames(Map<String, dynamic> release) => [
    for (final asset in release['assets'] as List) (asset as Map)['name'] as String,
  ];

  String assetText(Map<String, dynamic> release, String name) {
    final asset = (release['assets'] as List).cast<Map<String, dynamic>>().firstWhere((a) => a['name'] == name);
    return utf8.decode(_bytes[asset['id'] as int]!);
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final body = await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    final response = request.response;
    Future<void> send(int status, [Object? json]) async {
      response.statusCode = status;
      if (json != null) {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(json));
      }
      await response.close();
    }

    if (path.startsWith('/download/')) {
      response.add(_bytes[int.parse(path.split('/').last)]!);
      return response.close();
    }
    if (request.headers.value('authorization') != 'Bearer $_token') {
      return send(401, {'message': 'Bad credentials'});
    }
    final tagged = RegExp(r'^/repos/owner/repo/releases/tags/(.+)$').firstMatch(path);
    final byId = RegExp(r'^/repos/owner/repo/releases/(\d+)$').firstMatch(path);
    final asset = RegExp(r'^/repos/owner/repo/releases/assets/(\d+)$').firstMatch(path);
    final upload = RegExp(r'^/uploads/(\d+)/assets$').firstMatch(path);
    Map<String, dynamic>? release(bool Function(Map<String, dynamic>) test) =>
        releases.where(test).cast<Map<String, dynamic>?>().firstWhere((_) => true, orElse: () => null);

    if (request.method == 'GET' && tagged != null) {
      final found = release((r) => r['tag_name'] == Uri.decodeComponent(tagged.group(1)!));
      return found == null ? send(404, {'message': 'Not Found'}) : send(200, found);
    }
    if (request.method == 'POST' && path == '/repos/owner/repo/releases') {
      final json = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      final created = addRelease(
        json['tag_name'] as String,
        name: json['name'] as String,
        body: json['body'] as String,
      );
      created['prerelease'] = json['prerelease'];
      created['target_commitish'] = json['target_commitish'];
      return send(201, created);
    }
    if (byId != null) {
      final found = release((r) => r['id'] == int.parse(byId.group(1)!))!;
      if (request.method == 'PATCH') {
        found.addAll(jsonDecode(utf8.decode(body)) as Map<String, dynamic>);
      }
      return send(200, found);
    }
    if (request.method == 'DELETE' && asset != null) {
      final id = int.parse(asset.group(1)!);
      for (final r in releases) {
        (r['assets'] as List).removeWhere((a) => (a as Map)['id'] == id);
      }
      return send(204);
    }
    if (request.method == 'POST' && upload != null) {
      final found = release((r) => r['id'] == int.parse(upload.group(1)!))!;
      final name = request.uri.queryParameters['name']!;
      if (assetNames(found).contains(name)) {
        return send(422, {'message': 'already_exists'});
      }
      return send(201, addAsset(found, name, body));
    }
    return send(404, {'message': 'Not Found'});
  }
}

void main() {
  final folders = <Directory>[];

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

  const label = '3.3.0-rc.0-desktop.5';
  const tag = 'desktop-v3.3.0-rc.0-5';
  const files = {
    'Immuch360-Desktop-$label-windows-x64.zip': 'zip',
    'Immuch360-Desktop-$label-windows-x64-setup.exe': 'setup',
    'Immuch360-Desktop-$label-linux-amd64.deb': 'deb',
    'Immuch360-Desktop-$label-linux-x86_64.rpm': 'rpm',
    'Immuch360-Desktop-$label-macos.zip': 'app',
    'Immuch360-Desktop-$label-macos.dmg': 'dmg',
    'Immuch360-Desktop-$label-libsmb2-sources.tar.gz': 'sources',
  };
  String line(String name, String text) => '${sha256.convert(utf8.encode(text))}  $name';

  group('desktop_release.py', () {
    test('a dry run checks the seven files of a build and writes their SHA256SUMS.txt', () {
      final root = tree(files);
      final paths = [for (final name in files.keys) p.join(root.path, name)];
      final sums = p.join(root.path, 'sums.txt');
      var run = runCiScript('desktop_release.py', ['--dry-run', '--label', label, '--sums', sums, ...paths]);
      expect(run.exitCode, 0, reason: '$run');
      // Sorted by file name, after the 64 hexadecimal digits and the two spaces
      final expected = [for (final entry in files.entries) line(entry.key, entry.value)]
        ..sort((a, b) => a.substring(66).compareTo(b.substring(66)));
      expect(File(sums).readAsStringSync(), '${expected.join('\n')}\n');

      run = runCiScript('desktop_release.py', ['--dry-run', '--label', label, ...paths.skip(1)]);
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('missing: Immuch360-Desktop-$label-windows-x64.zip'));

      writeFiles(root, {'immuch360-desktop-windows-x64-symbols.zip': 'pdb'});
      run = runCiScript('desktop_release.py', [
        '--dry-run',
        '--label',
        label,
        ...paths,
        p.join(root.path, 'immuch360-desktop-windows-x64-symbols.zip'),
      ]);
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('not a file of the build: immuch360-desktop-windows-x64-symbols.zip'));
    });

    group('against the API', () {
      late _FakeGitHub github;

      setUp(() async {
        github = _FakeGitHub();
        await github.start();
      });

      tearDown(() => github.stop());

      Future<ScriptRun> release(List<String> arguments, {String token = _token}) => runCiScriptAsync(
        'desktop_release.py',
        ['--api', github.base, '--repo', 'owner/repo', ...arguments],
        environment: {'GH_TOKEN': token, 'GITHUB_TOKEN': ''},
      );

      test('creates the pre-release of a new tag, attaches the files and SHA256SUMS.txt', () async {
        final root = tree(files);
        final run = await release([
          '--tag',
          tag,
          '--commit',
          'abc1234',
          for (final n in files.keys) p.join(root.path, n),
        ]);
        expect(run.exitCode, 0, reason: '$run');
        expect(github.releases, hasLength(1));
        final created = github.releases.single;
        expect(created['name'], 'Immuch360 Desktop 3.3.0-rc.0, desktop build 5 (preview)');
        expect(created['prerelease'], isTrue);
        expect(created['target_commitish'], 'abc1234');
        expect(created['body'], contains('The release notes follow.'));
        expect(github.assetNames(created), containsAll([...files.keys, 'SHA256SUMS.txt']));
        expect(github.assetNames(created), hasLength(8));
        final sums = github.assetText(created, 'SHA256SUMS.txt');
        for (final entry in files.entries) {
          expect(sums, contains('${line(entry.key, entry.value)}\n'));
        }
        expect(run.output, isNot(contains(_token)));
      });

      test('on a release made by hand: its notes kept, a file replaced, every asset in SHA256SUMS.txt', () async {
        final existing = github.addRelease(tag, name: 'Desktop build 5', body: 'Notes written by hand');
        github.addAsset(existing, 'Immuch360-Desktop-$label-windows-x64.zip', utf8.encode('old zip'));
        github.addAsset(existing, 'Notes.pdf', utf8.encode('pdf'));
        // An asset of before the digests, read through its download address
        github.addAsset(existing, 'Older.txt', utf8.encode('older'), digest: false);
        github.addAsset(existing, 'SHA256SUMS.txt', utf8.encode('stale'));
        final root = tree(files);

        final run = await release(['--tag', tag, for (final n in files.keys) p.join(root.path, n)]);
        expect(run.exitCode, 0, reason: '$run');
        expect(existing['name'], 'Desktop build 5');
        expect(existing['body'], 'Notes written by hand');
        expect(run.output, contains('replaced: Immuch360-Desktop-$label-windows-x64.zip'));
        expect(github.assetNames(existing), hasLength(10));
        final sums = github.assetText(existing, 'SHA256SUMS.txt');
        expect(sums, contains('${line('Immuch360-Desktop-$label-windows-x64.zip', 'zip')}\n'));
        expect(sums, contains('${line('Notes.pdf', 'pdf')}\n'));
        expect(sums, contains('${line('Older.txt', 'older')}\n'));
        expect(sums, isNot(contains('old zip')));
        expect('\n'.allMatches(sums), hasLength(9));
      });

      test('the notes of the owner replace those of a release, the files stay', () async {
        final existing = github.addRelease(tag, name: 'Immuch360 Desktop', body: 'The release notes follow.');
        github.addAsset(existing, 'Immuch360-Desktop-$label-linux-amd64.deb', utf8.encode('deb'));
        final root = tree({'notes.md': '## Desktop build 5\n'});
        final run = await release([
          '--tag',
          tag,
          '--name',
          'Immuch360 Desktop 3.3.0-rc.0, desktop build 5',
          '--notes',
          p.join(root.path, 'notes.md'),
        ]);
        expect(run.exitCode, 0, reason: '$run');
        expect(existing['body'], '## Desktop build 5\n');
        expect(existing['name'], 'Immuch360 Desktop 3.3.0-rc.0, desktop build 5');
        expect(github.assetNames(existing), ['Immuch360-Desktop-$label-linux-amd64.deb', 'SHA256SUMS.txt']);
      });

      test('refuses a tag that is not a desktop pre-release, a missing token, and never prints the token', () async {
        final root = tree(files);
        final file = p.join(root.path, files.keys.first);
        var run = await release(['--tag', 'v3.3.0-rc.0-23', file]);
        expect(run.exitCode, 2, reason: '$run');
        expect(run.output, contains('is not a desktop pre-release tag'));

        run = await release(['--tag', tag, file], token: '');
        expect(run.exitCode, 2, reason: '$run');
        expect(run.output, contains('no token'));

        run = await release(['--tag', tag, file], token: 'wrong-token-value');
        expect(run.exitCode, 1, reason: '$run');
        expect(run.output, contains('HTTP 401'));
        expect(run.output, isNot(contains('wrong-token-value')));
        expect(github.releases, isEmpty);
      });
    });
  }, skip: skipCiScripts);
}
