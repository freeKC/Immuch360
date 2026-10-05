// SSDP discovery of the DLNA media servers (UPnP MediaServer devices): an M-SEARCH sent to the multicast group of
// SSDP from one UDP socket, and the same request sent to port 1900 of every host of the local /24 subnets from another,
// each on an ephemeral port. Each server answers to the port the request came from with the LOCATION of its device
// description, which tells its name and where its ContentDirectory takes the Browse requests.
//
// The unicast sweep is the only way on iOS until Apple grants the app the multicast entitlement (without it, sending to
// the group fails, and dart:io closes the socket the send failed on: hence a socket of its own for the group), and it
// also finds servers when the multicast leaves through a VPN or another interface. The answers come back to the
// ephemeral ports, so no Android MulticastLock is needed, and the NOTIFY announcements of the servers (sent to port
// 1900) are not listened for.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/infrastructure/network/upnp/upnp_description.dart';
import 'package:logging/logging.dart';

final _log = Logger('Ssdp');

const ssdpMulticastAddress = '239.255.255.250';
const ssdpPort = 1900;

/// What the probe searches for: the media servers, and the devices with a ContentDirectory (some servers only answer
/// for the service)
const ssdpMediaServerTarget = 'urn:schemas-upnp-org:device:MediaServer:1';
const ssdpContentDirectoryTarget = 'urn:schemas-upnp-org:service:ContentDirectory:1';
const ssdpSearchTargets = [ssdpMediaServerTarget, ssdpContentDirectoryTarget];

/// The product token of the app in the UPnP requests. Servers only use it to pick a profile for the client, which a
/// minor version would not change.
const upnpProductToken = 'Immuch360/3.3';

/// The M-SEARCH request for [searchTarget], sent to the multicast group, or to [host] for a unicast request. [osToken]
/// is the "OS/version" part of the USER-AGENT header, see [ssdpOsToken].
Uint8List ssdpSearchRequest({
  required String searchTarget,
  required String osToken,
  String host = ssdpMulticastAddress,
}) => ascii.encode(
  'M-SEARCH * HTTP/1.1\r\n'
  'HOST: $host:$ssdpPort\r\n'
  'MAN: "ssdp:discover"\r\n'
  'MX: 2\r\n'
  'ST: $searchTarget\r\n'
  'USER-AGENT: $osToken UPnP/1.1 $upnpProductToken\r\n'
  '\r\n',
);

/// "Android/14", "iOS/18": the system and its major version, as UPnP 1.1 wants it in the USER-AGENT. dart:io only tells
/// the kernel version on Android, so the release comes from the device information there.
Future<String> ssdpOsToken() async {
  if (Platform.isAndroid) {
    try {
      final info = await DeviceInfoPlugin().androidInfo.timeout(const Duration(seconds: 1));
      return 'Android/${_majorOf(info.version.release)}';
    } catch (error) {
      _log.fine('No Android version for SSDP: $error');
      return 'Android';
    }
  }
  final name = Platform.isIOS ? 'iOS' : Platform.operatingSystem;
  final major = _majorOf(Platform.operatingSystemVersion);
  return major.isEmpty ? name : '$name/$major';
}

String _majorOf(String version) => RegExp(r'\d+').firstMatch(version)?.group(0) ?? '';

/// An answer to an M-SEARCH, see [parseSsdpResponse]
class SsdpResponse {
  const SsdpResponse({required this.location, required this.searchTarget, this.udn, this.usn, this.server});

  /// The device description
  final Uri location;

  /// The ST the server answered for
  final String searchTarget;

  /// "uuid:...", the device part of the USN, null when the USN does not start with one
  final String? udn;
  final String? usn;

  /// The SERVER header, for the logs
  final String? server;

  @override
  String toString() => 'SsdpResponse($location $searchTarget ${udn ?? usn ?? ''})';
}

final _statusLine = RegExp(r'^HTTP/1\.\d\s+200(\s|$)', caseSensitive: false);

