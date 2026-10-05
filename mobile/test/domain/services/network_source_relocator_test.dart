// A share found on the network is found again by the id its server announces once its address changed: a phone share
// given another address by the router, a DLNA media server restarted on another port or under another path.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/domain/services/network_source_relocator.dart';

const _udn = 'uuid:4d696e69-444c-164e-9d41-b827eb000001';
const _phoneId = '0f1e2d3c4b5a6978';

const _phoneShare = NetworkSource(
  id: 'phone',
  type: NetworkSourceType.webdav,
  name: 'Immuch360 on Pixel',
  host: '192.168.1.23',
  port: 8360,
  share: '/',
  rootPath: '/360',
  username: 'phone1234',
  discoveryId: _phoneId,
);

const _mediaServer = NetworkSource(
  id: 'dlna',
  type: NetworkSourceType.dlna,
  name: 'minidlna',
  host: '192.168.1.10',
  port: 8200,
  share: '/rootDesc.xml',
  rootPath: '/Video',
  discoveryId: _udn,
);

DiscoveredServer _server(
  String host,
  int port, {
  NetworkSourceType type = NetworkSourceType.webdav,
  String path = '/',
  String? discoveryId,
  DiscoveryOrigin origin = DiscoveryOrigin.mdns,
}) => DiscoveredServer(
  host: host,
  displayName: host,
  type: type,
  port: port,
  path: path,
  origin: origin,
  discoveryId: discoveryId,
);

/// A discovery that finds [servers], and counts its runs
class _Discovery {
  _Discovery(this.servers);

  final List<DiscoveredServer> servers;
  int runs = 0;

  NetworkSourceRelocator relocator() => NetworkSourceRelocator(
    NetworkDiscoveryService(
      probes: [
        (request) async* {
          runs++;
          for (final server in servers) {
            await Future<void>.delayed(Duration.zero);
            yield server;
          }
        },
      ],
    ),
  );
}

void main() {
  test('follows a phone share to its new address, keeping everything else', () async {
    final discovery = _Discovery([
      _server('192.168.1.40', 445, type: NetworkSourceType.smb),
      _server('192.168.1.57', 8361, discoveryId: _phoneId),
    ]);

    final relocated = await discovery.relocator().relocate(_phoneShare);

    expect(relocated, isNotNull);
    expect(relocated!.host, '192.168.1.57');
    expect(relocated.port, 8361);
    expect(relocated.share, '/');
    expect(relocated.id, 'phone', reason: 'the same source, so the same stored password');
    expect(relocated.type, NetworkSourceType.webdav);
    expect(relocated.name, _phoneShare.name);
    expect(relocated.rootPath, '/360');
    expect(relocated.username, 'phone1234');
    expect(relocated.discoveryId, _phoneId);
  });

  test('follows a DLNA media server to its new port and description path, whatever the case of its UDN', () async {
    final discovery = _Discovery([
      _server(
        '192.168.1.10',
        8096,
        type: NetworkSourceType.dlna,
        path: '/dlna/7d2c/description.xml',
        discoveryId: _udn.toUpperCase().replaceFirst('UUID', 'uuid'),
        origin: DiscoveryOrigin.ssdp,
      ),
    ]);

    final relocated = await discovery.relocator().relocate(_mediaServer);

    expect(relocated!.host, '192.168.1.10');
    expect(relocated.port, 8096);
    expect(relocated.share, '/dlna/7d2c/description.xml');
    expect(relocated.rootPath, '/Video');
  });

  test('is null when the server answers at the same address', () async {
    final discovery = _Discovery([
      _server('192.168.1.23', 8360, discoveryId: _phoneId),
      _server('192.168.1.10', 8200, type: NetworkSourceType.dlna, path: '/rootDesc.xml', discoveryId: _udn),
    ]);
    final relocator = discovery.relocator();

    expect(await relocator.relocate(_phoneShare), isNull);
    expect(await relocator.relocate(_mediaServer), isNull);
  });

  test('a source without a port is at the default port of its type', () async {
    final discovery = _Discovery([_server('192.168.1.23', 80, discoveryId: _phoneId)]);
    final relocator = discovery.relocator();

    expect(await relocator.relocate(_phoneShare.copyWith(clearPort: true)), isNull);
    final tls = await relocator.relocate(_phoneShare.copyWith(clearPort: true, useTls: true));
    expect(tls?.port, 80, reason: '443 is the default port over TLS');
  });

  test('is null when no server with the id and the type answers', () async {
    final discovery = _Discovery([
      _server('192.168.1.57', 8360, discoveryId: 'another phone'),
      // The id of the phone share, on a server of another type
      _server('192.168.1.58', 8200, type: NetworkSourceType.dlna, discoveryId: _phoneId),
      _server('192.168.1.59', 8360),
    ]);

    expect(await discovery.relocator().relocate(_phoneShare), isNull);
  });

  test('runs no discovery for a share without a discovery id', () async {
    final discovery = _Discovery([_server('192.168.1.57', 8360, discoveryId: _phoneId)]);

    const typedIn = NetworkSource(
      id: 'typed',
      type: NetworkSourceType.webdav,
      name: 'NAS',
      host: '192.168.1.23',
      port: 8360,
    );
    expect(await discovery.relocator().relocate(typedIn), isNull);
    expect(discovery.runs, 0);
  });
}
