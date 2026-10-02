// A share reached over SMB 2 or 3 (Samba on a NAS or a Linux computer, Windows file sharing) through dart_smb2, which
// binds libsmb2. Each file system keeps up to two connections, each held by a worker isolate of its own so that the
// calls never block the interface: one for listing, stat and thumbnails, opened with the file system, and one kept for
// the video being streamed, opened the first time one is, so that the browser and the player never wait for each
// other. When a connection drops or the server ends the session, the call opens it again once and is tried again. A
// read asks the server for the bytes wanted only, a file is never transferred whole; a file read stays open for the
// next reads of it.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:logging/logging.dart';

final _log = Logger('SmbFileSystem');

/// Opens the connection of an [SmbFileSystem]: [server] is "host:port" (IPv6 addresses in brackets), [share] the bare
/// share name. The default one opens an [Smb2Pool] of one worker; tests give one of their own.
typedef SmbConnector =
    Future<Smb2Pool> Function({
      required String server,
      required String share,
      String? user,
      String? password,
      String? domain,
      required int timeoutSeconds,
    });

/// Lists the shares of [server] ("host:port") over its IPC$ share. The default one runs dart_smb2 in an isolate of its
/// own; tests give one of their own.
typedef SmbShareEnumerator =
    Future<List<Smb2ShareInfo>> Function({
      required String server,
      String? user,
      String? password,
      String? domain,
      required int timeoutSeconds,
    });

/// A [NetworkFileSystem] over SMB, see [open]
class SmbFileSystem implements NetworkFileSystem {
  SmbFileSystem._(this.source, Smb2Pool pool, this._serverLabel, this._share, this._connectAgain)
    : _general = _Link('general')..pool = pool;

  /// Connects to the share of [source] and lists its start folder (the root path of the source) once. Throws a
  /// [NetworkFileSystemException] when the server cannot be reached, refuses the credentials, has no such share or
  /// no such folder.
  ///
  /// A user name written "DOMAIN\user" logs on to that domain. Without a user name the logon is anonymous (guest); a
  /// user name with an empty password logs on with that empty password (a Freebox Server wants "freebox" and nothing).
  static Future<SmbFileSystem> open(
    NetworkSource source,
    String? password, {
    @visibleForTesting SmbConnector connect = _connectPool,
    int timeoutSeconds = defaultTimeoutSeconds,
  }) async {
    if (source.type != NetworkSourceType.smb) {
      throw ArgumentError.value(source.type, 'source.type', 'Not an SMB source');
    }
    final (host, typedPort) = _splitHost(source.host);
    if (host.isEmpty) {
      throw const NetworkFileSystemException('Enter the name or the address of the server');
    }
    final share = shareNameOf(source.share);
    if (share.isEmpty) {
      throw const NetworkFileSystemException('Enter the name of the shared folder');
    }
    final server = serverAddressOf(source.host, source.port);
    final port = source.port ?? typedPort ?? defaultPort;
    final serverLabel = port == defaultPort ? host : '$host:$port';
    final (user, domain) = splitUserName(source.username);

    // The pool waits for its worker to report the connection; a worker that dies before (the native library failed to
    // load) never reports, hence a limit of our own above the timeout of libsmb2
    final limit = Duration(seconds: timeoutSeconds) + connectGrace;
    Future<Smb2Pool> connectOnce() async {
      final pending = _serialized(
        limit,
        () => connect(
          server: server,
          share: share,
          user: user,
          password: logonPassword(user, password),
          domain: domain,
          timeoutSeconds: timeoutSeconds,
        ),
      );
      try {
        return await pending.timeout(limit);
      } on TimeoutException {
        unawaited(pending.then<void>((pool) => pool.disconnect(), onError: (Object _) {}));
        throw NetworkFileSystemException('The server at $serverLabel did not answer in time');
      } on NetworkFileSystemException {
        rethrow;
      } on Smb2Exception catch (error) {
        throw describeError(error, server: serverLabel, share: share, connecting: true);
      } catch (error) {
        throw NetworkFileSystemException('Cannot connect to $serverLabel: $error');
      }
    }

    final fileSystem = SmbFileSystem._(source, await connectOnce(), serverLabel, share, connectOnce);
    try {
      await fileSystem.list(source.rootPath);
    } catch (_) {
      await fileSystem.close();
      rethrow;
    }
    return fileSystem;
  }

