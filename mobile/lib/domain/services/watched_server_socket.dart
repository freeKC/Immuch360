// The listening socket of the media bridge, whose connections tell at once when their client closes them.
//
// dart:io's HttpServer reads nothing of a connection while it answers a request on it: a client that goes away is seen
// only when a write to it fails, so a response that waits for the bytes of a slow share learns it only once they came.
// A player that seeks closes the connection of the place it leaves and opens another: the bridge must stop reading for
// the place left at once (see LocalMediaBridge), not once the read under way ended. Here every connection is read as
// it comes, what the server does not take yet kept for it, and its end is told by the remote port of the client.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A [ServerSocket] for HttpServer.listenOn whose connections are read as they come: [closedFrom] tells when the client
/// at a remote port closed its connection, whatever the server does with it meanwhile
class WatchedServerSocket extends Stream<Socket> implements ServerSocket {
  WatchedServerSocket(this._inner);

  /// Binds a server socket at [address] and [port], as ServerSocket.bind
  static Future<WatchedServerSocket> bind(InternetAddress address, int port) async =>
      WatchedServerSocket(await ServerSocket.bind(address, port));

  final ServerSocket _inner;

  /// The ends of the connections open, by the remote port of their client
  final _ends = <int, Completer<void>>{};

  /// Completes once the client at [remotePort] closed its connection to this socket (or it failed); null when no
  /// connection from that port is open
  Future<void>? closedFrom(int remotePort) => _ends[remotePort]?.future;

  /// The connections open
  int get openConnections => _ends.length;

  @override
  int get port => _inner.port;

  @override
  InternetAddress get address => _inner.address;

  @override
  Future<ServerSocket> close() async {
    await _inner.close();
    return this;
  }

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _inner.map<Socket>(_watch).listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  Socket _watch(Socket socket) {
    final int remotePort;
    try {
      remotePort = socket.remotePort;
    } on SocketException {
      // Already closed
      return socket;
    }
    final ended = Completer<void>();
    final watched = _WatchedSocket(socket, ended);
    _ends[remotePort] = ended;
    unawaited(
      ended.future.whenComplete(() {
        if (identical(_ends[remotePort], ended)) {
          _ends.remove(remotePort);
        }
      }),
    );
    return watched;
  }
}

/// A connection read as it comes: what the server does not take yet waits in [_incoming] (a client sends its requests
/// and nothing more, a few KiB), and [_ended] completes as soon as the client closed it
class _WatchedSocket extends Stream<Uint8List> implements Socket {
  _WatchedSocket(this._socket, this._ended) {
    _incoming = StreamController<Uint8List>(
      onPause: () => _held = 0,
      onResume: () {
        _held = 0;
        if (_reading.isPaused) {
          _reading.resume();
        }
      },
      onCancel: () => _reading.cancel(),
    );
    _reading = _socket.listen(
      (data) {
        if (_incoming.isPaused) {
          _held += data.length;
          // A client that sends much while the server holds its connection: no longer read until the server reads
          if (_held > maxHeld) {
            _reading.pause();
          }
        }
        _incoming.add(data);
      },
      onError: (Object error, StackTrace stackTrace) {
        _end();
        _incoming.addError(error, stackTrace);
      },
      onDone: () {
        _end();
        unawaited(_incoming.close());
      },
    );
  }

  /// Most bytes kept for the server while it does not read the connection
  static const maxHeld = 64 * 1024;

  final Socket _socket;
  final Completer<void> _ended;
  late final StreamController<Uint8List> _incoming;
  late final StreamSubscription<Uint8List> _reading;
  int _held = 0;

  void _end() {
    if (!_ended.isCompleted) {
      _ended.complete();
    }
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _incoming.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  Encoding get encoding => _socket.encoding;

  @override
  set encoding(Encoding value) => _socket.encoding = value;

  @override
  void write(Object? object) => _socket.write(object);

  @override
  void writeln([Object? object = '']) => _socket.writeln(object);

  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) => _socket.writeAll(objects, separator);

  @override
  void add(List<int> data) => _socket.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _socket.addError(error, stackTrace);

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) => _socket.addStream(stream);

  @override
  void destroy() {
    _end();
    _socket.destroy();
  }

  @override
  Future<dynamic> flush() => _socket.flush();

  @override
  Future<dynamic> close() => _socket.close();

  @override
  Future<dynamic> get done => _socket.done;

  @override
  int get port => _socket.port;

  @override
  InternetAddress get address => _socket.address;

  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;

  @override
  int get remotePort => _socket.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) => _socket.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _socket.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
}
