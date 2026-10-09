// Server videos through the media bridge (design 0.2 and 2.2, plan 2.5): the player reads a bridge URL on 127.0.0.1,
// the requests to the server go through the app's client with the session, and only the originals and transcoded
// streams of assets are reachable.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/desktop/network/immich_server_file_system.dart';
import 'package:immich_mobile/desktop/video/desktop_video_sources.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:native_video_player/native_video_player.dart';

const _cookie = 'immich_access_token=SessionSecret42';

/// An Immich server that serves one video by range to a request with the session cookie, as the real one does
class _FakeServer {
  _FakeServer._(this._server, this.video);

  static Future<_FakeServer> start(Uint8List video) async =>
      _FakeServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), video).._listen();

  final HttpServer _server;
  final Uint8List video;
  final requests = <String>[];
  bool ignoreRanges = false;

  String get endpoint => 'http://127.0.0.1:${_server.port}/api';

  void _listen() {
    _server.listen((request) async {
      requests.add('${request.method} ${request.uri.path} ${request.headers.value('range') ?? ''}'.trim());
      final response = request.response;
      if (request.headers.value('cookie') != _cookie) {
        response.statusCode = HttpStatus.unauthorized;
        await response.close();
        return;
      }
      if (!RegExp(r'^/api/assets/v1/(original|video/playback)$').hasMatch(request.uri.path)) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      response.headers.set('content-type', 'video/mp4');
      response.headers.set('last-modified', HttpDate.format(DateTime.utc(2026, 9, 1)));
      final range = RegExp(r'bytes=(\d+)-(\d+)?').firstMatch(request.headers.value('range') ?? '');
      if (range == null || ignoreRanges) {
        response.contentLength = video.length;
        response.add(video);
      } else {
        final start = int.parse(range.group(1)!);
        final end = range.group(2) == null ? video.length - 1 : int.parse(range.group(2)!).clamp(0, video.length - 1);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set('content-range', 'bytes $start-$end/${video.length}');
        response.contentLength = end - start + 1;
        response.add(video.sublist(start, end + 1));
      }
      await response.close();
    });
  }

  Future<void> close() => _server.close(force: true);
}

/// What the app's HTTP stack does for the user's server: the session cookie on every request
class _SessionClient extends http.BaseClient {
  final _inner = IOClient();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['cookie'] = _cookie;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

void main() {
  final video = Uint8List.fromList(List.generate(300000, (i) => (i * 7) & 0xFF));
  late _FakeServer server;
  late _SessionClient client;
  late ImmichServerFileSystem fileSystem;

  setUp(() async {
    server = await _FakeServer.start(video);
    client = _SessionClient();
    fileSystem = ImmichServerFileSystem(endpoint: () => server.endpoint, client: () => client);
  });

  tearDown(() async {
    await fileSystem.close();
    client.close();
    await server.close();
  });

  test('the paths it serves: the original and the transcoded stream of an asset, nothing else', () {
    const endpoint = 'https://photos.example/api';
    expect(ImmichServerFileSystem.pathOf('$endpoint/assets/ab-12/original', endpoint), '/assets/ab-12/original');
    expect(
      ImmichServerFileSystem.pathOf('$endpoint/assets/ab-12/video/playback', '$endpoint/'),
      '/assets/ab-12/video/playback',
    );
    expect(ImmichServerFileSystem.pathOf('$endpoint//assets/ab-12/original', '$endpoint/'), '/assets/ab-12/original');
    expect(ImmichServerFileSystem.pathOf('$endpoint/users/me', endpoint), isNull);
    expect(ImmichServerFileSystem.pathOf('$endpoint/assets/../users/original', endpoint), isNull);
    expect(ImmichServerFileSystem.pathOf('https://other.example/api/assets/a/original', endpoint), isNull);
    expect(ImmichServerFileSystem.pathOf('$endpoint/assets/a/original', null), isNull);
  });

  test('stat tells the size, the type and the date from a one byte range', () async {
    final entry = await fileSystem.stat('/assets/v1/original');
    expect(entry.size, video.length);
    expect(entry.mimeType, 'video/mp4');
    expect(entry.modified, DateTime.utc(2026, 9, 1));
    expect(server.requests.single, 'GET /api/assets/v1/original bytes=0-0');
  });

  test('ranges are read with the session of the app', () async {
    final bytes = await fileSystem.readRange('/assets/v1/video/playback', 1000, 5000);
    expect(bytes, video.sublist(1000, 6000));
  });

  test('a server that ignores ranges still gives the bytes asked for', () async {
    server.ignoreRanges = true;
    expect((await fileSystem.stat('/assets/v1/original')).size, video.length);
    expect(await fileSystem.readRange('/assets/v1/original', 200000, 1000), video.sublist(200000, 201000));
  });

  test('a refused session, a missing asset and another path are the errors the bridge maps', () async {
    final plain = IOClient();
    final noSession = ImmichServerFileSystem(endpoint: () => server.endpoint, client: () => plain);
    addTearDown(() async {
      await noSession.close();
      plain.close();
    });
    await expectLater(
      noSession.stat('/assets/v1/original'),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.isAuthentication, 'isAuthentication', isTrue)),
    );
    await expectLater(
      fileSystem.stat('/assets/v2/original'),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
    );
    await expectLater(
      fileSystem.readRange('/users/me', 0, 10),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
    );
    expect(server.requests.where((request) => request.contains('/users/')), isEmpty, reason: 'never asked');
  });

  test('a player reads a server video through the bridge URL; neither the session nor the server is in it', () async {
    final bridge = LocalMediaBridge();
    addTearDown(bridge.stop);
    final source = await VideoSource.init(path: '${server.endpoint}/assets/v1/original', type: VideoSourceType.network);

    final url = await resolveDesktopVideoSource(
      source,
      bridge: bridge,
      serverEndpoint: server.endpoint,
      serverFileSystem: () => fileSystem,
    );

    final uri = Uri.parse(url);
    expect(uri.host, '127.0.0.1');
    expect(uri.port, isNot(Uri.parse(server.endpoint).port));
    expect(url, isNot(contains('SessionSecret42')));
    expect(url, endsWith('/immich-server/assets/v1/original'));

    // libmpv's part: a plain range request, with nothing of the session
    final player = HttpClient();
    addTearDown(() => player.close(force: true));
    final request = await player.getUrl(uri);
    request.headers.set('range', 'bytes=100-199');
    final response = await request.close();
    final body = await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    expect(response.statusCode, HttpStatus.partialContent);
    expect(body, video.sublist(100, 200));

    // The bridge serves nothing of the server but the videos
    final other = await player.getUrl(uri.replace(pathSegments: [...uri.pathSegments.take(2), 'users', 'me']));
    expect((await other.close()).statusCode, HttpStatus.notFound);
  });
}