/// The answer of a media server in [datagram], null for anything else: another status, another search target, no
/// LOCATION or one that is not an http or https URL, or a LOCATION outside the local network (see
/// [isAcceptableLocationHost]). Header names are read without case, lines may end with CRLF or LF.
SsdpResponse? parseSsdpResponse(Uint8List datagram) {
  final text = utf8.decode(datagram, allowMalformed: true);
  final lines = text.split(RegExp(r'\r?\n'));
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
  final target = headers['st'];
  final searched = ssdpSearchTargets.where((t) => t.toLowerCase() == target?.toLowerCase()).firstOrNull;
  if (searched == null) {
    return null;
  }
  final location = Uri.tryParse(headers['location'] ?? '');
  if (location == null ||
      (location.scheme != 'http' && location.scheme != 'https') ||
      location.host.isEmpty ||
      !isAcceptableLocationHost(location.host)) {
    return null;
  }
  final usn = headers['usn'];
  String? udn;
  if (usn != null && usn.toLowerCase().startsWith('uuid:')) {
    final end = usn.indexOf('::');
    udn = end < 0 ? usn : usn.substring(0, end);
  }
  return SsdpResponse(
    location: location,
    searchTarget: searched,
    udn: udn,
    usn: usn == null || usn.isEmpty ? null : usn,
    server: headers['server'],
  );
}

/// A host name, or an IPv4 address of the local network (see [isLocalNetworkAddress]). Anything else in a LOCATION is
/// a server pointing the app outside the local network, which it does not follow.
bool isAcceptableLocationHost(String host) {
  final address = InternetAddress.tryParse(host);
  if (address == null) {
    return true;
  }
  return address.type == InternetAddressType.IPv4 && isLocalNetworkAddress(address);
}

/// Loopback, link-local or private: 127/8, 169.254/16, 10/8, 172.16/12, 192.168/16, and for IPv6 ::1, fe80::/10 and
/// the unique local fc00::/7
bool isLocalNetworkAddress(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal) {
    return true;
  }
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] < 32) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }
  return address.type == InternetAddressType.IPv6 && (bytes[0] & 0xFE) == 0xFC;
}

/// A UDP socket the probe sends from and receives on. Injectable for the tests.
abstract class SsdpTransport {
  /// What comes to the socket, until [close]
  Stream<Datagram> get datagrams;

  /// Sends [bytes]; a failure (no route, multicast not allowed) is logged, not thrown
  void send(List<int> bytes, InternetAddress address, int port);

  void close();
}

/// A socket on an ephemeral port of every IPv4 interface (of the one of [address] when given: the multicast then leaves
/// through it), multicast limited to 4 hops.
///
/// dart:io closes a datagram socket for good on the first send that fails, without throwing: send returns 0 and the
/// error reaches the listener of the socket right after. iOS fails every send to the group without the multicast
/// entitlement, and iOS and macOS fail a send to a host whose ARP lookup failed shortly before ("Host is down", a sweep
/// run again soon after the first). The transport then binds a new socket on the same port, so that the answers to
/// what was sent before still come in, and sends what was sent meanwhile on it.
Future<SsdpTransport> bindSsdpTransport({InternetAddress? address}) async {
  final host = address ?? InternetAddress.anyIPv4;
  final transport = _RawSsdpTransport((port) async {
    final socket = await RawDatagramSocket.bind(host, port);
    try {
      socket.multicastHops = 4;
    } catch (error) {
      _log.fine('SSDP multicast hops: $error');
    }
    return socket;
  });
  await transport.start();
  return transport;
}

class _RawSsdpTransport implements SsdpTransport {
  _RawSsdpTransport(this._bind);

  /// Binds a socket on [port], 0 for an ephemeral one
  final Future<RawDatagramSocket> Function(int port) _bind;
  final _datagrams = StreamController<Datagram>();

  /// The socket to send on, null from the failure that closes one until the next one is bound
  RawDatagramSocket? _socket;
  bool _closed = false;

