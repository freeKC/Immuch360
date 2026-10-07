// A UDP socket that the discovery probes send from and receive on: SSDP (DLNA media servers), GDM (Plex Media
// Servers) and the TP-Link discovery (Tapo cameras). Each probe takes one socket for what goes to a group or a
// broadcast address and another for the unicast sweep of the local subnet, for the reason told at [bindUdpTransport].

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

final _log = Logger('UdpTransport');

/// A UDP socket a probe sends from and receives on. Injectable for the tests.
abstract class UdpTransport {
  /// What comes to the socket, until [close]
  Stream<Datagram> get datagrams;

  /// Sends [bytes]; a failure (no route, multicast not allowed) is logged, not thrown
  void send(List<int> bytes, InternetAddress address, int port);

  void close();
}

/// A socket on an ephemeral port of every IPv4 interface (of the one of [address] when given: the multicast then leaves
/// through it), multicast limited to 4 hops, allowed to send to a broadcast address when [broadcast] is true.
///
/// dart:io closes a datagram socket for good on the first send that fails, without throwing: send returns 0 and the
/// error reaches the listener of the socket right after. iOS fails every send to the group without the multicast
/// entitlement, and iOS and macOS fail a send to a host whose ARP lookup failed shortly before ("Host is down", a sweep
/// run again soon after the first). The transport then binds a new socket on the same port, so that the answers to
/// what was sent before still come in, and sends what was sent meanwhile on it, with the same options.
Future<UdpTransport> bindUdpTransport({
  InternetAddress? address,
  bool broadcast = false,
  @visibleForTesting Future<RawDatagramSocket> Function(InternetAddress host, int port) bindSocket = _bindSocket,
}) async {
  final host = address ?? InternetAddress.anyIPv4;
  final transport = _RawUdpTransport((port) async {
    final socket = await bindSocket(host, port);
    try {
      socket.multicastHops = 4;
    } catch (error) {
      _log.fine('UDP multicast hops: $error');
    }
    if (broadcast) {
      // Each socket bound again after a failed send too, or the next broadcast would fail on it
      socket.broadcastEnabled = true;
    }
    return socket;
  });
  await transport.start();
  return transport;
}

Future<RawDatagramSocket> _bindSocket(InternetAddress host, int port) => RawDatagramSocket.bind(host, port);

class _RawUdpTransport implements UdpTransport {
  _RawUdpTransport(this._bind);

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
        _log.fine('UDP socket on port $port: $error');
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
      _log.fine('UDP: port $port is not free again ($error), taking another one');
      try {
        socket = await _bind(0);
      } catch (error) {
        _log.fine('UDP: no socket any more: $error');
        close();
        return;
      }
    }
    _log.fine('UDP: a failed send closed the socket on port $port; sending from port ${socket.port} now');
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
      _log.finest('UDP: nothing sent to ${address.address}:$port');
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
