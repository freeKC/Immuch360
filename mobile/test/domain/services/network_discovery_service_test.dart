import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';

DiscoveredServer _server(
  String name,
  String host, {
  NetworkSourceType type = NetworkSourceType.smb,
  int port = 445,
  DiscoveryOrigin origin = DiscoveryOrigin.scan,
  String path = '',
  String? address,
  String? discoveryId,
  String? username,
  bool isPhoneShare = false,
  bool useTls = false,
  String? plexHash,
  String? version,
}) => DiscoveredServer(
  host: host,
  displayName: name,
  type: type,
  port: port,
  path: path,
  origin: origin,
  address: address,
  discoveryId: discoveryId,
  username: username,
  isPhoneShare: isPhoneShare,
  useTls: useTls,
  plexHash: plexHash,
  version: version,
);

/// A Tapo camera as TDP finds it (model, MAC, firmware) or as the scan finds it (the address only)
DiscoveredServer _camera({required DiscoveryOrigin origin}) => _server(
  origin == DiscoveryOrigin.tdp ? 'Tapo C200' : '192.0.2.30',
  '192.0.2.30',
  type: NetworkSourceType.tapo,
  port: 443,
  useTls: true,
  origin: origin,
  discoveryId: origin == DiscoveryOrigin.tdp ? '02-00-00-00-00-01' : null,
  version: origin == DiscoveryOrigin.tdp ? '1.3.9' : null,
);

/// A Plex Media Server as GDM finds it
DiscoveredServer _plex(
  String name,
  String machineId, {
  String? plexHash,
  String? version,
  String host = '192.0.2.20',
}) => _server(
  name,
  host,
  type: NetworkSourceType.plex,
  port: 32400,
  useTls: true,
  origin: DiscoveryOrigin.gdm,
  discoveryId: machineId,
  plexHash: plexHash,
  version: version,
);

/// A probe that gives [servers], one per [interval], then ends unless [endless]
DiscoveryProbe _probe(
  List<DiscoveredServer> servers, {
  Duration interval = Duration.zero,
  bool endless = false,
  List<DiscoveryRequest>? requests,
}) {
  return (request) async* {
    requests?.add(request);
    for (final server in servers) {
      await Future<void>.delayed(interval);
      yield server;
    }
    if (endless) {
      await request.done;
    }
  };
}

