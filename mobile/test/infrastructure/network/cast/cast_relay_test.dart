// The relay a Cast device reads a Plex film from: the one time path, Range forwarded to the media bridge, the poster
// from memory, a revoked or idle path refused, nothing but GET and HEAD

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/cast/cast_relay.dart';

/// A media bridge on the loopback serving [film] with ranges, and what it was asked
class _FakeBridge {
  _FakeBridge._(this.server, this.film);

  static Future<_FakeBridge> start(Uint8List film) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bridge = _FakeBridge._(server, film);
    server.listen(bridge._serve);
    return bridge;
  }

  final HttpServer server;
  final Uint8List film;
  final List<HttpHeaders> asked = [];
  final List<Uri> paths = [];

  Uri get url => Uri.parse('http://127.0.0.1:${server.port}/bridgetoken/source-1/.item/77/film.mp4');

  Future<void> _serve(HttpRequest request) async {
    asked.add(request.headers);
    paths.add(request.uri);
    final response = request.response;
    response.headers.contentType = ContentType('video', 'mp4');
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    final range = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    var start = 0;
    var end = film.length - 1;
    if (range != null) {
      start = int.parse(range.group(1)!);
      if (range.group(2)!.isNotEmpty) {
        end = int.parse(range.group(2)!);
      }
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${film.length}');
    }
    response.headers.contentLength = end - start + 1;
    if (request.method == 'GET') {
      response.add(film.sublist(start, end + 1));
    }
    await response.close();
  }
}

void main() {
  final film = Uint8List.fromList(List<int>.generate(4096, (index) => index % 251));
  final poster = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
  late _FakeBridge bridge;
  late CastRelayServer relay;
  late HttpClient client;
  var now = DateTime.utc(2026, 11, 11, 23);

  setUp(() async {
    now = DateTime.utc(2026, 11, 11, 23);
    bridge = await _FakeBridge.start(film);
    relay = await CastRelayServer.bind('127.0.0.1', port: 0, clock: () => now);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await relay.close();
    await bridge.server.close(force: true);
  });

  Future<({int status, HttpHeaders headers, List<int> body})> get(
    Uri url, {
    String method = 'GET',
    String? range,
  }) async {
    final request = await client.openUrl(method, url);
    if (range != null) {
      request.headers.set(HttpHeaders.rangeHeader, range);
    }
    final response = await request.close();
    final body = <int>[];
    await response.forEach(body.addAll);
    return (status: response.statusCode, headers: response.headers, body: body);
  }

  CastRelayLease lease({Uint8List? withPoster}) =>
      relay.lease(CastRelayContent(film: () async => bridge.url, poster: withPoster));

  test('the film under a random path of 128 bits on the relay address, a new one per lease', () {
    final first = lease();
    final second = lease();
    expect(first.filmUrl.host, '127.0.0.1');
    expect(first.filmUrl.port, relay.port);
    expect(first.filmUrl.path, matches(RegExp(r'^/cast/[0-9a-f]{32}/film$')));
    expect(first.id, isNot(second.id));
    expect(first.filmUrl.toString(), isNot(contains('bridgetoken')));
    expect(first.posterUrl, isNull);
  });

  test('a GET with a Range is forwarded and answered with the part', () async {
    final answer = await get(lease().filmUrl, range: 'bytes=100-199');
    expect(answer.status, HttpStatus.partialContent);
    expect(answer.headers.value(HttpHeaders.contentRangeHeader), 'bytes 100-199/4096');
    expect(answer.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    expect(answer.headers.contentType?.mimeType, 'video/mp4');
    expect(answer.body, film.sublist(100, 200));
    expect(bridge.asked.single.value(HttpHeaders.rangeHeader), 'bytes=100-199');
    expect(bridge.paths.single.path, bridge.url.path);
  });

  test('a whole GET and a HEAD', () async {
    final url = lease().filmUrl;
    final whole = await get(url);
    expect(whole.status, HttpStatus.ok);
    expect(whole.body, film);
    final head = await get(url, method: 'HEAD');
    expect(head.status, HttpStatus.ok);
    expect(head.headers.contentLength, film.length);
    expect(head.body, isEmpty);
  });

  test('the poster from memory', () async {
    final url = lease(withPoster: poster).posterUrl!;
    expect(url.path, endsWith('/poster.jpg'));
    final answer = await get(url);
    expect(answer.status, HttpStatus.ok);
    expect(answer.headers.contentType?.mimeType, 'image/jpeg');
    expect(answer.body, poster);
    expect(bridge.asked, isEmpty);
  });

  test('an unknown path, a revoked lease and another method are refused without asking the bridge', () async {
    final leased = lease();
    final url = leased.filmUrl;
    expect((await get(url.replace(path: '/cast/00000000000000000000000000000000/film'))).status, HttpStatus.notFound);
    expect((await get(url.replace(path: '/film'))).status, HttpStatus.notFound);
    expect((await get(url.replace(query: 'x=1'))).status, HttpStatus.notFound);
    expect((await get(url, method: 'POST')).status, HttpStatus.methodNotAllowed);
    leased.revoke();
    expect(leased.isRevoked, isTrue);
    expect((await get(url)).status, HttpStatus.notFound);
    expect(bridge.asked, isEmpty);
  });

  test('a lease idle for longer than allowed is forgotten', () async {
    final leased = lease();
    expect((await get(leased.filmUrl, range: 'bytes=0-9')).status, HttpStatus.partialContent);
    now = now.add(CastRelayServer.leaseIdle + const Duration(seconds: 1));
    expect((await get(leased.filmUrl, range: 'bytes=0-9')).status, HttpStatus.notFound);
    expect(relay.leaseCount, 0);
  });

  test('a bridge that cannot give the film is a 502', () async {
    final leased = relay.lease(CastRelayContent(film: () async => throw StateError('no bridge')));
    expect((await get(leased.filmUrl)).status, HttpStatus.badGateway);
  });
}
