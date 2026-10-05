// The probes of the network discovery (see NetworkDiscoveryService):
//
// - mDNS / DNS-SD through bonsoir: the servers that announce _smb._tcp, _webdav._tcp or _webdavs._tcp, and the web
//   servers that announce _http._tcp or _https._tcp when they turn out to speak WebDAV.
// - A scan of the local /24 subnet with plain TCP connections, on the ports of SMB (445), of the WebDAV server of
//   Synology (5005, 5006 over TLS) and of the usual web servers (80, 443, 8080, 8443).
// - The confirmation of what answers: an SMB2 NEGOTIATE on a raw socket for SMB, an HTTP OPTIONS or PROPFIND for
//   WebDAV, so that a router or a printer is not offered as a share.
// - SSDP for the DLNA media servers, see upnp/ssdp.dart. They are not scanned for by port: the path of their device
//   description cannot be guessed (Jellyfin, Windows and Synology put an id in it).
//
// Nothing is sent with credentials, and the probes stop when the discovery ends.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/network/upnp/ssdp.dart';
import 'package:logging/logging.dart';

final _log = Logger('NetworkDiscoveryProbes');

/// The discovery of the app: mDNS, the scan of the subnet, with [extraPorts] scanned as well (by default those of
/// IMMUCH_SCAN_PORTS, see [ScanPort.fromEnvironment]), and SSDP
NetworkDiscoveryService createNetworkDiscoveryService({List<ScanPort>? extraPorts}) {
  const confirmer = ServerConfirmer();
  return NetworkDiscoveryService(
    probes: [
      const MdnsProbe(confirmer: confirmer).call,
      SubnetScanProbe(confirmer: confirmer, extraPorts: extraPorts ?? ScanPort.fromEnvironment()).call,
      const SsdpProbe().call,
    ],
  );
}

/// The install id this device announces when it shares its gallery (see StoreKey.phoneShareId), null when it never
/// did or the store is not there
String? storedPhoneShareId() {
  try {
    return StoreService.I.tryGet(StoreKey.phoneShareId);
  } on UnsupportedError {
    return null;
  }
}

/// A port the scan tries, and what a server answering on it would be
class ScanPort {
  const ScanPort(this.port, this.type, {this.useTls = false});

  final int port;
  final NetworkSourceType type;

  /// WebDAV over HTTPS
  final bool useTls;

  /// SMB, the WebDAV server of Synology (5006 over TLS), then the web servers that may serve WebDAV
  static const defaults = [
    ScanPort(445, NetworkSourceType.smb),
    ScanPort(5005, NetworkSourceType.webdav),
    ScanPort(5006, NetworkSourceType.webdav, useTls: true),
    ScanPort(80, NetworkSourceType.webdav),
    ScanPort(443, NetworkSourceType.webdav, useTls: true),
    ScanPort(8080, NetworkSourceType.webdav),
    ScanPort(8443, NetworkSourceType.webdav, useTls: true),
  ];

  /// The ports given at build time with --dart-define=IMMUCH_SCAN_PORTS=..., see [parse]
  static List<ScanPort> fromEnvironment() => parse(const String.fromEnvironment('IMMUCH_SCAN_PORTS'));

  /// "port:type[:tls]" entries separated by commas, type "smb" or "webdav": "1445:smb,1880:webdav,8443:webdav:tls".
  /// Entries that do not read are left out.
  static List<ScanPort> parse(String text) {
    final ports = <ScanPort>[];
    for (final entry in text.split(',')) {
      final parts = entry.trim().split(':').map((part) => part.trim().toLowerCase()).toList();
      if (parts.length < 2 || parts.length > 3) {
        continue;
      }
      final port = int.tryParse(parts[0]);
      final type = switch (parts[1]) {
        'smb' => NetworkSourceType.smb,
        'webdav' || 'dav' => NetworkSourceType.webdav,
        _ => null,
      };
      final tls = parts.length == 3 ? parts[2] : '';
      if (port == null || port < 1 || port > 65535 || type == null || (tls.isNotEmpty && tls != 'tls')) {
        continue;
      }
      ports.add(ScanPort(port, type, useTls: tls == 'tls' && type == NetworkSourceType.webdav));
    }
    return ports;
  }

  @override
  bool operator ==(Object other) =>
      other is ScanPort && other.port == port && other.type == type && other.useTls == useTls;

