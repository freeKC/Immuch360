// The listener of "Sign in with your phone" on a big screen (a TV, the Quest window, a computer): small JSON
// requests of a phone, and the page a phone's browser opens from the QR code. It runs only while the pairing panel
// shows, and stops on success, when the panel goes, when the app goes to the background and when the codes pause.
//
// Security (design 5 and 6):
// - only on the LAN addresses of the device and its loopback (ServedSockets), clients outside the private ranges get
//   403 and the connection closed; a Host that is not an IPv4 literal is refused too, so that a web page of another
//   site that renames itself to this address (DNS rebinding) cannot read anything;
// - JSON bodies of at most [maxBody] bytes, read within [requestTimeout], [maxConnections] requests at once;
// - ten failures a minute from one address block it for a minute (429);
// - everything that matters is sealed with the keys of a hello (screen_pairing_session.dart); the page has a strict
//   Content-Security-Policy, and nothing is cached nor sent as a referrer;
// - the log has the route, the status and the time only: never a body, the code, a token or a password.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/pairing/screen_pairing_session.dart';
import 'package:immich_mobile/infrastructure/network/served_sockets.dart';
import 'package:logging/logging.dart';

final _log = Logger('PairingServer');

/// How a sign in the listener asked for went
class PairingSignInResult {
  const PairingSignInResult({
    required this.answer,
    required this.signedIn,
    this.retry = false,
    this.notice = ScreenPairingNotice.signInFailed,
    this.detail,
  });

  /// What goes back to the phone or the page, sealed: {status, ...}
  final Map<String, Object?> answer;
  final bool signedIn;

  /// The browser page may try again (a wrong email or password, a server address that does not answer or takes OAuth
  /// only): the code stays for another try
  final bool retry;

  /// What the panel says under the next code when the sign in failed
  final ScreenPairingNotice notice;
  final String? detail;
}

/// What signs the screen in: with the session a phone made, or with the email and password of the browser page
abstract interface class PairingSignIn {
  Future<PairingSignInResult> withSession(Map<String, Object?> payload);
  Future<PairingSignInResult> withPassword(Map<String, Object?> credentials);
}

/// The files of the browser page (assets/pairing) and what the page shows of this screen
class PairingPage {
  const PairingPage({required this.html, required this.script, required this.style, this.texts = const {}});

  final Uint8List html;
  final Uint8List script;
  final Uint8List style;

  /// The page's texts in the language of the screen, by key
  final Map<String, String> texts;
}

/// See the top of this file
class PairingServer {
  PairingServer({
    required this._session,
    required this._signIn,
    required this._page,
    required this._device,
    this._servedAddresses,
    bool Function(InternetAddress)? isAllowedClient,
    this.preferredPort = pairingDefaultPort,
    DateTime Function()? clock,
    this._requestTimeout = requestTimeout,
  }) : _isAllowedClient = isAllowedClient ?? isLocalNetworkAddress,
       _clock = clock ?? DateTime.now;

  static const maxBody = 16 * 1024;
  static const maxConnections = 8;
  static const requestTimeout = Duration(seconds: 10);
  static const maxFailures = 10;
  static const failureWindow = Duration(seconds: 60);
  static const blockDuration = Duration(seconds: 60);

  static const contentSecurityPolicy =
      "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; "
      "base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

  /// The port tried first, else any free port
  final int preferredPort;
  final ScreenPairingSession _session;
  final PairingSignIn _signIn;
  final PairingPage _page;