  /// The names of the shares of the server of [source] (its share is not used), sorted without case, without the
  /// hidden and administrative ones (names ending with "$", such as IPC$ or C$) nor the printers. dart_smb2 connects to
  /// the IPC$ share of the server and asks its share list through SRVSVC. Throws a [NetworkFileSystemException] like
  /// [open].
  static Future<List<String>> listShares(
    NetworkSource source,
    String? password, {
    @visibleForTesting SmbShareEnumerator connect = _enumerateShares,
    int timeoutSeconds = defaultTimeoutSeconds,
  }) async {
    if (source.type != NetworkSourceType.smb) {
      throw ArgumentError.value(source.type, 'source.type', 'Not an SMB source');
    }
    final (host, typedPort) = _splitHost(source.host);
    if (host.isEmpty) {
      throw const NetworkFileSystemException('Enter the name or the address of the server');
    }
    final server = serverAddressOf(source.host, source.port);
    final port = source.port ?? typedPort ?? defaultPort;
    final serverLabel = port == defaultPort ? host : '$host:$port';
    final (user, domain) = splitUserName(source.username);

    final limit = Duration(seconds: timeoutSeconds) + connectGrace;
    // Its own libsmb2 context, opened and closed like a connection: one at a time with the others
    final pending = _serialized(
      limit,
      () => connect(
        server: server,
        user: user,
        password: logonPassword(user, password),
        domain: domain,
        timeoutSeconds: timeoutSeconds,
      ),
    );
    final List<Smb2ShareInfo> shares;
    try {
      shares = await pending.timeout(limit);
    } on TimeoutException {
      throw NetworkFileSystemException('The server at $serverLabel did not answer in time');
    } on NetworkFileSystemException {
      rethrow;
    } on Smb2Exception catch (error) {
      throw describeError(error, server: serverLabel, share: r'IPC$', connecting: true);
    } catch (error) {
      throw NetworkFileSystemException('Cannot connect to $serverLabel: $error');
    }
    return shareNamesOf(shares);
  }

  /// The names [listShares] keeps: disk shares that are neither hidden nor administrative, sorted without case
  @visibleForTesting
  static List<String> shareNamesOf(Iterable<Smb2ShareInfo> shares) {
    final names = {
      for (final share in shares)
        if (share.name.trim().isNotEmpty && share.isDisk && !share.isHidden && !share.name.endsWith(r'$'))
          share.name.trim(),
    }.toList();
    names.sort((a, b) {
      final byName = a.toLowerCase().compareTo(b.toLowerCase());
      return byName != 0 ? byName : a.compareTo(b);
    });
    return names;
  }

  @override
  final NetworkSource source;

  /// The connection for listing, stat, thumbnails and any read that is not the file being streamed
  final _Link _general;

  /// The connection kept for the file being streamed (see [readRange]), opened the first time a file is streamed
  final _Link _stream = _Link('stream');

  bool _closed = false;
  final String _serverLabel;
  final String _share;

  /// Opens a new connection like the first one: the stream connection, or one that replaces a connection whose session
  /// the server ended
  final Future<Smb2Pool> Function() _connectAgain;

  /// When the stream connection last failed to open; the reads stay on the general connection for a while
  DateTime? _streamFailedAt;

  /// The files kept open, the least recently used first (a map literal keeps the insertion order)
  final Map<String, _OpenFile> _openFiles = {};

  /// The file that has the stream connection, null when it is free
  String? _streamPath;

  int _fileOpens = 0;

  static const defaultPort = 445;

  /// How long libsmb2 waits for the server before giving up on a call (and on the connection)
  static const defaultTimeoutSeconds = 20;

  /// Added to [defaultTimeoutSeconds] (or the timeout given to [open]) for the wait of a new connection
  @visibleForTesting
  static Duration connectGrace = const Duration(seconds: 15);

  /// Largest read asked of the worker at once; a larger window is read in several parts on one open file
  static const maxReadChunk = 4 * 1024 * 1024;

  /// Most files kept open per share
  static const maxOpenFiles = 4;

  /// A file kept open is closed once it was not read for this long
  @visibleForTesting
  static Duration openFileIdle = const Duration(seconds: 10);

  /// The file that has the stream connection keeps it while it was read less than this long ago
  @visibleForTesting
  static Duration streamHoldIdle = const Duration(seconds: 3);