  @override
  int get hashCode => Object.hash(port, type, useTls);

  @override
  String toString() => '$port:${type.name}${useTls ? ':tls' : ''}';
}

/// Tells whether what answers on a port is an SMB or a WebDAV server
class ServerConfirmer {
  const ServerConfirmer({
    this.smbTimeout = const Duration(milliseconds: 1500),
    this.httpTimeout = const Duration(seconds: 2),
  });

  final Duration smbTimeout;
  final Duration httpTimeout;

  /// Whether the server at [host]:[port] answers an SMB2 NEGOTIATE, on a connection of its own. False once [request]
  /// ended: nothing more is sent then.
  Future<bool> isSmb(String host, int port, {DiscoveryRequest? request}) async {
    if (request?.isCancelled ?? false) {
      return false;
    }
    final Socket socket;
    try {
      socket = await Socket.connect(host, port, timeout: smbTimeout);
    } catch (_) {
      return false;
    }
    if (request?.isCancelled ?? false) {
      socket.destroy();
      return false;
    }
    return negotiatesSmb2(socket, timeout: smbTimeout, until: request?.done);
  }

  /// Sends an SMB2 NEGOTIATE on [socket] and tells whether the answer is an SMB2 message (whatever its status: a
  /// server that refuses the dialects still answers in SMB2). Destroys the socket. Gives up with false when [until]
  /// completes first.
  static Future<bool> negotiatesSmb2(
    Socket socket, {
    Duration timeout = const Duration(milliseconds: 1500),
    Future<void>? until,
  }) async {
    final received = BytesBuilder(copy: false);
    final answered = Completer<bool>();
    StreamSubscription<Uint8List>? subscription;
    unawaited(
      until?.whenComplete(() {
        if (!answered.isCompleted) {
          answered.complete(false);
        }
      }),
    );
    try {
      subscription = socket.listen(
        (data) {
          received.add(data);
          if (received.length >= 8 && !answered.isCompleted) {
            answered.complete(isSmb2Reply(received.toBytes()));
          }
        },
        onError: (Object _) {
          if (!answered.isCompleted) {
            answered.complete(false);
          }
        },
        onDone: () {
          if (!answered.isCompleted) {
            answered.complete(isSmb2Reply(received.toBytes()));
          }
        },
        cancelOnError: true,
      );
      socket.add(smb2NegotiateRequest());
      return await answered.future.timeout(timeout, onTimeout: () => false);
    } catch (_) {
      return false;
    } finally {
      unawaited(subscription?.cancel());
      socket.destroy();
    }
  }

  /// SMB2 NEGOTIATE request offering the dialects 2.0.2, 2.1, 3.0, 3.0.2 and 3.1.1 (with the preauthentication
  /// integrity context that 3.1.1 requires), behind its NetBIOS session header
  @visibleForTesting
  static Uint8List smb2NegotiateRequest({Random? random}) {
    final rng = random ?? Random.secure();
    const dialects = [0x0202, 0x0210, 0x0300, 0x0302, 0x0311];
    const headerLength = 64;
    const bodyLength = 36 + 2 * 5; // 46
    const contextOffset = headerLength + bodyLength + 2; // 112, contexts start 8-byte aligned
    const contextDataLength = 2 + 2 + 2 + 32; // hash count, salt length, SHA-512, salt
    const messageLength = contextOffset + 8 + contextDataLength;

    final message = ByteData(messageLength);
    // SMB2 header
    message.setUint32(0, 0xFE534D42); // 0xFE 'S' 'M' 'B'
    message.setUint16(4, headerLength, Endian.little); // StructureSize
    message.setUint16(12, 0, Endian.little); // Command: NEGOTIATE
    message.setUint16(14, 1, Endian.little); // CreditRequest
    // NEGOTIATE request
    const body = headerLength;
    message.setUint16(body, 36, Endian.little); // StructureSize
    message.setUint16(body + 2, dialects.length, Endian.little); // DialectCount
    message.setUint16(body + 4, 1, Endian.little); // SecurityMode: signing enabled
    message.setUint32(body + 8, 0, Endian.little); // Capabilities
    for (var i = 0; i < 16; i++) {
      message.setUint8(body + 12 + i, rng.nextInt(256)); // ClientGuid
    }
    message.setUint32(body + 28, contextOffset, Endian.little); // NegotiateContextOffset
    message.setUint16(body + 32, 1, Endian.little); // NegotiateContextCount
    for (var i = 0; i < dialects.length; i++) {
      message.setUint16(body + 36 + 2 * i, dialects[i], Endian.little);
    }
    // SMB2_PREAUTH_INTEGRITY_CAPABILITIES
    message.setUint16(contextOffset, 1, Endian.little); // ContextType
    message.setUint16(contextOffset + 2, contextDataLength, Endian.little); // DataLength
    message.setUint16(contextOffset + 8, 1, Endian.little); // HashAlgorithmCount
    message.setUint16(contextOffset + 10, 32, Endian.little); // SaltLength
    message.setUint16(contextOffset + 12, 1, Endian.little); // SHA-512
    for (var i = 0; i < 32; i++) {
      message.setUint8(contextOffset + 14 + i, rng.nextInt(256));
    }

    // NetBIOS session message: type 0, then the length on 3 bytes, big endian
    final packet = Uint8List(4 + messageLength);
    packet[1] = (messageLength >> 16) & 0xFF;
    packet[2] = (messageLength >> 8) & 0xFF;
    packet[3] = messageLength & 0xFF;
    packet.setRange(4, packet.length, message.buffer.asUint8List());
    return packet;
  }

