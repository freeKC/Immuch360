// The UDP socket the discovery probes share (SSDP, GDM, TDP): a broadcast probe needs every socket it sends from to be
// allowed to broadcast, the one bound again after a failed send included. The SSDP tests cover the rest unchanged.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/udp_transport.dart';
import 'package:immich_mobile/infrastructure/network/upnp/ssdp.dart';

void main() {
  /// Binds on the loopback and remembers each socket
  Future<RawDatagramSocket> Function(InternetAddress host, int port) recording(List<RawDatagramSocket> sockets) =>
      (host, port) async {
        final socket = await RawDatagramSocket.bind(host, port);
        sockets.add(socket);
        return socket;
      };

  test('a broadcast transport allows broadcasts on its socket, and on the one bound after a failed send', () async {
    final sockets = <RawDatagramSocket>[];
    final transport = await bindUdpTransport(
      address: InternetAddress.loopbackIPv4,
      broadcast: true,
      bindSocket: recording(sockets),
    );
    addTearDown(transport.close);
    final receiver = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(receiver.close);

    expect(sockets.single.broadcastEnabled, isTrue);

    // Linux refuses a datagram to port 0, and dart:io closes the socket then
    transport.send([1], InternetAddress.loopbackIPv4, 0);
    final watch = Stopwatch()..start();
    while (sockets.length < 2 && watch.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(sockets, hasLength(2), reason: 'a new socket after the failed send');
    expect(sockets.last.broadcastEnabled, isTrue);
    expect(sockets.last.port, sockets.first.port, reason: 'on the same port, for the answers');
  });

  test('a transport that does not broadcast leaves its sockets as they are', () async {
    final sockets = <RawDatagramSocket>[];
    final transport = await bindUdpTransport(address: InternetAddress.loopbackIPv4, bindSocket: recording(sockets));
    addTearDown(transport.close);

    expect(sockets.single.broadcastEnabled, isFalse);
  });

  test('SSDP keeps its names for the same transport', () async {
    final SsdpTransport transport = await bindSsdpTransport(address: InternetAddress.loopbackIPv4);
    addTearDown(transport.close);

    expect(transport, isA<UdpTransport>());
  });
}