  /// After a failure, how long the stream connection is not tried again
  @visibleForTesting
  static Duration streamRetryDelay = const Duration(minutes: 1);

  /// Files from this size on are streamed on the stream connection whatever their type (videos are, whatever their
  /// size): larger than the photos the browser loads whole for their thumbnail
  static const streamMinSize = 32 * 1024 * 1024;

  /// How many files were opened on the server, for the tests and the measures
  @visibleForTesting
  int get fileOpens => _fileOpens;

  /// How many files are kept open now
  @visibleForTesting
  int get openFileCount => _openFiles.length;

  /// Whether the stream connection is open
  @visibleForTesting
  bool get hasStreamConnection => _stream.pool != null;

  /// The file that has the stream connection, null when it is free
  @visibleForTesting
  String? get streamedPath => _streamPath;

  @override
  Future<List<NetworkEntry>> list(String path) {
    final folder = normalizePath(path);
    return _guard(_general, folder, (pool) async {
      final children = await pool.listDirectory(smbPathOf(folder));
      final entries = [
        for (final child in children)
          if (child.name.isNotEmpty && child.name != '.' && child.name != '..')
            _entryOf(folder == '/' ? '/${child.name}' : '$folder/${child.name}', child.stat),
      ];
      entries.sort(compareEntries);
      return entries;
    });
  }

  @override
  Future<NetworkEntry> stat(String path) {
    final target = normalizePath(path);
    return _guard(_general, target, (pool) async => _entryOf(target, await pool.stat(smbPathOf(target))));
  }

  /// The file stays open after the read, so that the next read of it (the media bridge reads a video in sequence)
  /// asks the server for its bytes only: it is closed once not read for [openFileIdle], when more than
  /// [maxOpenFiles] are open, and by [close]. A file read in sequence that is a video or a large file gets the stream
  /// connection, so that the thumbnails and listings of the browser never wait behind it, and it never waits behind
  /// them; one file at a time has it.
  @override
  Future<Uint8List> readRange(String path, int offset, int length) {
    RangeError.checkNotNegative(offset, 'offset');
    RangeError.checkNotNegative(length, 'length');
    final target = normalizePath(path);
    if (length == 0) {
      return Future.value(Uint8List(0));
    }
    final file = smbPathOf(target);
    final link = _linkFor(target, offset);
    return _guard(link, target, (pool) => _readOpenFile(link, pool, target, file, offset, length));
  }

  Future<Uint8List> _readOpenFile(_Link link, Smb2Pool pool, String target, String file, int offset, int length) async {
    var open = _openFileFor(link, pool, target, file);
    var reused = open.size != null;
    while (true) {
      open.reading++;
      try {
        final bytes = await _readFrom(open, pool, offset, length);
        open.next = offset + bytes.length;
        return bytes;
      } catch (error) {
        // A handle that failed is not kept; one kept open since may have been lost with its worker or closed by the
        // server: once again on a file opened anew
        _retire(open);
        if (!reused || error is! Smb2Exception || _closed) {
          rethrow;
        }
      } finally {
        open.reading--;
        _released(open);
      }
      open = _openFileFor(link, pool, target, file);
      reused = false;
    }
  }

  Future<Uint8List> _readFrom(_OpenFile open, Smb2Pool pool, int offset, int length) async {
    final (handle, size) = await open.opened;
    final first = await pool.readFromHandle(handle, offset: offset, length: min(length, maxReadChunk));
    if (first.length >= length || first.isEmpty) {
      return first.length > length ? Uint8List.sublistView(first, 0, length) : first;
    }
    // Fewer bytes than asked: a larger window, the end of the file, or a server that reads less at once (SMB 2.0
    // reads 64 KB at most). The size at the opening tells where to stop.
    final end = offset + length;
    final builder = BytesBuilder(copy: false)..add(first);
    while (offset + builder.length < end && offset + builder.length < size) {
      final position = offset + builder.length;
      final part = await pool.readFromHandle(handle, offset: position, length: min(end - position, maxReadChunk));
      if (part.isEmpty) {
        break;
      }
      builder.add(part);
    }
    final bytes = builder.takeBytes();
    return bytes.length > length ? Uint8List.sublistView(bytes, 0, length) : bytes;
  }

