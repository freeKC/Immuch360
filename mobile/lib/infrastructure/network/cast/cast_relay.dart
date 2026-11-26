// The relay a Cast device reads a film, a photo or a video from: a small HTTP server of the phone, bound to its
// address on the device's network, that serves an item only under a random path made for one cast
// ([CastRelayLease]) and forgets it when that cast ends. A request is forwarded, Range included, to the phone's media
// bridge on the loopback, which reads a Plex film from the server with the token in a header (plex_client.dart), or
// to the phone's Immich server through the app's own HTTP client, which adds the session itself
// ([CastRelayContent.upstream]): no token, no session, no address of the server is ever in a URL the device sees.
// The poster is served from memory under the same path.
//
// The same relay serves a linked screen of "Play on…" (release 53): the phone's own photos and videos, read from the
// device ([CastRelayContent.file], [CastRelayContent.bytes]), and items the screen cannot reach with its own access.
// Such a lease is pinned to the screen's address like a Cast lease, and also asks for the header x-immuch-relay, the
// MAC of its path under the K_relay of the play link session ([CastRelayLease.macKeys], play_link_protocol.dart):
// another device of the network, or the screen without the session, gets the same 404 as for an unknown path.
//
// Rules: GET and HEAD only, private IPv4 clients only, an unknown or revoked path is a 404 without a body, the path
// never logged, a lease revoked after [CastRelayServer.leaseIdle] without a request or [CastRelayServer.leaseMaxAge]
// at most. A lease answers only the Cast device it was made for ([CastRelayLease.client], its IPv4 address): the
// device tells what it plays, the relay's address included, to any sender of the network that asks, so the path alone
// is no secret on the home network. Any other client gets the 404 of an unknown path. The loopback is let in only when
// the relay was bound with allowLoopback (the tests).

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:logging/logging.dart';

final _log = Logger('CastRelay');

/// A request of the item to its source, with the device's Range and If-Range: what the relay forwards
typedef CastRelayUpstream = Future<http.StreamedResponse> Function(String method, Map<String, String> headers);

/// What a lease serves: the item from [film] (the bridge URL of its file, asked at each request so that a bridge bound
/// again is followed), from [upstream] (a request of the app's own HTTP client), from [file] (a file of this device,
/// read at each request with its range) or from [bytes] (a picture made in memory), and the poster's bytes
class CastRelayContent {
  const CastRelayContent({this.film, this.upstream, this.poster, this.posterType = 'image/jpeg'})
    : file = null,
      bytes = null,
      contentType = null,
      assert(film != null || upstream != null);

  /// A photo or a video of this device, served by the relay itself (release 53)
  const CastRelayContent.local({this.file, this.bytes, required String this.contentType})
    : film = null,
      upstream = null,
      poster = null,
      posterType = 'image/jpeg',
      assert((file == null) != (bytes == null));

  final Future<Uri> Function()? film;
  final CastRelayUpstream? upstream;
  final Uint8List? poster;
  final String posterType;

  /// The file asked for at each request (a file of the gallery is looked up again: it may move)
  final Future<File?> Function()? file;
  final Uint8List? bytes;

  /// The type of [file] or [bytes]
  final String? contentType;
}

/// One film served under one random path
class CastRelayLease {
  CastRelayLease._(this._server, this.id, this._content, this.client, DateTime now, {this.macKeys})
    : _created = now,
      _lastUse = now;

  final CastRelayServer _server;

  /// The IPv4 address of the only client served: the Cast device, or the linked screen
  final String client;

  /// For a linked screen: the K_relay of the sessions the play may have gone through (the session that sealed it, or
  /// the one opened again after the screen forgot it), asked at each request; null for a Cast device, which cannot
  /// send a header
  final List<List<int>> Function()? macKeys;

  /// 128 random bits in hex: the path's only secret
  final String id;
  final CastRelayContent _content;
  final DateTime _created;
  DateTime _lastUse;

  /// The film's address on the network
  Uri get filmUrl => _server._urlOf(path);

  /// The film's path, the one its MAC is made of
  String get path => '/cast/$id/film';

  /// The port of the relay
  int get port => _server.port;

  /// The poster's address, null without a poster
  Uri? get posterUrl => _content.poster == null ? null : _server._urlOf('/cast/$id/poster.jpg');

  bool get isRevoked => !_server._leases.containsKey(id);

  /// Forgets the path: the device's next request is a 404
  void revoke() => _server._leases.remove(id);
}