  /// Whether [bytes] start with a NetBIOS session message holding an SMB2 message
  @visibleForTesting
  static bool isSmb2Reply(List<int> bytes) =>
      bytes.length >= 8 &&
      bytes[0] == 0 &&
      bytes[4] == 0xFE &&
      bytes[5] == 0x53 &&
      bytes[6] == 0x4D &&
      bytes[7] == 0x42;

  /// The first of [paths] where [host]:[port] answers like a WebDAV server, null when none does. A server answers
  /// like one when an OPTIONS gets a DAV header, a PROPFIND a multistatus, or a PROPFIND a 401 with a WWW-Authenticate
  /// header (it exists and wants credentials). Certificates are not checked: this is a probe that sends nothing.
  /// Null once [request] ended: the request under way is dropped and no other is sent.
  Future<String?> webDavPath(
    String host,
    int port, {
    required bool useTls,
    List<String> paths = const ['/'],
    DiscoveryRequest? request,
  }) async {
    if (request?.isCancelled ?? false) {
      return null;
    }
    final client = IOClient(
      HttpClient()
        ..connectionTimeout = httpTimeout
        ..idleTimeout = const Duration(seconds: 1)
        // The probe only reads the status and headers of the answer and sends no credentials
        ..badCertificateCallback = (_, _, _) => true,
    );
    // Closing the client makes the request under way fail at once
    unawaited(request?.done.whenComplete(client.close));
    try {
      for (final path in paths) {
        if (request?.isCancelled ?? false) {
          return null;
        }
        final uri = Uri(scheme: useTls ? 'https' : 'http', host: host, port: port, path: path);
        final verdict = await _probeWebDav(client, uri, request);
        if (verdict == true) {
          return path;
        }
        if (verdict == null) {
          // Nothing answers there, the other paths would not do better
          return null;
        }
      }
      return null;
    } finally {
      client.close();
    }
  }

  /// true: WebDAV. false: an HTTP server that is not one (at this path). null: no HTTP answer.
  Future<bool?> _probeWebDav(http.Client client, Uri uri, DiscoveryRequest? request) async {
    final options = await _send(client, 'OPTIONS', uri, request);
    if (options == null) {
      return null;
    }
    if (options.headers.containsKey('dav')) {
      return true;
    }
    final propfind = await _send(client, 'PROPFIND', uri, request, headers: {'Depth': '0'});
    if (propfind == null) {
      return false;
    }
    return propfind.statusCode == 207 ||
        (propfind.statusCode == 401 && propfind.headers.containsKey('www-authenticate')) ||
        propfind.headers.containsKey('dav');
  }

  /// Null when nothing answers, or once [request] ended (then nothing is sent)
  Future<http.StreamedResponse?> _send(
    http.Client client,
    String method,
    Uri uri,
    DiscoveryRequest? request, {
    Map<String, String> headers = const {},
  }) async {
    if (request?.isCancelled ?? false) {
      return null;
    }
    try {
      final request = http.Request(method, uri)
        ..followRedirects = false
        ..headers.addAll(headers);
      final response = await client.send(request).timeout(httpTimeout);
      // Only the status and the headers matter
      unawaited(response.stream.listen(null, cancelOnError: true).cancel());
      return response;
    } catch (error) {
      _log.finest('$method $uri: $error');
      return null;
    }
  }
}

