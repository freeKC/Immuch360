// "Share this phone on the network": a read-only WebDAV server over the gallery of the phone, so that a headset (or
// any WebDAV client of the local network) browses and plays the photos and videos of the phone without a computer or
// a NAS. The headset reaches it with the WebDAV client it uses for every share, through its media bridge.
//
// What it serves is the virtual tree of PhoneGalleryTree: a client only names nodes of that tree, which resolve to
// asset ids, so no path of the file system ever comes from the network. It answers OPTIONS, PROPFIND (depth 0 and 1),
// GET and HEAD, with ranges; anything else is refused with 405.
//
// Security, for a share the user starts by hand on a network they trust:
// - only clients of the local network: loopback, link-local and private (RFC 1918) addresses, which cover the Wi-Fi,
//   Ethernet and the hotspot of the phone; anyone else gets 403 and the connection is closed;
// - only on the addresses of the phone on that network (servedAddresses) and its loopback: a client that reaches the
//   phone on its mobile data or VPN address, where the operator may hand out private addresses too, finds no server;
// - Basic authentication on every request, the user name and password compared in constant time (through their
//   SHA-256, so the time does not even tell their length); ten failures from one address within a minute block it
//   for a minute (429), and one address has at most [maxUnauthenticated] requests waiting for their check at once;
// - a body waits a few seconds at most for its turn (503 after), and a client that stops reading for
//   [defaultStallTimeout] has its connection cut, so that it does not keep its turn;
// - read only, and the password never goes to the logs. The password travels in clear on the Wi-Fi (plain HTTP
//   Basic): accepted for a read-only, LAN-only share the user started.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/http_byte_range.dart';
import 'package:immich_mobile/domain/services/phone_share/phone_gallery_tree.dart';
import 'package:immich_mobile/infrastructure/network/lite_xml.dart';
import 'package:immich_mobile/platform/phone_share_api.g.dart';
import 'package:logging/logging.dart';

final _log = Logger('PhoneShareServer');

/// One request of a client, for the page of the share. Holds no credential.
class PhoneShareActivity {
  const PhoneShareActivity({required this.client, required this.method, required this.path, required this.at});

  /// The address of the client
  final String client;
  final String method;

  /// The path asked for, decoded
  final String path;
  final DateTime at;

  @override
  String toString() => 'PhoneShareActivity($client $method $path)';
}

/// The password as the server compares it: without its spaces and in lower case, so that the groups shown on the page
/// ("k7m3 x9p2") and a keyboard that starts with a capital letter are accepted
String normalizePhoneSharePassword(String password) => password.replaceAll(RegExp(r'\s'), '').toLowerCase();

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

/// The WebDAV server of the phone share, see the top of this file
class PhoneShareServer {
  PhoneShareServer({
    required this._tree,
    required this._files,
    required String username,
    required String password,
    bool Function(InternetAddress)? isAllowedClient,
    this._servedAddresses,
    this.preferredPort = defaultPort,
    DateTime Function()? clock,
    this._bodyWaitTimeout = defaultBodyWaitTimeout,
    this._stallTimeout = defaultStallTimeout,
  }) : _usernameDigest = _digestOf(username),
       _passwordDigest = _digestOf(normalizePhoneSharePassword(password)),
       _isAllowedClient = isAllowedClient ?? isLocalNetworkAddress,
       _clock = clock ?? DateTime.now;

  static const defaultPort = 8360;
  static const realm = 'Immuch360';

  /// Bodies sent at once; the next requests wait for one to end
  static const maxBodies = 8;

  /// How long a request waits for a body to end before it is answered 503 with [busyRetryAfter]: a player gives up on
  /// a request that hangs for long, while one told to come back may try again
  static const defaultBodyWaitTimeout = Duration(seconds: 10);
  static const busyRetryAfter = Duration(seconds: 5);

  /// A body whose client takes nothing for this long has its connection cut: a client that stopped reading without
  /// closing would keep its turn for as long as the connection lives
  static const defaultStallTimeout = Duration(seconds: 30);

