// The local media bridge: a small HTTP server on 127.0.0.1 that serves the files of the registered network shares to
// the players of the app, so that the image widgets, Media3, AVPlayer, the Spatial player and the Quest viewer stream
// straight from the share with ordinary http URLs and Range requests.
//
// Nothing is copied to the device: a body is read from the share in chunks while the client takes them, one chunk
// ahead at most, and the reading stops as soon as the client goes away. Only the stat results are kept, for a minute,
// so that a HEAD followed by a GET, or several players opening the same file, do not ask the share twice.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:logging/logging.dart';

final _log = Logger('MediaBridge');

/// Bytes of a file, [start] included, [end] excluded
typedef _ByteRange = ({int start, int end});

/// The [MediaBridge] of the app: URLs are `http://127.0.0.1:<port>/<token>/<sourceId>/<path>`, the token random per
/// bridge so that the other apps of the device cannot read the shares through it.
class LocalMediaBridge implements MediaBridge {
  LocalMediaBridge({
    this.chunkSize = defaultChunkSize,
    Duration statCacheTtl = const Duration(seconds: 60),
    int statCacheSize = 512,
    DateTime Function()? clock,
  }) : _token = _randomToken(),
       _stats = _StatCache(ttl: statCacheTtl, maxEntries: statCacheSize, clock: clock ?? DateTime.now);

  static const defaultChunkSize = 512 * 1024;

  /// Bytes asked to the share per read
  final int chunkSize;

  final String _token;
  final _StatCache _stats;
  final Map<String, NetworkFileSystem> _fileSystems = {};
  HttpServer? _server;
  Future<void>? _starting;

  /// The port of the last server, tried first when the bridge starts again so that the URLs already given stay valid
  int? _lastPort;

  /// The port the bridge listens on, null while it does not run
  int? get port => _server?.port;

  /// Whether the bridge listens
  bool get isRunning => _server != null;

  @override
  Future<void> start() {
    if (_server != null) {
      return Future.value();
    }
    return _starting ??= _bind().whenComplete(() => _starting = null);
  }

  Future<void> _bind() async {
    HttpServer? bound;
    final lastPort = _lastPort;
    if (lastPort != null) {
      try {
        bound = await HttpServer.bind(InternetAddress.loopbackIPv4, lastPort);
      } on SocketException catch (error) {
        _log.fine('Port $lastPort is taken, the media bridge moves to another one: $error');
      }
    }
    final server = bound ?? await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.autoCompress = false;
    _server = server;
    _lastPort = server.port;
    server.listen(
      (request) => unawaited(_serve(request)),
      onError: (Object error, StackTrace stackTrace) =>
          _log.warning('The media bridge server failed', error, stackTrace),
      onDone: () {
        // Closed by stop, or by the system (a suspended iOS app may lose its sockets): the next start binds again
        if (identical(_server, server)) {
          _server = null;
        }
      },
    );
    _log.info('Media bridge listening on 127.0.0.1:${server.port}');
  }

  @override
  void register(NetworkFileSystem fileSystem) {
    final sourceId = fileSystem.source.id;
    _fileSystems[sourceId] = fileSystem;
    _stats.removeSource(sourceId);
  }

  @override
  void unregister(String sourceId) {
    _fileSystems.remove(sourceId);
    _stats.removeSource(sourceId);
  }

