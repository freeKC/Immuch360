// A share reached over SMB 2 or 3 (Samba on a NAS or a Linux computer, Windows file sharing) through dart_smb2, which
// binds libsmb2. Each file system keeps one connection, held by a worker isolate of its own so that the calls never
// block the interface; when the connection drops or the server ends the session, the call opens it again once and is
// tried again. A read asks the server for the bytes wanted only, a file is never transferred whole.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';

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

/// A [NetworkFileSystem] over SMB, see [open]
class SmbFileSystem implements NetworkFileSystem {
  SmbFileSystem._(this.source, this._pool, this._serverLabel, this._share, this._connectAgain);

  /// Connects to the share of [source] and lists its start folder (the root path of the source) once. Throws a
  /// [NetworkFileSystemException] when the server cannot be reached, refuses the credentials, has no such share or
  /// no such folder.
  ///
  /// A user name written "DOMAIN\user" logs on to that domain. With no password the logon is anonymous (guest).
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
          password: password == null || password.isEmpty ? null : password,
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

  @override
  final NetworkSource source;

  /// Null once closed
  Smb2Pool? _pool;
  final String _serverLabel;
  final String _share;

  /// Opens a new connection like the first one, for when the server ended the session
  final Future<Smb2Pool> Function() _connectAgain;
  Future<Smb2Pool>? _reconnecting;

  static const defaultPort = 445;

  /// How long libsmb2 waits for the server before giving up on a call (and on the connection)
  static const defaultTimeoutSeconds = 20;

  /// Added to [defaultTimeoutSeconds] (or the timeout given to [open]) for the wait of a new connection
  @visibleForTesting
  static Duration connectGrace = const Duration(seconds: 15);

  /// Largest read asked of the worker at once; a larger window is read in several parts on one open file
  static const maxReadChunk = 4 * 1024 * 1024;

  @override
  Future<List<NetworkEntry>> list(String path) {
    final folder = normalizePath(path);
    return _guard(folder, (pool) async {
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
    return _guard(target, (pool) async => _entryOf(target, await pool.stat(smbPathOf(target))));
  }

  @override
  Future<Uint8List> readRange(String path, int offset, int length) {
    RangeError.checkNotNegative(offset, 'offset');
    RangeError.checkNotNegative(length, 'length');
    final target = normalizePath(path);
    if (length == 0) {
      return Future.value(Uint8List(0));
    }
    final file = smbPathOf(target);
    return _guard(target, (pool) async {
      // Most reads fit in one request: open, read, close in a single call to the worker
      final first = await pool.readFileRange(file, offset: offset, length: min(length, maxReadChunk));
      if (first.length >= length || first.isEmpty) {
        return first;
      }
      // Fewer bytes than asked: the end of the file, or a server that reads less at once (SMB 2.0 reads 64 KB at
      // most). Go on with one open file, whose size tells where to stop.
      return pool.withFile(file, (opened) async {
        final end = min(offset + length, opened.size);
        final builder = BytesBuilder(copy: false)..add(first);
        while (offset + builder.length < end) {
          final position = offset + builder.length;
          final part = await opened.read(offset: position, length: min(end - position, maxReadChunk));
          if (part.isEmpty) {
            break;
          }
          builder.add(part);
        }
        return builder.takeBytes();
      });
    });
  }

  @override
  Future<void> close() async {
    final pool = _pool;
    _pool = null;
    if (pool == null) {
      return;
    }
    try {
      await _serialized(const Duration(seconds: 10), pool.disconnect);
    } catch (_) {
      // The worker is gone either way
    }
  }

  Future<T> _guard<T>(String path, Future<T> Function(Smb2Pool pool) action) async {
    final pool = _pool;
    if (pool == null) {
      throw _closedError();
    }
    try {
      return await action(pool);
    } on Smb2Exception catch (error) {
      if (_pool == null) {
        throw _closedError();
      }
      // A call cut short by the replacement of its connection is tried again on the new one
      if (!isSessionLost(error) && identical(_pool, pool)) {
        throw describeError(error, server: _serverLabel, share: _share, path: path);
      }
    }
    // dart_smb2 opens the connection again after a transport failure only; a session the server ended (expired,
    // closed by an administrator) needs a new connection as well
    final fresh = await _replace(pool);
    try {
      return await action(fresh);
    } on Smb2Exception catch (error) {
      if (_pool == null) {
        throw _closedError();
      }
      throw describeError(error, server: _serverLabel, share: _share, path: path);
    }
  }

  /// The connection that follows [stale], opened once whatever the number of calls that found [stale] lost
  Future<Smb2Pool> _replace(Smb2Pool stale) async {
    final current = _pool;
    if (current == null) {
      throw _closedError();
    }
    if (!identical(current, stale)) {
      return current;
    }
    final reconnecting = _reconnecting ??= () async {
      try {
        final fresh = await _connectAgain();
        if (_pool == null) {
          unawaited(_serialized(const Duration(seconds: 10), fresh.disconnect).catchError((Object _) {}));
          throw _closedError();
        }
        _pool = fresh;
        unawaited(_serialized(const Duration(seconds: 10), stale.disconnect).catchError((Object _) {}));
        return fresh;
      } finally {
        _reconnecting = null;
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

  /// Opening and closing connections one at a time: libsmb2 keeps a list of its connections without a lock. One that
  /// takes longer than its [limit] no longer holds the others back.
  static Future<void> _lifecycle = Future.value();

  static Future<T> _serialized<T>(Duration limit, Future<T> Function() action) {
    final result = _lifecycle.then((_) => action());
    _lifecycle = result.then<void>((_) {}, onError: (Object _) {}).timeout(limit, onTimeout: () {});
    return result;
  }

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