/// A service announced over mDNS, resolved
class MdnsService {
  const MdnsService({
    required this.name,
    required this.type,
    required this.host,
    required this.port,
    this.attributes = const {},
  });

  final String name;

  /// "_smb._tcp" and the like
  final String type;
  final String host;
  final int port;

  /// The TXT record
  final Map<String, String> attributes;
}

/// The resolved services of one mDNS [type] until [until] completes
typedef MdnsBrowser = Stream<MdnsService> Function(String type, Future<void> until);

/// Finds the servers that announce themselves over mDNS / DNS-SD
class MdnsProbe {
  const MdnsProbe({
    required this.confirmer,
    this.browse = bonsoirBrowse,
    this.lookup = lookupIPv4,
    this.ownPhoneShareId = storedPhoneShareId,
  });

  final ServerConfirmer confirmer;
  final MdnsBrowser browse;

  /// The IPv4 address of a host name, null when unknown (see [DiscoveredServer.address])
  final Future<String?> Function(String host) lookup;

  /// The id this device announces when it shares its gallery, so that it does not find itself
  final String? Function() ownPhoneShareId;

  /// The TXT "app" value of a phone sharing its gallery with this app ("Share this phone on the network")
  static const phoneShareApp = 'immuch360';

  static const serviceTypes = ['_smb._tcp', '_webdav._tcp', '_webdavs._tcp', '_http._tcp', '_https._tcp'];

  Stream<DiscoveredServer> call(DiscoveryRequest request) {
    final controller = StreamController<DiscoveredServer>();
    final subscriptions = <StreamSubscription<MdnsService>>[];
    final pending = <Future<void>>[];
    var browsing = serviceTypes.length;

    Future<void> closeWhenIdle() async {
      if (browsing > 0) {
        return;
      }
      await Future.wait(pending);
      if (!controller.isClosed) {
        unawaited(controller.close());
      }
    }

    controller.onListen = () {
      for (final type in serviceTypes) {
        try {
          subscriptions.add(
            browse(type, request.done).listen(
              (service) => pending.add(_found(service, request, controller)),
              onError: (Object error) => _log.fine('mDNS $type: $error'),
              onDone: () {
                browsing--;
                unawaited(closeWhenIdle());
              },
            ),
          );
        } catch (error) {
          _log.fine('mDNS $type: $error');
          browsing--;
        }
      }
      unawaited(closeWhenIdle());
    };
    controller.onCancel = () async {
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
    };
    return controller.stream;
  }

  Future<void> _found(MdnsService service, DiscoveryRequest request, StreamController<DiscoveredServer> out) async {
    try {
      final server = await serverOf(service, request: request);
      if (server != null && !request.isCancelled && !out.isClosed) {
        out.add(server);
      }
    } catch (error) {
      _log.fine('mDNS ${service.name}: $error');
    }
  }

