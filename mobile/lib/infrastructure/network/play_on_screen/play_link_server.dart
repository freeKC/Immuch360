// The listener of "Play on the TV" on a big screen (a TV, the Quest window, a computer): the hello, the open and the
// sealed commands of the linked phones (screen_player_session.dart). It runs while the app is in front, the setting
// is on and at least one phone is linked (screen_player.provider.dart).
//
// The rules of the pairing listener (pairing_server.dart): only on the LAN addresses of the device and its loopback
// (ServedSockets), clients outside the private ranges get 403 and the connection closed, a Host that is not an IPv4
// literal is refused (DNS rebinding), JSON bodies of at most [maxBody] bytes read within [requestTimeout],
// [maxConnections] requests at once (a long poll of the status holds one), ten failures a minute from one address
// block it for a minute. The log has the route, the status and the time only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/infrastructure/network/served_sockets.dart';
import 'package:logging/logging.dart';

final _log = Logger('PlayLinkServer');

/// See the top of this file
class PlayLinkServer {
  PlayLinkServer({
    required this._session,
    this._servedAddresses,
    bool Function(InternetAddress)? isAllowedClient,
    this.preferredPort = playLinkDefaultPort,
    DateTime Function()? clock,
    this._requestTimeout = requestTimeout,
  }) : _isAllowedClient = isAllowedClient ?? isLocalNetworkAddress,
       _clock = clock ?? DateTime.now;

  static const maxBody = 16 * 1024;
  static const maxConnections = 12;
  static const requestTimeout = Duration(seconds: 10);
  static const maxFailures = 10;
  static const failureWindow = Duration(seconds: 60);
  static const blockDuration = Duration(seconds: 60);

  final int preferredPort;
  final ScreenPlayerSession _session;
  final Future<List<String>> Function()? _servedAddresses;
  final bool Function(InternetAddress) _isAllowedClient;
  final DateTime Function() _clock;
  final Duration _requestTimeout;

  HttpServer? _server;
  ServerSocket? _socket;
  int _open = 0;
  final Map<String, List<DateTime>> _failures = {};
  final Map<String, DateTime> _blockedUntil = {};

  int? get port => _server?.port;

  /// Listens on [preferredPort] when it is free, else on any port; returns the port
  Future<int> start() async {
    final running = _server;
    if (running != null) {
      return running.port;
    }
    ServerSocket? bound;
    try {
      bound = await _listen(preferredPort);
    } on SocketException catch (error) {
      _log.fine('Port $preferredPort is taken, the player listener moves to another one: ${error.osError?.errorCode}');
    }
    final socket = bound ?? await _listen(0);
    final server = HttpServer.listenOn(socket)
      ..autoCompress = false
      ..idleTimeout = const Duration(seconds: 30)
      ..serverHeader = 'Immuch360';
    _server = server;
    _socket = socket;
    server.listen(
      (request) => unawaited(_serve(request)),
      onError: (Object error) => _log.fine('The player listener failed: ${error.runtimeType}'),
    );
    _log.info('Player listener on port ${server.port}');
    return server.port;
  }

  Future<ServerSocket> _listen(int port) {
    final served = _servedAddresses;
    return served == null
        ? ServerSocket.bind(InternetAddress.loopbackIPv4, port)
        : ServedSockets.bind(port, served, strict: port != 0, label: 'Player');
  }

  /// Listens on the addresses the device has now, at once
  Future<void> refreshServedAddresses() async {
    final socket = _socket;
    if (socket is ServedSockets) {
      await socket.refresh();
    }
  }