  /// Throws a [StateError] when the bridge was never started. When it stopped since, the URL is on its last port,
  /// which the next [start] tries to listen on again.
  @override
  Uri urlFor(String sourceId, String path) {
    final port = _server?.port ?? _lastPort;
    if (port == null) {
      throw StateError('The media bridge is not started');
    }
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: port,
      pathSegments: [_token, sourceId, ...path.split('/').where((segment) => segment.isNotEmpty)],
    );
  }

  @override
  Future<void> stop() async {
    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } on SocketException catch (error) {
        _log.fine('The media bridge did not start: $error');
      }
    }
    final server = _server;
    _server = null;
    _stats.clear();
    await server?.close(force: true);
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    // A client that goes away makes the response fail: nothing the bridge has to report
    unawaited(response.done.then<void>((_) {}, onError: (Object _) {}));
    try {
      await _answer(request, response);
    } catch (error) {
      _log.fine('A media bridge response ended early: $error');
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
    final target = _target(request.uri);
    if (target == null) {
      return _fail(response, HttpStatus.notFound, 'Not found');
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      return _fail(response, HttpStatus.methodNotAllowed, 'Only GET and HEAD are served');
    }

    final (fileSystem, path) = target;
    final NetworkEntry entry;
    try {
      entry = await _stats.get(fileSystem, path);
    } catch (error, stackTrace) {
      return _failForShare(response, fileSystem, path, error, stackTrace);
    }
    if (entry.isDirectory) {
      return _fail(response, HttpStatus.notFound, 'Not a file');
    }

    final size = entry.size;
    final modified = entry.modified;
    final lastModified = modified == null ? null : HttpDate.format(modified);
    var start = 0;
    var end = size;
    var partial = false;
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    // A range asked on the condition that the file did not change since the client saw it: the whole file otherwise
    final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
    if (size != null && rangeHeader != null && (ifRange == null || ifRange == lastModified)) {
      final asked = _parseRange(rangeHeader, size);
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

    // The first chunk is read before the headers go out, so that a share that cannot read answers with a status
    Uint8List? first;
    if (request.method == 'GET' && (end == null || start < end)) {
      try {
        first = await _readChunk(fileSystem, path, start, end);
      } catch (error, stackTrace) {
        return _failForShare(response, fileSystem, path, error, stackTrace);
      }
      if (first.isEmpty && end != null) {
        // Shorter than the stat said: the file changed on the share since, the next request asks again
        _stats.remove(fileSystem.source.id, path);
        return _fail(response, HttpStatus.internalServerError, 'The file changed on the share');
      }
    }

    final headers = response.headers;
    headers.set(HttpHeaders.contentTypeHeader, _contentType(entry));
    if (lastModified != null) {
      headers.set(HttpHeaders.lastModifiedHeader, lastModified);
    }
    if (end == null) {
      // A share that does not tell the size: the whole file, read until it ends, without ranges
      headers.set(HttpHeaders.acceptRangesHeader, 'none');
    } else {
      headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.contentLength = end - start;
      if (partial) {
        response.statusCode = HttpStatus.partialContent;
        headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${end - 1}/$size');
      }
    }
    if (first != null) {
      await response.addStream(_read(fileSystem, path, first, start, end));
    }
    await response.close();
  }

  /// The file system and the path a request URL names, null when the token or the source is wrong
  (NetworkFileSystem, String)? _target(Uri uri) {
    final List<String> segments;
    try {
      segments = uri.pathSegments;
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
    if (segments.length < 3 || !_isToken(segments[0])) {
      return null;
    }
    // Dot segments sent encoded, so that the URL parser kept them: no file has such a name
    if (segments.skip(2).any((segment) => segment == '.' || segment == '..')) {
      return null;
    }
    final fileSystem = _fileSystems[segments[1]];
    if (fileSystem == null) {
      return null;
    }
    return (fileSystem, '/${segments.skip(2).join('/')}');
  }

  /// Compares in a time that does not depend on where the strings differ
  bool _isToken(String candidate) {
    if (candidate.length != _token.length) {
      return false;
    }
    var difference = 0;
    for (var i = 0; i < candidate.length; i++) {
      difference |= candidate.codeUnitAt(i) ^ _token.codeUnitAt(i);
    }
    return difference == 0;
  }

  /// At most [chunkSize] bytes of [path] from [offset], not past [end] (the end of the file when null)
  Future<Uint8List> _readChunk(NetworkFileSystem fileSystem, String path, int offset, int? end) async {
    final length = end == null ? chunkSize : min(chunkSize, end - offset);
    final chunk = await fileSystem.readRange(path, offset, length);
    return chunk.length > length ? Uint8List.sublistView(chunk, 0, length) : chunk;
  }

  /// The body: [first], read at [start], then the bytes up to [end] (to the end of the file when null), a chunk at a
  /// time. The next chunk is read while the client receives the current one; the client pausing pauses the reading,
  /// and once it leaves no read is started.
  Stream<List<int>> _read(NetworkFileSystem fileSystem, String path, Uint8List first, int start, int? end) async* {
    var chunk = first;
    var offset = start;
    while (chunk.isNotEmpty) {
      offset += chunk.length;
      yield chunk;
      // Without a known size, a short read is the end of the file
      final done = end == null ? chunk.length < chunkSize : offset >= end;
      if (done) {
        return;
      }
      chunk = await _readChunk(fileSystem, path, offset, end);
    }
    if (end != null) {
      // The file ended before its announced size: the client sees a short body, the next request a fresh stat
      _stats.remove(fileSystem.source.id, path);
    }
  }

  /// Answers a failure of the share, before anything of the file was sent
  Future<void> _failForShare(
    HttpResponse response,
    NetworkFileSystem fileSystem,
    String path,
    Object error,
    StackTrace stackTrace,
  ) {
    // The file may have changed or gone: the next request asks again
    _stats.remove(fileSystem.source.id, path);
    if (error is NetworkFileSystemException) {
      if (error.isNotFound) {
        return _fail(response, HttpStatus.notFound, 'Not found');
      }
      if (error.isAuthentication) {
        return _fail(response, HttpStatus.badGateway, 'The share refused the credentials');
      }
      _log.warning('Could not read $path on ${fileSystem.source.name}: ${error.message}');
    } else {
      _log.warning('Could not read $path on ${fileSystem.source.name}', error, stackTrace);
    }
    return _fail(response, HttpStatus.internalServerError, 'The share could not be read');
  }

  static Future<void> _fail(HttpResponse response, int status, String message) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.text;
    response.write(message);
    await response.close();
  }
}

