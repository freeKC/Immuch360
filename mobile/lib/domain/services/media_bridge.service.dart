// The local media bridge: a small HTTP server on 127.0.0.1 that serves the files of the registered network shares to
// the players of the app, so that the image widgets, Media3, AVPlayer, the Spatial player and the Quest viewer stream
// straight from the share with ordinary http URLs and Range requests.
//
// Nothing is copied to the device: a body is read from the share in chunks of 1 to 4 MiB, up to 16 MiB ahead of the
// client so that a share that answers in bursts (SMB on a Freebox Server) does not starve the player, and the reading
// stops as soon as the client goes away or asks for another part of the file. What is read ahead is bounded for the
// whole bridge. Only the stat results are kept, for a minute, so that a HEAD followed by a GET, or several players
// opening the same file, do not ask the share twice.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/http_byte_range.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:logging/logging.dart';

final _log = Logger('MediaBridge');

/// The [MediaBridge] of the app: URLs are `http://127.0.0.1:<port>/<token>/<sourceId>/<path>`, the token random per
/// bridge so that the other apps of the device cannot read the shares through it.
class LocalMediaBridge implements MediaBridge {
  LocalMediaBridge({
    this.minChunkSize = defaultMinChunkSize,
    this.maxChunkSize = defaultMaxChunkSize,
    this.readAheadSize = defaultReadAheadSize,
    int maxBufferedSize = defaultMaxBufferedSize,
    Duration statCacheTtl = const Duration(seconds: 60),
    int statCacheSize = 512,
    DateTime Function()? clock,
  }) : assert(minChunkSize > 0 && maxChunkSize >= minChunkSize),
       _token = _randomToken(),
       _budget = _ReadAheadBudget(maxBufferedSize),
       _stats = _StatCache(ttl: statCacheTtl, maxEntries: statCacheSize, clock: clock ?? DateTime.now);

  static const defaultMinChunkSize = 1024 * 1024;
  static const defaultMaxChunkSize = 4 * 1024 * 1024;
  static const defaultReadAheadSize = 16 * 1024 * 1024;
  static const defaultMaxBufferedSize = 32 * 1024 * 1024;

  /// Bytes asked to the share by the first read of a body; each next read asks twice as many, up to [maxChunkSize]
  final int minChunkSize;

  /// Most bytes asked to the share per read
  final int maxChunkSize;

  /// Most bytes of a file read ahead of its client
  final int readAheadSize;

  /// The bytes read ahead and not yet taken by the clients, all files together
  int get bufferedSize => _budget.used;

  final _ReadAheadBudget _budget;

  /// The bodies being sent
  final Set<_BodyReader> _bodies = {};

  /// The open bodies that stream each file, by source id and path, oldest first: only the latest one reads ahead, and
  /// when it closes the one before it reads ahead again
  final Map<(String, String), List<_BodyReader>> _streams = {};

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
    for (final reader in _bodies.where((reader) => reader.sourceId == sourceId).toList()) {
      reader.stopReadingAhead();
    }
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
    for (final reader in _bodies.toList()) {
      reader.stopReadingAhead();
    }
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