  /// Requests of one address whose body is being read before their credentials are checked; the next ones are
  /// refused (429) until one of them is through
  static const maxUnauthenticated = 16;

  /// Bytes read from a file at a time
  static const chunkSize = 1024 * 1024;

  static const maxFailures = 10;
  static const failureWindow = Duration(seconds: 60);
  static const blockDuration = Duration(seconds: 60);

  /// How long the answer of the platform about where a file is stays good: a player asks for many ranges of one file
  static const openedFileTtl = Duration(minutes: 2);

  /// Past this size, or after 10 s, a request body is not read further: the connection is closed after the answer
  /// instead. No request of a WebDAV client that reads has a body this big.
  static const maxDrainedBody = 16 * 1024 * 1024;

  static const _allow = 'OPTIONS, PROPFIND, GET, HEAD';

  /// The port tried first, else any free port
  final int preferredPort;

  final PhoneGalleryTree _tree;
  final PhoneShareFiles _files;
  final Digest _usernameDigest;
  final Digest _passwordDigest;
  final bool Function(InternetAddress) _isAllowedClient;

  /// The addresses of the phone the share listens on besides the loopback; null listens on every address
  final Future<List<String>> Function()? _servedAddresses;
  final DateTime Function() _clock;
  final Duration _bodyWaitTimeout;
  final Duration _stallTimeout;

  final _activity = StreamController<PhoneShareActivity>.broadcast();
  final _bodies = _BodySlots(maxBodies);
  final Map<String, List<DateTime>> _failures = {};
  final Map<String, DateTime> _blockedUntil = {};

  /// The requests of each address whose credentials are not checked yet
  final Map<String, int> _unauthenticated = {};
  final Map<String, ({DateTime at, Future<PhoneShareOpenedFile?> file})> _opened = {};

  /// The bodies being sent, each completed once its file is closed
  final Set<Completer<void>> _sending = {};

  HttpServer? _server;

  /// The socket the server listens on: a server made with listenOn leaves it open when it closes
  ServerSocket? _socket;
  bool _stopped = false;
  DateTime? _lastRequestAt;

  /// The requests of the authenticated clients, as they come; lives as long as this object
  Stream<PhoneShareActivity> get activity => _activity.stream;

  /// When an authenticated client last asked for something or received a part of a file: a video played for an hour
  /// in one long read keeps the share in use
  DateTime? get lastRequestAt => _lastRequestAt;

  /// The port it listens on, null while it does not run
  int? get port => _server?.port;

  /// Listens on [preferredPort] when it is free, else on any port, on the loopback and the served addresses (every
  /// IPv4 interface without them); returns the port
  Future<int> start() async {
    final running = _server;
    if (running != null) {
      return running.port;
    }
    ServerSocket? bound;
    if (preferredPort != 0) {
      try {
        bound = await _listen(preferredPort);
      } on SocketException catch (error) {
        _log.fine('Port $preferredPort is taken, the phone share moves to another one: $error');
      }
    }
    final socket = bound ?? await _listen(0);
    final server = HttpServer.listenOn(socket);
    server
      ..autoCompress = false
      ..idleTimeout = const Duration(seconds: 30)
      ..serverHeader = realm;
    _stopped = false;
    _server = server;
    _socket = socket;
    server.listen(
      (request) => unawaited(_serve(request)),
      onError: (Object error, StackTrace stackTrace) =>
          _log.warning('The phone share server failed', error, stackTrace),
      onDone: () {
        if (identical(_server, server)) {
          _server = null;
        }
      },
    );
    _log.info('Phone share listening on port ${server.port}');
    return server.port;
  }

  /// Listens on the served addresses the phone has now and no more on the ones it lost, at once rather than at the
  /// next check of [_ServedSockets.refreshInterval]: for when the network changed
  Future<void> refreshServedAddresses() async {
    final socket = _socket;
    if (socket is _ServedSockets) {
      await socket.refresh();
    }
  }