final _plainContentType = RegExp(r'^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+_-]*$');

/// The content type of [entry] for the header, without parameters. One from the server that a header cannot carry is
/// replaced by the type of the extension.
String _contentType(NetworkEntry entry) {
  final given = entry.guessedMimeType.split(';').first.trim().toLowerCase();
  if (_plainContentType.hasMatch(given)) {
    return given;
  }
  return NetworkEntry(sourceId: entry.sourceId, path: entry.path, isDirectory: false).guessedMimeType;
}

/// What a Range header asks of a file of [size] bytes. Null to ignore it and send the whole file: another unit,
/// several ranges, or a header that does not parse. An empty range when no byte of it is in the file.
_ByteRange? _parseRange(String header, int size) {
  final match = RegExp(r'^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*$', caseSensitive: false).firstMatch(header);
  if (match == null) {
    return null;
  }
  final first = match.group(1)!;
  final last = match.group(2)!;
  const unsatisfiable = (start: 0, end: 0);

  if (first.isEmpty) {
    // The last bytes of the file: bytes=-n
    if (last.isEmpty) {
      return null;
    }
    // Too many digits for an int: more bytes than any file has
    final suffix = int.tryParse(last) ?? size;
    if (suffix == 0 || size == 0) {
      return unsatisfiable;
    }
    return (start: max(0, size - suffix), end: size);
  }

  final start = int.tryParse(first);
  if (start == null || start >= size) {
    return unsatisfiable;
  }
  if (last.isEmpty) {
    return (start: start, end: size);
  }
  final lastByte = int.tryParse(last);
  if (lastByte != null && lastByte < start) {
    return null;
  }
  return (start: start, end: lastByte == null ? size : min(lastByte + 1, size));
}

String _randomToken() {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final random = Random.secure();
  return String.fromCharCodes(List.generate(32, (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length))));
}

class _CachedStat {
  _CachedStat(this.at, this.entry);

  final DateTime at;
  final Future<NetworkEntry> entry;
}

/// The stat results of the last files served, least recently used dropped first. A stat in progress is shared by the
/// requests that need it; a failed one is not kept.
class _StatCache {
  _StatCache({required this.ttl, required this.maxEntries, required this.clock});

  final Duration ttl;
  final int maxEntries;
  final DateTime Function() clock;
  // In the order of use, the least recently used first (a map literal keeps the insertion order)
  final _entries = <(String, String), _CachedStat>{};

  Future<NetworkEntry> get(NetworkFileSystem fileSystem, String path) {
    final key = (fileSystem.source.id, path);
    final now = clock();
    final cached = _entries.remove(key);
    if (cached != null && now.difference(cached.at) < ttl) {
      // Back at the end, the most recently used
      _entries[key] = cached;
      return cached.entry;
    }

    final entry = Future.sync(() => fileSystem.stat(path));
    final record = _CachedStat(now, entry);
    _entries[key] = record;
    if (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    unawaited(
      entry.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_entries[key], record)) {
            _entries.remove(key);
          }
        },
      ),
    );
    return entry;
  }

  void remove(String sourceId, String path) => _entries.remove((sourceId, path));

  void removeSource(String sourceId) => _entries.removeWhere((key, _) => key.$1 == sourceId);

  void clear() => _entries.clear();
}
