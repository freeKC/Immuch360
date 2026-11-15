// WS-Discovery of the ONVIF cameras (WS-Discovery 2005/04, ONVIF Core 7.3): a Probe for the NetworkVideoTransmitter
// and Device types to the group 239.255.255.250:3702 from each local address (the multicast then leaves through each
// interface), sent again after 400 and 1200 ms since UDP may drop it, and to a typed address in unicast for the
// networks that filter multicast (iOS without the multicast entitlement, access points with client isolation of
// multicast). The ProbeMatches that answer our MessageID are read: the endpoint, the scopes, and the XAddrs of the
// device service, the one on a local network kept (never a link-local 169.254 address). Nothing is sent to a camera
// but the Probe.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/services/ip_camera.dart';
import 'package:immich_mobile/infrastructure/network/lite_xml.dart';
import 'package:immich_mobile/infrastructure/network/udp_transport.dart';
import 'package:logging/logging.dart';

final _log = Logger('WsDiscovery');

const wsDiscoveryPort = 3702;
final wsDiscoveryGroup = InternetAddress('239.255.255.250');

/// The Probe of [messageId] ("uuid:..."), for the ONVIF types
String wsDiscoveryProbe(String messageId) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"'
    ' xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing"'
    ' xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"'
    ' xmlns:dn="http://www.onvif.org/ver10/network/wsdl" xmlns:tds="http://www.onvif.org/ver10/device/wsdl">'
    '<s:Header><a:MessageID>$messageId</a:MessageID>'
    '<a:To s:mustUnderstand="1">urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To>'
    '<a:Action s:mustUnderstand="1">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</a:Action></s:Header>'
    '<s:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter tds:Device</d:Types></d:Probe></s:Body></s:Envelope>';

/// The devices of a ProbeMatches answer to [messageId]; empty for anything else (another message, another kind of
/// device without an ONVIF device service, a broken answer). [from] is the address the answer came from: an XAddr on
/// it comes first, then one on a private network, never a link-local one.
List<DiscoveredOnvifDevice> parseProbeMatches(String text, {required String messageId, String? from}) {
  final document = parseLiteXml(text);
  final relates = document.descendantsNamed('RelatesTo').firstOrNull?.text.trim();
  if (relates != messageId) {
    return const [];
  }
  final devices = <DiscoveredOnvifDevice>[];
  for (final match in document.descendantsNamed('ProbeMatch')) {
    String? text(String local) => match.descendantsNamed(local).firstOrNull?.text;
    final endpoint = text('Address')?.trim();
    final xaddrs = (text('XAddrs') ?? '').split(RegExp(r'\s+')).where((value) => value.isNotEmpty);
    final candidates = <Uri>[];
    for (final value in xaddrs) {
      final uri = Uri.tryParse(value);
      if (uri == null || uri.scheme != 'http' || uri.host.isEmpty || uri.host.startsWith('169.254.')) {
        continue;
      }
      if (!uri.path.toLowerCase().contains('onvif')) {
        continue;
      }
      candidates.add(uri);
    }
    if (endpoint == null || endpoint.isEmpty || candidates.isEmpty) {
      continue;
    }
    candidates.sort((a, b) => _rank(a.host, from).compareTo(_rank(b.host, from)));
    final best = candidates.first;
    final scopes = (text('Scopes') ?? '').split(RegExp(r'\s+')).where((value) => value.isNotEmpty).toList();
    String? scope(String kind) {
      const prefix = 'onvif://www.onvif.org/';
      for (final value in scopes) {
        if (value.toLowerCase().startsWith('$prefix$kind/')) {
          final raw = value.substring(prefix.length + kind.length + 1);
          try {
            final decoded = Uri.decodeComponent(raw).trim();
            return decoded.isEmpty ? null : decoded;
          } on ArgumentError {
            return raw;
          }
        }
      }
      return null;
    }

    devices.add(
      DiscoveredOnvifDevice(
        endpoint: endpoint,
        host: best.host,
        port: best.hasPort ? best.port : 80,
        path: best.path.isEmpty ? '/' : best.path,
        name: scope('name'),
        hardware: scope('hardware'),
        scopes: scopes,
      ),
    );
  }
  return devices;
}

/// 0: the address the answer came from, 1: a private IPv4 one, 2: anything else
int _rank(String host, String? from) {
  if (host == from) {
    return 0;
  }
  final private = RegExp(r'^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)').hasMatch(host);
  return private ? 1 : 2;
}

/// Looks for the ONVIF devices of the network for [duration]: from each of [localAddresses] to the group, and in
/// unicast to each of [unicastHosts]. Each device once, by its endpoint, as it answers.
Stream<DiscoveredOnvifDevice> discoverOnvifDevices({
  required List<String> localAddresses,
  List<String> unicastHosts = const [],
  Duration duration = const Duration(seconds: 3),
  @visibleForTesting Future<UdpTransport> Function(InternetAddress? address)? bind,
  @visibleForTesting InternetAddress? group,
  @visibleForTesting int port = wsDiscoveryPort,
  @visibleForTesting
  List<Duration> resends = const [Duration.zero, Duration(milliseconds: 400), Duration(milliseconds: 1200)],
}) {
  final binder = bind ?? ((address) => bindUdpTransport(address: address));
  final controller = StreamController<DiscoveredOnvifDevice>();
  final transports = <UdpTransport>[];
  final timers = <Timer>[];
  final seen = <String>{};
  final messageId = 'uuid:${_uuid()}';
  final probe = utf8.encode(wsDiscoveryProbe(messageId));
  var closed = false;

  Future<void> close() async {
    if (closed) {
      return;
    }
    closed = true;
    for (final timer in timers) {
      timer.cancel();
    }
    for (final transport in transports) {
      transport.close();
    }
    await controller.close();
  }

  Future<void> start() async {
    final targets = <(InternetAddress?, List<InternetAddress>)>[
      for (final address in localAddresses) (InternetAddress.tryParse(address), [group ?? wsDiscoveryGroup]),
      if (unicastHosts.isNotEmpty) (null, [for (final host in unicastHosts) ?InternetAddress.tryParse(host)]),
    ];
    for (final (local, destinations) in targets) {
      if (closed || destinations.isEmpty) {
        continue;
      }
      final UdpTransport transport;
      try {
        transport = await binder(local);
      } catch (error) {
        _log.fine('WS-Discovery could not bind a socket: ${error.runtimeType}');
        continue;
      }
      if (closed) {
        transport.close();
        return;
      }
      transports.add(transport);
      transport.datagrams.listen((datagram) {
        if (closed) {
          return;
        }
        final text = utf8.decode(datagram.data, allowMalformed: true);
        for (final device in parseProbeMatches(text, messageId: messageId, from: datagram.address.address)) {
          if (seen.add(device.endpoint)) {
            controller.add(device);
          }
        }
      });
      for (final delay in resends) {
        timers.add(
          Timer(delay, () {
            if (!closed) {
              for (final destination in destinations) {
                transport.send(probe, destination, port);
              }
            }
          }),
        );
      }
    }
    timers.add(Timer(duration, () => unawaited(close())));
  }

  controller.onListen = () => unawaited(start());
  controller.onCancel = close;
  return controller.stream;
}

String _uuid() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
