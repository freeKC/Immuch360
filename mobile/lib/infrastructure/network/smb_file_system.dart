// A share reached over SMB 2 or 3 (Samba on a NAS or a Linux computer, Windows file sharing) through dart_smb2, which
// binds libsmb2. Each connection is held by a worker isolate of its own so that the calls never block the interface.
// The general connection, opened with the file system, serves the listings, the stats, the thumbnails and the reads
// out of sequence. The video being streamed gets a pool of up to [SmbFileSystem.defaultStreamConnections] connections
// of its own, opened one after the other the first time a file is read in sequence and released once it is no longer
// read: libsmb2 sends the parts of one read one after the other, each waiting for its answer, so that a slow server (a
// Freebox Server answers 4.5 MiB/s to one read at a time) only reaches the rate of a 5.7K video when several reads run
// at once; a read of the streamed file is split in pieces read in parallel, one per connection, and put back in order.
// When a connection drops or the server ends the session, the call opens it again once and is tried again. A read asks
// the server for the bytes wanted only, a file is never transferred whole; a file read stays open for the next reads
// of it.

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
  SmbFileSystem._(
    this.source,
    Smb2Pool pool,
    this._serverLabel,
    this._share,
    this._connectAgain,
    this.streamConnections,
  ) : _general = _Link('general')..pool = pool;

  /// Connects to the share of [source] and lists its start folder (the root path of the source) once. Throws a
  /// [NetworkFileSystemException] when the server cannot be reached, refuses the credentials, has no such share or
  /// no such folder.
  ///
  /// A user name written "DOMAIN\user" logs on to that domain. Without a user name the logon is anonymous (guest); a
  /// user name with an empty password logs on with that empty password (a Freebox Server wants "freebox" and nothing).
  ///
  /// [streamConnections] is the most connections the file being streamed reads on at once, none to read everything on
  /// the general connection.
  static Future<SmbFileSystem> open(
    NetworkSource source,
    String? password, {
    @visibleForTesting SmbConnector connect = _connectPool,
    int timeoutSeconds = defaultTimeoutSeconds,
    int streamConnections = defaultStreamConnections,
  }) async {
    if (source.type != NetworkSourceType.smb) {
      throw ArgumentError.value(source.type, 'source.type', 'Not an SMB source');
    }
    RangeError.checkNotNegative(streamConnections, 'streamConnections');
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

    final fileSystem = SmbFileSystem._(source, await connectOnce(), serverLabel, share, connectOnce, streamConnections);
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

  /// The most connections of the stream pool, see [open]
  final int streamConnections;

  /// The stream pool: the connections open for the file being streamed, opened one after the other the first time a
  /// file is read in sequence (see [readRange]) and released once none was read for [streamPoolIdle]
  final List<_Link> _streamLinks = [];

  /// The opening under way of the next connection of the stream pool
  Future<void>? _streamOpening;

  /// Changed when the stream pool is released: a connection opened for the previous one is closed again
  int _streamGeneration = 0;

  /// Releases the stream pool once it was not read for [streamPoolIdle]
  Timer? _streamIdle;

  bool _closed = false;
  final String _serverLabel;
  final String _share;

  /// Opens a new connection like the first one: one of the stream pool, or one that replaces a connection whose
  /// session the server ended
  final Future<Smb2Pool> Function() _connectAgain;

  /// When a connection of the stream pool last failed to open, or the pool was given up because none of its
  /// connections could read; the pool does not grow for [streamRetryDelay]. A connection dropped alone is replaced
  /// at the next read.
  DateTime? _streamFailedAt;

  /// The reads in a row whose pieces no connection of the stream pool could read, while the general one could
  int _streamPoolFailures = 0;

  /// The files kept open on the general connection, the least recently used first (a map literal keeps the insertion
  /// order)
  final Map<String, _OpenFile> _openFiles = {};

  /// The file that has the stream pool, null when it is free
  _StreamedFile? _streamed;

  int _fileOpens = 0;

  static const defaultPort = 445;

  /// How long libsmb2 waits for the server before giving up on a call (and on the connection)
  static const defaultTimeoutSeconds = 20;

  /// Added to [defaultTimeoutSeconds] (or the timeout given to [open]) for the wait of a new connection
  @visibleForTesting
  static Duration connectGrace = const Duration(seconds: 15);

  /// Largest read asked of the worker at once; a larger window is read in several parts on one open file
  static const maxReadChunk = 4 * 1024 * 1024;

  /// Most connections of the stream pool by default: six reads at once take a Freebox Server from 4.5 MiB/s to the
  /// rate its disk gives, above the 16.6 MiB/s of a 5.7K video
  static const defaultStreamConnections = 6;

  /// The pieces a read of the streamed file is split in start and end on multiples of this size (but for the first
  /// and the last), and are as long at least: a smaller read is one piece
  static const streamPieceAlignment = 256 * 1024;

  /// A read of a video from its start of this size at least, the first chunk the media bridge asks for a player, opens
  /// the stream pool at once; a smaller one (the browser looking for the spherical metadata) waits for a second read in
  /// sequence
  static const streamStartRead = 1024 * 1024;

  /// A connection of the stream pool that is the only one to fail in this many reads in a row is dropped from it (and
  /// replaced); the pool is given up when none of its connections could read in this many reads in a row. Connections
  /// that fail together in one read (the network was cut a moment) are not counted against: dart_smb2 starts their
  /// worker again at the next call.
  static const streamConnectionMaxFailures = 2;

  /// Most files kept open per share
  static const maxOpenFiles = 4;

  /// A file kept open is closed once it was not read for this long
  @visibleForTesting
  static Duration openFileIdle = const Duration(seconds: 10);

  /// The file that has the stream pool keeps it while it was read less than this long ago
  @visibleForTesting
  static Duration streamHoldIdle = const Duration(seconds: 3);

  /// The stream pool is released once it was not read for this long
  @visibleForTesting
  static Duration streamPoolIdle = const Duration(seconds: 10);

  /// After a connection of the stream pool failed to open, or the pool was given up, how long it does not grow
  @visibleForTesting
  static Duration streamRetryDelay = const Duration(minutes: 1);

  /// Files from this size on are streamed on the stream pool whatever their type (videos are, whatever their size):
  /// larger than the photos the browser loads whole for their thumbnail
  static const streamMinSize = 32 * 1024 * 1024;

  /// How many files were opened on the server, for the tests and the measures
  @visibleForTesting
  int get fileOpens => _fileOpens;

  /// How many files are kept open on the general connection now
  @visibleForTesting
  int get openFileCount => _openFiles.length;

  /// Whether the stream pool has a connection open
  @visibleForTesting
  bool get hasStreamConnection => _streamLinks.isNotEmpty;

  /// The connections of the stream pool open now
  @visibleForTesting
  int get streamConnectionCount => _streamLinks.length;

  /// The file that has the stream pool, null when it is free
  @visibleForTesting
  String? get streamedPath => _streamed?.path;

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
  /// pool, so that the thumbnails and listings of the browser never wait behind it, and it never waits behind them;
  /// one file at a time has it. Its reads are split in pieces read at once on the connections of the pool.
  @override
  Future<Uint8List> readRange(String path, int offset, int length) {
    RangeError.checkNotNegative(offset, 'offset');
    RangeError.checkNotNegative(length, 'length');
    final target = normalizePath(path);
    if (length == 0) {
      return Future.value(Uint8List(0));
    }
    final file = smbPathOf(target);
    final streamed = _streamedFor(target, offset, length);
    if (streamed != null) {
      return _readStreamed(streamed, file, offset, length);
    }
    return _readGeneral(target, file, offset, length);
  }

  Future<Uint8List> _readGeneral(String target, String file, int offset, int length) =>
      _guard(_general, target, (pool) => _readOpenFile(pool, target, file, offset, length));

  Future<Uint8List> _readOpenFile(Smb2Pool pool, String target, String file, int offset, int length) async {
    var open = _openFileFor(pool, target, file);
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
      open = _openFileFor(pool, target, file);
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

  /// The streamed file a read of [target] at [offset] goes to: the file that has the stream pool, or a video or a
  /// large file read in sequence that takes it when no other file read it lately. Null for the general connection.
  _StreamedFile? _streamedFor(String target, int offset, int length) {
    final current = _streamed;
    if (current != null && current.path == target) {
      // In place of a connection dropped, or of one that could not open, after a while
      _growStreamPool();
      if (_streamLinks.isNotEmpty) {
        return current;
      }
      // Every connection of the pool was dropped: on the general connection until the pool opens again
      _releaseStreamed();
    }
    if (streamConnections == 0) {
      return null;
    }
    if (offset == 0 && length >= streamStartRead && _isVideo(target)) {
      // A player starts: the pool opens meanwhile, so that it is there when the reads go on in sequence
      _growStreamPool();
    }
    final open = _openFiles[target];
    final size = open?.size;
    if (open == null || size == null || open.next != offset || !_isStreamed(target, size)) {
      return null;
    }
    final holder = _streamed;
    if (holder != null && (holder.reading > 0 || DateTime.now().difference(holder.lastUsed) < streamHoldIdle)) {
      return null;
    }
    if (_streamLinks.isEmpty) {
      // Opened meanwhile, for the next reads
      _growStreamPool();
      return null;
    }
    _releaseStreamed();
    // Closed on the general connection, once its reads under way end
    _retire(open);
    final streamed = _streamed = _StreamedFile(target, size);
    _growStreamPool();
    return streamed;
  }

  static bool _isStreamed(String path, int size) => size >= streamMinSize || _isVideo(path);

  static bool _isVideo(String path) => NetworkEntry(sourceId: '', path: path, isDirectory: false).isVideo;

  /// Opens the next connection of the stream pool, then the next ones one after the other up to
  /// [streamConnections]
  void _growStreamPool() {
    if (_closed || _streamOpening != null || _streamLinks.length >= streamConnections) {
      return;
    }
    final failedAt = _streamFailedAt;
    if (failedAt != null && DateTime.now().difference(failedAt) < streamRetryDelay) {
      return;
    }
    final generation = _streamGeneration;
    var opened = false;
    final opening = _streamOpening = _connectAgain()
        .then<void>(
          (pool) {
            if (_closed || generation != _streamGeneration) {
              unawaited(_disconnect(pool));
              return;
            }
            _streamLinks.add(_Link('stream')..pool = pool);
            _streamFailedAt = null;
            opened = true;
            _scheduleStreamRelease();
          },
          onError: (Object error) {
            _streamFailedAt = DateTime.now();
            _log.info(
              'The stream pool of ${source.name} ($_serverLabel) stays at ${_streamLinks.length} connections: $error',
            );
          },
        )
        .whenComplete(() {
          _streamOpening = null;
          if (opened) {
            _growStreamPool();
          }
        });
    unawaited(opening);
  }

  /// [length] bytes of [file] from [offset], in pieces read at once on the connections of the stream pool and put
  /// back in order
  Future<Uint8List> _readStreamed(_StreamedFile file, String smbPath, int offset, int length) async {
    file.reading++;
    _streamIdle?.cancel();
    try {
      // Not past the end of the file, which the pieces would ask for nothing; a read that starts there asks anyway
      final end = offset < file.size ? min(offset + length, file.size) : offset + length;
      // The least busy connections first, for a read that comes while another one is under way
      final links = _streamLinks.toList();
      mergeSort(links, compare: (a, b) => a.busy.compareTo(b.busy));
      final pieces = streamPiecesOf(offset, end - offset, links.length);
      final outcome = _StreamReadOutcome();
      final Uint8List bytes;
      if (pieces.length == 1) {
        bytes = await _readPiece(file, smbPath, links.first, offset, end - offset, outcome);
      } else {
        final parts = await Future.wait([
          for (var i = 0; i < pieces.length; i++)
            _readPiece(file, smbPath, links[i % links.length], pieces[i].offset, pieces[i].length, outcome),
        ]);
        // Up to the first piece that came short: the end of the file
        final builder = BytesBuilder(copy: false);
        for (var i = 0; i < parts.length; i++) {
          builder.add(parts[i]);
          if (parts[i].length < pieces[i].length) {
            break;
          }
        }
        bytes = builder.takeBytes();
      }
      // Counted once the read gave its bytes: a read that failed whole met a network down, no connection of its own
      _streamReadDone(outcome);
      return bytes;
    } finally {
      file.reading--;
      file.lastUsed = DateTime.now();
      _scheduleStreamRelease();
    }
  }

  /// The pieces a read of [length] bytes at [offset] is split in for [connections] connections: as many as the
  /// connections at most, each of whole multiples of [streamPieceAlignment] (but for the first and the last, which
  /// start and end where the read does), as even as can be, the first ones longer by one multiple. A read shorter than
  /// two multiples is one piece.
  @visibleForTesting
  static List<({int offset, int length})> streamPiecesOf(int offset, int length, int connections) {
    const unit = streamPieceAlignment;
    final end = offset + length;
    final firstUnit = offset ~/ unit;
    // The multiples the read touches
    final units = (end + unit - 1) ~/ unit - firstUnit;
    final count = max(1, min(connections, min(units, length ~/ unit)));
    if (count == 1) {
      return [(offset: offset, length: length)];
    }
    final pieces = <({int offset, int length})>[];
    var start = offset;
    var cut = firstUnit;
    for (var i = 0; i < count; i++) {
      cut += units ~/ count + (i < units % count ? 1 : 0);
      final stop = i == count - 1 ? end : min(end, cut * unit);
      pieces.add((offset: start, length: stop - start));
      start = stop;
    }
    return pieces;
  }

  /// A piece of [file] read on [link], once again on another connection of the pool when it fails, and last on the
  /// general connection; the connections that read it or failed to are noted in [outcome]
  Future<Uint8List> _readPiece(
    _StreamedFile file,
    String smbPath,
    _Link link,
    int offset,
    int length,
    _StreamReadOutcome outcome,
  ) async {
    final tried = <_Link>{};
    _Link? current = link;
    while (current != null && tried.length < 2) {
      tried.add(current);
      try {
        final bytes = await _readOnStreamLink(current, file, smbPath, offset, length);
        outcome.read.add(current);
        return bytes;
      } catch (error) {
        if (_closed || (error is NetworkFileSystemException && (error.isNotFound || error.isAuthentication))) {
          rethrow;
        }
        _log.fine('A read of the stream pool of ${source.name} ($_serverLabel) failed: $error');
        outcome.failed[current] = error;
      }
      current = _streamLinks
          .where((other) => !tried.contains(other))
          .fold<_Link?>(null, (best, other) => best == null || other.busy < best.busy ? other : best);
    }
    return _readGeneral(file.path, smbPath, offset, length);
  }

  Future<Uint8List> _readOnStreamLink(_Link link, _StreamedFile file, String smbPath, int offset, int length) async {
    link.busy++;
    try {
      return await _guard(link, file.path, (pool) => _readStreamHandle(link, pool, file, smbPath, offset, length));
    } finally {
      link.busy--;
    }
  }

  Future<Uint8List> _readStreamHandle(
    _Link link,
    Smb2Pool pool,
    _StreamedFile file,
    String smbPath,
    int offset,
    int length,
  ) async {
    var open = _streamHandleFor(file, link, pool, smbPath);
    var reused = open.size != null;
    while (true) {
      open.reading++;
      try {
        return await _readFrom(open, pool, offset, length);
      } catch (error) {
        // As on the general connection: once again on a file opened anew when the handle was kept from before
        if (identical(file.handles[link], open)) {
          file.handles.remove(link);
        }
        _retireHandle(open);
        if (!reused || error is! Smb2Exception || _closed) {
          rethrow;
        }
      } finally {
        open.reading--;
        if (open.retired && open.reading == 0) {
          _closeHandle(open);
        }
      }
      open = _streamHandleFor(file, link, pool, smbPath);
      reused = false;
    }
  }

  /// The handle of [file] on [link], opened when there is none on its current connection
  _OpenFile _streamHandleFor(_StreamedFile file, _Link link, Smb2Pool pool, String smbPath) {
    final kept = file.handles[link];
    if (kept != null && identical(kept.pool, pool) && !kept.retired) {
      return kept;
    }
    if (kept != null) {
      _retireHandle(kept);
    }
    _fileOpens++;
    final open = _OpenFile(file.path, link, pool, pool.openFileWithSize(smbPath));
    unawaited(open.opened.then<void>((opened) => open.size = opened.$2, onError: (Object _) {}));
    if (file.released) {
      // Read once, then closed
      open.retired = true;
    } else {
      file.handles[link] = open;
    }
    return open;
  }

  /// A read of the streamed file gave its bytes: a connection is counted against only when it is the only one that
  /// failed in it, the others read; the pool as a whole when none of its connections read and the general one did.
  /// Connections that failed together (the network was cut a moment, the server was slow to answer them all) are
  /// neither counted against nor dropped.
  void _streamReadDone(_StreamReadOutcome outcome) {
    if (_closed) {
      return;
    }
    final failed = outcome.failed.keys.where(_streamLinks.contains).toList();
    final read = outcome.read.where((link) => _streamLinks.contains(link) && !outcome.failed.containsKey(link));
    for (final link in read) {
      link.failures = 0;
    }
    if (outcome.failed.isEmpty || outcome.read.isNotEmpty) {
      _streamPoolFailures = 0;
    }
    if (outcome.failed.isEmpty) {
      return;
    }
    if (outcome.read.isEmpty) {
      // Every piece came from the general connection
      _streamPoolFailures++;
      _log.fine('No connection of the stream pool of ${source.name} ($_serverLabel) could read ($_streamPoolFailures)');
      if (_streamPoolFailures >= streamConnectionMaxFailures && _streamLinks.isNotEmpty) {
        _log.info(
          'The stream pool of ${source.name} ($_serverLabel) is given up for $streamRetryDelay after '
          '${outcome.failed.values.first}',
        );
        _releaseStreamPool();
        _streamFailedAt = DateTime.now();
      }
      return;
    }
    if (outcome.failed.length > 1) {
      return;
    }
    for (final link in failed) {
      _streamLinkFailed(link, outcome.failed[link]!);
    }
  }

  /// [link] alone failed a read: dropped from the stream pool when it did in too many reads in a row, the next read
  /// opens a new one in its place
  void _streamLinkFailed(_Link link, Object error) {
    link.failures++;
    if (link.failures < streamConnectionMaxFailures || !_streamLinks.remove(link)) {
      return;
    }
    _log.info('A connection of the stream pool of ${source.name} ($_serverLabel) is dropped after $error');
    _closeStreamLink(link);
  }

  void _closeStreamLink(_Link link) {
    link.dropped = true;
    final handle = _streamed?.handles.remove(link);
    if (handle != null) {
      _retireHandle(handle);
    }
    final pool = link.pool;
    link.pool = null;
    if (pool != null) {
      unawaited(_disconnect(pool));
    }
  }

  /// Releases the stream pool once it is not read for [streamPoolIdle]
  void _scheduleStreamRelease() {
    _streamIdle?.cancel();
    _streamIdle = null;
    if (_closed || (_streamed?.reading ?? 0) > 0 || (_streamLinks.isEmpty && _streamOpening == null)) {
      return;
    }
    _streamIdle = Timer(streamPoolIdle, () {
      _streamIdle = null;
      if ((_streamed?.reading ?? 0) == 0) {
        _releaseStreamPool();
      }
    });
  }

  /// Closes the connections of the stream pool, and the handles of the streamed file
  void _releaseStreamPool() {
    _streamIdle?.cancel();
    _streamIdle = null;
    _streamGeneration++;
    _streamPoolFailures = 0;
    _releaseStreamed();
    for (final link in _streamLinks.toList()) {
      _closeStreamLink(link);
    }
    _streamLinks.clear();
  }

  /// The streamed file gives the stream pool up: its handles are closed once their reads under way end
  void _releaseStreamed() {
    final streamed = _streamed;
    if (streamed == null) {
      return;
    }
    _streamed = null;
    streamed.released = true;
    for (final handle in streamed.handles.values) {
      _retireHandle(handle);
    }
    streamed.handles.clear();
  }

  /// The file kept open for [target] on the general connection [pool], opened when there is none. One kept open on a
  /// connection since replaced is closed.
  _OpenFile _openFileFor(Smb2Pool pool, String target, String file) {
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
      // The least recently read
      _retire(_openFiles.values.first);
    }
    _fileOpens++;
    final open = _OpenFile(target, _general, pool, pool.openFileWithSize(file));
    _openFiles[target] = open;
    unawaited(open.opened.then<void>((opened) => open.size = opened.$2, onError: (Object _) {}));
    return open;
  }

  /// No longer kept on the general connection: closed now, or once its reads under way end
  void _retire(_OpenFile open) {
    if (identical(_openFiles[open.path], open)) {
      _openFiles.remove(open.path);
    }
    _retireHandle(open);
  }

  void _retireHandle(_OpenFile open) {
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

  static Future<void> _disconnect(Smb2Pool pool) =>
      _serialized(const Duration(seconds: 10), pool.disconnect).catchError((Object _) {});

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _streamIdle?.cancel();
    _streamIdle = null;
    for (final open in _openFiles.values.toList()) {
      _retire(open);
    }
    _releaseStreamed();
    final pools = [_general.pool, for (final link in _streamLinks) link.pool].nonNulls.toList();
    _general.pool = null;
    for (final link in _streamLinks) {
      link
        ..dropped = true
        ..pool = null;
    }
    _streamLinks.clear();
    for (final pool in pools) {
      // The worker is gone either way when it fails
      await _disconnect(pool);
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
        if (_closed || link.dropped) {
          unawaited(_disconnect(fresh));
          throw _closedError();
        }
        link.pool = fresh;
        // The files kept open on the old connection go with it
        for (final open in _openFiles.values.where((open) => identical(open.pool, stale)).toList()) {
          _retire(open);
        }
        final streamed = _streamed?.handles[link];
        if (streamed != null && identical(streamed.pool, stale)) {
          _streamed?.handles.remove(link);
          _retireHandle(streamed);
        }
        unawaited(_disconnect(stale));
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

/// A connection of a share, the general one or one of the stream pool: [pool] is null until it is opened, once it is
/// dropped from the pool, and once the file system is closed
class _Link {
  _Link(this.name);

  final String name;
  Smb2Pool? pool;

  /// The replacement under way of a connection the server ended the session of
  Future<Smb2Pool>? reconnecting;

  /// Reads of the streamed file under way on it
  int busy = 0;

  /// Reads of the streamed file in a row in which it was the only connection of the pool to fail
  int failures = 0;

  /// No longer part of the file system: a replacement opened meanwhile is closed again
  bool dropped = false;

  @override
  String toString() => '_Link($name)';
}

/// The connections of the stream pool that read the pieces of one read, and those that failed to, with their error
class _StreamReadOutcome {
  final Set<_Link> read = {};
  final Map<_Link, Object> failed = {};
}

/// The file that has the stream pool, with its handle on each connection of the pool
class _StreamedFile {
  _StreamedFile(this.path, this.size);

  final String path;

  /// The size when it took the pool
  final int size;
  final Map<_Link, _OpenFile> handles = {};

  /// Reads under way
  int reading = 0;
  DateTime lastUsed = DateTime.now();

  /// Gave the pool up: a handle opened by a read under way is closed after it
  bool released = false;
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