class CastRelayServer {
  CastRelayServer._(
    this._http,
    this._address, {
    HttpClient? client,
    DateTime Function()? clock,
    this.allowLoopback = false,
  }) : _client = client ?? (HttpClient()..autoUncompress = false),
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
    bool allowLoopback = false,
  }) async {
    HttpServer http;
    try {
      http = await HttpServer.bind(address, port);
    } on SocketException {
      http = await HttpServer.bind(address, 0);
    }
    http.autoCompress = false;
    http.idleTimeout = const Duration(seconds: 30);
    return CastRelayServer._(http, address, client: client, clock: clock, allowLoopback: allowLoopback);
  }

  final HttpServer _http;
  final String _address;

  /// Whether a client on the loopback is served whatever the lease's device (the tests, where everything is there)
  final bool allowLoopback;
  final HttpClient _client;
  final DateTime Function() _clock;
  final Map<String, CastRelayLease> _leases = {};
  final _random = Random.secure();
  bool _closed = false;

  String get address => _address;
  int get port => _http.port;
  bool get isClosed => _closed;

  /// A new path for [content], served to the device at [client] (an IPv4 address) only; with [macKeys], to requests
  /// that carry the MAC of the path under one of them only (a linked screen)
  CastRelayLease lease(CastRelayContent content, {required String client, List<List<int>> Function()? macKeys}) {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final id = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final lease = CastRelayLease._(this, id, content, client, _clock(), macKeys: macKeys);
    _leases[id] = lease;
    return lease;
  }

  int get leaseCount => _leases.length;

  /// The leases alive now
  Iterable<CastRelayLease> get leases => List.unmodifiable(_leases.values);

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

  /// The IPv4 address of [remote], an IPv4 mapped in IPv6 included
  static String? _ipv4Of(InternetAddress? remote) {
    if (remote == null) {
      return null;
    }
    return remote.type == InternetAddressType.IPv6 && remote.address.toLowerCase().startsWith('::ffff:')
        ? remote.address.substring(7)
        : remote.address;
  }

  bool _clientAllowed(InternetAddress? remote) {
    if (remote == null) {
      return false;
    }
    // The loopback passes here; the lease's device decides below
    final address = _ipv4Of(remote);
    return remote.isLoopback || (address != null && isPrivatePairingIPv4(address));
  }

  /// Whether [remote] is the device [lease] was made for
  bool _servesClient(CastRelayLease lease, InternetAddress? remote) =>
      _ipv4Of(remote) == lease.client || (allowLoopback && (remote?.isLoopback ?? false));

  /// Whether [request] carries the MAC of [lease]'s path under one of its keys; true for a lease without keys
  static bool _carriesMac(CastRelayLease lease, HttpRequest request) {
    final keysOf = lease.macKeys;
    if (keysOf == null) {
      return true;
    }
    final values = request.headers[playRelayHeader];
    final given = values == null || values.length != 1 ? null : pairingDecodeBase64(values.single);
    if (given == null) {
      return false;
    }
    final keys = keysOf();
    var found = false;
    // Every key is tried, found or not: the time does not tell which one matched
    for (final key in keys) {
      final expected = pairingDecodeBase64(playRelayMac(key, lease.path));
      if (expected != null && pairingSameBytes(expected, given)) {
        found = true;
      }
    }
    return found;
  }

  /// The lease of [id] when [remote] is its device, with the MAC of its path when it asks for one; another client of
  /// the network learns nothing, not even that the path exists, and does not keep the lease alive
  CastRelayLease? _leaseOf(String id, InternetAddress? remote, HttpRequest request) {
    final lease = _leases[id];
    if (lease == null) {
      return null;
    }
    if (!_servesClient(lease, remote)) {
      _log.info('A client that is not the device of a lease asked for it');
      return null;
    }
    if (!_carriesMac(lease, request)) {
      _log.info('A request without the MAC of its lease was refused');
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
      final lease = _leaseOf(segments[1], request.connectionInfo?.remoteAddress, request);
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
    final content = lease._content;
    if (content.bytes != null || content.file != null) {
      return _serveLocal(request, content);
    }
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

  /// A file of this device or bytes made in memory, with one range at most (what players and image widgets ask)
  Future<void> _serveLocal(HttpRequest request, CastRelayContent content) async {
    final response = request.response;
    final bytes = content.bytes;
    File? file;
    if (bytes == null) {
      try {
        file = await content.file!();
      } catch (error) {
        _log.info('The file of a lease could not be found: ${error.runtimeType}');
      }
      if (file == null) {
        await _end(response, HttpStatus.notFound);
        return;
      }
    }
    final int length;
    try {
      length = bytes?.length ?? await file!.length();
    } on FileSystemException {
      await _end(response, HttpStatus.notFound);
      return;
    }
    final range = castRelayRangeOf(request.headers.value(HttpHeaders.rangeHeader), length);
    if (range == null) {
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
      await _end(response, HttpStatus.requestedRangeNotSatisfiable);
      return;
    }
    response.headers.contentType = ContentType.parse(content.contentType!);
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (range.partial) {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes ${range.start}-${range.end - 1}/$length');
    }
    response.headers.contentLength = range.end - range.start;
    if (request.method == 'HEAD' || range.end == range.start) {
      await response.close();
      return;
    }
    if (bytes != null) {
      response.add(Uint8List.sublistView(bytes, range.start, range.end));
      await response.close();
      return;
    }
    await response.addStream(file!.openRead(range.start, range.end));
    await response.close();
  }

  static Future<void> _end(HttpResponse response, int status) async {
    response.statusCode = status;
    response.headers.contentLength = 0;
    await response.close();
  }
}

/// The bytes [header] (a Range header) asks of a file of [length] bytes: the whole file without one (or with one that is
/// not a single byte range, which a server may ignore), null when the range is past the end
({int start, int end, bool partial})? castRelayRangeOf(String? header, int length) {
  final whole = (start: 0, end: length, partial: false);
  if (header == null) {
    return whole;
  }
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
    return whole;
  }
  final first = int.tryParse(match[1]!);
  final last = int.tryParse(match[2]!);
  if (first == null) {
    // The last bytes
    if (last == null || last == 0) {
      return null;
    }
    final start = last >= length ? 0 : length - last;
    return (start: start, end: length, partial: true);
  }
  if (first >= length || (last != null && last < first)) {
    return null;
  }
  final end = last == null || last >= length ? length : last + 1;
  return (start: first, end: end, partial: true);
}