  /// The connection a read of [target] at [offset] goes to: the stream connection for the file that has it, and for a
  /// video or a large file read in sequence when no other file read it lately; the general connection otherwise
  _Link _linkFor(String target, int offset) {
    if (_streamPath == target) {
      if (_stream.pool != null) {
        return _stream;
      }
      _streamPath = null;
    }
    final open = _openFiles[target];
    final size = open?.size;
    if (open == null || size == null || open.next != offset || !_isStreamed(target, size)) {
      return _general;
    }
    final holderPath = _streamPath;
    final holder = holderPath == null ? null : _openFiles[holderPath];
    if (holder != null &&
        (holder.reading > 0 || DateTime.now().difference(holder.lastUsed) < streamHoldIdle) &&
        identical(holder.link, _stream)) {
      return _general;
    }
    if (_stream.pool == null) {
      // Opened meanwhile, for the next reads
      _openStreamConnection();
      return _general;
    }
    _streamPath = target;
    return _stream;
  }

  static bool _isStreamed(String path, int size) =>
      size >= streamMinSize || NetworkEntry(sourceId: '', path: path, isDirectory: false).isVideo;

  void _openStreamConnection() {
    if (_closed || _stream.pool != null || _stream.opening != null) {
      return;
    }
    final failedAt = _streamFailedAt;
    if (failedAt != null && DateTime.now().difference(failedAt) < streamRetryDelay) {
      return;
    }
    final opening = _stream.opening = _connectAgain();
    unawaited(
      opening
          .then<void>(
            (pool) {
              if (_closed) {
                unawaited(_serialized(const Duration(seconds: 10), pool.disconnect).catchError((Object _) {}));
                return;
              }
              _stream.pool = pool;
              _streamFailedAt = null;
            },
            onError: (Object error) {
              _streamFailedAt = DateTime.now();
              _log.info('No stream connection to ${source.name} ($_serverLabel), the reads share one: $error');
            },
          )
          .whenComplete(() => _stream.opening = null),
    );
  }

  /// The file kept open for [target] on [pool], opened when there is none. One kept open on another connection is
  /// closed: the file moved to the stream connection or away from it, or its connection was replaced.
  _OpenFile _openFileFor(_Link link, Smb2Pool pool, String target, String file) {
    final kept = _openFiles.remove(target);
    if (kept != null) {
      if (identical(kept.pool, pool)) {
        // Back at the end, the most recently used
        _openFiles[target] = kept;
        return kept;
      }
      _retire(kept);
    }
    while (_openFiles.length >= maxOpenFiles) {
      // The least recently read, the file being streamed last
      final oldest = _openFiles.values.firstWhere(
        (open) => open.path != _streamPath,
        orElse: () => _openFiles.values.first,
      );
      _retire(oldest);
    }
    _fileOpens++;
    final open = _OpenFile(target, link, pool, pool.openFileWithSize(file));
    _openFiles[target] = open;
    unawaited(open.opened.then<void>((opened) => open.size = opened.$2, onError: (Object _) {}));
    return open;
  }

  /// No longer kept: closed now, or once its reads under way end
  void _retire(_OpenFile open) {
    if (identical(_openFiles[open.path], open)) {
      _openFiles.remove(open.path);
    }
    if (_streamPath == open.path && identical(open.link, _stream)) {
      _streamPath = null;
    }
    open.idle?.cancel();
    if (open.retired) {
      return;
    }
    open.retired = true;
    if (open.reading == 0) {
      _closeHandle(open);
    }
  }

  /// After a read: closed when retired meanwhile, otherwise closed once idle
  void _released(_OpenFile open) {
    open.lastUsed = DateTime.now();
    if (open.reading > 0) {
      return;
    }
    if (open.retired) {
      _closeHandle(open);
      return;
    }
    open.idle?.cancel();
    open.idle = Timer(openFileIdle, () {
      if (open.reading == 0) {
        _retire(open);
      }
    });
  }