  /// What was sent while there was no socket, sent on the next one: a few batches of the sweep at most
  final _waiting = Queue<({List<int> bytes, InternetAddress address, int port})>();
  static const _maxWaiting = 256;

  @override
  Stream<Datagram> get datagrams => _datagrams.stream;

  /// Binds the first socket; throws when there is none to have
  Future<void> start() async => _use(await _bind(0));

  void _use(RawDatagramSocket socket) {
    if (_closed) {
      socket.close();
      return;
    }
    final port = socket.port;
    _socket = socket;
    socket.listen(
      (event) {
        if (event != RawSocketEvent.read) {
          return;
        }
        for (var datagram = socket.receive(); datagram != null; datagram = socket.receive()) {
          if (!_datagrams.isClosed) {
            _datagrams.add(datagram);
          }
        }
      },
      onError: (Object error) {
        // dart:io closes the socket right after any error: what is sent from now on waits for the next one
        _log.fine('SSDP socket on port $port: $error');
        if (identical(_socket, socket)) {
          _socket = null;
        }
      },
      onDone: () {
        if (identical(_socket, socket)) {
          _socket = null;
        }
        // Once the socket is really closed, so that its port is free again
        if (!_closed) {
          unawaited(_rebind(port));
        }
      },
    );
    while (_waiting.isNotEmpty) {
      final datagram = _waiting.removeFirst();
      socket.send(datagram.bytes, datagram.address, datagram.port);
    }
  }

  /// A new socket on [port], else on another port when it is taken: only the answers to what the closed socket sent
  /// are lost then
  Future<void> _rebind(int port) async {
    RawDatagramSocket socket;
    try {
      socket = await _bind(port);
    } catch (error) {
      _log.fine('SSDP: port $port is not free again ($error), taking another one');
      try {
        socket = await _bind(0);
      } catch (error) {
        _log.fine('SSDP: no socket any more: $error');
        close();
        return;
      }
    }
    _log.fine('SSDP: a failed send closed the socket on port $port; sending from port ${socket.port} now');
    _use(socket);
  }

  @override
  void send(List<int> bytes, InternetAddress address, int port) {
    if (_closed) {
      return;
    }
    final socket = _socket;
    if (socket == null) {
      if (_waiting.length < _maxWaiting) {
        _waiting.add((bytes: bytes, address: address, port: port));
      }
      return;
    }
    // 0 when nothing left: a failure (no route, multicast not allowed), which closes the socket right after (see
    // onError), or a full buffer, which only loses this datagram as UDP may anyway
    if (socket.send(bytes, address, port) == 0) {
      _log.finest('SSDP: nothing sent to ${address.address}:$port');
    }
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _waiting.clear();
    _socket?.close();
    _socket = null;
    unawaited(_datagrams.close());
  }
}

/// The media server described at [location], null when there is none there. Gives up once [request] ended.
typedef UpnpDescriptionFetcher = Future<UpnpDevice?> Function(Uri location, DiscoveryRequest request);

/// Longest wait for a device description, and its largest size
const upnpDescriptionTimeout = Duration(milliseconds: 2500);
const upnpDescriptionMaxSize = 256 * 1024;