  /// The server a resolved service stands for, null when it is not an SMB or WebDAV server, or once [request] ended
  /// (the confirmation and the lookup of the address stop then). A phone sharing its gallery tells it in its TXT
  /// record, with its user name and its install id; this device's own share is left out.
  @visibleForTesting
  Future<DiscoveredServer?> serverOf(MdnsService service, {DiscoveryRequest? request}) async {
    final type = service.type.toLowerCase().replaceAll(RegExp(r'\.(local\.?)?$'), '');
    final host = service.host.endsWith('.') ? service.host.substring(0, service.host.length - 1) : service.host;
    if (host.isEmpty || service.port <= 0) {
      return null;
    }
    final isPhoneShare = type == '_webdav._tcp' && service.attributes['app'] == phoneShareApp;
    final phoneShareId = isPhoneShare ? _nonEmpty(service.attributes['id']) : null;
    if (phoneShareId != null && phoneShareId == ownPhoneShareId()) {
      return null;
    }
    final useTls = type == '_webdavs._tcp' || type == '_https._tcp';
    final isSmb = type == '_smb._tcp';
    if (!isSmb && !const ['_webdav._tcp', '_webdavs._tcp', '_http._tcp', '_https._tcp'].contains(type)) {
      return null;
    }
    var path = '';
    if (!isSmb) {
      final announced = service.attributes['path'] ?? service.attributes['root'] ?? '';
      path = _normalizePath(announced);
      if (type == '_http._tcp' || type == '_https._tcp') {
        // A web server: only kept when it speaks WebDAV
        final confirmed = await confirmer.webDavPath(
          host,
          service.port,
          useTls: useTls,
          paths: [path.isEmpty ? '/' : path],
          request: request,
        );
        if (confirmed == null) {
          return null;
        }
      }
    }
    if (request?.isCancelled ?? false) {
      return null;
    }
    final address = InternetAddress.tryParse(host) == null ? await lookup(host) : null;
    return DiscoveredServer(
      host: host,
      displayName: service.name.trim().isEmpty ? host : service.name.trim(),
      type: isSmb ? NetworkSourceType.smb : NetworkSourceType.webdav,
      port: service.port,
      useTls: useTls,
      path: path,
      origin: DiscoveryOrigin.mdns,
      address: address,
      discoveryId: phoneShareId,
      username: isPhoneShare ? _nonEmpty(service.attributes['u']) : null,
      isPhoneShare: isPhoneShare,
    );
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// "/" separated, starting with "/", no "/" at the end; "" for the root
String _normalizePath(String path) {
  final segments = path.trim().split('/').where((segment) => segment.isNotEmpty);
  return segments.isEmpty ? '' : '/${segments.join('/')}';
}

/// The IPv4 address of [host], null when it does not resolve within a second
Future<String?> lookupIPv4(String host) async {
  try {
    final addresses = await InternetAddress.lookup(
      host,
      type: InternetAddressType.IPv4,
    ).timeout(const Duration(seconds: 1));
    return addresses.firstOrNull?.address;
  } catch (_) {
    return null;
  }
}

/// The resolved services of one type through bonsoir (NSD on Android, the DNS-SD of Apple on iOS). Any failure (no
/// mDNS on the platform, local network access denied on iOS) ends the stream without an error.
Stream<MdnsService> bonsoirBrowse(String type, Future<void> until) {
  final controller = StreamController<MdnsService>();
  BonsoirDiscovery? discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? events;
  var stopped = false;

  Future<void> stop() async {
    if (stopped) {
      return;
    }
    stopped = true;
    try {
      await events?.cancel();
    } catch (_) {}
    try {
      final running = discovery;
      if (running != null && !running.isStopped) {
        await running.stop();
      }
    } catch (error) {
      _log.fine('mDNS $type, stop: $error');
    }
    if (!controller.isClosed) {
      unawaited(controller.close());
    }
  }

  Future<void> run() async {
    try {
      final started = BonsoirDiscovery(type: type, printLogs: false);
      discovery = started;
      await started.ready.timeout(const Duration(seconds: 2));
      if (stopped) {
        return;
      }
      events = started.eventStream?.listen((event) {
        final service = event.service;
        if (service == null || stopped) {
          return;
        }
        if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
          unawaited(
            service.resolve(started.serviceResolver).catchError((Object error) {
              _log.fine('mDNS $type, resolve ${service.name}: $error');
            }),
          );
        } else if (event.type == BonsoirDiscoveryEventType.discoveryServiceResolved) {
          final json = service.toJson();
          final host = json['service.host'] ?? json['service.ip'];
          if (host is String && host.isNotEmpty && !controller.isClosed) {
            controller.add(
              MdnsService(
                name: service.name,
                type: service.type,
                host: host,
                port: service.port,
                attributes: service.attributes,
              ),
            );
          }
        }
      }, onError: (Object error) => _log.fine('mDNS $type: $error'));
      await started.start().timeout(const Duration(seconds: 2));
      if (stopped) {
        // Ended while starting: stop() found it not started yet
        await started.stop();
        return;
      }
    } catch (error) {
      _log.fine('mDNS $type is not available: $error');
      await stop();
      return;
    }
    await until;
    await stop();
  }

  controller.onListen = () => unawaited(run());
  controller.onCancel = stop;
  return controller.stream;
}

/// What a TCP connection attempt found
enum _Reach { open, refused, silent }

/// Opens a TCP connection, or tells why it could not
typedef TcpConnector = Future<Socket> Function(String host, int port, Duration timeout);

Future<Socket> _connect(String host, int port, Duration timeout) => Socket.connect(host, port, timeout: timeout);

/// At most [size] tasks at once; the urgent ones that wait go before the others
class _Slots {
  _Slots(this.size);

