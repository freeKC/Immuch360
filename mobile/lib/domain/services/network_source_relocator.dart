// A share found on the network keeps the id its server announces (the UPnP UDN of a DLNA media server, the TXT id of
// a phone share, the machine id of a Plex server, the MAC address of a Tapo camera), not only its address. When the
// address stops answering (a phone or a box given another address by the router, a media server restarted on another
// port), one discovery finds the server again by that id, so that the user does not have to edit the share.

import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';

/// Finds a share with a [NetworkSource.discoveryId] again at its current address, see [relocate]
class NetworkSourceRelocator {
  NetworkSourceRelocator(this._discovery);

  final NetworkDiscoveryService _discovery;

  /// [source] at the address where a server with its discoveryId and type answers now; null when none answers or
  /// nothing changed. Runs one discovery of [timeout].
  Future<NetworkSource?> relocate(NetworkSource source, {Duration timeout = const Duration(seconds: 5)}) async {
    final discoveryId = source.discoveryId?.toLowerCase();
    if (discoveryId == null || discoveryId.isEmpty) {
      return null;
    }
    var servers = const <DiscoveredServer>[];
    await for (final found in _discovery.discover(timeout: timeout)) {
      servers = found;
    }
    // UDNs and ids are hexadecimal, which servers do not always write in the same case
    final server = servers
        .where((s) => s.type == source.type && s.discoveryId?.toLowerCase() == discoveryId)
        .firstOrNull;
    if (server == null) {
      return null;
    }
    // Only the server holding the certificate of the stored hash may get the token: another one announcing the same
    // machine id is ignored. The stored hash is lower case, as in the plex.direct names
    if (source.type == NetworkSourceType.plex &&
        (server.plexHash == null || server.plexHash!.toLowerCase() != source.plex?.hash)) {
      return null;
    }

    // The description of a DLNA server may move as well (Jellyfin puts its server id in the path)
    final share = source.type == NetworkSourceType.dlna && server.path.isNotEmpty ? server.path : source.share;
    final samePort = (source.port ?? _defaultPort(source)) == server.port;
    if (server.host.toLowerCase() == source.host.trim().toLowerCase() && samePort && share == source.share) {
      return null;
    }
    return source.copyWith(host: server.host, port: server.port, share: share);
  }

  /// The port a source without one uses
  static int _defaultPort(NetworkSource source) => switch (source.type) {
    NetworkSourceType.smb => 445,
    NetworkSourceType.webdav || NetworkSourceType.dlna => source.useTls ? 443 : 80,
    NetworkSourceType.plex => 32400,
    NetworkSourceType.tapo => 443,
  };
}