  Future<void> stop() async {
    final server = _server;
    final socket = _socket;
    _server = null;
    _socket = null;
    await server?.close(force: true);
    await socket?.close();
    _failures.clear();
    _blockedUntil.clear();
    if (server != null) {
      _log.info('Player listener stopped');
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    unawaited(response.done.then<void>((_) {}, onError: (Object _) {}));
    final started = _clock();
    var route = 'refused';
    try {
      route = await _answer(request, response);
    } catch (error) {
      route = 'failed (${error.runtimeType})';
      try {
        response.statusCode = HttpStatus.internalServerError;
        response.contentLength = 0;
      } catch (_) {
        // The headers are already sent
      }
      try {
        await response.close();
      } catch (_) {
        // The connection is already gone
      }
    }
    _log.fine('Player $route: ${response.statusCode} in ${_clock().difference(started).inMilliseconds} ms');
  }

  Future<String> _answer(HttpRequest request, HttpResponse response) async {
    final remote = request.connectionInfo?.remoteAddress;
    if (remote == null || !_isAllowedClient(remote)) {
      response.persistentConnection = false;
      await _plain(response, HttpStatus.forbidden);
      return 'outside the local network';
    }
    if (!_isLiteralHost(request.headers.host)) {
      response.persistentConnection = false;
      await _plain(response, HttpStatus.forbidden);
      return 'host name';
    }
    final client = remote.address;
    if (_isBlocked(client, _clock())) {
      response.persistentConnection = false;
      response.headers.set(HttpHeaders.retryAfterHeader, '${blockDuration.inSeconds}');
      await _plain(response, HttpStatus.tooManyRequests);
      return 'blocked';
    }
    if (_open >= maxConnections) {
      response.persistentConnection = false;
      response.headers.set(HttpHeaders.retryAfterHeader, '2');
      await _plain(response, HttpStatus.serviceUnavailable);
      return 'busy';
    }
    _open++;
    try {
      return await _route(request, response, client);
    } finally {
      _open--;
    }
  }

  Future<String> _route(HttpRequest request, HttpResponse response, String client) async {
    final method = request.method.toUpperCase();
    final path = request.uri.path;
    if (path == '/v1/hello') {
      if (method != 'GET') {
        _recordFailure(client);
        response.headers.set(HttpHeaders.allowHeader, 'GET');
        await _plain(response, HttpStatus.methodNotAllowed);
        return 'hello';
      }
      final answer = _session.hello();
      await _json(response, answer.status, answer.body);
      return 'hello';
    }
    if (path != '/v1/open' && path != '/v1/cmd') {
      _recordFailure(client);
      await _plain(response, HttpStatus.notFound);
      return 'unknown';
    }
    final route = path == '/v1/open' ? 'open' : 'command';
    if (method != 'POST') {
      _recordFailure(client);
      response.headers.set(HttpHeaders.allowHeader, 'POST');
      await _plain(response, HttpStatus.methodNotAllowed);
      return route;
    }
    // A form of another site can post text/plain without asking first: only JSON is read
    if (request.headers.contentType?.mimeType != 'application/json') {
      _recordFailure(client);
      await _plain(response, HttpStatus.unsupportedMediaType);
      return route;
    }
    final body = await _readBody(request);
    if (body == null) {
      _recordFailure(client);
      response.persistentConnection = false;
      await _json(response, HttpStatus.requestEntityTooLarge, {'v': playLinkProtocolVersion, 'error': 'tooLarge'});
      return route;
    }
    final Map<String, Object?> message;
    try {
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is! Map<String, Object?> || decoded['v'] != playLinkProtocolVersion) {
        throw const FormatException();
      }
      message = decoded;
    } on FormatException {
      _recordFailure(client);
      await _json(response, HttpStatus.badRequest, {'v': playLinkProtocolVersion, 'error': 'invalid'});
      return route;
    }
    final answer = route == 'open' ? _session.open(message) : await _session.command(message);
    // A gone session is no attack: the phone opens a new one
    if (answer.status != HttpStatus.ok && answer.status != HttpStatus.gone) {
      _recordFailure(client);
    }
    await _json(response, answer.status, answer.body);
    return route;
  }

  static void _commonHeaders(HttpResponse response, String contentType) {
    response.headers
      ..set(HttpHeaders.contentTypeHeader, contentType)
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('referrer-policy', 'no-referrer')
      ..set('x-content-type-options', 'nosniff');
  }

  static Future<void> _json(HttpResponse response, int status, Map<String, Object?> body) async {
    final bytes = utf8.encode(jsonEncode(body));
    response.statusCode = status;
    _commonHeaders(response, 'application/json; charset=utf-8');
    response.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }

  static Future<void> _plain(HttpResponse response, int status) async {
    response.statusCode = status;
    _commonHeaders(response, 'text/plain; charset=utf-8');
    response.contentLength = 0;
    await response.close();
  }

  /// The body, null when it is larger than [maxBody] or does not come within the request timeout
  Future<Uint8List?> _readBody(HttpRequest request) async {
    if (request.contentLength > maxBody) {
      await request.listen(null).cancel();
      return null;
    }
    final builder = BytesBuilder(copy: false);
    final done = Completer<Uint8List?>();
    late final StreamSubscription<List<int>> subscription;
    subscription = request.listen(
      (chunk) {
        builder.add(chunk);
        if (builder.length > maxBody && !done.isCompleted) {
          unawaited(subscription.cancel());
          done.complete(null);
        }
      },
      onDone: () {
        if (!done.isCompleted) {
          done.complete(builder.takeBytes());
        }
      },
      onError: (Object _) {
        if (!done.isCompleted) {
          done.complete(null);
        }
      },
      cancelOnError: true,
    );
    return done.future.timeout(
      _requestTimeout,
      onTimeout: () {
        unawaited(subscription.cancel());
        return null;
      },
    );
  }

  static bool _isLiteralHost(String? host) =>
      host != null &&
      RegExp(r'^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$').hasMatch(host) &&
      InternetAddress.tryParse(host) != null;

  bool _isBlocked(String client, DateTime now) {
    final until = _blockedUntil[client];
    if (until == null) {
      return false;
    }
    if (now.isBefore(until)) {
      return true;
    }
    _blockedUntil.remove(client);
    _failures.remove(client);
    return false;
  }

  void _recordFailure(String client) {
    final now = _clock();
    _failures.removeWhere((_, times) {
      times.removeWhere((time) => now.difference(time) >= failureWindow);
      return times.isEmpty;
    });
    final times = _failures.putIfAbsent(client, () => [])..add(now);
    if (times.length >= maxFailures) {
      _log.warning('Player: a client failed $maxFailures times, blocked for a minute');
      _blockedUntil[client] = now.add(blockDuration);
      _failures.remove(client);
    }
  }
}
