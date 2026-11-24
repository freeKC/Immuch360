// The relay a Cast device reads a film, a photo or a video from: a small HTTP server of the phone, bound to its
// address on the device's network, that serves an item only under a random path made for one cast
// ([CastRelayLease]) and forgets it when that cast ends. A request is forwarded, Range included, to the phone's media
// bridge on the loopback, which reads a Plex film from the server with the token in a header (plex_client.dart), or
// to the phone's Immich server through the app's own HTTP client, which adds the session itself
// ([CastRelayContent.upstream]): no token, no session, no address of the server is ever in a URL the device sees.
// The poster is served from memory under the same path.
//
// Rules: GET and HEAD only, private IPv4 clients only (and the loopback, the tests), an unknown or revoked path is a
// 404 without a body, the path never logged, a lease revoked after [CastRelayServer.leaseIdle] without a request or
// [CastRelayServer.leaseMaxAge] at most.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:logging/logging.dart';

final _log = Logger('CastRelay');

/// A request of the item to its source, with the device's Range and If-Range: what the relay forwards
typedef CastRelayUpstream = Future<http.StreamedResponse> Function(String method, Map<String, String> headers);

/// What a lease serves: the item from [film] (the bridge URL of its file, asked at each request so that a bridge bound
/// again is followed) or from [upstream] (a request of the app's own HTTP client), and the poster's bytes
class CastRelayContent {
  const CastRelayContent({this.film, this.upstream, this.poster, this.posterType = 'image/jpeg'})
    : assert(film != null || upstream != null);

  final Future<Uri> Function()? film;
  final CastRelayUpstream? upstream;
  final Uint8List? poster;
  final String posterType;
}

/// One film served under one random path
class CastRelayLease {
  CastRelayLease._(this._server, this.id, this._content, DateTime now) : _created = now, _lastUse = now;

  final CastRelayServer _server;

  /// 128 random bits in hex: the path's only secret
  final String id;
  final CastRelayContent _content;
  final DateTime _created;
  DateTime _lastUse;

  /// The film's address on the network
  Uri get filmUrl => _server._urlOf('/cast/$id/film');

  /// The poster's address, null without a poster
  Uri? get posterUrl => _content.poster == null ? null : _server._urlOf('/cast/$id/poster.jpg');

  bool get isRevoked => !_server._leases.containsKey(id);

  /// Forgets the path: the device's next request is a 404
  void revoke() => _server._leases.remove(id);
}

class CastRelayServer {
  CastRelayServer._(this._http, this._address, {HttpClient? client, DateTime Function()? clock})
    : _client = client ?? (HttpClient()..autoUncompress = false),
      _clock = clock ?? DateTime.now {
    _http.listen((request) => unawaited(_handle(request)));
  }

  /// The port tried first: next to the ports of the pairing (8361) and of Play on (8363)
  static const preferredPort = 8364;

  static const leaseIdle = Duration(minutes: 30);
  static const leaseMaxAge = Duration(hours: 12);

  /// Binds to [address] (an IPv4 address of this phone), on [preferredPort] when free
  static Future<CastRelayServer> bind(
    String address, {
    int port = preferredPort,
    HttpClient? client,
    DateTime Function()? clock,
  }) async {
    HttpServer http;
    try {
      http = await HttpServer.bind(address, port);
    } on SocketException {
      http = await HttpServer.bind(address, 0);
    }
    http.autoCompress = false;
    http.idleTimeout = const Duration(seconds: 30);
    return CastRelayServer._(http, address, client: client, clock: clock);
  }

  final HttpServer _http;
  final String _address;
  final HttpClient _client;
  final DateTime Function() _clock;
  final Map<String, CastRelayLease> _leases = {};
  final _random = Random.secure();
  bool _closed = false;

  String get address => _address;
  int get port => _http.port;
  bool get isClosed => _closed;

  /// A new path for [content]
  CastRelayLease lease(CastRelayContent content) {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final id = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final lease = CastRelayLease._(this, id, content, _clock());
    _leases[id] = lease;
    return lease;
  }

  int get leaseCount => _leases.length;

