// Finds the Jellyfin and Emby servers of the local network with their own discovery: the questions "who is
// JellyfinServer?" and "who is EmbyServer?" sent to UDP 7359 by broadcast from one socket, and to port 7359 of every
// host of the local /24 subnets from another. Each product answers its own question only (bench of release 49), from
// port 7359, with {Address, Id, Name} (Jellyfin adds EndpointAddress). Address is the server's own idea of its address:
// in Docker bridge mode it holds the container's (172.17.0.3), so the host is the datagram's source and only the
// scheme and the port are taken from Address. Each answer is then confirmed by /System/Info/Public at that address,
// which needs no credential and tells the product and the version; an answer that does not confirm (a port mapped
// elsewhere) is left to the scan or to a typed address.
//
// The two sockets have the reason of GDM and SSDP (see plex/gdm.dart): the broadcast fails on iOS without the
// multicast entitlement, and dart:io closes the socket a send failed on, which must not be the one of the sweep. The
// sweep is then the only way, and the bench showed both products answer a question sent to their own address.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/infrastructure/network/udp_transport.dart';
import 'package:immich_mobile/infrastructure/network/upnp/ssdp.dart' show isLocalNetworkAddress;
import 'package:logging/logging.dart';

final _log = Logger('JellyfinDiscovery');

const jellyfinDiscoveryPort = 7359;

/// The questions of the two products, both sent: each answers its own only
final jellyfinDiscoveryQuestions = [ascii.encode('who is JellyfinServer?'), ascii.encode('who is EmbyServer?')];

/// The answer in [datagram], null for anything else
JellyfinDiscoveryAnswer? parseJellyfinDiscoveryAnswer(List<int> datagram) {
  try {
    return JellyfinDiscoveryAnswer.parse(jsonDecode(utf8.decode(datagram, allowMalformed: true)));
  } on FormatException {
    return null;
  }
}

/// What /System/Info/Public says at [base], null when nothing answers like Jellyfin or Emby there within [timeout].
/// Sends no credential; the certificate of an https address is not checked, since nothing is sent.
Future<JellyfinPublicInfo?> jellyfinPublicInfoAt(
  Uri base, {
  Duration timeout = const Duration(seconds: 2),
  Future<void>? until,
}) async {
  final client = IOClient(
    HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = const Duration(seconds: 1)
      ..badCertificateCallback = (_, _, _) => true,
  );
  unawaited(until?.whenComplete(client.close));
  try {
    final request = http.Request('GET', base.replace(path: '${base.path}/System/Info/Public'))
      ..followRedirects = false
      ..headers['accept'] = 'application/json';
    final response = await client.send(request).timeout(timeout);
    if (response.statusCode != 200) {
      unawaited(response.stream.listen(null, cancelOnError: true).cancel());
      return null;
    }
    final body = await response.stream.timeout(timeout).fold<List<int>>([], (all, part) {
      if (all.length + part.length > 64 * 1024) {
        throw const FormatException('Too large');
      }
      return all..addAll(part);
    });
    return JellyfinPublicInfo.parse(jsonDecode(utf8.decode(body, allowMalformed: true)));
  } catch (error) {
    _log.finest('No Jellyfin or Emby answer: ${error.runtimeType}');
    return null;
  } finally {
    client.close();
  }
}

/// The server [info] found at [host]:[port], for the found list: its id as discovery id, its product and version
DiscoveredServer jellyfinDiscovered(
  JellyfinPublicInfo info, {
  required String host,
  required int port,
  required bool useTls,
  required DiscoveryOrigin origin,
  String? name,
}) {
  final shown = (info.serverName ?? name ?? '').trim();
  return DiscoveredServer(
    host: host,
    displayName: shown.isEmpty ? host : shown,
    type: NetworkSourceType.jellyfin,
    port: port,
    useTls: useTls,
    origin: origin,
    address: host,
    discoveryId: info.id,
    version: info.version,
    product: info.product.name,
  );
}

/// The UDP socket of the probe, see [bindUdpTransport]
typedef JellyfinDiscoveryBind = Future<UdpTransport> Function({InternetAddress? address, bool broadcast});