  /// {label, kind, os, app}, as the hello sends it
  final Map<String, String> _device;
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
      _log.fine('Port $preferredPort is taken, the pairing listener moves to another one: ${error.osError?.errorCode}');
    }
    final socket = bound ?? await _listen(0);
    final server = HttpServer.listenOn(socket)
      ..autoCompress = false
      ..idleTimeout = const Duration(seconds: 15)
      ..serverHeader = 'Immuch360';
    _server = server;
    _socket = socket;
    server.listen(
      (request) => unawaited(_serve(request)),
      onError: (Object error) => _log.fine('The pairing listener failed: ${error.runtimeType}'),
    );
    _log.info('Pairing listener on port ${server.port}');
    return server.port;
  }

  Future<ServerSocket> _listen(int port) {
    final served = _servedAddresses;
    return served == null
        ? ServerSocket.bind(InternetAddress.loopbackIPv4, port)
        : ServedSockets.bind(port, served, strict: port != 0, label: 'Pairing');
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
      _log.info('Pairing listener stopped');
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
    final method = const ['GET', 'HEAD', 'POST'].contains(request.method) ? request.method : 'other';
    _log.fine('Pairing $method $route: ${response.statusCode} in ${_clock().difference(started).inMilliseconds} ms');
  }

  /// Answers [request]; gives the name of the route for the log, never its path
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
    final now = _clock();
    if (_isBlocked(client, now)) {
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
    final segments = request.uri.pathSegments;
    if (segments.isEmpty || segments.first != 'p' || request.uri.path.contains('//')) {
      _recordFailure(client);
      await _plain(response, HttpStatus.notFound);
      return 'unknown';
    }

    // The page and what it reads
    if (segments.length <= 2 &&
        (segments.length == 1 || const ['', 'app.js', 'app.css', 'info'].contains(segments[1]))) {
      if (method != 'GET' && method != 'HEAD') {
        response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        await _plain(response, HttpStatus.methodNotAllowed);
        return 'page';
      }
      final name = segments.length == 1 ? '' : segments[1];
      return switch (name) {
        'app.js' => _file(response, _page.script, 'text/javascript; charset=utf-8', 'script'),
        'app.css' => _file(response, _page.style, 'text/css; charset=utf-8', 'style'),
        'info' => _info(response),
        _ => _file(response, _page.html, 'text/html; charset=utf-8', 'page'),
      };
    }

    // POST /p/{id}/hello, /session, /login
    if (segments.length != 3 || !const ['hello', 'session', 'login'].contains(segments[2])) {
      _recordFailure(client);
      await _plain(response, HttpStatus.notFound);
      return 'unknown';
    }
    final action = segments[2];
    if (method != 'POST') {
      response.headers.set(HttpHeaders.allowHeader, 'POST');
      _recordFailure(client);
      await _plain(response, HttpStatus.methodNotAllowed);
      return action;
    }
    // A form of another site can post text/plain without asking first: only JSON is read
    if (request.headers.contentType?.mimeType != 'application/json') {
      _recordFailure(client);
      await _plain(response, HttpStatus.unsupportedMediaType);
      return action;
    }
    final body = await _readBody(request);
    if (body == null) {
      _recordFailure(client);
      response.persistentConnection = false;
      await _json(response, HttpStatus.requestEntityTooLarge, {'v': pairingProtocolVersion, 'error': 'tooLarge'});
      return action;
    }
    final Map<String, Object?> message;
    try {
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is! Map<String, Object?> || decoded['v'] != pairingProtocolVersion) {
        throw const FormatException();
      }
      message = decoded;
    } on FormatException {
      _recordFailure(client);
      await _json(response, HttpStatus.badRequest, {'v': pairingProtocolVersion, 'error': 'invalid'});
      return action;
    }
    final id = segments[1];
    return switch (action) {
      'hello' => _hello(response, client, id, message),
      'session' => _sealed(response, client, id, message, PairingClient.app),
      _ => _sealed(response, client, id, message, PairingClient.web),
    };
  }

  Future<String> _hello(HttpResponse response, String client, String id, Map<String, Object?> message) async {
    final outcome = await _session.hello(
      id: id,
      mode: message['mode'],
      client: message['client'],
      phoneKey: message['pk'],
    );
    final (status, body) = switch (outcome) {
      HelloAccepted(:final response) => (HttpStatus.ok, response),
      HelloGone(:final used) => (HttpStatus.gone, {'v': pairingProtocolVersion, 'error': used ? 'used' : 'expired'}),
      HelloThrottled() => (HttpStatus.tooManyRequests, {'v': pairingProtocolVersion, 'error': 'tooMany'}),
      HelloInvalid() => (HttpStatus.badRequest, {'v': pairingProtocolVersion, 'error': 'invalid'}),
    };
    if (status != HttpStatus.ok && status != HttpStatus.tooManyRequests) {
      _recordFailure(client);
    }
    await _json(response, status, body);
    return 'hello';
  }

  Future<String> _sealed(
    HttpResponse response,
    String client,
    String id,
    Map<String, Object?> envelope,
    PairingClient kind,
  ) async {
    final route = kind == PairingClient.app ? 'session' : 'login';
    final outcome = _session.open(id: id, envelope: envelope, client: kind);
    switch (outcome) {
      case SealedGone(:final used):
        _recordFailure(client);
        await _json(response, HttpStatus.gone, {'v': pairingProtocolVersion, 'error': used ? 'used' : 'expired'});
        return route;
      case SealedRejected():
        _recordFailure(client);
        await _json(response, HttpStatus.badRequest, {'v': pairingProtocolVersion, 'error': 'rejected'});
        return route;
      case SealedUnknown():
        _recordFailure(client);
        await _json(response, HttpStatus.badRequest, {'v': pairingProtocolVersion, 'error': 'invalid'});
        return route;
      case SealedCancelled(:final hello):
        await _json(response, HttpStatus.ok, hello.channel.seal({'v': pairingProtocolVersion, 'status': 'cancelled'}));
        return '$route cancelled';
      case SealedBusy():
        await _json(response, HttpStatus.conflict, {'v': pairingProtocolVersion, 'error': 'busy'});
        return route;
      case SealedOpened(:final hello, :final message):
        PairingSignInResult result;
        try {
          result = kind == PairingClient.app ? await _signIn.withSession(message) : await _signIn.withPassword(message);
        } catch (error) {
          _log.warning('Pairing: the sign in failed: ${error.runtimeType}');
          result = const PairingSignInResult(answer: {'status': 'failed'}, signedIn: false);
        }
        final answer = {'v': pairingProtocolVersion, ...result.answer};
        if (result.retry) {
          final left = _session.finish(
            id: id,
            signedIn: false,
            retry: true,
            notice: result.notice,
            detail: result.detail,
          );
          answer['triesLeft'] = left ?? 0;
        }
        // The answer goes out before the panel moves on: the phone keeps the session only once it has it
        await _json(response, HttpStatus.ok, hello.channel.seal(answer));
        if (!result.retry) {
          _session.finish(id: id, signedIn: result.signedIn, notice: result.notice, detail: result.detail);
        }
        return '$route ${result.answer['status']}';
    }
  }

  Future<String> _info(HttpResponse response) async {
    final code = _session.currentCode;
    await _json(response, HttpStatus.ok, {
      'v': pairingProtocolVersion,
      // Null while paused: the page says to show a new code on the screen
      'id': code?.id,
      'device': _device,
      'texts': _page.texts,
    });
    return 'info';
  }

  Future<String> _file(HttpResponse response, Uint8List bytes, String type, String route) async {
    response.statusCode = HttpStatus.ok;
    _commonHeaders(response, type);
    response.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
    return route;
  }

  static void _commonHeaders(HttpResponse response, String contentType) {
    response.headers
      ..set(HttpHeaders.contentTypeHeader, contentType)
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('referrer-policy', 'no-referrer')
      ..set('x-content-type-options', 'nosniff')
      ..set('x-frame-options', 'DENY')
      ..set('content-security-policy', contentSecurityPolicy);
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
    final declared = request.contentLength;
    if (declared > maxBody) {
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

  /// An IPv4 literal, with or without a port: what a phone or a browser sends when it follows the QR code
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
      _log.warning('Pairing: a client failed $maxFailures times, blocked for a minute');
      _blockedUntil[client] = now.add(blockDuration);
      _failures.remove(client);
    }
  }
}