    // The first chunk is read before the headers go out, so that a share that cannot read answers with a status
    _BodyReader? reader;
    Uint8List? first;
    if (request.method == 'GET' && (end == null || start < end)) {
      final body = reader = _BodyReader(this, fileSystem, path, start, end);
      // A client that goes away stops the reading at once, rather than at the next chunk sent
      unawaited(response.done.then<void>((_) => body.close(), onError: (Object _) => body.close()));
      try {
        first = await body.next();
      } catch (error, stackTrace) {
        body.close();
        return _failForShare(response, fileSystem, path, error, stackTrace);
      }
      if (first.isEmpty && end != null) {
        body.close();
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
    if (reader != null && first != null) {
      await response.addStream(_read(reader, first));
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

  /// The body: [first], then the next chunks of [reader] up to its end, read ahead while the client receives them.
  /// The client pausing pauses the sending (the reading ahead stops at [readAheadSize]), and once it leaves no read is
  /// started.
  Stream<List<int>> _read(_BodyReader reader, Uint8List first) async* {
    try {
      var chunk = first;
      while (chunk.isNotEmpty) {
        yield chunk;
        if (reader.isComplete) {
          return;
        }
        chunk = await reader.next();
      }
      if (reader.end != null) {
        // The file ended before its announced size: the client sees a short body, the next request a fresh stat
        _stats.remove(reader.sourceId, reader.path);
      }
    } finally {
      reader.close();
    }
  }

  void _opened(_BodyReader reader) {
    _bodies.add(reader);
    if (!reader.streams) {
      return;
    }
    // [reader] reads ahead in its file, instead of the stream that did: a player asking for another part of a file
    // leaves the previous one (or reads it slowly, on demand)
    final streams = _streams.putIfAbsent((reader.sourceId, reader.path), () => []);
    streams.lastOrNull?._pauseReadingAhead();
    streams.add(reader);
  }

  void _closed(_BodyReader reader) {
    _bodies.remove(reader);
    final key = (reader.sourceId, reader.path);
    final streams = _streams[key];
    if (streams == null) {
      return;
    }
    final wasLatest = identical(streams.lastOrNull, reader);
    if (!streams.remove(reader)) {
      return;
    }
    if (streams.isEmpty) {
      _streams.remove(key);
    } else if (wasLatest) {
      // The client still takes the previous stream: it reads ahead again
      streams.last._resumeReadingAhead();
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

/// The bytes read ahead by all the bodies of a bridge, not yet taken by their clients
class _ReadAheadBudget {
  _ReadAheadBudget(this.capacity);

  final int capacity;
  int used = 0;

  /// The bodies that wait for room to read ahead, in the order they asked
  final _waiting = <_BodyReader>{};

  /// Takes [bytes] when there is room for them
  bool tryTake(int bytes) {
    if (used + bytes > capacity) {
      return false;
    }
    used += bytes;
    return true;
  }

  /// Takes [bytes] whatever the room: a read the client waits for
  void take(int bytes) => used += bytes;

  void giveBack(int bytes) {
    if (bytes <= 0) {
      return;
    }
    used -= bytes;
    if (_waiting.isEmpty) {
      return;
    }
    final waiting = _waiting.toList();
    _waiting.clear();
    for (final reader in waiting) {
      reader._fill();
    }
  }

  void wait(_BodyReader reader) => _waiting.add(reader);

  void forget(_BodyReader reader) => _waiting.remove(reader);
}

/// The bytes of a body, [start] included, [end] excluded (to the end of the file when null), read from the share in
/// chunks of [LocalMediaBridge.minChunkSize] growing to [LocalMediaBridge.maxChunkSize] bytes. A body of more than
/// one chunk keeps reading ahead of its client, one read at a time, up to [LocalMediaBridge.readAheadSize] bytes and
/// within the budget of the bridge; the chunks wait in a ring until the client takes them.
///
/// A body to the end of the file, or longer than [LocalMediaBridge.readAheadSize], [streams]: it takes the reading
/// ahead from the other streams of its file, and gives it back to the latest one still open when it closes. A shorter
/// body (a probe of the metadata, a look at a box) reads ahead its own few chunks and leaves the streams alone.
class _BodyReader {
  _BodyReader(this._bridge, this._fileSystem, this.path, int start, this.end)
    : _position = start,
      _next = start,
      _chunkSize = _bridge.minChunkSize,
      _readsAhead = end == null || end - start > _bridge.minChunkSize,
      streams = end == null || end - start > _bridge.readAheadSize {
    _bridge._opened(this);
  }

  final LocalMediaBridge _bridge;
  final NetworkFileSystem _fileSystem;
  final String path;
  final int? end;

  String get sourceId => _fileSystem.source.id;

  /// The next byte for the client
  int _position;

  /// The next byte to ask the share for
  int _next;

  /// Bytes asked by the next read
  int _chunkSize;

  final _ring = Queue<Uint8List>();
  int _buffered = 0;

  /// The read under way, and the bytes it holds of the budget
  Future<void>? _reading;

  /// Changed when what was read ahead is dropped: a read under way then is forgotten
  int _generation = 0;
  Object? _error;
  StackTrace? _errorStackTrace;

  /// The share gave fewer bytes than asked: nothing to read past [_next]
  bool _ended = false;
  bool _readsAhead;

  /// Whether the body streams its file, see the class
  final bool streams;

  /// The source left, or the bridge stopped: no reading ahead any more
  bool _stopped = false;
  bool _closed = false;

  /// Whether the client had all the bytes of the body
  bool get isComplete {
    final end = this.end;
    return end != null && _position >= end;
  }

  bool get _readAll {
    final end = this.end;
    return _ended || (end != null && _next >= end);
  }

  /// The next chunk for the client, empty at the end of the body. Throws what the share threw.
  Future<Uint8List> next() async {
    while (true) {
      if (_ring.isNotEmpty) {
        final chunk = _ring.removeFirst();
        _buffered -= chunk.length;
        _position += chunk.length;
        _bridge._budget.giveBack(chunk.length);
        _fill();
        return chunk;
      }
      final error = _error;
      if (error != null) {
        _error = null;
        Error.throwWithStackTrace(error, _errorStackTrace ?? StackTrace.empty);
      }
      final reading = _reading;
      if (reading != null) {
        await reading;
        continue;
      }
      if (_closed || _readAll) {
        return Uint8List(0);
      }
      // The client waits: read whatever the budget
      final size = _sizeNow;
      _bridge._budget.take(size);
      _startRead(size);
    }
  }

  /// Reads ahead when there is room
  void _fill() {
    if (!_readsAhead || _closed || _reading != null || _error != null || _readAll) {
      return;
    }
    final size = _sizeNow;
    if (_buffered + size > _bridge.readAheadSize) {
      return;
    }
    if (!_bridge._budget.tryTake(size)) {
      _bridge._budget.wait(this);
      return;
    }
    _startRead(size);
  }

  /// The size of the next read: the chunk size, not past the end
  int get _sizeNow {
    final end = this.end;
    return end == null ? _chunkSize : min(_chunkSize, end - _next);
  }

  /// Reads [size] bytes at [_next], which the budget holds already
  void _startRead(int size) {
    final offset = _next;
    final generation = _generation;
    _next += size;
    _chunkSize = min(_chunkSize * 2, _bridge.maxChunkSize);
    _reading = () async {
      try {
        var bytes = await _fileSystem.readRange(path, offset, size);
        if (bytes.length > size) {
          bytes = Uint8List.sublistView(bytes, 0, size);
        }
        if (_closed || generation != _generation) {
          _bridge._budget.giveBack(size);
          return;
        }
        _bridge._budget.giveBack(size - bytes.length);
        if (bytes.length < size) {
          // The end of the file, or a file shorter than its stat said
          _ended = true;
          _next = offset + bytes.length;
        }
        if (bytes.isNotEmpty) {
          _ring.add(bytes);
          _buffered += bytes.length;
        }
      } catch (error, stackTrace) {
        _bridge._budget.giveBack(size);
        if (!_closed && generation == _generation) {
          _error = error;
          _errorStackTrace = stackTrace;
        }
      } finally {
        if (generation == _generation) {
          _reading = null;
        }
      }
      _fill();
    }();
  }

  /// Drops what was read ahead and reads on demand from now on: the source left, or the bridge stopped
  void stopReadingAhead() {
    _stopped = true;
    _pauseReadingAhead();
  }

  /// Drops what was read ahead and reads on demand until [_resumeReadingAhead]: the client asked for another part of
  /// the file
  void _pauseReadingAhead() {
    _readsAhead = false;
    _drop();
  }

  /// Reads ahead again: the stream that took the reading ahead closed
  void _resumeReadingAhead() {
    if (_closed || _stopped) {
      return;
    }
    _readsAhead = true;
    _fill();
  }

  /// The client is done or gone: nothing more is read
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _readsAhead = false;
    _drop();
    _bridge._closed(this);
  }

  void _drop() {
    _bridge._budget.forget(this);
    if (_ring.isEmpty) {
      // A read under way starts where the client is: the client waits for it
      return;
    }
    _ring.clear();
    _bridge._budget.giveBack(_buffered);
    _buffered = 0;
    // A read under way is past what was dropped: forgotten, the next one starts where the client is
    _generation++;
    _reading = null;
    _next = _position;
    _ended = false;
  }
}
