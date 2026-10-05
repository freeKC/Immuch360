// Finds the SMB, WebDAV and DLNA servers of the local network for the form that adds a share. Several probes run side
// by side (mDNS / DNS-SD, a scan of the subnet, SSDP, see network_discovery_probes.dart); what they find is merged into
// one list that grows while they run. A probe that fails, or a platform without what it needs, only means fewer
// servers.

import 'dart:async';

import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:logging/logging.dart';

final _log = Logger('NetworkDiscovery');

/// How a server was found
enum DiscoveryOrigin { mdns, scan, ssdp }

/// A server found on the network, with what the form needs to reach it
class DiscoveredServer {
  const DiscoveredServer({
    required this.host,
    required this.displayName,
    required this.type,
    required this.port,
    this.useTls = false,
    this.path = '',
    required this.origin,
    this.address,
    this.discoveryId,
    this.username,
    this.isPhoneShare = false,
  });

  /// The IP address or the host name to put in the server field
  final String host;

  /// The name of the server: its mDNS name, else its reverse DNS name, else its address
  final String displayName;
  final NetworkSourceType type;
  final int port;

  /// WebDAV over HTTPS
  final bool useTls;

  /// The path of the WebDAV root when known, "" otherwise (and always for SMB). DLNA: the path of the device
  /// description URL with its query.
  final String path;
  final DiscoveryOrigin origin;

  /// The IPv4 address of [host] when [host] is a name, so that the same server found by name and by address is shown
  /// once. Not part of the equality.
  final String? address;

  /// What the server tells about itself, to find it again when its address changes: the UPnP UDN of a DLNA media
  /// server, the TXT id of a phone share. Not part of the equality.
  final String? discoveryId;

  /// The user name the server announces (a phone share), for the form to fill in
  final String? username;

  /// The gallery of a phone running this app, shared on the network ("Share this phone on the network")
  final bool isPhoneShare;

  /// What tells two finds of the same server apart from two servers: [address] when known, else [host]. One address
  /// and port may serve several DLNA media servers (a NAS, a server with embedded devices): each is told apart by its
  /// UDN, else by its description path.
  (String, NetworkSourceType, int, String) get mergeKey => (
    (address ?? host).toLowerCase(),
    type,
    port,
    type == NetworkSourceType.dlna ? (discoveryId ?? path).toLowerCase() : '',
  );

  /// The same server as found by two probes: the mDNS find wins (it has the name the server gives itself), a known
  /// WebDAV path, discovery id and user name are kept
  DiscoveredServer mergedWith(DiscoveredServer other) {
    final preferred = other.origin == DiscoveryOrigin.mdns && origin != DiscoveryOrigin.mdns ? other : this;
    final second = identical(preferred, this) ? other : this;
    return DiscoveredServer(
      host: preferred.host,
      displayName: preferred.displayName,
      type: preferred.type,
      port: preferred.port,
      useTls: preferred.useTls,
      path: preferred.path.isNotEmpty ? preferred.path : second.path,
      origin: preferred.origin,
      address: preferred.address ?? second.address,
      discoveryId: preferred.discoveryId ?? second.discoveryId,
      username: preferred.username ?? second.username,
      isPhoneShare: preferred.isPhoneShare || second.isPhoneShare,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DiscoveredServer && other.host == host && other.type == type && other.port == port;

  @override
  int get hashCode => Object.hash(host, type, port);

  @override
  String toString() =>
      'DiscoveredServer(${type.name} $displayName $host:$port${useTls ? ' tls' : ''} $path'
      '${discoveryId == null ? '' : ' $discoveryId'}${isPhoneShare ? ' phone' : ''})';

  /// By name without case, then by host
  static int compare(DiscoveredServer a, DiscoveredServer b) {
    final byName = a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    if (byName != 0) {
      return byName;
    }
    final byHost = a.host.compareTo(b.host);
    return byHost != 0 ? byHost : a.port.compareTo(b.port);
  }
}

/// What one discovery asks of the probes
class DiscoveryRequest {
  DiscoveryRequest({this.hosts, required this.done}) {
    unawaited(done.whenComplete(() => _cancelled = true));
  }

  /// The hosts to scan instead of the local subnet, null for the subnet
  final List<String>? hosts;

  /// Completes when the discovery ends (timeout or no more listener); the probes stop then
  final Future<void> done;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;
}

/// One way of finding servers. Its stream ends when it has nothing more to find; it may also be cut short when the
/// discovery ends.
typedef DiscoveryProbe = Stream<DiscoveredServer> Function(DiscoveryRequest request);

/// Runs the [probes] side by side and merges what they find
class NetworkDiscoveryService {
  NetworkDiscoveryService({required List<DiscoveryProbe> probes}) : _probes = List.unmodifiable(probes);

  final List<DiscoveryProbe> _probes;

  static const defaultTimeout = Duration(seconds: 6);

  /// The servers found, de-duplicated and sorted (see [DiscoveredServer.compare]); a new list each time one more is
  /// found. The stream ends after [timeout], or sooner once every probe ended. [hosts] replaces the scan of the local
  /// subnet by these hosts.
  Stream<List<DiscoveredServer>> discover({Duration timeout = defaultTimeout, List<String>? hosts}) {
    final done = Completer<void>();
    final found = <(String, NetworkSourceType, int, String), DiscoveredServer>{};
    final subscriptions = <StreamSubscription<DiscoveredServer>>[];
    late final StreamController<List<DiscoveredServer>> controller;
    Timer? timer;
    var running = 0;

    Future<void> finish() async {
      if (done.isCompleted) {
        return;
      }
      done.complete();
      timer?.cancel();
      final cancelling = [for (final subscription in subscriptions) subscription.cancel()];
      subscriptions.clear();
      // Not awaited: the future of close never completes once the listener is gone
      unawaited(controller.close());
      try {
        await Future.wait(cancelling).timeout(const Duration(seconds: 1));
      } catch (error) {
        _log.fine('A discovery probe did not stop cleanly: $error');
      }
    }

    void add(DiscoveredServer server) {
      if (done.isCompleted) {
        return;
      }
      final key = server.mergeKey;
      final known = found[key];
      final merged = known == null ? server : known.mergedWith(server);
      if (known != null &&
          merged == known &&
          merged.displayName == known.displayName &&
          merged.path == known.path &&
          merged.useTls == known.useTls &&
          merged.discoveryId == known.discoveryId &&
          merged.username == known.username &&
          merged.isPhoneShare == known.isPhoneShare) {
        return;
      }
      found[key] = merged;
      controller.add(List.unmodifiable(found.values.toList()..sort(DiscoveredServer.compare)));
    }

    void probeEnded() {
      running--;
      if (running == 0) {
        unawaited(finish());
      }
    }

    controller = StreamController<List<DiscoveredServer>>(
      onListen: () {
        final request = DiscoveryRequest(hosts: hosts, done: done.future);
        timer = Timer(timeout, () => unawaited(finish()));
        for (final probe in _probes) {
          final Stream<DiscoveredServer> stream;
          try {
            stream = probe(request);
          } catch (error, stackTrace) {
            _log.warning('A discovery probe failed to start', error, stackTrace);
            continue;
          }
          running++;
          subscriptions.add(
            stream.listen(
              add,
              onError: (Object error, StackTrace stackTrace) =>
                  _log.warning('A discovery probe failed', error, stackTrace),
              onDone: probeEnded,
            ),
          );
        }
        if (running == 0) {
          scheduleMicrotask(() => unawaited(finish()));
        }
      },
      onCancel: finish,
    );
    return controller.stream;
  }
}