/// Finds the Jellyfin and Emby servers, see the top of this file. A [DiscoveryProbe]: it listens until the discovery
/// ends.
class JellyfinDiscoveryProbe {
  const JellyfinDiscoveryProbe({
    this.bind = bindUdpTransport,
    this.localAddresses = localIPv4Addresses,
    this.confirm = jellyfinPublicInfoAt,
    this.repeatAt = const [Duration(milliseconds: 400), Duration(milliseconds: 1200)],
    this.sweepAt = const Duration(milliseconds: 100),
    this.sweepBatch = 32,
    this.sweepInterval = const Duration(milliseconds: 20),
  });

  final JellyfinDiscoveryBind bind;
  final Future<List<String>> Function() localAddresses;

  /// Confirms an answer at its address (see [jellyfinPublicInfoAt])
  final Future<JellyfinPublicInfo?> Function(Uri base, {Duration timeout, Future<void>? until}) confirm;
  final List<Duration> repeatAt;
  final Duration sweepAt;
  final int sweepBatch;
  final Duration sweepInterval;

  Stream<DiscoveredServer> call(DiscoveryRequest request) {
    final controller = StreamController<DiscoveredServer>();
    final stopped = Completer<void>();
    final transports = <UdpTransport>[];
    final subscriptions = <StreamSubscription<Datagram>>[];
    final confirmations = <Future<void>>[];

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
      unawaited(
        Future.wait(confirmations).whenComplete(() {
          if (!controller.isClosed) {
            unawaited(controller.close());
          }
        }),
      );
    }

    bool isOver() => stopped.isCompleted || request.isCancelled;

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
        _log.fine('The Jellyfin discovery is not available: ${error.runtimeType}');
        stop();
        return;
      }

      final seen = <String>{};
      void received(Datagram datagram) {
        if (isOver()) {
          return;
        }
        final from = datagram.address;
        if (from.type != InternetAddressType.IPv4 || !isLocalNetworkAddress(from)) {
          return;
        }
        final answer = parseJellyfinDiscoveryAnswer(datagram.data);
        if (answer == null) {
          return;
        }
        final port = answer.port ?? (answer.useTls ? 8920 : 8096);
        if (!seen.add('${answer.id} ${from.address} $port')) {
          return;
        }
        confirmations.add(() async {
          final base = Uri(scheme: answer.useTls ? 'https' : 'http', host: from.address, port: port);
          final info = await confirm(base, timeout: const Duration(seconds: 2), until: stopped.future);
          if (info == null || info.id != answer.id) {
            _log.fine('An answer of the discovery did not confirm at its address');
            return;
          }
          if (!controller.isClosed && !request.isCancelled) {
            controller.add(
              jellyfinDiscovered(
                info,
                host: from.address,
                port: port,
                useTls: answer.useTls,
                origin: DiscoveryOrigin.jellyfin,
                name: answer.name,
              ),
            );
          }
        }());
      }

      for (final transport in [group, sweep]) {
        subscriptions.add(
          transport.datagrams.listen(received, onError: (Object error) => _log.fine('UDP: ${error.runtimeType}')),
        );
      }

      final targets = <InternetAddress>{
        InternetAddress('255.255.255.255'),
        for (final address in own)
          if (address.split('.').length == 4) InternetAddress('${address.substring(0, address.lastIndexOf('.'))}.255'),
      };
      void ask() {
        for (final target in targets) {
          for (final question in jellyfinDiscoveryQuestions) {
            if (isOver()) {
              return;
            }
            group.send(question, target, jellyfinDiscoveryPort);
          }
        }
      }

      ask();
      unawaited(_sweep(request, sweep, own, stopped.future, isOver));
      var elapsed = Duration.zero;
      for (final at in repeatAt) {
        if (!await _pause(at - elapsed, stopped.future)) {
          return;
        }
        elapsed = at;
        ask();
      }
    }

    controller.onListen = () => unawaited(run());
    controller.onCancel = stop;
    unawaited(request.done.whenComplete(stop));
    return controller.stream;
  }

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
      for (final question in jellyfinDiscoveryQuestions) {
        transport.send(question, address, jellyfinDiscoveryPort);
        sent++;
      }
      if (sent % sweepBatch == 0 && !await _pause(sweepInterval, stopped)) {
        return;
      }
    }
  }
}

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
