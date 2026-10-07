import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_pairing.dart';

import 'fake_plex_server.dart';

void main() {
  group('parsePlexAddress', () {
    test('reads an address with or without its port', () {
      final plain = parsePlexAddress(' 192.0.2.20 ');
      expect((plain.host, plain.port, plain.hash, plain.isName), ('192.0.2.20', null, null, false));
      final withPort = parsePlexAddress('192.0.2.20:32401');
      expect((withPort.host, withPort.port), ('192.0.2.20', 32401));
      expect(withPort.text, '192.0.2.20:32401');
    });

    test('reads a name typed for outside home', () {
      final name = parsePlexAddress('Plex.Example.com:32400');
      expect((name.host, name.port, name.isName), ('plex.example.com', 32400, true));
    });

    test('reads a plex.direct address, with or without its scheme, keeping the hash', () {
      for (final text in [
        'https://203-0-113-7.$plexTestHash.plex.direct:32401',
        '203-0-113-7.$plexTestHash.plex.direct:32401/identity',
      ]) {
        final direct = parsePlexAddress(text);
        expect((direct.host, direct.port, direct.hash), ('203.0.113.7', 32401, plexTestHash), reason: text);
      }
    });

    test('takes the token of a whole "View XML" address', () {
      final address = parsePlexAddress(
        'https://192-0-2-20.$plexTestHash.plex.direct:32400/library/metadata/1?X-Plex-Token=$plexTestToken',
      );
      expect(address.token?.token, plexTestToken);
      expect(address.text, '192.0.2.20:32400');
      expect(address.toString(), isNot(contains(plexTestToken)));
    });

    test('refuses nothing, IPv6 and what is no address', () {
      Matcher problem(PlexAddressProblem kind) =>
          throwsA(isA<PlexAddressException>().having((e) => e.problem, 'problem', kind));
      expect(() => parsePlexAddress('  '), problem(PlexAddressProblem.empty));
      expect(() => parsePlexAddress('[2001:db8::1]:32400'), problem(PlexAddressProblem.ipv6));
      expect(() => parsePlexAddress('2001:db8::1'), problem(PlexAddressProblem.ipv6));
      expect(() => parsePlexAddress('https://[2001:db8::1]:32400/'), problem(PlexAddressProblem.ipv6));
      expect(() => parsePlexAddress('192.0.2.20:70000'), problem(PlexAddressProblem.invalid));
      expect(() => parsePlexAddress('192.0.2.20:x'), problem(PlexAddressProblem.invalid));
      expect(() => parsePlexAddress('two words'), problem(PlexAddressProblem.invalid));
      expect(() => parsePlexAddress('ftp://192.0.2.20'), problem(PlexAddressProblem.invalid));
    });
  });

  test('a server found by GDM needs no request, and a find without its hash is none', () {
    const found = DiscoveredServer(
      host: '192.0.2.20',
      displayName: 'Test Plex',
      type: NetworkSourceType.plex,
      port: 32400,
      useTls: true,
      origin: DiscoveryOrigin.gdm,
      discoveryId: plexTestMachine,
      plexHash: plexTestHash,
      version: '1.42.1.10060-4e8b05daf',
    );
    final server = PlexServerFound.fromDiscovery(found);
    expect(server?.hash, plexTestHash);
    expect(server?.machineIdentifier, plexTestMachine);
    expect(server?.name, 'Test Plex');
    expect(server?.isLocal, isFalse, reason: '192.0.2.0/24 is a documentation range, not a private one');
    expect(server?.shortId, '00000000');
    const withoutHash = DiscoveredServer(
      host: '192.168.1.20',
      displayName: 'x',
      type: NetworkSourceType.plex,
      port: 32400,
      origin: DiscoveryOrigin.gdm,
      discoveryId: plexTestMachine,
    );
    expect(PlexServerFound.fromDiscovery(withoutHash), isNull);
  });

  group('PlexPairing against a server', () {
    late FakePlexServer server;
    late List<(InternetAddress, int)> probed;

    setUp(() async {
      server = await FakePlexServer.start();
      probed = [];
    });
    tearDown(() => server.close());

    PlexPairing pairing({String? hash = plexTestHash}) => PlexPairing(
      probeHash: (address, port) async {
        probed.add((address, port));
        return hash;
      },
      lookupIPv4: (host) async => InternetAddress('192.168.1.20'),
      clientFor: (_) => IOClient(HttpClient()),
      baseOf: (_) => server.base,
      clientIdentifier: () async => 'client-test-0000',
    );

    test('looks a typed address up: its hash from the certificate, then its identity, without the token', () async {
      final found = await pairing().lookUp(parsePlexAddress('192.168.1.20'));
      expect(probed.single.$2, 32400);
      expect(found.hash, plexTestHash);
      expect(found.machineIdentifier, plexTestMachine);
      expect(found.version, '1.42.1.10060-4e8b05daf');
      expect(found.isLocal, isTrue);
      expect(server.requests.single.path, '/identity');
      expect(server.requests.single.headers.containsKey('x-plex-token'), isFalse);
    });

    test('does not read the hash again when the address or the source tells it', () async {
      await pairing().lookUp(parsePlexAddress('192-168-1-20.$plexTestHash.plex.direct:32400'));
      await pairing().lookUp(parsePlexAddress('192.168.1.20'), knownHash: plexTestHash);
      expect(probed, isEmpty);
    });

    test('keeps a name typed as the address outside home', () async {
      final found = await pairing().lookUp(parsePlexAddress('plex.example.com:32401'));
      expect(found.typedName, 'plex.example.com');
      expect(found.addressText, 'plex.example.com:32401');
    });

    test('tells a server without a Plex certificate, and one that does not answer', () async {
      await expectLater(
        pairing(hash: null).lookUp(parsePlexAddress('192.168.1.20')),
        throwsA(isA<PlexFileSystemException>().having((e) => e.failure, 'failure', PlexFailure.notPlex)),
      );
      final silent = PlexPairing(
        probeHash: (_, _) async => throw const SocketException('refused'),
        clientIdentifier: () async => 'client-test-0000',
      );
      await expectLater(
        silent.lookUp(parsePlexAddress('192.168.1.20')),
        throwsA(isA<PlexFileSystemException>().having((e) => e.failure, 'failure', PlexFailure.unreachable)),
      );
    });

    test('a token test gives the libraries, the name and at home the address outside home', () async {
      final found = await pairing().lookUp(parsePlexAddress('192.168.1.20'));
      final check = await pairing().testToken(found, plexTestToken);
      expect([for (final s in check.sections) s.title], ['Movies', 'Photos', 'Series']);
      expect(check.serverName, 'Test Plex');
      expect(check.version, '1.42.1.10060-4e8b05daf');
      expect((check.learned?.host, check.learned?.port), ('203.0.113.7', 32401));
      final sections = server.requests.lastWhere((r) => r.path == '/library/sections');
      expect(sections.headers['x-plex-token'], plexTestToken);
    });

    test('tells a token refused, one without the right to read, and another server', () async {
      final found = await pairing().lookUp(parsePlexAddress('192.168.1.20'));
      await expectLater(
        pairing().testToken(found, 'WRONG-TOKEN-000000000'),
        throwsA(isA<PlexFileSystemException>().having((e) => e.failure, 'failure', PlexFailure.tokenRefused)),
      );
      server.forbidden = true;
      await expectLater(
        pairing().testToken(found, plexTestToken),
        throwsA(isA<PlexFileSystemException>().having((e) => e.failure, 'failure', PlexFailure.tokenForbidden)),
      );
      server.forbidden = false;
      server.machineIdentifier = '0000000000000000000000000000000000000002';
      await expectLater(
        pairing().testToken(found, plexTestToken),
        throwsA(isA<PlexFileSystemException>().having((e) => e.failure, 'failure', PlexFailure.otherServer)),
      );
    });

    test('does not ask a server outside home for its address outside home', () async {
      final outside = PlexPairing(
        probeHash: (_, _) async => plexTestHash,
        lookupIPv4: (host) async => InternetAddress('203.0.113.7'),
        clientFor: (_) => IOClient(HttpClient()),
        baseOf: (_) => server.base,
        clientIdentifier: () async => 'client-test-0000',
      );
      final found = await outside.lookUp(parsePlexAddress('plex.example.com'));
      expect(found.isLocal, isFalse);
      final check = await outside.testToken(found, plexTestToken);
      expect(check.learned, isNull);
      expect(server.requests.any((r) => r.path == '/myplex/account'), isFalse);
    });
  });
}
