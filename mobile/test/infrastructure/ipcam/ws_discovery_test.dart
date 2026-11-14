// WS-Discovery: the Probe, the ProbeMatches read (our MessageID only, the XAddr of the local network, the scopes
// decoded), the multicast from each local address and the unicast to a typed one, sent again, each device once. A
// fake UDP socket answers as a camera would; one test on real sockets of 127.0.0.1 in unicast (multicast in the
// loopback is not reliable on the runners). Synthetic answers written from the WS-Discovery 2005/04 schema.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/ip_camera.dart';
import 'package:immich_mobile/infrastructure/ipcam/ws_discovery.dart';
import 'package:immich_mobile/infrastructure/network/udp_transport.dart';

String _match(
  String relatesTo, {
  String endpoint = 'urn:uuid:00000000-0000-4000-8000-000000000001',
  String xaddrs = 'http://192.0.2.20/onvif/device_service',
  String scopes =
      'onvif://www.onvif.org/type/video_encoder onvif://www.onvif.org/name/Front%20Door '
      'onvif://www.onvif.org/hardware/IPC-0000 onvif://www.onvif.org/Profile/Streaming',
}) =>
    '<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"'
    ' xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">'
    '<s:Header><a:MessageID>uuid:00000000-0000-4000-8000-0000000000ff</a:MessageID><a:RelatesTo>$relatesTo</a:RelatesTo>'
    '<a:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</a:Action></s:Header>'
    '<s:Body><d:ProbeMatches><d:ProbeMatch><a:EndpointReference><a:Address>$endpoint</a:Address></a:EndpointReference>'
    '<d:Types>dn:NetworkVideoTransmitter</d:Types><d:Scopes>$scopes</d:Scopes><d:XAddrs>$xaddrs</d:XAddrs>'
    '<d:MetadataVersion>1</d:MetadataVersion></d:ProbeMatch></d:ProbeMatches></s:Body></s:Envelope>';

class _FakeUdp implements UdpTransport {
  _FakeUdp(this.local, this.answer);

  final InternetAddress? local;

  /// What answers a probe sent to an address: (from, text) pairs
  final List<(InternetAddress, String)> Function(String probe, InternetAddress to) answer;
  final sent = <(InternetAddress, int)>[];
  final _controller = StreamController<Datagram>();
  bool closed = false;

  @override
  Stream<Datagram> get datagrams => _controller.stream;

  @override
  void send(List<int> bytes, InternetAddress address, int port) {
    sent.add((address, port));
    for (final (from, text) in answer(utf8.decode(bytes), address)) {
      scheduleMicrotask(() {
        if (!closed) {
          _controller.add(Datagram(Uint8List.fromList(utf8.encode(text)), from, wsDiscoveryPort));
        }
      });
    }
  }

  @override
  void close() {
    closed = true;
    unawaited(_controller.close());
  }
}

String _messageIdOf(String probe) => RegExp(r'<a:MessageID>([^<]+)</a:MessageID>').firstMatch(probe)!.group(1)!;

void main() {
  group('parseProbeMatches', () {
    test('reads the endpoint, the device service and the scopes', () {
      final devices = parseProbeMatches(_match('uuid:me'), messageId: 'uuid:me', from: '192.0.2.20');
      expect(devices, hasLength(1));
      final device = devices.single;
      expect(device.endpoint, 'urn:uuid:00000000-0000-4000-8000-000000000001');
      expect(device.host, '192.0.2.20');
      expect(device.port, 80);
      expect(device.path, '/onvif/device_service');
      expect(device.name, 'Front Door');
      expect(device.hardware, 'IPC-0000');
      expect(device.label, 'Front Door');
    });

    test('another message, a broken answer or a device without ONVIF: nothing', () {
      expect(parseProbeMatches(_match('uuid:other'), messageId: 'uuid:me'), isEmpty);
      expect(parseProbeMatches('<not xml', messageId: 'uuid:me'), isEmpty);
      // A printer answering a probe without types
      expect(
        parseProbeMatches(_match('uuid:me', xaddrs: 'http://192.0.2.30/wsd/printer'), messageId: 'uuid:me'),
        isEmpty,
      );
    });

    test('the XAddr the answer came from, never a link-local one', () {
      final devices = parseProbeMatches(
        _match(
          'uuid:me',
          xaddrs:
              'http://169.254.10.20/onvif/device_service http://10.9.9.9:8000/onvif/device_service '
              'http://192.0.2.21:8000/onvif/device_service',
        ),
        messageId: 'uuid:me',
        from: '192.0.2.21',
      );
      expect(devices.single.host, '192.0.2.21');
      expect(devices.single.port, 8000);
      final linkLocalOnly = parseProbeMatches(
        _match('uuid:me', xaddrs: 'http://169.254.10.20/onvif/device_service'),
        messageId: 'uuid:me',
      );
      expect(linkLocalOnly, isEmpty);
    });
  });

  test('the Probe asks for the ONVIF types', () {
    final probe = wsDiscoveryProbe('uuid:me');
    expect(probe, contains('<d:Types>dn:NetworkVideoTransmitter tds:Device</d:Types>'));
    expect(probe, contains('http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe'));
  });

  test('multicast from each local address, unicast to a typed one, sent again, each device once', () async {
    final sockets = <_FakeUdp>[];
    Future<UdpTransport> bind(InternetAddress? local) async {
      final socket = _FakeUdp(local, (probe, to) {
        final id = _messageIdOf(probe);
        if (to == wsDiscoveryGroup) {
          return [(InternetAddress('192.0.2.20'), _match(id))];
        }
        return [(to, _match(id, endpoint: 'urn:uuid:typed', xaddrs: 'http://${to.address}:2020/onvif/device_service'))];
      });
      sockets.add(socket);
      return socket;
    }

    final devices = await discoverOnvifDevices(
      localAddresses: ['192.0.2.5', '198.51.100.5'],
      unicastHosts: ['192.0.2.77'],
      duration: const Duration(milliseconds: 300),
      resends: const [Duration.zero, Duration(milliseconds: 50)],
      bind: bind,
    ).toList();
    expect(devices.map((d) => d.endpoint), ['urn:uuid:00000000-0000-4000-8000-000000000001', 'urn:uuid:typed']);
    expect(devices.last.port, 2020);
    expect(sockets, hasLength(3));
    expect(sockets.map((s) => s.local?.address), ['192.0.2.5', '198.51.100.5', null]);
    // Each probe twice, to the group from the local addresses, to the host for the typed one
    expect(sockets[0].sent, [(wsDiscoveryGroup, 3702), (wsDiscoveryGroup, 3702)]);
    expect(sockets[2].sent.map((s) => s.$1.address), ['192.0.2.77', '192.0.2.77']);
    expect(sockets.every((s) => s.closed), isTrue);
  });

  test('on real sockets of 127.0.0.1, in unicast', () async {
    final camera = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(camera.close);
    camera.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      final datagram = camera.receive();
      if (datagram == null) {
        return;
      }
      final id = _messageIdOf(utf8.decode(datagram.data));
      camera.send(
        utf8.encode(_match(id, xaddrs: 'http://127.0.0.1:8899/onvif/device_service')),
        datagram.address,
        datagram.port,
      );
    });
    final devices = await discoverOnvifDevices(
      localAddresses: const [],
      unicastHosts: ['127.0.0.1'],
      port: camera.port,
      duration: const Duration(milliseconds: 500),
    ).toList();
    expect(devices, hasLength(1));
    expect(devices.single, isA<DiscoveredOnvifDevice>().having((d) => d.port, 'port', 8899));
  });
}