  final int size;
  var _busy = 0;
  final _urgent = Queue<Completer<void>>();
  final _waiting = Queue<Completer<void>>();

  /// Runs [task] once a slot is free, unless the discovery ended by then
  Future<void> run(Future<void> Function() task, DiscoveryRequest request, {bool urgent = false}) async {
    if (_busy < size) {
      _busy++;
    } else {
      // The slot is handed over by the task that ends, see _release
      final turn = Completer<void>();
      (urgent ? _urgent : _waiting).add(turn);
      await turn.future;
    }
    try {
      if (!request.isCancelled) {
        await task();
      }
    } catch (error) {
      _log.fine('Scan: $error');
    } finally {
      _release();
    }
  }

  void _release() {
    final next = _urgent.isNotEmpty
        ? _urgent.removeFirst()
        : _waiting.isNotEmpty
        ? _waiting.removeFirst()
        : null;
    if (next != null) {
      next.complete();
    } else {
      _busy--;
    }
  }
}

/// Scans the local /24 subnet (or the hosts given to the discovery) for the [ScanPort]s
class SubnetScanProbe {
  const SubnetScanProbe({
    required this.confirmer,
    this.ports = ScanPort.defaults,
    this.extraPorts = const [],
    this.connectTimeout = const Duration(milliseconds: 400),
    this.maxInFlight = 64,
    this.maxBurst = 128,
    this.minConnectTimeout = const Duration(milliseconds: 250),
    this.scanBudget = const Duration(seconds: 3),
    this.connect = _connect,
    this.localAddresses = localIPv4Addresses,
    this.reverseLookup = reverseName,
  });

  final ServerConfirmer confirmer;
  final List<ScanPort> ports;

  /// Tried first, on top of [ports] (see [ScanPort.fromEnvironment])
  final List<ScanPort> extraPorts;
  final Duration connectTimeout;
  final int maxInFlight;

  /// The connections at once when [maxInFlight] would not try every host in [scanBudget] (two subnets, extra ports)
  final int maxBurst;

  /// The shortest connection timeout of the first ports, when [maxBurst] is not enough either. A host of the local
  /// network answers within a few milliseconds.
  final Duration minConnectTimeout;

  /// The time the first ports should take over every host, the rest of the discovery (see
  /// [NetworkDiscoveryService.defaultTimeout]) being left to the other ports and to the confirmations
  final Duration scanBudget;
  final TcpConnector connect;

  /// The IPv4 addresses of this device on its local networks
  final Future<List<String>> Function() localAddresses;

  /// The name of an address, null when it has none
  final Future<String?> Function(String address) reverseLookup;

  /// The ports tried on every host of a subnet before the others, which are only tried on the hosts that answered:
  /// a host that does not exist costs the whole connection timeout on each port
  static const _livenessPorts = {445, 80};

  Stream<DiscoveredServer> call(DiscoveryRequest request) {
    final controller = StreamController<DiscoveredServer>();
    controller.onListen = () => unawaited(
      _scan(request, controller).whenComplete(() {
        if (!controller.isClosed) {
          unawaited(controller.close());
        }
      }),
    );
    return controller.stream;
  }

  List<ScanPort> get _allPorts {
    final all = <ScanPort>[];
    for (final port in [...extraPorts, ...ports]) {
      if (!all.any((known) => known.port == port.port)) {
        all.add(port);
      }
    }
    return all;
  }

