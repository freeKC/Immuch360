// The Plex client against a real Plex Media Server, skipped unless IMMUCH_NET_TESTS=1, IMMUCH_PLEX_URL (the
// https://<ipv4-dashes>.<hash>.plex.direct:<port> address of the server, outside home) and IMMUCH_PLEX_TOKEN are set.
// IMMUCH_PLEX_LOCAL (host:port on the local network) adds the address at home and the GDM check;
// IMMUCH_PLEX_GDM_HOSTS (comma separated) adds hosts to that check. The test reads these variables only: the shell
// loads them from the secrets file, which never goes into the repository.
//
// Read only: GETs of the server's own API, one of them with a wrong token. What it prints is counts, statuses,
// booleans, kinds and header names: never the token, an address, a hash, a title or a path.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/gdm.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_direct.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_pairing.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_token.dart';

void _report(String line) => stdout.writeln('plex: $line');

List<String> _list(String? value) =>
    (value ?? '').split(',').map((part) => part.trim()).where((part) => part.isNotEmpty).toList();

void main() {
  final environment = Platform.environment;
  final url = environment['IMMUCH_PLEX_URL'] ?? '';
  final token = environment['IMMUCH_PLEX_TOKEN'] ?? '';
  final local = environment['IMMUCH_PLEX_LOCAL'] ?? '';
  final enabled = environment['IMMUCH_NET_TESTS'] == '1' && url.isNotEmpty && token.isNotEmpty;
  final skip = enabled ? false : 'needs IMMUCH_NET_TESTS=1, IMMUCH_PLEX_URL and IMMUCH_PLEX_TOKEN';
  final skipLocal = !enabled ? skip : (local.isEmpty ? 'needs IMMUCH_PLEX_LOCAL' : false);

  late PlexAddress public;
  late PlexServerFound outsideHome;
  PlexServerFound? atHome;
  final pairing = PlexPairing();

  /// The source as the page would save it: the address at home when known, the one of the URL outside home
  NetworkSource sourceOf({required bool withLocal}) => NetworkSource(
    id: '0123456789abcdef',
    type: NetworkSourceType.plex,
    name: 'Integration',
    host: withLocal && atHome != null ? atHome!.address.address : '',
    port: withLocal && atHome != null ? atHome!.port : null,
    useTls: true,
    discoveryId: outsideHome.machineIdentifier,
    plex: PlexServerInfo(hash: outsideHome.hash, publicHost: public.host, publicPort: public.port),
  );

  Future<PlexClient> client() async => PlexClient(
    IOClient(pinnedPlexHttpClient(outsideHome.hash)),
    token: token,
    clientIdentifier: await plexClientIdentifier(),
  );

  Uri base() => atHome != null
      ? plexDirectUri(atHome!.address, atHome!.port, atHome!.hash)
      : plexDirectUri(outsideHome.address, outsideHome.port, outsideHome.hash);

  setUpAll(() async {
    if (!enabled) {
      return;
    }
    public = parsePlexAddress(url);
    outsideHome = await pairing.lookUp(public);
    if (local.isNotEmpty) {
      atHome = await pairing.lookUp(parsePlexAddress(local), knownHash: outsideHome.hash);
    }
  });

  test('1. /identity through the pinned client, at both addresses', () {
    _report(
      'machine id of ${outsideHome.machineIdentifier.length} hex digits, version told: ${outsideHome.version != null}',
    );
    // Booleans only: a failing comparison of values would print them
    expect(outsideHome.hash == public.hash, isTrue, reason: 'the hash of the URL is the one of the certificate');
    expect(outsideHome.isLocal, isFalse);
    final home = atHome;
    if (home != null) {
      _report(
        'at home: same machine id ${home.machineIdentifier == outsideHome.machineIdentifier}, local ${home.isLocal}',
      );
      expect(home.machineIdentifier == outsideHome.machineIdentifier, isTrue);
      expect(home.isLocal, isTrue);
    }
  }, skip: skip);

  test('2. the token reads the libraries, and the server tells its address outside home at home', () async {
    final check = await pairing.testToken(atHome ?? outsideHome, token);
    final kinds = <String, int>{};
    for (final section in check.sections) {
      kinds[section.type] = (kinds[section.type] ?? 0) + 1;
    }
    _report('sections shown: ${check.sections.length} $kinds, name told: ${check.serverName != null}');
    _report('address outside home told: ${check.learned != null}');
    expect(check.sections.where((s) => s.type == 'photo' || s.type == 'movie'), isNotEmpty);
  }, skip: skip);

  test('3. the file system opens at home first, and outside home without the address at home', () async {
    final remote = await PlexFileSystem.open(sourceOf(withLocal: false), token);
    addTearDown(remote.close);
    final remoteRoot = await remote.list('/');
    _report('outside home: open ${remote.isOutsideHome}, ${remoteRoot.length} sections');
    expect(remote.isOutsideHome, isTrue);
    if (atHome != null) {
      final home = await PlexFileSystem.open(sourceOf(withLocal: true), token);
      addTearDown(home.close);
      final homeRoot = await home.list('/');
      _report('at home: open ${!home.isOutsideHome}, same sections ${homeRoot.length == remoteRoot.length}');
      expect(home.isOutsideHome, isFalse);
      expect(_same(homeRoot, remoteRoot), isTrue);
    }
  }, skip: skip);

  test(
    '4. every section: the folder view answers, and pages of 2 give the same names as one page',
    () async {
      final plex = await PlexFileSystem.open(sourceOf(withLocal: true), token);
      addTearDown(plex.close);
      final paged = await PlexFileSystem.open(sourceOf(withLocal: true), token, pageSize: 2);
      addTearDown(paged.close);
      final raw = await client();
      addTearDown(raw.close);
      final sections = await raw.getJson(base().resolve('/library/sections'), parsePlexSections);
      for (final (index, section) in sections.indexed) {
        final page = await raw.getJson(
          base().resolve('/library/sections/${section.key}/folder'),
          parsePlexListing,
          headers: const {'x-plex-container-start': '0', 'x-plex-container-size': '1'},
        );
        _report('section $index (${section.type}): totalSize told ${page.totalSize != null}');
      }
      for (final (index, folder) in (await plex.list('/')).indexed) {
        final one = await plex.list(folder.path);
        final two = await paged.list(folder.path);
        _report('section $index: ${one.length} entries, the same by pages of 2: ${_same(one, two)}');
        expect(_same(one, two), isTrue);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    '5. the first video and the first photo: sizes, ranges, the raw range answer and the bridge',
    () async {
      final plex = await PlexFileSystem.open(sourceOf(withLocal: true), token);
      addTearDown(plex.close);
      final bridge = LocalMediaBridge();
      addTearDown(bridge.stop);
      await bridge.start();
      bridge.register(plex);

      final queue = [...await plex.list('/')];
      var listed = 0;
      var video = false;
      var photo = false;
      while (queue.isNotEmpty && listed < 60 && !(video && photo)) {
        final entry = queue.removeAt(0);
        if (entry.isDirectory) {
          listed++;
          queue.addAll(await plex.list(entry.path));
          continue;
        }
        final kind = entry.isVideo ? 'video' : (entry.isImage ? 'photo' : null);
        if (kind == null || (kind == 'video' && video) || (kind == 'photo' && photo)) {
          continue;
        }
        video |= kind == 'video';
        photo |= kind == 'photo';
        final stat = await plex.stat(entry.path);
        final head = await plex.readRange(entry.path, 0, 64 * 1024);
        final again = await plex.readRange(entry.path, 1000, 100);
        final consistent = head.length > 1100 && listEquals(again, head.sublist(1000, 1100));
        _report('$kind: size known ${(stat.size ?? 0) > 0}, head ${head.length} bytes, ranges consistent $consistent');
        expect(stat.size, greaterThan(0));
        expect(consistent, isTrue);

        final httpClient = HttpClient();
        addTearDown(httpClient.close);
        final request = await httpClient.getUrl(bridge.urlFor(plex.source.id, entry.path));
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=10-109');
        final response = await request.close();
        final body = await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
        _report(
          '$kind through the bridge: ${response.statusCode}, same bytes ${listEquals(body, head.sublist(10, 110))}',
        );
        expect(response.statusCode, HttpStatus.partialContent);
        expect(listEquals(body, head.sublist(10, 110)), isTrue);
      }
      _report('found a video $video, a photo $photo, after $listed folders');
      expect(video || photo, isTrue);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('6. parts and the photo transcoder take the token in the header only', () async {
    final raw = await client();
    addTearDown(raw.close);
    final file = await _firstFile(raw, base());
    expect(file, isNotNull, reason: 'a file in the first folders');
    final response = await raw.send(
      'GET',
      base().resolve(file!.partKey),
      accept: '*/*',
      headers: const {'range': 'bytes=0-99', 'accept-encoding': 'identity'},
    );
    final body = await response.stream.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    final names = response.headers.keys.toList()..sort();
    _report('part range: ${response.statusCode}, ${body.length} bytes, headers $names');
    _report('part content type: ${response.headers['content-type']}');
    expect(response.statusCode, 206);
    expect(response.headers.keys, containsAll(['content-range', 'accept-ranges', 'content-type']));
    final thumb = file.thumb;
    if (thumb != null) {
      final picture = await raw.getBytes(
        base()
            .resolve('/photo/:/transcode')
            .replace(queryParameters: {'width': '256', 'height': '256', 'minSize': '1', 'upscale': '0', 'url': thumb}),
      );
      _report('transcoder with the header token: picture ${picture != null}, JPEG ${_isJpeg(picture)}');
      expect(_isJpeg(picture), isTrue);
    }
  }, skip: skip);

  test('7. a wrong token gets 401 and an authentication error', () async {
    final wrong = PlexClient(
      IOClient(pinnedPlexHttpClient(outsideHome.hash)),
      token: 'WRONG-TOKEN-000000000',
      clientIdentifier: await plexClientIdentifier(),
    );
    addTearDown(wrong.close);
    final response = await wrong.send('GET', base().resolve('/library/sections'));
    await response.stream.drain<void>();
    _report('wrong token: ${response.statusCode}');
    expect(response.statusCode, 401);
    await expectLater(
      PlexFileSystem.open(sourceOf(withLocal: true), 'WRONG-TOKEN-000000000'),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.isAuthentication, 'isAuthentication', isTrue)),
    );
  }, skip: skip);

  test('8. /myplex/account and /:/prefs: which fields of the address outside home are there', () async {
    final raw = await client();
    addTearDown(raw.close);
    final account = await raw.getJson(base().resolve('/myplex/account'), parsePlexAccount);
    final prefs = await raw.getJson(base().resolve('/:/prefs'), (json) => parsePlexPrefs(json, outsideHome.hash));
    _report(
      'account: public address ${account?.publicAddress != null}, public port ${account?.publicPort != null}, '
      'mapping ${account?.mappingState != null}; prefs: manual port ${prefs.manualPort != null}, '
      'custom address ${prefs.customHost != null}; usable ${plexPublicAddressOf(account, prefs) != null}',
    );
    expect(account, isNotNull);
  }, skip: skip);

  test('9. the kind of the token', () {
    final pasted = parsePastedPlexToken(token);
    _report('token kind: ${pasted?.kind.name}, expiry told: ${pasted?.expires != null}');
    expect(pasted, isNotNull);
  }, skip: skip);

  test('10. GDM by unicast finds the same server', () async {
    final hosts = [local.split(':').first, ..._list(environment['IMMUCH_PLEX_GDM_HOSTS'])];
    final done = Completer<void>();
    final found = <DiscoveredServer>[];
    final subscription = const GdmProbe()(DiscoveryRequest(hosts: hosts, done: done.future)).listen(found.add);
    await Future<void>.delayed(const Duration(seconds: 3));
    done.complete();
    await subscription.cancel();
    final same = found.where((s) => s.discoveryId == outsideHome.machineIdentifier && s.plexHash == outsideHome.hash);
    _report(
      'GDM: ${found.length} answers, the same server ${same.isNotEmpty}, port told ${same.firstOrNull?.port != null}',
    );
    expect(same, isNotEmpty);
  }, skip: skipLocal);
}

bool _same(List<NetworkEntry> a, List<NetworkEntry> b) =>
    listEquals([for (final e in a) e.name], [for (final e in b) e.name]);

bool _isJpeg(Uint8List? bytes) => bytes != null && bytes.length > 3 && bytes[0] == 0xff && bytes[1] == 0xd8;

/// The first file of the first sections, a few folders down, read with the raw client
Future<PlexFileItem?> _firstFile(PlexClient raw, Uri base) async {
  final sections = await raw.getJson(base.resolve('/library/sections'), parsePlexSections);
  final keys = [for (final section in sections) '/library/sections/${section.key}/folder'];
  for (var listed = 0; keys.isNotEmpty && listed < 20; listed++) {
    final page = await raw.getJson(
      base.resolve(keys.removeAt(0)),
      parsePlexListing,
      headers: const {'x-plex-container-start': '0', 'x-plex-container-size': '50'},
    );
    final file = page.items.whereType<PlexFileItem>().firstOrNull;
    if (file != null) {
      return file;
    }
    keys.addAll([for (final folder in page.items.whereType<PlexFolderItem>()) folder.key]);
  }
  return null;
}
