import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_direct.dart';

const _hash = '0123456789abcdef0123456789abcdef';
const _other = 'fedcba9876543210fedcba9876543210';

void main() {
  group('plex.direct names', () {
    test('are built from an IPv4 address and the hash', () {
      expect(plexDirectHost(InternetAddress('192.0.2.20'), _hash), '192-0-2-20.$_hash.plex.direct');
      expect(
        plexDirectUri(InternetAddress('203.0.113.7'), 32401, _hash).toString(),
        'https://203-0-113-7.$_hash.plex.direct:32401',
      );
    });

    test('are refused for an IPv6 address or a hash of another form', () {
      expect(() => plexDirectHost(InternetAddress('2001:db8::1'), _hash), throwsArgumentError);
      expect(() => plexDirectHost(InternetAddress('192.0.2.20'), _hash.toUpperCase()), throwsArgumentError);
      expect(() => plexDirectHost(InternetAddress('192.0.2.20'), 'abc'), throwsArgumentError);
    });

    test('give back their address and hash', () {
      final parsed = parsePlexDirectHost('192-0-2-20.$_hash.plex.direct');
      expect(parsed?.address.address, '192.0.2.20');
      expect(parsed?.address.type, InternetAddressType.IPv4);
      expect(parsed?.hash, _hash);
    });

    test('of another form are not plex.direct names', () {
      for (final host in [
        '256-0-2-20.$_hash.plex.direct',
        '192-0-02-20.$_hash.plex.direct',
        '192-0-2.$_hash.plex.direct',
        '192-0-2-20.${_hash.toUpperCase()}.plex.direct',
        '192-0-2-20.$_hash.plex.direct.example.com',
        'www.192-0-2-20.$_hash.plex.direct',
        '192-0-2-20.$_hash.plex.direct.',
        '192.0.2.20',
        'plex.direct',
      ]) {
        expect(parsePlexDirectHost(host), isNull, reason: host);
      }
      expect(isPlexHash(_hash), isTrue);
      expect(isPlexHash('${_hash}0'), isFalse);
    });
  });

  group('plexHashOfSubject', () {
    test('reads the one line form of dart:io and the comma form', () {
      expect(plexHashOfSubject('/CN=*.$_hash.plex.direct'), _hash);
      expect(plexHashOfSubject('CN=*.$_hash.plex.direct, O=Plex, Inc.'), _hash);
      expect(plexHashOfSubject('/C=US/CN=*.$_hash.plex.direct/O=Plex'), _hash);
    });

    test('takes a wildcard common name only, as a whole attribute', () {
      expect(plexHashOfSubject('/CN=192-0-2-20.$_hash.plex.direct'), isNull);
      expect(plexHashOfSubject('/CN=*.$_hash.plex.direct.example.com'), isNull);
      expect(plexHashOfSubject('/O=CN=*.$_hash.plex.direct'), isNull);
      expect(plexHashOfSubject('/CN=*.${_hash.toUpperCase()}.plex.direct'), isNull);
      expect(plexHashOfSubject('/CN=nas.example.com'), isNull);
      expect(plexHashOfSubject(''), isNull);
    });
  });

  group('pinnedPlexHttpClient', () {
    late ServerSocket listener;
    late int connections;

    setUp(() async {
      listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      connections = 0;
      listener.listen((socket) {
        connections++;
        socket.destroy();
      });
    });

    tearDown(() => listener.close());

    Future<Object?> errorOf(HttpClient client, String url) async {
      try {
        final request = await client.getUrl(Uri.parse(url));
        await (await request.close()).drain<void>();
        return null;
      } catch (error) {
        return error;
      }
    }

    test('refuses a hash of another form', () {
      expect(() => pinnedPlexHttpClient('not a hash'), throwsArgumentError);
    });

    test('refuses plain http, another hash and any other name before connecting', () async {
      final client = pinnedPlexHttpClient(_hash);
      addTearDown(() => client.close(force: true));
      final port = listener.port;

      for (final url in [
        'http://127-0-0-1.$_hash.plex.direct:$port/identity',
        'https://127-0-0-1.$_other.plex.direct:$port/identity',
        'https://127.0.0.1:$port/identity',
        'https://localhost:$port/identity',
      ]) {
        expect(await errorOf(client, url), isA<HandshakeException>(), reason: url);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(connections, 0, reason: 'nothing is connected to for an address of another server');
    });

    test('connects to the address of the name, without DNS, and refuses what is no TLS', () async {
      final client = pinnedPlexHttpClient(_hash);
      addTearDown(() => client.close(force: true));

      final error = await errorOf(client, 'https://127-0-0-1.$_hash.plex.direct:${listener.port}/identity');
      expect(error, isNotNull);
      expect(connections, 1, reason: 'the name gives the address: 127.0.0.1');
    });
  });

  test('probePlexHash fails on an address where nothing answers', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    await expectLater(
      probePlexHash(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 2)),
      throwsA(isA<SocketException>()),
    );
  });
}