  Future<void> _scan(DiscoveryRequest request, StreamController<DiscoveredServer> out) async {
    final givenHosts = request.hosts;
    final List<String> hosts;
    if (givenHosts != null) {
      hosts = givenHosts;
    } else {
      final own = await localAddresses();
      hosts = {for (final address in own) ...subnetHostsOf(address)}.toList();
    }
    if (hosts.isEmpty || request.isCancelled) {
      return;
    }

    final names = <String, Future<String?>>{};
    final confirmations = <Future<void>>[];
    final alive = <String>{};

    void confirm(String host, ScanPort port, Socket? socket) {
      confirmations.add(() async {
        try {
          final server = await _confirm(host, port, socket, names, request);
          if (server != null && !request.isCancelled && !out.isClosed) {
            out.add(server);
          }
        } catch (error) {
          _log.fine('Scan $host:${port.port}: $error');
        }
      }());
    }

    // The given hosts get every port. On a subnet, the other ports are only tried on the hosts that answered on one of
    // the first ones, as soon as they did.
    final all = _allPorts;
    final extras = extraPorts.map((port) => port.port).toSet();
    bool first(ScanPort port) => givenHosts != null || _livenessPorts.contains(port.port) || extras.contains(port.port);
    final firstPorts = all.where(first).toList();
    final laterPorts = all.where((port) => !first(port)).toList();
    final (inFlight, firstTimeout) = plan(hosts.length * firstPorts.length);
    final slots = _Slots(inFlight);
    final tasks = <Future<void>>[];

    Future<void> tryPort(String host, ScanPort port, Duration timeout) async {
      final (reach, socket) = await _reach(host, port.port, timeout);
      if (reach != _Reach.silent && alive.add(host)) {
        // The host exists: its other ports go before the hosts not tried yet
        for (final later in laterPorts) {
          tasks.add(slots.run(() => tryPort(host, later, connectTimeout), request, urgent: true));
        }
      }
      if (reach == _Reach.open) {
        if (request.isCancelled) {
          socket?.destroy();
          return;
        }
        confirm(host, port, socket);
      }
    }

    for (final host in hosts) {
      for (final port in firstPorts) {
        tasks.add(slots.run(() => tryPort(host, port, firstTimeout), request));
      }
    }
    // More tasks are added while these run
    for (var awaited = 0; awaited < tasks.length;) {
      final running = tasks.sublist(awaited);
      awaited = tasks.length;
      await Future.wait(running);
    }
    await Future.wait(confirmations);
  }

  /// The connections at once and their timeout for [connections] attempts on hosts that may not exist, so that they
  /// take [scanBudget] at most: more at once first (up to [maxBurst]), then a shorter timeout (down to
  /// [minConnectTimeout])
  @visibleForTesting
  (int, Duration) plan(int connections) {
    final budget = scanBudget.inMicroseconds;
    int rounds(int inFlight) => (connections / inFlight).ceil();
    var inFlight = max(1, maxInFlight);
    if (rounds(inFlight) * connectTimeout.inMicroseconds > budget) {
      final wanted = (connections * connectTimeout.inMicroseconds / budget).ceil();
      inFlight = min(max(wanted, inFlight), max(inFlight, maxBurst));
    }
    var timeout = connectTimeout;
    final needed = rounds(inFlight);
    if (needed * timeout.inMicroseconds > budget) {
      timeout = Duration(
        microseconds: max(min(minConnectTimeout.inMicroseconds, connectTimeout.inMicroseconds), budget ~/ needed),
      );
    }
    return (inFlight, timeout);
  }

  Future<(_Reach, Socket?)> _reach(String host, int port, Duration timeout) async {
    try {
      // Handed over to the confirmation, which destroys it
      // ignore: close_sinks
      final socket = await connect(host, port, timeout);
      return (_Reach.open, socket);
    } on SocketException catch (error) {
      return (_isRefusal(error) ? _Reach.refused : _Reach.silent, null);
    } catch (_) {
      return (_Reach.silent, null);
    }
  }

  /// A refused connection tells that the host exists; a timeout or an unreachable host does not
  static bool _isRefusal(SocketException error) {
    final code = error.osError?.errorCode;
    // ECONNREFUSED on Linux and Android, macOS and iOS, Windows; ECONNRESET
    return const {111, 61, 10061, 104, 54, 10054}.contains(code) ||
        (error.osError?.message.toLowerCase().contains('refused') ?? false);
  }