  static void _closeHandle(_OpenFile open) {
    if (open.closing) {
      return;
    }
    open.closing = true;
    unawaited(open.opened.then<void>((opened) => open.pool.closeHandle(opened.$1), onError: (Object _) {}));
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final open in _openFiles.values.toList()) {
      _retire(open);
    }
    _streamPath = null;
    final pools = [_general.pool, _stream.pool].nonNulls.toList();
    _general.pool = null;
    _stream.pool = null;
    for (final pool in pools) {
      try {
        await _serialized(const Duration(seconds: 10), pool.disconnect);
      } catch (_) {
        // The worker is gone either way
      }
    }
  }

  Future<T> _guard<T>(_Link link, String path, Future<T> Function(Smb2Pool pool) action) async {
    final pool = link.pool;
    if (_closed || pool == null) {
      throw _closedError();
    }
    try {
      return await action(pool);
    } on Smb2Exception catch (error) {
      if (_closed) {
        throw _closedError();
      }
      // A call cut short by the replacement of its connection is tried again on the new one
      if (!isSessionLost(error) && identical(link.pool, pool)) {
        throw describeError(error, server: _serverLabel, share: _share, path: path);
      }
    }
    // dart_smb2 opens the connection again after a transport failure only; a session the server ended (expired,
    // closed by an administrator) needs a new connection as well
    final fresh = await _replace(link, pool);
    try {
      return await action(fresh);
    } on Smb2Exception catch (error) {
      if (_closed) {
        throw _closedError();
      }
      throw describeError(error, server: _serverLabel, share: _share, path: path);
    }
  }

  /// The connection of [link] that follows [stale], opened once whatever the number of calls that found [stale] lost
  Future<Smb2Pool> _replace(_Link link, Smb2Pool stale) async {
    final current = link.pool;
    if (_closed || current == null) {
      throw _closedError();
    }
    if (!identical(current, stale)) {
      return current;
    }
    final reconnecting = link.reconnecting ??= () async {
      try {
        final fresh = await _connectAgain();
        if (_closed) {
          unawaited(_serialized(const Duration(seconds: 10), fresh.disconnect).catchError((Object _) {}));
          throw _closedError();
        }
        link.pool = fresh;
        // The files kept open on the old connection go with it
        for (final open in _openFiles.values.where((open) => identical(open.pool, stale)).toList()) {
          _retire(open);
        }
        unawaited(_serialized(const Duration(seconds: 10), stale.disconnect).catchError((Object _) {}));
        return fresh;
      } finally {
        link.reconnecting = null;
      }
    }();
    return reconnecting;
  }

  NetworkFileSystemException _closedError() =>
      NetworkFileSystemException('The connection to ${source.name} ($_serverLabel) is closed');

  NetworkEntry _entryOf(String path, Smb2Stat stat) => NetworkEntry(
    sourceId: source.id,
    path: path,
    isDirectory: stat.isDirectory,
    size: stat.isDirectory ? null : stat.size,
    // A missing date comes as the epoch
    modified: stat.modified.millisecondsSinceEpoch == 0 ? null : stat.modified,
  );

  static Future<Smb2Pool> _connectPool({
    required String server,
    required String share,
    String? user,
    String? password,
    String? domain,
    required int timeoutSeconds,
  }) {
    _checkLibrary();
    return Smb2Pool.connect(
      host: server,
      share: share,
      user: user,
      password: password,
      domain: domain,
      workers: 1,
      timeoutSeconds: timeoutSeconds,
    );
  }

  static Future<List<Smb2ShareInfo>> _enumerateShares({
    required String server,
    String? user,
    String? password,
    String? domain,
    required int timeoutSeconds,
  }) {
    _checkLibrary();
    return Smb2Pool.listSharesOn(
      host: server,
      user: user,
      password: password,
      domain: domain,
      timeoutSeconds: timeoutSeconds,
    );
  }

  static bool _libraryLoaded = false;

  /// Loads libsmb2 in this isolate first: a worker that fails to load it dies without a word and the pool would wait
  /// for it forever
  static void _checkLibrary() {
    if (_libraryLoaded) {
      return;
    }
    try {
      Smb2Client.open();
      _libraryLoaded = true;
    } catch (error) {
      throw NetworkFileSystemException('SMB is not available on this device: $error');
    }
  }

  /// Opening and closing connections one at a time: libsmb2 keeps a list of its connections without a lock. The lock
  /// is the one of dart_smb2, which its pools also take for each worker they spawn or close, the respawns after a
  /// connection loss included, so that the connections of all the shares, and of both links of a share, never
  /// overlap. One that takes longer than its [limit] no longer holds the others back.
  static Future<T> _serialized<T>(Duration limit, Future<T> Function() action) =>
      Smb2ContextLock.run(action, limit: limit);

  /// "/" separated, starting with "/", without "." and ".." (which cannot leave the share) nor a trailing "/"
  @visibleForTesting
  static String normalizePath(String path) {
    final segments = <String>[];
    for (final segment in path.replaceAll(r'\', '/').split('/')) {
      if (segment.isEmpty || segment == '.') {
        continue;
      }
      if (segment == '..') {
        if (segments.isNotEmpty) {
          segments.removeLast();
        }
        continue;
      }
      segments.add(segment);
    }
    return '/${segments.join('/')}';
  }

  /// The path as libsmb2 takes it: relative to the share, "" for its root
  @visibleForTesting
  static String smbPathOf(String path) => normalizePath(path).substring(1);

  /// The server name or address alone, without what users often type around it ("smb://", "\\", a trailing "/")
  /// nor a port
  @visibleForTesting
  static String hostOf(String host) => _splitHost(host).$1;

  /// "host:port" for libsmb2, IPv6 addresses in brackets. [port] wins over a port typed after the host.
  @visibleForTesting
  static String serverAddressOf(String host, int? port) {
    final (name, typedPort) = _splitHost(host);
    final address = name.contains(':') ? '[$name]' : name;
    return '$address:${port ?? typedPort ?? defaultPort}';
  }

  static (String, int?) _splitHost(String host) {
    var name = host.trim().replaceFirst(RegExp('^smb://', caseSensitive: false), '');
    name = name.replaceAll(RegExp(r'^[\\/]+|[\\/]+$'), '');
    // A share typed along with the server
    final slash = name.indexOf(RegExp(r'[\\/]'));
    if (slash >= 0) {
      name = name.substring(0, slash);
    }
    final bracketed = RegExp(r'^\[([^\]]+)\](?::(\d+))?$').firstMatch(name);
    if (bracketed != null) {
      return (bracketed[1]!, int.tryParse(bracketed[2] ?? ''));
    }
    final withPort = RegExp(r'^([^:]+):(\d+)$').firstMatch(name);
    if (withPort != null) {
      return (withPort[1]!, int.tryParse(withPort[2]!));
    }
    return (name, null);
  }

  /// The share name without slashes around it
  @visibleForTesting
  static String shareNameOf(String share) => share.trim().replaceAll(RegExp(r'^[\\/]+|[\\/]+$'), '');

  /// The password handed to libsmb2: null (anonymous logon) without a user name, otherwise the password as typed, an
  /// empty one included. libsmb2 treats a missing password as an anonymous session, which servers such as the Freebox
  /// Server refuse for their disk shares while they accept "freebox" with an empty password.
  static String? logonPassword(String? user, String? password) {
    if (user == null || user.isEmpty) {
      return null;
    }
    return password ?? '';
  }

  /// "DOMAIN\user" gives the user and the domain; an empty name gives none (anonymous logon)
  @visibleForTesting
  static (String?, String?) splitUserName(String username) {
    final name = username.trim();
    if (name.isEmpty) {
      return (null, null);
    }
    final backslash = name.indexOf(r'\');
    if (backslash > 0 && backslash < name.length - 1) {
      return (name.substring(backslash + 1), name.substring(0, backslash));
    }
    return (name, null);
  }

  /// Folders first, then files, both by name without case
  @visibleForTesting
  static int compareEntries(NetworkEntry a, NetworkEntry b) {
    if (a.isDirectory != b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.name.compareTo(b.name);
  }

  static const _authenticationStatuses = [
    'STATUS_LOGON_FAILURE',
    'STATUS_WRONG_PASSWORD',
    'STATUS_NO_SUCH_USER',
    'STATUS_ACCOUNT_DISABLED',
    'STATUS_ACCOUNT_EXPIRED',
    'STATUS_ACCOUNT_LOCKED_OUT',
    'STATUS_ACCOUNT_RESTRICTION',
    'STATUS_PASSWORD_EXPIRED',
    'STATUS_PASSWORD_MUST_CHANGE',
    'STATUS_INVALID_LOGON_HOURS',
    'STATUS_INVALID_WORKSTATION',
    'STATUS_LOGON_TYPE_NOT_GRANTED',
  ];

  static const _sessionLostStatuses = [
    'STATUS_USER_SESSION_DELETED',
    'STATUS_NETWORK_SESSION_EXPIRED',
    'STATUS_NO_SUCH_LOGON_SESSION',
  ];

  /// Whether the server ended the session, which a new connection mends
  @visibleForTesting
  static bool isSessionLost(Smb2Exception error) {
    final status = error.message.toUpperCase();
    return _sessionLostStatuses.any(status.contains);
  }

  static const _notFoundStatuses = [
    'STATUS_OBJECT_NAME_NOT_FOUND',
    'STATUS_OBJECT_PATH_NOT_FOUND',
    'STATUS_NO_SUCH_FILE',
    'STATUS_DELETE_PENDING',
  ];

  /// A message for the user from an error of dart_smb2. [connecting] tells that the error came while logging on to
  /// the share, where a refused access means that the credentials do not open it.
  @visibleForTesting
  static NetworkFileSystemException describeError(
    Smb2Exception error, {
    required String server,
    required String share,
    String? path,
    bool connecting = false,
  }) {
    final message = error.message;
    final status = message.toUpperCase();
    final type = _typeOf(error);
    final detail = _detailOf(message);
    final where = path == null || path == '/' ? share : '$share$path';

    if (status.contains('STATUS_BAD_NETWORK_NAME')) {
      return NetworkFileSystemException('There is no share "$share" on $server', isNotFound: true);
    }
    if (type == Smb2ErrorType.auth || _authenticationStatuses.any(status.contains)) {
      return NetworkFileSystemException('$server refused the user name or password', isAuthentication: true);
    }
    if (type == Smb2ErrorType.accessDenied ||
        status.contains('STATUS_ACCESS_DENIED') ||
        status.contains('STATUS_NETWORK_ACCESS_DENIED')) {
      return connecting
          ? NetworkFileSystemException('$server refused access to "$share" for this user', isAuthentication: true)
          : NetworkFileSystemException('Access denied to $where');
    }
    if (type == Smb2ErrorType.notADirectory || status.contains('STATUS_NOT_A_DIRECTORY')) {
      return NetworkFileSystemException('$where is not a folder');
    }
    if (type == Smb2ErrorType.fileNotFound || _notFoundStatuses.any(status.contains)) {
      return NetworkFileSystemException('$where was not found', isNotFound: true);
    }
    if (type == Smb2ErrorType.timeout) {
      return NetworkFileSystemException('The server at $server did not answer in time');
    }
    if (status.contains('RESOLVE')) {
      return NetworkFileSystemException('Cannot find the server $server');
    }
    if (type == Smb2ErrorType.connection) {
      return NetworkFileSystemException('Cannot reach $server: $detail');
    }
    return NetworkFileSystemException('$server: $detail');
  }

  /// The type of the error; dart_smb2 reports the errors of a connection being opened as text only
  /// ("Worker failed to start: Smb2Exception(Smb2ErrorType.auth, errno=111): ...")
  static Smb2ErrorType _typeOf(Smb2Exception error) {
    if (error.type != Smb2ErrorType.unknown) {
      return error.type;
    }
    final name = RegExp(r'Smb2ErrorType\.(\w+)').firstMatch(error.message)?[1];
    return Smb2ErrorType.values.where((type) => type.name == name).firstOrNull ??
        Smb2ErrorType.classify(error.message, -1);
  }

  /// What libsmb2 said, without the wrapping of dart_smb2
  static String _detailOf(String message) => message
      .replaceFirst('Worker failed to start: ', '')
      .replaceFirst(RegExp(r'^Smb2Exception\([^)]*\):\s*'), '')
      .trim();
}

/// One of the two connections of a share: [pool] is null until it is opened, and once the file system is closed
class _Link {
  _Link(this.name);

  final String name;
  Smb2Pool? pool;

  /// The first opening under way
  Future<Smb2Pool>? opening;

  /// The replacement under way of a connection the server ended the session of
  Future<Smb2Pool>? reconnecting;

  @override
  String toString() => '_Link($name)';
}

/// A file kept open between reads, on one connection
class _OpenFile {
  _OpenFile(this.path, this.link, this.pool, this.opened);

  final String path;
  final _Link link;
  final Smb2Pool pool;

  /// The handle and the size of the file when it was opened
  final Future<(Smb2PoolHandle, int)> opened;

  /// The size when it was opened, null until it is
  int? size;

  /// The offset after the last read, where the next one in sequence starts
  int next = -1;

  /// Reads under way
  int reading = 0;
  DateTime lastUsed = DateTime.now();
  Timer? idle;

  /// No longer kept: closed once its reads under way end
  bool retired = false;
  bool closing = false;
}
