// The listening sockets of the local servers of the app (the phone share, the pairing listener of the big screens):
// only on the addresses of the device on its local network and its loopback, and the check of the clients they take.

import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

final _log = Logger('ServedSockets');

/// Whether [address] is of the local network: loopback, link-local, private IPv4 (RFC 1918) or unique local IPv6
bool isLocalNetworkAddress(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal) {
    return true;
  }
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
    return _isPrivateIPv4(bytes);
  }
  if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
    // An IPv4 client of a dual stack socket: ::ffff:a.b.c.d
    final isMapped = bytes.take(10).every((byte) => byte == 0) && bytes[10] == 0xff && bytes[11] == 0xff;
    if (isMapped) {
      final ipv4 = bytes.sublist(12);
      return _isPrivateIPv4(ipv4) || ipv4[0] == 127 || (ipv4[0] == 169 && ipv4[1] == 254);
    }
    return (bytes[0] & 0xfe) == 0xfc;
  }
  return false;
}

bool _isPrivateIPv4(List<int> bytes) =>
    bytes[0] == 10 || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] < 32) || (bytes[0] == 192 && bytes[1] == 168);

/// The listening sockets of a local server with served addresses (the phone share, the pairing listener of the big
/// screens), as one for HttpServer.listenOn: one on the loopback, which holds the port while the device has no
/// network, and one per served address on that port, opened and closed as the addresses come and go. A single socket
/// on every interface would also take the clients that reach the device on its mobile data or VPN address, and a
/// connection it accepts does not tell which address it was made to.
class ServedSockets extends Stream<Socket> implements ServerSocket {
  ServedSockets._(this._loopback, this._servedAddresses, this._label) {
    _loopback.listen(_connections.add, onError: _onListenError);
    _timer = Timer.periodic(refreshInterval, (_) => unawaited(refresh()));
  }

  /// How often the served addresses are checked: a hotspot comes up, or an iPhone makes its hotspot interface for its
  /// first client, without any change of connectivity the app hears of
  static const refreshInterval = Duration(seconds: 5);

  /// Listens on [port] (any free one with 0) on the loopback and on every served address of now; [strict], an address
  /// that cannot have the port fails it instead of being left out
  static Future<ServedSockets> bind(
    int port,
    Future<List<String>> Function() servedAddresses, {
    required bool strict,
    String label = 'Local server',
  }) async {
    final sockets = ServedSockets._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, port),
      servedAddresses,
      label,
    );
    try {
      await sockets._update(strict: strict);
    } catch (_) {
      await sockets.close();
      rethrow;
    }
    return sockets;
  }

  final ServerSocket _loopback;
  final Future<List<String>> Function() _servedAddresses;

  /// What the log lines start with
  final String _label;
  final Map<String, ServerSocket> _listeners = {};
  final _connections = StreamController<Socket>();
  late final Timer _timer;
  Future<void> _updates = Future.value();
  bool _closed = false;

  @override
  int get port => _loopback.port;

  @override
  InternetAddress get address => _loopback.address;

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket connection)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _connections.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  /// Brings the listening sockets in line with the served addresses of now, after the checks asked before
  Future<void> refresh() => _updates = _updates.then((_) => _update());

  Future<void> _update({bool strict = false}) async {
    final List<String> wanted;
    try {
      wanted = await _servedAddresses();
    } catch (error) {
      if (strict) {
        rethrow;
      }
      _log.fine('$_label: the addresses of the device are not known: $error');
      return;
    }
    if (_closed) {
      return;
    }
    for (final gone in [..._listeners.keys.where((address) => !wanted.contains(address))]) {
      // The connections it accepted stay open: a client of a network that went away times out on its own
      _log.info('$_label: no more listening on $gone');
      unawaited(_listeners.remove(gone)!.close());
    }
    for (final address in wanted) {
      final internetAddress = InternetAddress.tryParse(address);
      if (internetAddress == null || internetAddress == _loopback.address || _listeners.containsKey(address)) {
        continue;
      }
      final ServerSocket listener;
      try {
        listener = await ServerSocket.bind(internetAddress, port);
      } catch (error) {
        if (strict) {
          rethrow;
        }
        _log.warning('$_label: cannot listen on $address port $port: $error');
        continue;
      }
      if (_closed) {
        await listener.close();
        return;
      }
      _listeners[address] = listener;
      listener.listen(_connections.add, onError: _onListenError);
    }
  }

  void _onListenError(Object error) => _log.fine('$_label: a listening socket failed: $error');

  @override
  Future<ServerSocket> close() async {
    _closed = true;
    _timer.cancel();
    final sockets = [_loopback, ..._listeners.values];
    _listeners.clear();
    await Future.wait([for (final socket in sockets) socket.close()]);
    // Not awaited: the done event waits for a listener, and none came when the start failed
    unawaited(_connections.close());
    return this;
  }
}