  /// The server on [port] of [host], null when it is not what the port suggests, or once [request] ended (nothing more
  /// is sent then, and the name is not looked up)
  Future<DiscoveredServer?> _confirm(
    String host,
    ScanPort port,
    Socket? socket,
    Map<String, Future<String?>> names,
    DiscoveryRequest request,
  ) async {
    if (request.isCancelled) {
      socket?.destroy();
      return null;
    }
    var path = '';
    if (port.type == NetworkSourceType.smb) {
      final isSmb = socket != null
          ? await ServerConfirmer.negotiatesSmb2(socket, timeout: confirmer.smbTimeout, until: request.done)
          : await confirmer.isSmb(host, port.port, request: request);
      if (!isSmb) {
        return null;
      }
    } else {
      socket?.destroy();
      // A Nextcloud or ownCloud server keeps its WebDAV under remote.php
      final found = await confirmer.webDavPath(
        host,
        port.port,
        useTls: port.useTls,
        paths: const ['/', '/remote.php/webdav'],
        request: request,
      );
      if (found == null) {
        return null;
      }
      path = found == '/' ? '' : found;
    }
    if (request.isCancelled) {
      return null;
    }
    final name = await (names[host] ??= reverseLookup(host));
    return DiscoveredServer(
      host: host,
      displayName: name ?? host,
      type: port.type,
      port: port.port,
      useTls: port.useTls,
      path: path,
      origin: DiscoveryOrigin.scan,
    );
  }

  /// The other hosts of the /24 subnet of [address], for this scan and the SSDP sweep
  static List<String> subnetHostsOf(String address) {
    final parts = address.split('.');
    if (parts.length != 4) {
      return const [];
    }
    final prefix = parts.take(3).join('.');
    return [
      for (var i = 1; i < 255; i++)
        if ('$prefix.$i' != address) '$prefix.$i',
    ];
  }

  /// The addresses worth a scan among the IPv4 [addresses] of the interfaces of the device, by interface name: the
  /// private ones (Wi-Fi, Ethernet, the network of the Android emulator), without the loopback, the link-local ones
  /// nor those of the mobile data, VPN, hotspot, Wi-Fi Direct and tethering interfaces. The main Wi-Fi and Ethernet
  /// interfaces come first. Two subnets at most.
  @visibleForTesting
  static List<String> lanAddressesOf(List<(String, InternetAddress)> addresses) {
    const skipped = [
      'rmnet', 'ccmni', 'pdp', 'tun', 'ppp', 'wg', 'ipsec', 'clat', 'v4-', 'dummy', 'utun', 'docker', //
      'ap', 'swlan', 'p2p', 'rndis', 'bt-pan', 'ncm', 'bridge',
    ];
    // 0: the main Wi-Fi or Ethernet interface (Android, iOS), 1: another one, 2: anything else
    int rank(String name) => const ['wlan0', 'eth0', 'en0'].contains(name)
        ? 0
        : const ['wlan', 'eth', 'en'].any(name.startsWith)
        ? 1
        : 2;
    final candidates = <(int, String)>[];
    for (final (name, address) in addresses) {
      final lowerName = name.toLowerCase();
      if (address.type != InternetAddressType.IPv4 || address.isLoopback || address.isLinkLocal) {
        continue;
      }
      if (skipped.any(lowerName.startsWith)) {
        continue;
      }
      final bytes = address.rawAddress;
      final private =
          bytes[0] == 10 ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] < 32) ||
          (bytes[0] == 192 && bytes[1] == 168);
      if (private) {
        candidates.add((rank(lowerName), address.address));
      }
    }
    final picked = <String>[];
    final subnets = <String>{};
    for (var level = 0; level <= 2 && picked.length < 2; level++) {
      for (final (rankOf, address) in candidates) {
        if (rankOf != level || !subnets.add(address.substring(0, address.lastIndexOf('.')))) {
          continue;
        }
        picked.add(address);
        if (picked.length == 2) {
          break;
        }
      }
    }
    return picked;
  }
}

/// The local IPv4 addresses of the device worth a scan, see [SubnetScanProbe.lanAddressesOf]
Future<List<String>> localIPv4Addresses() async {
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return SubnetScanProbe.lanAddressesOf([
      for (final interface in interfaces)
        for (final address in interface.addresses) (interface.name, address),
    ]);
  } catch (error) {
    _log.fine('No network interface: $error');
    return const [];
  }
}

/// The reverse DNS name of [address], null when there is none within a second
Future<String?> reverseName(String address) async {
  try {
    final parsed = InternetAddress.tryParse(address);
    if (parsed == null) {
      return null;
    }
    final name = (await parsed.reverse().timeout(const Duration(seconds: 1))).host;
    return name.isEmpty || name == address ? null : name;
  } catch (_) {
    return null;
  }
}