/// GETs the device description at [location] and parses it. Certificates are not checked: nothing is sent but the
/// request, and the user picks the server afterwards.
Future<UpnpDevice?> fetchUpnpDescription(Uri location, DiscoveryRequest request) async {
  if (request.isCancelled) {
    return null;
  }
  final client = HttpClient()
    ..connectionTimeout = upnpDescriptionTimeout
    ..idleTimeout = const Duration(seconds: 1)
    ..userAgent = '$upnpProductToken UPnP/1.0 DLNADOC/1.50'
    ..badCertificateCallback = (_, _, _) => true;
  // Closing the client makes the request under way fail at once
  unawaited(request.done.whenComplete(() => client.close(force: true)));
  try {
    return await () async {
      final response = await (await client.getUrl(location)).close();
      if (response.statusCode != HttpStatus.ok) {
        await response.listen(null).cancel();
        return null;
      }
      final body = BytesBuilder(copy: false);
      await for (final chunk in response) {
        body.add(chunk);
        if (body.length > upnpDescriptionMaxSize) {
          _log.fine('SSDP: the description at $location is too large');
          return null;
        }
      }
      return parseUpnpDescription(utf8.decode(body.takeBytes(), allowMalformed: true), location);
    }().timeout(upnpDescriptionTimeout);
  } catch (error) {
    _log.fine('SSDP: no description at $location: $error');
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Finds the DLNA media servers with SSDP, see the top of this file. A [DiscoveryProbe]: it listens until the
/// discovery ends.
class SsdpProbe {
  const SsdpProbe({
    this.bind = bindSsdpTransport,
    this.fetchDescription = fetchUpnpDescription,
    this.localAddresses = localIPv4Addresses,
    this.osToken = ssdpOsToken,
    this.repeatAt = const [Duration(milliseconds: 400), Duration(milliseconds: 1200)],
    this.sweepAt = const Duration(milliseconds: 100),
    this.sweepBatch = 32,
    this.sweepInterval = const Duration(milliseconds: 20),
    this.maxFetches = 8,
    this.maxDescriptionAttempts = 3,
  });

  /// Opens a socket; called twice, the group requests going from the first and the sweep from the second
  final Future<SsdpTransport> Function() bind;
  final UpnpDescriptionFetcher fetchDescription;

  /// The IPv4 addresses of this device on its local networks, whose /24 the unicast sweep covers
  final Future<List<String>> Function() localAddresses;
  final Future<String> Function() osToken;

  /// When the MediaServer search goes to the group again, from the start: UDP may lose it
  final List<Duration> repeatAt;

  /// When the unicast sweep starts, and its pace: [sweepBatch] datagrams every [sweepInterval]
  final Duration sweepAt;
  final int sweepBatch;
  final Duration sweepInterval;

  /// Device descriptions fetched at once
  final int maxFetches;

  /// Times the description of one server is asked for when it cannot be read, each on a new answer of the server
  final int maxDescriptionAttempts;

  Stream<DiscoveredServer> call(DiscoveryRequest request) {
    final controller = StreamController<DiscoveredServer>();
    final stopped = Completer<void>();
    final transports = <SsdpTransport>[];
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
    Future<SsdpTransport?> open() async {
      final transport = await bind();
      if (isOver()) {
        transport.close();
        return null;
      }
      transports.add(transport);
      return transport;
    }

    Future<void> run() async {
      final String os;
      // Two sockets: a send to the group that fails (always on iOS without the multicast entitlement) closes the socket
      // it went from, which must not be the one of the sweep and of its answers
      final SsdpTransport group;
      final SsdpTransport sweep;
      try {
        os = await osToken();
        final first = isOver() ? null : await open();
        final second = first == null ? null : await open();
        if (first == null || second == null) {
          return;
        }
        group = first;
        sweep = second;
      } catch (error) {
        _log.fine('SSDP is not available: $error');
        stop();
        return;
      }
      final seen = <String>{};
      final attempts = <String, int>{};
      final fetches = _Fetches(maxFetches);
      void received(Datagram datagram) {
        if (isOver()) {
          return;
        }
        final response = parseSsdpResponse(datagram.data);
        if (response == null) {
          return;
        }
        // One description per server, whatever it answered for and however many requests reached it. One that could
        // not be read (a server slow to answer its first request) is asked for again on the next answer, a few times.
        final key = (response.udn ?? response.location.toString()).toLowerCase();
        final attempt = (attempts[key] ?? 0) + 1;
        if (attempt > maxDescriptionAttempts || !seen.add(key)) {
          return;
        }
        attempts[key] = attempt;
        unawaited(
          fetches.run(() async {
            if (isOver()) {
              return;
            }
            UpnpDevice? device;
            try {
              device = await fetchDescription(response.location, request);
            } finally {
              if (device == null) {
                seen.remove(key);
              }
            }
            if (device == null || isOver() || controller.isClosed) {
              return;
            }
            controller.add(serverOf(response, device));
          }),
        );
      }

      for (final transport in [group, sweep]) {
        subscriptions.add(transport.datagrams.listen(received, onError: (Object error) => _log.fine('SSDP: $error')));
      }

      final groupAddress = InternetAddress(ssdpMulticastAddress);
      void search(String target) {
        if (!isOver()) {
          group.send(ssdpSearchRequest(searchTarget: target, osToken: os), groupAddress, ssdpPort);
        }
      }

      search(ssdpMediaServerTarget);
      search(ssdpContentDirectoryTarget);
      unawaited(_sweep(request, sweep, os, stopped.future, isOver));
      var elapsed = Duration.zero;
      for (final at in repeatAt) {
        if (!await _pause(at - elapsed, stopped.future)) {
          return;
        }
        elapsed = at;
        search(ssdpMediaServerTarget);
      }
    }

    controller.onListen = () => unawaited(run());
    controller.onCancel = stop;
    unawaited(request.done.whenComplete(stop));
    return controller.stream;
  }

  /// The unicast requests to port 1900 of every host to scan, [sweepBatch] datagrams at a time. Each host gets the
  /// request of UPnP 1.1, with its own address as HOST, and the multicast one: servers built on libupnp (Gerbera, many
  /// NAS and TV boxes) only answer a request whose HOST is the multicast group, wherever it came from.
  ///
  /// minidlna on Linux binds its SSDP socket to the group address, so no unicast request ever reaches it: on iOS,
  /// until the multicast entitlement is granted, it is added by hand (the DLNA hint of the form tells how).
  Future<void> _sweep(
    DiscoveryRequest request,
    SsdpTransport transport,
    String os,
    Future<void> stopped,
    bool Function() isOver,
  ) async {
    if (!await _pause(sweepAt, stopped)) {
      return;
    }
    final List<String> hosts;
    final given = request.hosts;
    if (given != null) {
      hosts = given;
    } else {
      final own = await localAddresses();
      hosts = {for (final address in own) ...SubnetScanProbe.subnetHostsOf(address)}.toList();
    }
    var sent = 0;
    for (final host in hosts) {
      if (isOver()) {
        return;
      }
      final address = InternetAddress.tryParse(host);
      if (address == null || address.type != InternetAddressType.IPv4) {
        continue;
      }
      for (final search in [
        ssdpSearchRequest(searchTarget: ssdpMediaServerTarget, osToken: os, host: host),
        ssdpSearchRequest(searchTarget: ssdpMediaServerTarget, osToken: os),
      ]) {
        transport.send(search, address, ssdpPort);
        sent++;
        if (sent % sweepBatch == 0 && !await _pause(sweepInterval, stopped)) {
          return;
        }
      }
    }
  }

  /// The server a description stands for
  static DiscoveredServer serverOf(SsdpResponse response, UpnpDevice device) {
    final location = response.location;
    final host = location.host;
    final name = device.friendlyName.trim();
    final udn = device.udn.isNotEmpty ? device.udn : response.udn;
    return DiscoveredServer(
      host: host,
      displayName: name.isEmpty ? host : name,
      type: NetworkSourceType.dlna,
      port: location.port,
      useTls: location.scheme == 'https',
      path: location.hasQuery ? '${location.path}?${location.query}' : location.path,
      origin: DiscoveryOrigin.ssdp,
      address: InternetAddress.tryParse(host) == null ? null : host,
      discoveryId: udn == null || udn.isEmpty ? null : udn,
    );
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

/// At most [size] fetches at once, the others in turn
class _Fetches {
  _Fetches(this.size);

  final int size;
  var _running = 0;
  final _waiting = Queue<Completer<void>>();

  Future<void> run(Future<void> Function() task) async {
    if (_running < size) {
      _running++;
    } else {
      final turn = Completer<void>();
      _waiting.add(turn);
      // Handed over by the task that ends, the count staying the same
      await turn.future;
    }
    try {
      await task();
    } catch (error) {
      _log.fine('SSDP: $error');
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }
}
