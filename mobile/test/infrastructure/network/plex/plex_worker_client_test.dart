// A Plex share whose client runs in the worker isolate, as the app opens them (pinnedPlexClientOffMainIsolate), against
// the fake server of the tests: its listings, its ranges, a read stopped, and a film streamed by the media bridge
// with a seek.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/infrastructure/network/isolate_http_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_direct.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_server_breaker.dart';

import 'fake_plex_server.dart';

const _source = NetworkSource(
  id: '0123456789abcdef',
  type: NetworkSourceType.plex,
  name: 'Test Plex',
  host: '192.0.2.20',
  useTls: true,
  discoveryId: plexTestMachine,
  plex: PlexServerInfo(hash: plexTestHash),
);

const _filmPart = 41;
const _filmSize = 3 * 1024 * 1024 + 17;

/// The status, a header and the body of a GET of [url], with [range]
Future<(int, String?, Uint8List)> _get(Uri url, {String? range, String header = 'cache-control'}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    if (range != null) {
      request.headers.set(HttpHeaders.rangeHeader, range);
    }
    final response = await request.close();
    final body = BytesBuilder(copy: false);
    await response.forEach(body.add);
    return (response.statusCode, response.headers.value(header), body.takeBytes());
  } finally {
    client.close(force: true);
  }
}

void main() {
  late FakePlexServer server;

  setUp(PlexServerBreakers.clear);
  setUp(() async {
    server = await FakePlexServer.start();
    server.listings['/library/sections/1/folder']!.add(plexFile(_filmPart, '/data/movies/film.mkv', _filmSize));
    server.partSizes[_filmPart] = _filmSize;
  });
  tearDown(() => server.close());

  Future<PlexFileSystem> open() async {
    final client = IsolateHttpClient(unpinnedPlexHttpClientForTests);
    final fileSystem = await PlexFileSystem.open(
      _source,
      plexTestToken,
      baseOverride: server.base,
      clientIdentifier: 'client-test-0000',
      client: client,
    );
    addTearDown(() async {
      await fileSystem.close();
      client.close();
    });
    return fileSystem;
  }

  test('the client of the app for a hash refuses what is not one', () {
    expect(() => pinnedPlexClientOffMainIsolate('not-a-hash'), throwsArgumentError);
    pinnedPlexClientOffMainIsolate(plexTestHash).close();
  });

  test('lists and reads ranges through the worker, with the headers of the app', () async {
    final plex = await open();
    expect([for (final entry in await plex.list('/')) entry.name], ['Movies', 'Photos', 'Series']);
    final whole = plexPartBytes(21, 5000);
    expect(await plex.readRange('/Movies/Holidays/beach.mp4', 100, 50), whole.sublist(100, 150));
    expect(await plex.readRange('/Movies/Holidays/beach.mp4', 4990, 100), whole.sublist(4990));
    expect(await plex.readRange('/Movies/Holidays/beach.mp4', 5000, 10), isEmpty);
    final read = server.requests.lastWhere((r) => r.path.startsWith('/library/parts/21/'));
    expect(read.headers['range'], 'bytes=4990-4999');
    expect(read.headers['x-plex-token'], plexTestToken);
  });

  test('a read stopped while the server waits ends at once, and the next one goes', () async {
    final plex = await open();
    await plex.list('/Movies');
    server.delays['/library/parts/11/1700000000/file.mp4'] = const Duration(seconds: 3);
    final abort = Completer<void>();
    final watch = Stopwatch()..start();

    final read = plex.readRange('/Movies/a.mp4', 0, 10, abort: abort.future);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    abort.complete();

    await expectLater(read, throwsA(isA<PlexRequestCancelled>()));
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    server.delays.clear();
    expect(await plex.readRange('/Movies/a.mp4', 0, 4), plexPartBytes(11, 1000).sublist(0, 4));
  });

  test('the media bridge streams a film read through the worker, then the place a seek asks', () async {
    final plex = await open();
    final bridge = LocalMediaBridge(minChunkSize: 64 * 1024, maxChunkSize: 1024 * 1024);
    addTearDown(bridge.stop);
    bridge.register(plex);
    await bridge.start();
    final url = bridge.urlFor(_source.id, '/Movies/film.mkv');
    final whole = plexPartBytes(_filmPart, _filmSize);

    final (status, cache, body) = await _get(url, range: 'bytes=1000-');
    expect(status, HttpStatus.partialContent);
    expect(cache, 'no-store');
    expect(body, whole.sublist(1000));

    final (seekStatus, range, seekBody) = await _get(url, range: 'bytes=2097152-', header: 'content-range');
    expect(seekStatus, HttpStatus.partialContent);
    expect(range, 'bytes 2097152-${_filmSize - 1}/$_filmSize');
    expect(seekBody, whole.sublist(2097152));
  });
}