  Uri _urlOf(String path) => Uri(scheme: 'http', host: _address, port: _http.port, path: path);

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _leases.clear();
    await _http.close(force: true);
    _client.close(force: true);
  }

  static bool _clientAllowed(InternetAddress? remote) {
    if (remote == null) {
      return false;
    }
    if (remote.isLoopback) {
      return true;
    }
    final address = remote.type == InternetAddressType.IPv6 && remote.address.startsWith('::ffff:')
        ? remote.address.substring(7)
        : remote.address;
    return isPrivatePairingIPv4(address);
  }

  CastRelayLease? _leaseOf(String id) {
    final lease = _leases[id];
    if (lease == null) {
      return null;
    }
    final now = _clock();
    if (now.difference(lease._lastUse) > leaseIdle || now.difference(lease._created) > leaseMaxAge) {
      lease.revoke();
      return null;
    }
    lease._lastUse = now;
    return lease;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (!_clientAllowed(request.connectionInfo?.remoteAddress)) {
        _log.info('A client outside the private network was refused');
        await _end(response, HttpStatus.forbidden);
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        await _end(response, HttpStatus.methodNotAllowed);
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.length != 3 || segments[0] != 'cast' || request.uri.hasQuery) {
        await _end(response, HttpStatus.notFound);
        return;
      }
      final lease = _leaseOf(segments[1]);
      if (lease == null) {
        await _end(response, HttpStatus.notFound);
        return;
      }
      response.headers.set('access-control-allow-origin', '*');
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      switch (segments[2]) {
        case 'film':
          await _forward(request, lease);
        case 'poster.jpg':
          final poster = lease._content.poster;
          if (poster == null) {
            await _end(response, HttpStatus.notFound);
            return;
          }
          response.headers.contentType = ContentType.parse(lease._content.posterType);
          response.headers.contentLength = poster.length;
          if (request.method == 'GET') {
            response.add(poster);
          }
          await response.close();
        default:
          await _end(response, HttpStatus.notFound);
      }
    } catch (error) {
      // The device went away mid answer, or the bridge did: nothing to tell it any more
      _log.fine('A relay answer ended early: ${error.runtimeType}');
      try {
        await response.close();
      } catch (_) {}
    }
  }

  static const _forwardedAnswerHeaders = [
    HttpHeaders.contentTypeHeader,
    HttpHeaders.contentRangeHeader,
    HttpHeaders.acceptRangesHeader,
    HttpHeaders.lastModifiedHeader,
    HttpHeaders.etagHeader,
  ];

  Future<void> _forward(HttpRequest request, CastRelayLease lease) async {
    final upstreamRequest = lease._content.upstream;
    if (upstreamRequest != null) {
      return _forwardUpstream(request, upstreamRequest);
    }
    final response = request.response;
    final Uri upstream;
    try {
      upstream = await lease._content.film!();
    } catch (error) {
      _log.info('The film could not be found for the relay: ${error.runtimeType}');
      await _end(response, HttpStatus.badGateway);
      return;
    }
    final out = await _client.openUrl(request.method, upstream);
    out.followRedirects = false;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      out.headers.set(HttpHeaders.rangeHeader, range);
    }
    final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
    if (ifRange != null) {
      out.headers.set(HttpHeaders.ifRangeHeader, ifRange);
    }
    final answer = await out.close();
    response.statusCode = answer.statusCode;
    for (final name in _forwardedAnswerHeaders) {
      final value = answer.headers.value(name);
      if (value != null) {
        response.headers.set(name, value);
      }
    }
    if (answer.contentLength >= 0) {
      response.headers.contentLength = answer.contentLength;
    }
    if (request.method == 'HEAD') {
      await answer.drain<void>();
      await response.close();
      return;
    }
    // Stops reading the bridge (and the bridge the server) as soon as the device goes away
    await answer.pipe(response);
  }

  Future<void> _forwardUpstream(HttpRequest request, CastRelayUpstream upstream) async {
    final response = request.response;
    final headers = <String, String>{
      HttpHeaders.rangeHeader: ?request.headers.value(HttpHeaders.rangeHeader),
      HttpHeaders.ifRangeHeader: ?request.headers.value(HttpHeaders.ifRangeHeader),
    };
    final http.StreamedResponse answer;
    try {
      answer = await upstream(request.method, headers);
    } catch (error) {
      _log.info('The item could not be read for the relay: ${error.runtimeType}');
      await _end(response, HttpStatus.badGateway);
      return;
    }
    // A refusal of the server (its session ended, the asset is gone) is not the device's business
    if (answer.statusCode >= 300) {
      await answer.stream.drain<void>();
      await _end(response, answer.statusCode == HttpStatus.notFound ? HttpStatus.notFound : HttpStatus.badGateway);
      return;
    }
    response.statusCode = answer.statusCode;
    for (final name in _forwardedAnswerHeaders) {
      final value = answer.headers[name];
      if (value != null) {
        response.headers.set(name, value);
      }
    }
    final length = answer.contentLength;
    if (length != null && length >= 0) {
      response.headers.contentLength = length;
    }
    if (request.method == 'HEAD') {
      await answer.stream.drain<void>();
      await response.close();
      return;
    }
    await response.addStream(answer.stream);
    await response.close();
  }

  static Future<void> _end(HttpResponse response, int status) async {
    response.statusCode = status;
    response.headers.contentLength = 0;
    await response.close();
  }
}
