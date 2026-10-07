// Finds the Plex Media Servers of the local network with GDM, the discovery of Plex: an M-SEARCH sent to UDP 32414 by
// broadcast and to the GDM multicast group from one socket, and to port 32414 of every host of the local /24 subnets
// from another. Each server answers from port 32414 to the port the request came from, with its name, its port, its
// machine identifier and the hash of its plex.direct certificate (the Host header), which is all the pairing page needs
// before the token. Nothing else is sent, and the answer comes from the address the server has on the network.
//
// The two sockets have the reason of SSDP (see upnp/ssdp.dart): the broadcast and group sends fail on iOS without the
// multicast entitlement, and dart:io closes the socket a send failed on, which must not be the one of the sweep. The
// sweep is then the only way, and it also finds the servers when a router drops broadcasts between Wi-Fi clients. A
// server whose owner turned "Enable local network discovery (GDM)" off is not found: its address is typed instead.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_direct.dart';
import 'package:immich_mobile/infrastructure/network/udp_transport.dart';
import 'package:immich_mobile/infrastructure/network/upnp/ssdp.dart' show isLocalNetworkAddress;
import 'package:logging/logging.dart';

final _log = Logger('Gdm');

const gdmPort = 32414;
const gdmMulticastAddress = '239.0.0.250';

/// The request every Plex Media Server answers
final gdmSearch = ascii.encode('M-SEARCH * HTTP/1.1\r\n\r\n');

/// A Plex Media Server that answered, see [parseGdmAnswer]
class GdmAnswer {
  const GdmAnswer({
    required this.name,
    required this.hash,
    required this.machineIdentifier,
    required this.port,
    this.version,
  });

  /// The name the owner gave the server, "" when it has none
  final String name;

  /// The 32 hex digits of its plex.direct certificate
  final String hash;

  /// Its machine identifier, lower case
  final String machineIdentifier;
  final int port;
  final String? version;

  @override
  String toString() => 'GdmAnswer(port $port)';
}

final _statusLine = RegExp(r'^HTTP/1\.\d\s+200(\s|$)', caseSensitive: false);

// "<hash>.plex.direct" in the answers of 1.42; a name with an address part is accepted as well
final _hostHash = RegExp(r'(?:^|\.)([0-9a-f]{32})\.plex\.direct\.?$');
final _machineIdentifier = RegExp(r'^[0-9a-f]{8,64}$');

/// The answer of a media server in [datagram], null for anything else: another status, a Content-Type other than
/// plex/media-server (the players answer too), no hash in Host, no Resource-Identifier, a port out of range. Header
/// names are read without case; lines may end with CRLF or LF, and the server mixes both (CRLF after the status line,
/// LF after each header).
GdmAnswer? parseGdmAnswer(Uint8List datagram) {
  final lines = utf8.decode(datagram, allowMalformed: true).split(RegExp(r'\r?\n'));
  if (lines.isEmpty || !_statusLine.hasMatch(lines.first.trim())) {
    return null;
  }
  final headers = <String, String>{};
  for (final line in lines.skip(1)) {
    if (line.trim().isEmpty) {
      break;
    }
    final colon = line.indexOf(':');
    if (colon <= 0) {
      continue;
    }
    headers.putIfAbsent(line.substring(0, colon).trim().toLowerCase(), () => line.substring(colon + 1).trim());
  }
  if (headers['content-type']?.toLowerCase() != 'plex/media-server') {
    return null;
  }
  final hash = _hostHash.firstMatch(headers['host']?.toLowerCase() ?? '')?.group(1);
  final machineIdentifier = headers['resource-identifier']?.toLowerCase();
  final port = int.tryParse(headers['port'] ?? '');
  if (hash == null ||
      !isPlexHash(hash) ||
      machineIdentifier == null ||
      !_machineIdentifier.hasMatch(machineIdentifier) ||
      port == null ||
      port <= 0 ||
      port > 65535) {
    return null;
  }
  final version = headers['version'];
  return GdmAnswer(
    name: headers['name'] ?? '',
    hash: hash,
    machineIdentifier: machineIdentifier,
    port: port,
    version: version == null || version.isEmpty ? null : version,
  );
}

/// The UDP socket of the probe, see [bindUdpTransport]
typedef GdmBind = Future<UdpTransport> Function({InternetAddress? address, bool broadcast});

/// Finds the Plex Media Servers with GDM, see the top of this file. A [DiscoveryProbe]: it listens until the discovery
/// ends.
class GdmProbe {
  const GdmProbe({
    this.bind = bindUdpTransport,
    this.localAddresses = localIPv4Addresses,
    this.repeatAt = const [Duration(milliseconds: 400), Duration(milliseconds: 1200)],
    this.sweepAt = const Duration(milliseconds: 100),
    this.sweepBatch = 32,
    this.sweepInterval = const Duration(milliseconds: 20),
  });

  /// Opens a socket; called twice, the broadcast and group requests going from the first (with broadcast allowed) and
  /// the sweep from the second
  final GdmBind bind;

  /// The IPv4 addresses of this device on its local networks, whose /24 the broadcasts and the sweep cover
  final Future<List<String>> Function() localAddresses;