  /// Listens on [port], any free one with 0. A served address that cannot have a given port fails it, so that the
  /// share moves to another port rather than miss that network; on any port, it is left out.
  Future<ServerSocket> _listen(int port) {
    final servedAddresses = _servedAddresses;
    return servedAddresses == null
        ? ServerSocket.bind(InternetAddress.anyIPv4, port)
        : _ServedSockets.bind(port, servedAddresses, strict: port != 0);
  }

  /// Closes the server and its connections; the bodies being sent stop and close their files
  Future<void> stop() async {
    _stopped = true;
    final server = _server;
    final socket = _socket;
    _server = null;
    _socket = null;
    _bodies.cancelWaiting(StateError('The phone share stopped'));
    await server?.close(force: true);
    await socket?.close();
    final sending = [for (final body in _sending) body.future];
    if (sending.isNotEmpty) {
      await Future.wait(sending).timeout(const Duration(seconds: 5), onTimeout: () => const []);
    }
    _opened.clear();
    _failures.clear();
    _blockedUntil.clear();
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    // A client that goes away makes the response fail: nothing to report
    unawaited(response.done.then<void>((_) {}, onError: (Object _) {}));
    try {
      await _answer(request, response);
    } catch (error, stackTrace) {
      if (_stopped || error is SocketException || error is HttpException) {
        // The server stopped, or the client went away: a player leaves a transfer as soon as it has its bytes
        _log.fine('A phone share response ended early: $error');
      } else {
        _log.warning('A phone share response failed', error, stackTrace);
      }
      try {
        // An error status while the headers did not go out yet; once the body started, the connection is cut
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
  }

  Future<void> _answer(HttpRequest request, HttpResponse response) async {
    final remote = request.connectionInfo?.remoteAddress;
    if (remote == null || !_isAllowedClient(remote)) {
      _log.info('Phone share: refused ${remote?.address ?? 'a client'}, outside the local network');
      response.persistentConnection = false;
      return _fail(response, HttpStatus.forbidden, 'Only the devices of the local network may connect');
    }
    final client = remote.address;

    final waiting = _unauthenticated[client] ?? 0;
    if (waiting >= maxUnauthenticated) {
      // Not read: a body still coming is cut with its connection, an answer would first wait for all of it
      response.persistentConnection = false;
      await request.listen(null).cancel();
      response.headers.set(HttpHeaders.retryAfterHeader, '1');
      return _fail(response, HttpStatus.tooManyRequests, 'Too many requests at once');
    }
    _unauthenticated[client] = waiting + 1;
    try {
      await _drain(request, response);
    } finally {
      final left = (_unauthenticated[client] ?? 1) - 1;
      if (left > 0) {
        _unauthenticated[client] = left;
      } else {
        _unauthenticated.remove(client);
      }
    }

    // Nothing awaits from here to the record of a failure: requests sent at once, each waiting for its body, would
    // otherwise all pass the check before the first failure counts
    final now = _clock();
    if (_isBlocked(client, now)) {
      response.headers.set(HttpHeaders.retryAfterHeader, '${blockDuration.inSeconds}');
      return _fail(response, HttpStatus.tooManyRequests, 'Too many failed attempts, try again in a minute');
    }
    final authentication = _authenticate(request.headers.value(HttpHeaders.authorizationHeader));
    if (authentication != _Authentication.accepted) {
      if (authentication == _Authentication.refused) {
        _recordFailure(client, now);
      }
      response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Basic realm="$realm", charset="UTF-8"');
      return _fail(response, HttpStatus.unauthorized, 'A user name and a password are needed');
    }
    _lastRequestAt = now;

    final method = request.method.toUpperCase();
    if (method == 'OPTIONS') {
      response.headers
        ..set('dav', '1')
        ..set(HttpHeaders.allowHeader, _allow)
        ..set('ms-author-via', 'DAV');
      response.contentLength = 0;
      return response.close();
    }
    if (method != 'PROPFIND' && method != 'GET' && method != 'HEAD') {
      response.headers.set(HttpHeaders.allowHeader, _allow);
      return _fail(response, HttpStatus.methodNotAllowed, 'This share is read only');
    }

    final path = _pathOf(request.uri);
    if (path == null) {
      return _fail(response, HttpStatus.notFound, 'Not found');
    }
    _activity.add(PhoneShareActivity(client: client, method: method, path: path, at: now));

    final node = await _tree.resolve(path);
    if (node == null) {
      return _fail(response, HttpStatus.notFound, 'Not found');
    }
    if (method == 'PROPFIND') {
      return _propfind(request, response, node);
    }
    if (node is! PhoneGalleryFile) {
      // No HTML index of a folder
      return _fail(response, HttpStatus.notFound, 'Not a file');
    }
    return _sendFile(request, response, node, withBody: method == 'GET');
  }

  /// The decoded path of [uri], "/" separated; null when it does not decode, names "." or "..", or has a segment
  /// with an encoded "/" or "\" (no name of the tree has one)
  static String? _pathOf(Uri uri) {
    final List<String> segments;
    try {
      segments = uri.pathSegments;
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
    final kept = [
      for (final segment in segments)
        if (segment.isNotEmpty) segment,
    ];
    if (kept.any((segment) => segment == '.' || segment == '..' || segment.contains('/') || segment.contains(r'\'))) {
      return null;
    }
    return '/${kept.join('/')}';
  }

  Future<void> _propfind(HttpRequest request, HttpResponse response, PhoneGalleryNode node) async {
    final depthHeader = request.headers.value('depth')?.trim().toLowerCase();
    final depth = depthHeader == '0' ? 0 : 1;
    if (depthHeader != '0' && depthHeader != '1') {
      // Infinity is refused by most servers; a listing of one level is what every client can use
      _log.fine('PROPFIND with depth ${depthHeader ?? 'missing'} on ${node.path}, answered as depth 1');
    }
    final nodes = [node, if (depth == 1 && node is PhoneGalleryFolder) ...node.children];
    final body = utf8.encode(_multistatus(nodes));
    response.statusCode = HttpStatus.multiStatus;
    response.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
    response.contentLength = body.length;
    response.add(body);
    await response.close();
  }

  String _multistatus(List<PhoneGalleryNode> nodes) {
    final xml = StringBuffer('<?xml version="1.0" encoding="utf-8"?>\n<D:multistatus xmlns:D="DAV:">\n');
    for (final node in nodes) {
      xml
        ..write('<D:response><D:href>')
        ..write(escapeXmlText(hrefOf(node)))
        ..write('</D:href><D:propstat><D:prop><D:displayname>')
        ..write(escapeXmlText(node.name))
        ..write('</D:displayname>');
      switch (node) {
        case PhoneGalleryFolder():
          xml.write('<D:resourcetype><D:collection/></D:resourcetype>');
        case PhoneGalleryFile(:final size):
          xml.write('<D:resourcetype/>');
          // Unknown until the file is opened: left out, so that a client reads it without ranges rather than empty
          if (size != null) {
            xml.write('<D:getcontentlength>$size</D:getcontentlength>');
          }
          xml.write('<D:getcontenttype>${escapeXmlText(_contentType(node))}</D:getcontenttype>');
      }
      final modified = node.modified;
      if (modified != null) {
        xml.write('<D:getlastmodified>${HttpDate.format(modified)}</D:getlastmodified>');
      }
      if (node is PhoneGalleryFile) {
        xml.write('<D:getetag>${escapeXmlText(_etagOf(node))}</D:getetag>');
      }
      xml.write('</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\n');
    }
    xml.write('</D:multistatus>\n');
    return xml.toString();
  }

  /// The href of [node]: its segments percent encoded, a folder ending with "/"
  static String hrefOf(PhoneGalleryNode node) {
    final segments = node.segments;
    if (segments.isEmpty) {
      return '/';
    }
    final encoded = segments.map((segment) => Uri(pathSegments: [segment]).path).join('/');
    return node is PhoneGalleryFolder ? '/$encoded/' : '/$encoded';
  }

  Future<void> _sendFile(
    HttpRequest request,
    HttpResponse response,
    PhoneGalleryFile node, {
    required bool withBody,
  }) async {
    final PhoneShareOpenedFile? opened;
    try {
      opened = await _open(node.assetId);
    } catch (error) {
      // The platform could not give the file (an iPhone photo only in iCloud): for the client it is not here
      _log.warning('Phone share: the file of ${node.path} is not available: $error');
      return _fail(response, HttpStatus.notFound, 'Not available on this phone');
    }
    if (opened == null) {
      return _fail(response, HttpStatus.notFound, 'Not found');
    }
    final file = File(opened.path);
    final int size;
    try {
      size = await file.length();
    } on FileSystemException catch (error) {
      _opened.remove(node.assetId);
      _log.warning('Phone share: the file of ${node.path} cannot be read: ${error.message}');
      return _fail(response, HttpStatus.notFound, 'Not found');
    }
    _tree.rememberSize(node.assetId, size);

    final lastModified = HttpDate.format(node.modified);
    final etag = _etagOf(node);
    var start = 0;
    var end = size;
    var partial = false;
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    // A range asked on the condition that the file did not change since the client saw it: the whole file otherwise
    final ifRange = request.headers.value(HttpHeaders.ifRangeHeader)?.trim();
    if (rangeHeader != null && (ifRange == null || ifRange == lastModified || ifRange == etag)) {
      final asked = parseSingleByteRange(rangeHeader, size);
      if (asked != null && asked.start >= asked.end) {
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        return _fail(response, HttpStatus.requestedRangeNotSatisfiable, 'Range not satisfiable');
      }
      if (asked != null) {
        start = asked.start;
        end = asked.end;
        partial = true;
      }
    }

    void writeHeaders() {
      final headers = response.headers;
      headers
        ..set(HttpHeaders.contentTypeHeader, _contentType(node))
        ..set(HttpHeaders.lastModifiedHeader, lastModified)
        ..set(HttpHeaders.etagHeader, etag)
        ..set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.contentLength = end - start;
      if (partial) {
        response.statusCode = HttpStatus.partialContent;
        headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${end - 1}/$size');
      }
    }

    if (!withBody || start >= end) {
      writeHeaders();
      return response.close();
    }

    if (!await _bodies.acquire(_bodyWaitTimeout)) {
      response.headers.set(HttpHeaders.retryAfterHeader, '${busyRetryAfter.inSeconds}');
      return _fail(response, HttpStatus.serviceUnavailable, 'The phone is sending other files, try again shortly');
    }
    final sent = Completer<void>();
    _sending.add(sent);
    RandomAccessFile? reader;
    try {
      // Opened before the headers go out, so that a file that cannot be read answers with a status
      reader = await file.open();
      writeHeaders();
      // Pushed back at each chunk the client takes (see _read): only a client that stopped reading is cut
      response.deadline = _stallTimeout;
      await response.addStream(_read(reader, start, end, response));
      await response.close();
    } on FileSystemException catch (error) {
      if (reader == null) {
        _opened.remove(node.assetId);
        _log.warning('Phone share: the file of ${node.path} cannot be opened: ${error.message}');
        return _fail(response, HttpStatus.notFound, 'Not found');
      }
      rethrow;
    } finally {
      try {
        await reader?.close();
      } catch (error) {
        _log.fine('Phone share: closing ${node.path}: $error');
      }
      _bodies.release();
      _sending.remove(sent);
      sent.complete();
    }
  }

  /// Bytes [start] to [end] (excluded) of [file], a chunk at a time; stops when the server stops or the client leaves.
  /// The next chunk is read once the socket took the previous one, so each one pushes back the deadline of [response].
  Stream<List<int>> _read(RandomAccessFile file, int start, int end, HttpResponse response) async* {
    await file.setPosition(start);
    var position = start;
    while (position < end && !_stopped) {
      final want = end - position < chunkSize ? end - position : chunkSize;
      final Uint8List chunk = await file.read(want);
      if (chunk.isEmpty) {
        // Shorter than its size said: the file changed while it was sent
        throw FileSystemException('The file ended early', file.path);
      }
      position += chunk.length;
      _lastRequestAt = _clock();
      response.deadline = _stallTimeout;
      yield chunk;
    }
  }

  /// Where the file of [assetId] is, asked once per [openedFileTtl] and shared by the requests meanwhile
  Future<PhoneShareOpenedFile?> _open(String assetId) {
    final now = _clock();
    final cached = _opened[assetId];
    if (cached != null && now.difference(cached.at) < openedFileTtl && !now.isBefore(cached.at)) {
      return cached.file;
    }
    _opened.removeWhere((_, entry) => now.difference(entry.at) >= openedFileTtl);
    final file = _files.openFile(assetId);
    _opened[assetId] = (at: now, file: file);
    unawaited(
      file.then<void>(
        (opened) {
          if (opened == null && identical(_opened[assetId]?.file, file)) {
            _opened.remove(assetId);
          }
        },
        onError: (Object _) {
          if (identical(_opened[assetId]?.file, file)) {
            _opened.remove(assetId);
          }
        },
      ),
    );
    return file;
  }

  /// Reads the request body away, up to [maxDrainedBody]; past it the connection closes after the answer
  static Future<void> _drain(HttpRequest request, HttpResponse response) async {
    final done = Completer<void>();
    var received = 0;
    late final StreamSubscription<List<int>> subscription;
    void finish() {
      if (!done.isCompleted) {
        done.complete();
      }
    }

    void giveUp() {
      response.persistentConnection = false;
      unawaited(subscription.cancel());
      finish();
    }

    subscription = request.listen(
      (chunk) {
        received += chunk.length;
        if (received > maxDrainedBody) {
          giveUp();
        }
      },
      onDone: finish,
      onError: (Object _) => giveUp(),
      cancelOnError: true,
    );
    await done.future.timeout(const Duration(seconds: 10), onTimeout: giveUp);
  }

  _Authentication _authenticate(String? header) {
    if (header == null || header.trim().isEmpty) {
      return _Authentication.missing;
    }
    final match = RegExp(r'^\s*basic\s+(\S+)\s*$', caseSensitive: false).firstMatch(header);
    if (match == null) {
      return _Authentication.refused;
    }
    final String credentials;
    try {
      credentials = utf8.decode(base64.decode(match.group(1)!));
    } on FormatException {
      return _Authentication.refused;
    }
    final colon = credentials.indexOf(':');
    if (colon < 0) {
      return _Authentication.refused;
    }
    // Both compared every time, so that the time does not tell which one was wrong
    final username = _sameDigest(_digestOf(credentials.substring(0, colon)), _usernameDigest);
    final password = _sameDigest(
      _digestOf(normalizePhoneSharePassword(credentials.substring(colon + 1))),
      _passwordDigest,
    );
    return username & password ? _Authentication.accepted : _Authentication.refused;
  }

  static Digest _digestOf(String text) => sha256.convert(utf8.encode(text));

  /// Compares in a time that does not depend on where the digests differ
  static bool _sameDigest(Digest a, Digest b) {
    final x = a.bytes;
    final y = b.bytes;
    if (x.length != y.length) {
      return false;
    }
    var difference = 0;
    for (var i = 0; i < x.length; i++) {
      difference |= x[i] ^ y[i];
    }
    return difference == 0;
  }

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

  void _recordFailure(String client, DateTime now) {
    // Forget the failures that are too old, of every client, so that the map does not grow
    _failures.removeWhere((_, times) {
      times.removeWhere((time) => now.difference(time) >= failureWindow);
      return times.isEmpty;
    });
    final times = _failures.putIfAbsent(client, () => [])..add(now);
    if (times.length >= maxFailures) {
      _log.warning('Phone share: $client gave wrong credentials $maxFailures times, blocked for a minute');
      _blockedUntil[client] = now.add(blockDuration);
      _failures.remove(client);
    }
  }

  static String _etagOf(PhoneGalleryFile node) {
    final id = node.assetId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    return '"$id-${node.modified.millisecondsSinceEpoch}"';
  }

  /// The type the platform gave, else the one of the extension; one a header cannot carry is replaced by the latter
  static String _contentType(PhoneGalleryFile node) {
    final given = node.mimeType.split(';').first.trim().toLowerCase();
    final guessed = NetworkEntry(
      sourceId: '',
      path: node.path,
      isDirectory: false,
      mimeType: _plainContentType.hasMatch(given) ? given : null,
    ).guessedMimeType;
    return guessed;
  }

  static Future<void> _fail(HttpResponse response, int status, String message) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.text;
    final body = utf8.encode(message);
    response.contentLength = body.length;
    response.add(body);
    await response.close();
  }
}

final _plainContentType = RegExp(r'^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+_-]*$');

enum _Authentication { accepted, missing, refused }

/// The listening sockets of a share with served addresses, as one for HttpServer.listenOn: one on the loopback, which
/// holds the port while the phone has no network, and one per served address on that port, opened and closed as the
/// addresses come and go. A single socket on every interface would also take the clients that reach the phone on its
/// mobile data or VPN address, and a connection it accepts does not tell which address it was made to.
class _ServedSockets extends Stream<Socket> implements ServerSocket {
  _ServedSockets._(this._loopback, this._servedAddresses) {
    _loopback.listen(_connections.add, onError: _onListenError);
    _timer = Timer.periodic(refreshInterval, (_) => unawaited(refresh()));
  }

  /// How often the served addresses are checked: a hotspot comes up, or an iPhone makes its hotspot interface for its
  /// first client, without any change of connectivity the app hears of
  static const refreshInterval = Duration(seconds: 5);

  /// Listens on [port] (any free one with 0) on the loopback and on every served address of now; [strict], an address
  /// that cannot have the port fails it instead of being left out
  static Future<_ServedSockets> bind(
    int port,
    Future<List<String>> Function() servedAddresses, {
    required bool strict,
  }) async {
    final sockets = _ServedSockets._(await ServerSocket.bind(InternetAddress.loopbackIPv4, port), servedAddresses);
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
      _log.fine('Phone share: the addresses of the phone are not known: $error');
      return;
    }
    if (_closed) {
      return;
    }
    for (final gone in [..._listeners.keys.where((address) => !wanted.contains(address))]) {
      // The connections it accepted stay open: a client of a network that went away times out on its own
      _log.info('Phone share: no more listening on $gone');
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
        _log.warning('Phone share: cannot listen on $address port $port: $error');
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

  void _onListenError(Object error) => _log.fine('Phone share: a listening socket failed: $error');

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

/// At most [max] bodies at once; the others wait their turn, in order
class _BodySlots {
  _BodySlots(this.max);

  final int max;
  int _used = 0;
  final Queue<Completer<bool>> _waiting = Queue();

  /// Whether a slot came within [timeout]; when not, the request left the queue and holds no slot
  Future<bool> acquire(Duration timeout) {
    if (_used < max) {
      _used++;
      return Future.value(true);
    }
    final turn = Completer<bool>();
    _waiting.add(turn);
    // Only a turn still in the queue times out: one that left it got its slot, or the server stopped
    final timer = Timer(timeout, () {
      if (_waiting.remove(turn)) {
        turn.complete(false);
      }
    });
    return turn.future.whenComplete(timer.cancel);
  }

  void release() {
    if (_waiting.isNotEmpty) {
      // The slot goes to the next one as it is
      _waiting.removeFirst().complete(true);
    } else if (_used > 0) {
      _used--;
    }
  }

  void cancelWaiting(Object error) {
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().completeError(error);
    }
  }
}
