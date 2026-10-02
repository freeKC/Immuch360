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
}) => DiscoveredServer(
  host: host,
  displayName: name,
  type: type,
  port: port,
  path: path,
  origin: origin,
  address: address,
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
}