  /// When the broadcast and group requests go again: UDP may lose them
  final List<Duration> repeatAt;

  /// When the unicast sweep starts, and its pace: [sweepBatch] datagrams every [sweepInterval]
  final Duration sweepAt;
  final int sweepBatch;
  final Duration sweepInterval;

  Stream<DiscoveredServer> call(DiscoveryRequest request) {
    final controller = StreamController<DiscoveredServer>();
    final stopped = Completer<void>();
    final transports = <UdpTransport>[];
    final subscriptions = <StreamSubscription<Datagram>>[];

    void stop() {
      if (stopped.isCompleted) {
        return;
      }
      stopped.complete();
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
      for (final transport in transports) {
        transport.close();
      }
      if (!controller.isClosed) {
        unawaited(controller.close());
      }
    }

    bool isOver() => stopped.isCompleted || request.isCancelled;

    /// A socket, null when the discovery ended meanwhile
    Future<UdpTransport?> open({bool broadcast = false}) async {
      final transport = await bind(broadcast: broadcast);
      if (isOver()) {
        transport.close();
        return null;
      }
      transports.add(transport);
      return transport;
    }

    Future<void> run() async {
      final UdpTransport group;
      final UdpTransport sweep;
      final List<String> own;
      try {
        final first = isOver() ? null : await open(broadcast: true);
        final second = first == null ? null : await open();
        if (first == null || second == null) {
          return;
        }
        group = first;
        sweep = second;
        own = request.hosts == null ? await localAddresses() : const [];
      } catch (error) {
        _log.fine('GDM is not available: $error');
        stop();
        return;
      }

      final seen = <String>{};
      void received(Datagram datagram) {
        if (isOver()) {
          return;
        }
        // The address the answer came from is the one of the server on this network; only the local network counts
        final from = datagram.address;
        if (from.type != InternetAddressType.IPv4 || !isLocalNetworkAddress(from)) {
          return;
        }
        final answer = parseGdmAnswer(datagram.data);
        if (answer == null || !seen.add('${answer.machineIdentifier} ${from.address} ${answer.port}')) {
          return;
        }
        final name = answer.name.trim();
        controller.add(
          DiscoveredServer(
            host: from.address,
            displayName: name.isEmpty ? from.address : name,
            type: NetworkSourceType.plex,
            port: answer.port,
            useTls: true,
            origin: DiscoveryOrigin.gdm,
            address: from.address,
            discoveryId: answer.machineIdentifier,
            plexHash: answer.hash,
            version: answer.version,
          ),
        );
      }

      for (final transport in [group, sweep]) {
        subscriptions.add(transport.datagrams.listen(received, onError: (Object error) => _log.fine('GDM: $error')));
      }

      // The limited broadcast, the broadcast of each local /24 (some routers forward one and not the other), the group
      final targets = <InternetAddress>{
        InternetAddress('255.255.255.255'),
        for (final address in own)
          if (address.split('.').length == 4) InternetAddress('${address.substring(0, address.lastIndexOf('.'))}.255'),
        InternetAddress(gdmMulticastAddress),
      };
      void search() {
        for (final target in targets) {
          if (isOver()) {
            return;
          }
          group.send(gdmSearch, target, gdmPort);
        }
      }

      search();
      unawaited(_sweep(request, sweep, own, stopped.future, isOver));
      var elapsed = Duration.zero;
      for (final at in repeatAt) {
        if (!await _pause(at - elapsed, stopped.future)) {
          return;
        }
        elapsed = at;
        search();
      }
    }

    controller.onListen = () => unawaited(run());
    controller.onCancel = stop;
    unawaited(request.done.whenComplete(stop));
    return controller.stream;
  }

  /// The unicast requests to port 32414 of every host to scan, [sweepBatch] datagrams at a time
  Future<void> _sweep(
    DiscoveryRequest request,
    UdpTransport transport,
    List<String> own,
    Future<void> stopped,
    bool Function() isOver,
  ) async {
    if (!await _pause(sweepAt, stopped)) {
      return;
    }
    final hosts = request.hosts ?? {for (final address in own) ...SubnetScanProbe.subnetHostsOf(address)}.toList();
    var sent = 0;
    for (final host in hosts) {
      if (isOver()) {
        return;
      }
      final address = InternetAddress.tryParse(host);
      if (address == null || address.type != InternetAddressType.IPv4) {
        continue;
      }
      transport.send(gdmSearch, address, gdmPort);
      sent++;
      if (sent % sweepBatch == 0 && !await _pause(sweepInterval, stopped)) {
        return;
      }
    }
  }
}

/// Waits [delay], or less when [stopped] completes first; true when the whole delay passed
Future<bool> _pause(Duration delay, Future<void> stopped) {
  final done = Completer<bool>();
  final timer = Timer(delay, () {
    if (!done.isCompleted) {
      done.complete(true);
    }
  });
  unawaited(
    stopped.whenComplete(() {
      timer.cancel();
      if (!done.isCompleted) {
        done.complete(false);
      }
    }),
  );
  return done.future;
}