void main() {
  group('DiscoveredServer', () {
    test('is equal on host, type and port only', () {
      final a = _server('NAS', '192.168.1.20');
      expect(a, _server('Other name', '192.168.1.20', origin: DiscoveryOrigin.mdns, path: '/x'));
      expect(a.hashCode, _server('Other name', '192.168.1.20').hashCode);
      expect(a, isNot(_server('NAS', '192.168.1.21')));
      expect(a, isNot(_server('NAS', '192.168.1.20', port: 1445)));
      expect(a, isNot(_server('NAS', '192.168.1.20', type: NetworkSourceType.webdav)));
    });

    test('merges two finds of a server, the mDNS one first, keeping a known path', () {
      final scanned = _server('192.168.1.20', '192.168.1.20', type: NetworkSourceType.webdav, port: 5005, path: '/dav');
      final announced = _server(
        'Living room NAS',
        'nas.local',
        type: NetworkSourceType.webdav,
        port: 5005,
        origin: DiscoveryOrigin.mdns,
        address: '192.168.1.20',
      );
      for (final merged in [scanned.mergedWith(announced), announced.mergedWith(scanned)]) {
        expect(merged.displayName, 'Living room NAS');
        expect(merged.host, 'nas.local');
        expect(merged.origin, DiscoveryOrigin.mdns);
        expect(merged.path, '/dav');
        expect(merged.address, '192.168.1.20');
      }
    });

    test('is equal whatever its discovery id, user name and phone share mark', () {
      final plain = _server('Pixel', '192.168.1.23', type: NetworkSourceType.webdav, port: 8360);
      final announced = _server(
        'Immuch360 on Pixel',
        '192.168.1.23',
        type: NetworkSourceType.webdav,
        port: 8360,
        origin: DiscoveryOrigin.mdns,
        discoveryId: '0f1e2d3c4b5a6978',
        username: 'phone1234',
        isPhoneShare: true,
      );

      expect(plain, announced);
      expect(plain.hashCode, announced.hashCode);
    });

    test('merging keeps the discovery id, the user name and the phone share mark of either find', () {
      final scanned = _server('192.168.1.23', '192.168.1.23', type: NetworkSourceType.webdav, port: 8360);
      final announced = _server(
        'Immuch360 on Pixel',
        'Pixel.local',
        type: NetworkSourceType.webdav,
        port: 8360,
        origin: DiscoveryOrigin.mdns,
        address: '192.168.1.23',
        discoveryId: '0f1e2d3c4b5a6978',
        username: 'phone1234',
        isPhoneShare: true,
      );
      for (final merged in [scanned.mergedWith(announced), announced.mergedWith(scanned)]) {
        expect(merged.discoveryId, '0f1e2d3c4b5a6978');
        expect(merged.username, 'phone1234');
        expect(merged.isPhoneShare, isTrue);
        expect(merged.origin, DiscoveryOrigin.mdns);
      }

      // The preferred find first, the other one when it has none
      final other = _server('NAS', '192.168.1.23', type: NetworkSourceType.webdav, port: 8360, discoveryId: 'other');
      expect(announced.mergedWith(other).discoveryId, '0f1e2d3c4b5a6978');
      expect(other.mergedWith(scanned).discoveryId, 'other');
      expect(scanned.mergedWith(scanned).isPhoneShare, isFalse);
    });

    test('a DLNA media server found by SSDP keeps its UDN and description path', () {
      final server = _server(
        'minidlna',
        '192.168.1.10',
        type: NetworkSourceType.dlna,
        port: 8200,
        origin: DiscoveryOrigin.ssdp,
        path: '/rootDesc.xml',
        discoveryId: 'uuid:4d696e69-444c-164e-9d41-b827eb000001',
      );

      final merged = server.mergedWith(server);
      expect(merged.origin, DiscoveryOrigin.ssdp);
      expect(merged.path, '/rootDesc.xml');
      expect(merged.discoveryId, 'uuid:4d696e69-444c-164e-9d41-b827eb000001');
      expect(merged.toString(), contains('uuid:4d696e69'));
    });
  });

  group('NetworkDiscoveryService', () {
    test('merges the probes into one growing list, without duplicates, sorted by name then host', () async {
      final service = NetworkDiscoveryService(
        probes: [
          _probe([_server('zeta', '192.168.1.30'), _server('Alpha', '192.168.1.40')]),
          _probe([
            _server('alpha', '192.168.1.10', type: NetworkSourceType.webdav, port: 5005),
            // The same server as the first one, found again
            _server('zeta', '192.168.1.30'),
          ], interval: const Duration(milliseconds: 5)),
        ],
      );

      final lists = await service.discover(timeout: const Duration(seconds: 5)).toList();

      expect(lists, isNotEmpty);
      for (var i = 1; i < lists.length; i++) {
        expect(lists[i].length, greaterThan(lists[i - 1].length), reason: 'a list only when something new came');
      }
      final last = lists.last;
      expect(last.map((s) => '${s.displayName} ${s.host}'), [
        'alpha 192.168.1.10',
        'Alpha 192.168.1.40',
        'zeta 192.168.1.30',
      ]);
    });

    test('shows a server found by name and by address once, with its mDNS name', () async {
      final service = NetworkDiscoveryService(
        probes: [
          _probe([_server('192.168.1.20', '192.168.1.20')]),
          _probe([
            _server('NAS', 'nas.local', origin: DiscoveryOrigin.mdns, address: '192.168.1.20'),
          ], interval: const Duration(milliseconds: 10)),
        ],
      );

      final last = (await service.discover().toList()).last;

      expect(last, hasLength(1));
      expect(last.single.displayName, 'NAS');
      expect(last.single.host, 'nas.local');
    });

    test('keeps apart two DLNA media servers at one address and port, and merges the finds of each', () async {
      DiscoveredServer media(String name, String path, String? udn) => _server(
        name,
        '192.168.1.10',
        type: NetworkSourceType.dlna,
        port: 8200,
        origin: DiscoveryOrigin.ssdp,
        path: path,
        discoveryId: udn,
      );
      final service = NetworkDiscoveryService(
        probes: [
          _probe([
            media('Photos', '/photos.xml', 'uuid:AAAA'),
            media('Videos', '/videos.xml', 'uuid:bbbb'),
            media('Music', '/music.xml', null),
            media('Radio', '/radio.xml', null),
          ]),
          _probe([media('Photos', '/photos.xml', 'uuid:aaaa')], interval: const Duration(milliseconds: 10)),
        ],
      );

      final last = (await service.discover().toList()).last;

      expect(last.map((s) => s.displayName), ['Music', 'Photos', 'Radio', 'Videos']);
      expect(media('Photos', '/a.xml', 'uuid:AAAA').mergeKey, media('Other', '/b.xml', 'uuid:aaaa').mergeKey);
      expect(
        _server('NAS', '192.168.1.20', discoveryId: 'one').mergeKey,
        _server('NAS', '192.168.1.20', discoveryId: 'two').mergeKey,
        reason: 'only DLNA servers are told apart by their device',
      );
    });

    test('gives a new list when a second find of a server brings its discovery id', () async {
      final service = NetworkDiscoveryService(
        probes: [
          _probe([_server('192.168.1.23', '192.168.1.23', type: NetworkSourceType.webdav, port: 8360)]),
          _probe([
            _server(
              'Immuch360 on Pixel',
              '192.168.1.23',
              type: NetworkSourceType.webdav,
              port: 8360,
              origin: DiscoveryOrigin.mdns,
              discoveryId: '0f1e2d3c4b5a6978',
              username: 'phone1234',
              isPhoneShare: true,
            ),
            // Found again, with nothing new
            _server(
              'Immuch360 on Pixel',
              '192.168.1.23',
              type: NetworkSourceType.webdav,
              port: 8360,
              origin: DiscoveryOrigin.mdns,
              discoveryId: '0f1e2d3c4b5a6978',
              username: 'phone1234',
              isPhoneShare: true,
            ),
          ], interval: const Duration(milliseconds: 10)),
        ],
      );

      final lists = await service.discover(timeout: const Duration(seconds: 5)).toList();

      expect(lists, hasLength(2));
      expect(lists.first.single.discoveryId, isNull);
      final last = lists.last.single;
      expect(last.discoveryId, '0f1e2d3c4b5a6978');
      expect(last.username, 'phone1234');
      expect(last.isPhoneShare, isTrue);
    });

    test('ends at the timeout and stops the probes that still run', () async {
      final requests = <DiscoveryRequest>[];
      final service = NetworkDiscoveryService(
        probes: [
          _probe([_server('NAS', '192.168.1.20')], endless: true, requests: requests),
        ],
      );

      final watch = Stopwatch()..start();
      final lists = await service.discover(timeout: const Duration(milliseconds: 200)).toList();
      watch.stop();

      expect(lists.last.single.displayName, 'NAS');
      expect(watch.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 190)));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(requests.single.isCancelled, isTrue);
    });

    test('ends as soon as every probe ended', () async {
      final service = NetworkDiscoveryService(
        probes: [
          _probe([_server('NAS', '192.168.1.20')]),
        ],
      );

      final watch = Stopwatch()..start();
      await service.discover(timeout: const Duration(seconds: 30)).toList();

      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a probe that fails does not stop the others', () async {
      final service = NetworkDiscoveryService(
        probes: [
          (_) => throw StateError('no network'),
          (_) async* {
            yield _server('First', '192.168.1.1');
            throw StateError('lost');
          },
          (_) => Stream<DiscoveredServer>.error(StateError('denied')),
          _probe([_server('NAS', '192.168.1.20')], interval: const Duration(milliseconds: 20)),
        ],
      );

      final last = (await service.discover(timeout: const Duration(seconds: 5)).toList()).last;

      expect(last.map((s) => s.displayName), ['First', 'NAS']);
    });

    test('ends at once with no probe, or with probes that all fail to start', () async {
      expect(await NetworkDiscoveryService(probes: const []).discover().toList(), isEmpty);
      final failing = NetworkDiscoveryService(probes: [(_) => throw StateError('no')]);
      expect(await failing.discover().toList(), isEmpty);
    });

    test('hands the hosts to the probes, and stops them when the listener leaves', () async {
      final requests = <DiscoveryRequest>[];
      final service = NetworkDiscoveryService(
        probes: [
          _probe([_server('NAS', '10.0.2.2')], endless: true, requests: requests),
        ],
      );

      final first = await service.discover(hosts: ['10.0.2.2']).first;

      expect(first.single.host, '10.0.2.2');
      expect(requests.single.hosts, ['10.0.2.2']);
      await Future<void>.delayed(Duration.zero);
      expect(requests.single.isCancelled, isTrue);
    });
  });

  group('Plex servers and Tapo cameras', () {
    test('a camera found by TDP and by the scan shows once, with what TDP tells, whichever came first', () {
      final scanned = _camera(origin: DiscoveryOrigin.scan);
      final announced = _camera(origin: DiscoveryOrigin.tdp);

      expect(scanned.mergeKey, announced.mergeKey);
      for (final merged in [scanned.mergedWith(announced), announced.mergedWith(scanned)]) {
        expect(merged.origin, DiscoveryOrigin.tdp);
        expect(merged.displayName, 'Tapo C200');
        expect(merged.discoveryId, '02-00-00-00-00-01');
        expect(merged.version, '1.3.9');
      }
    });

    test('the mDNS find still wins over every other origin, TDP over the rest, the first find on a tie', () {
      expect(DiscoveryOrigin.values.map((origin) => origin.rank), [0, 2, 2, 2, 1]);
      final mdns = _server('NAS', '192.168.1.20', origin: DiscoveryOrigin.mdns);
      final scan = _server('192.168.1.20', '192.168.1.20');
      final ssdp = _server('Other', '192.168.1.20', origin: DiscoveryOrigin.ssdp);
      expect(scan.mergedWith(mdns).origin, DiscoveryOrigin.mdns);
      expect(mdns.mergedWith(scan).origin, DiscoveryOrigin.mdns);
      expect(scan.mergedWith(ssdp).displayName, '192.168.1.20');
      expect(ssdp.mergedWith(scan).displayName, 'Other');
    });

    test('two Plex servers at one address are told apart by their machine id, the finds of each merged', () {
      final first = _plex('Living room', '0000000000000000000000000000000000000001');
      final second = _plex('Office', '0000000000000000000000000000000000000002');
      final firstAgain = _plex('Living room', '0000000000000000000000000000000000000001'.toUpperCase());

      expect(first.mergeKey, isNot(second.mergeKey));
      expect(first.mergeKey, firstAgain.mergeKey, reason: 'machine ids are hexadecimal, in either case');
      expect(
        _plex('A', '').mergeKey,
        _server('A', '192.0.2.20', type: NetworkSourceType.plex, port: 32400, origin: DiscoveryOrigin.gdm).mergeKey,
      );
    });

    test('merging keeps the Plex hash and the version of either find', () {
      final withHash = _plex(
        'Test Plex',
        '0000000000000000000000000000000000000001',
        plexHash: '0123456789abcdef0123456789abcdef',
        version: '1.42.1',
      );
      final bare = _plex('Test Plex', '0000000000000000000000000000000000000001');

      for (final merged in [withHash.mergedWith(bare), bare.mergedWith(withHash)]) {
        expect(merged.plexHash, '0123456789abcdef0123456789abcdef');
        expect(merged.version, '1.42.1');
      }
      expect(withHash, bare, reason: 'the hash and the version are not part of the equality');
    });

    test('gives a new list when a second find brings the Plex hash or the version', () async {
      const id = '0000000000000000000000000000000000000001';
      final service = NetworkDiscoveryService(
        probes: [
          _probe([_plex('Test Plex', id)]),
          _probe([
            _plex('Test Plex', id, plexHash: '0123456789abcdef0123456789abcdef'),
            _plex('Test Plex', id, plexHash: '0123456789abcdef0123456789abcdef'),
            _plex('Test Plex', id, plexHash: '0123456789abcdef0123456789abcdef', version: '1.42.1'),
          ], interval: const Duration(milliseconds: 10)),
        ],
      );

      final lists = await service.discover(timeout: const Duration(seconds: 5)).toList();

      expect(lists, hasLength(3), reason: 'nothing new in the second find of the hash');
      expect(lists[0].single.plexHash, isNull);
      expect(lists[1].single.plexHash, '0123456789abcdef0123456789abcdef');
      expect(lists[2].single.version, '1.42.1');
    });

    test('the scan and TDP finds of one camera make one line in the list', () async {
      final service = NetworkDiscoveryService(
        probes: [
          _probe([_camera(origin: DiscoveryOrigin.scan)]),
          _probe([_camera(origin: DiscoveryOrigin.tdp)], interval: const Duration(milliseconds: 10)),
        ],
      );

      final last = (await service.discover(timeout: const Duration(seconds: 5)).toList()).last;

      expect(last.single.displayName, 'Tapo C200');
      expect(last.single.origin, DiscoveryOrigin.tdp);
    });
  });
}
