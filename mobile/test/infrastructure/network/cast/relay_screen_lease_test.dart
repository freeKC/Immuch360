// The relay of the phone serving a linked screen (release 53): a lease answers only the screen it was made for, and
// only with the MAC of its path under the K_relay of the play link session. Another device of the network, the screen
// without the MAC, with the MAC of another session or of another path, and anyone after the lease was revoked get the
// 404 of an unknown path. The phone's own files and pictures are served with their ranges. The tests' client is on the
// loopback: it is the screen of a lease made for 127.0.0.1.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/infrastructure/network/cast/cast_relay.dart';

void main() {
  final video = Uint8List.fromList(List<int>.generate(10000, (index) => index % 253));
  final photo = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 9, 8, 7, 6, 5, 0xff, 0xd9]);
  final sessionKey = List<int>.filled(32, 3);
  final otherSessionKey = List<int>.filled(32, 4);
  late Directory folder;
  late File file;
  late CastRelayServer relay;
  late HttpClient client;
  var now = DateTime.utc(2026, 11, 26, 20);

  setUp(() async {
    now = DateTime.utc(2026, 11, 26, 20);
    folder = await Directory.systemTemp.createTemp('relay_screen_lease');
    file = File('${folder.path}/clip.mp4');
    await file.writeAsBytes(video);
    relay = await CastRelayServer.bind('127.0.0.1', port: 0, clock: () => now);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await relay.close();
    await folder.delete(recursive: true);
  });

  Future<({int status, HttpHeaders headers, List<int> body})> get(
    CastRelayLease lease, {
    String method = 'GET',
    String? range,
    List<int>? key,
    String? mac,
    String? path,
  }) async {
    final request = await client.openUrl(
      method,
      Uri(scheme: 'http', host: '127.0.0.1', port: relay.port, path: path ?? lease.path),
    );
    final header = mac ?? (key == null ? null : playRelayMac(key, lease.path));
    if (header != null) {
      request.headers.set(playRelayHeader, header);
    }
    if (range != null) {
      request.headers.set(HttpHeaders.rangeHeader, range);
    }
    final response = await request.close();
    final body = <int>[];
    await response.forEach(body.addAll);
    return (status: response.statusCode, headers: response.headers, body: body);
  }

  CastRelayLease screenLease({String client = '127.0.0.1', CastRelayContent? content}) => relay.lease(
    content ?? CastRelayContent.local(file: () async => file, contentType: 'video/mp4'),
    client: client,
    macKeys: () => [sessionKey],
  );

  group('who is served', () {
    test('the screen with the MAC of the session reads the video, ranges included', () async {
      final lease = screenLease();
      final whole = await get(lease, key: sessionKey);
      expect(whole.status, HttpStatus.ok);
      expect(whole.body, video);
      expect(whole.headers.contentType?.mimeType, 'video/mp4');
      expect(whole.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');

      final part = await get(lease, key: sessionKey, range: 'bytes=100-199');
      expect(part.status, HttpStatus.partialContent);
      expect(part.body, video.sublist(100, 200));
      expect(part.headers.value(HttpHeaders.contentRangeHeader), 'bytes 100-199/10000');

      final tail = await get(lease, key: sessionKey, range: 'bytes=9990-');
      expect(tail.body, video.sublist(9990));
      final suffix = await get(lease, key: sessionKey, range: 'bytes=-10');
      expect(suffix.body, video.sublist(9990));

      final head = await get(lease, key: sessionKey, method: 'HEAD');
      expect(head.status, HttpStatus.ok);
      expect(head.headers.contentLength, 10000);
      expect(head.body, isEmpty);
    });

    test('another device of the network gets 404, even with the right MAC', () async {
      // The lease is the screen's at 192.168.1.50; the test's client is another address
      final lease = screenLease(client: '192.168.1.50');
      final answer = await get(lease, key: sessionKey);
      expect(answer.status, HttpStatus.notFound);
      expect(answer.body, isEmpty);
      expect(lease.isRevoked, isFalse);
    });

    test('the screen without the MAC, or with the MAC of another session or another path, gets 404', () async {
      final lease = screenLease();
      expect((await get(lease)).status, HttpStatus.notFound);
      expect((await get(lease, key: otherSessionKey)).status, HttpStatus.notFound);
      expect((await get(lease, mac: playRelayMac(sessionKey, '/cast/${'0' * 32}/film'))).status, HttpStatus.notFound);
      expect((await get(lease, mac: 'not base64 !')).status, HttpStatus.notFound);
      // Still alive for the right request
      expect((await get(lease, key: sessionKey)).status, HttpStatus.ok);
    });

    test('a refused request does not keep the lease alive', () async {
      final lease = screenLease();
      now = now.add(const Duration(minutes: 20));
      await get(lease);
      now = now.add(const Duration(minutes: 20));
      // 40 minutes after its last real use: idle, gone
      expect((await get(lease, key: sessionKey)).status, HttpStatus.notFound);
      expect(lease.isRevoked, isTrue);
    });

    test('a revoked lease is a 404 for the screen too', () async {
      final lease = screenLease();
      lease.revoke();
      expect((await get(lease, key: sessionKey)).status, HttpStatus.notFound);
    });

    test('either key of the sessions the play may have gone through opens it', () async {
      final lease = relay.lease(
        CastRelayContent.local(bytes: photo, contentType: 'image/jpeg'),
        client: '127.0.0.1',
        macKeys: () => [otherSessionKey, sessionKey],
      );
      expect((await get(lease, key: sessionKey)).status, HttpStatus.ok);
      expect((await get(lease, key: otherSessionKey)).status, HttpStatus.ok);
      expect((await get(lease, key: List<int>.filled(32, 5))).status, HttpStatus.notFound);
    });

    test('a Cast lease stays without a MAC: its device cannot send a header', () async {
      final lease = relay.lease(
        CastRelayContent.local(bytes: photo, contentType: 'image/jpeg'),
        client: '127.0.0.1',
      );
      expect((await get(lease)).status, HttpStatus.ok);
    });
  });

  group('what is served', () {
    test('a picture made in memory, with its type and its ranges', () async {
      final lease = screenLease(
        content: CastRelayContent.local(bytes: photo, contentType: 'image/jpeg'),
      );
      final whole = await get(lease, key: sessionKey);
      expect(whole.body, photo);
      expect(whole.headers.contentType?.mimeType, 'image/jpeg');
      final part = await get(lease, key: sessionKey, range: 'bytes=2-4');
      expect(part.body, photo.sublist(2, 5));
    });

    test('a range past the end is refused with the length', () async {
      final lease = screenLease();
      final answer = await get(lease, key: sessionKey, range: 'bytes=20000-');
      expect(answer.status, HttpStatus.requestedRangeNotSatisfiable);
      expect(answer.headers.value(HttpHeaders.contentRangeHeader), 'bytes */10000');
    });

    test('a file gone from the gallery is a 404', () async {
      final lease = screenLease(
        content: CastRelayContent.local(file: () async => null, contentType: 'video/mp4'),
      );
      expect((await get(lease, key: sessionKey)).status, HttpStatus.notFound);
    });

    test('nothing but GET and HEAD', () async {
      final lease = screenLease();
      expect((await get(lease, key: sessionKey, method: 'POST')).status, HttpStatus.methodNotAllowed);
    });
  });

  group('castRelayRangeOf', () {
    test('reads one range, and the whole file without one', () {
      expect(castRelayRangeOf(null, 10), (start: 0, end: 10, partial: false));
      expect(castRelayRangeOf('bytes=0-', 10), (start: 0, end: 10, partial: true));
      expect(castRelayRangeOf('bytes=2-3', 10), (start: 2, end: 4, partial: true));
      expect(castRelayRangeOf('bytes=5-100', 10), (start: 5, end: 10, partial: true));
      expect(castRelayRangeOf('bytes=-3', 10), (start: 7, end: 10, partial: true));
      expect(castRelayRangeOf('bytes=-30', 10), (start: 0, end: 10, partial: true));
      // Several ranges: the whole file, which a server may answer
      expect(castRelayRangeOf('bytes=0-1,4-5', 10), (start: 0, end: 10, partial: false));
      expect(castRelayRangeOf('bytes=10-', 10), isNull);
      expect(castRelayRangeOf('bytes=4-2', 10), isNull);
      expect(castRelayRangeOf('bytes=-0', 10), isNull);
    });
  });
}
