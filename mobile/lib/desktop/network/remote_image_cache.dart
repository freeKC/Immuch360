// The disk cache of the server's images on the computers (thumbnails, previews, originals fetched for the viewer).
// The phones keep them in the HTTP caches of their native clients: Cronet's or OkHttp's on Android, 1 GiB
// (MEDIA_CACHE_SIZE_BYTES of HttpClientManager.kt), the URLCache of the shared session on iOS, 1 GiB too. This cache
// follows the server's Cache-Control the way an HTTP cache does: an asset image ("private, max-age=86400,
// stale-while-revalidate=2592000, stale-if-error=2592000") is used for a day, then shown at once while it is checked
// again in the background, and a face ("private, no-cache") is checked at each use; a check costs a 304 thanks to
// the ETag the server sends. The least recently used files go first above the size limit.
//
// One file per address, named by the SHA-256 of the address (the address itself is never written: a shared link's
// key can be in it): a header of [headerSize] bytes holding the cache metadata as JSON, then the body as the server
// sent it. A fixed header lets a 304 refresh the metadata in place without copying the body.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('RemoteImageCache');

/// What the server's headers allow, stored in front of each body
@immutable
class CacheMeta {
  const CacheMeta({
    required this.storedAt,
    this.maxAge,
    this.staleWhileRevalidate,
    this.staleIfError,
    this.noCache = false,
    this.mustRevalidate = false,
    this.etag,
    this.lastModified,
  });

  /// When the body was received, minus the Age a proxy gave
  final DateTime storedAt;

  /// Freshness lifetime in seconds, from max-age or Expires; null is 0
  final int? maxAge;
  final int? staleWhileRevalidate;
  final int? staleIfError;
  final bool noCache;
  final bool mustRevalidate;
  final String? etag;
  final String? lastModified;

  bool get hasValidators => etag != null || lastModified != null;

  /// Worth a file: a later request can use it, or check it for the cost of a 304; an answer with neither a lifetime
  /// nor a validator would be downloaded again whole anyway
  bool get isReusable => hasValidators || (maxAge ?? 0) > 0 || staleIfError != null;

  /// The metadata of a 200 answer, null when the server forbids storing it
  static CacheMeta? fromResponse(Map<String, String> headers, DateTime now) {
    final directives = _directives(headers['cache-control']);
    if (directives.containsKey('no-store')) {
      return null;
    }
    return CacheMeta(
      storedAt: now.subtract(Duration(seconds: int.tryParse(headers['age'] ?? '') ?? 0)),
      maxAge: _seconds(directives['max-age']) ?? _expiresLifetime(headers, now),
      staleWhileRevalidate: _seconds(directives['stale-while-revalidate']),
      staleIfError: _seconds(directives['stale-if-error']),
      noCache: directives.containsKey('no-cache'),
      mustRevalidate: directives.containsKey('must-revalidate'),
      etag: headers['etag'],
      lastModified: headers['last-modified'],
    );
  }

  /// After a 304: a new lifetime from now, with the headers the answer brought and the validators kept otherwise
  CacheMeta revalidated(Map<String, String> headers, DateTime now) {
    final directives = headers.containsKey('cache-control') ? _directives(headers['cache-control']) : null;
    return CacheMeta(
      storedAt: now,
      maxAge: directives == null ? maxAge : (_seconds(directives['max-age']) ?? _expiresLifetime(headers, now)),
      staleWhileRevalidate: directives == null ? staleWhileRevalidate : _seconds(directives['stale-while-revalidate']),
      staleIfError: directives == null ? staleIfError : _seconds(directives['stale-if-error']),
      noCache: directives == null ? noCache : directives.containsKey('no-cache'),
      mustRevalidate: directives == null ? mustRevalidate : directives.containsKey('must-revalidate'),
      etag: headers['etag'] ?? etag,
      lastModified: headers['last-modified'] ?? lastModified,
    );
  }

  Duration _age(DateTime now) => now.difference(storedAt);

  /// Usable without asking the server
  bool isFresh(DateTime now) => !noCache && _age(now) < Duration(seconds: maxAge ?? 0);

  /// Usable while the server is asked in the background
  bool canServeWhileRevalidating(DateTime now) =>
      !noCache && !mustRevalidate && _age(now) < Duration(seconds: (maxAge ?? 0) + (staleWhileRevalidate ?? 0));

  /// Usable when the server cannot be reached or fails
  bool canServeOnError(DateTime now) =>
      staleIfError != null && !mustRevalidate && _age(now) < Duration(seconds: (maxAge ?? 0) + staleIfError!);

  Map<String, Object?> toJson() => {
    'storedAt': storedAt.millisecondsSinceEpoch,
    'maxAge': maxAge,
    'swr': staleWhileRevalidate,
    'sie': staleIfError,
    'noCache': noCache,
    'mustRevalidate': mustRevalidate,
    'etag': etag,
    'lastModified': lastModified,
  };

  static CacheMeta? fromJson(Object? json) {
    if (json case {'storedAt': final int storedAt, 'noCache': final bool noCache}) {
      return CacheMeta(
        storedAt: DateTime.fromMillisecondsSinceEpoch(storedAt, isUtc: true),
        maxAge: json['maxAge'] as int?,
        staleWhileRevalidate: json['swr'] as int?,
        staleIfError: json['sie'] as int?,
        noCache: noCache,
        mustRevalidate: json['mustRevalidate'] == true,
        etag: json['etag'] as String?,
        lastModified: json['lastModified'] as String?,
      );
    }
    return null;
  }

  static Map<String, String?> _directives(String? value) {
    final directives = <String, String?>{};
    for (final part in (value ?? '').split(',')) {
      final directive = part.trim();
      if (directive.isEmpty) {
        continue;
      }
      final equals = directive.indexOf('=');
      if (equals < 0) {
        directives[directive.toLowerCase()] = null;
      } else {
        directives[directive.substring(0, equals).trim().toLowerCase()] = directive
            .substring(equals + 1)
            .trim()
            .replaceAll('"', '');
      }
    }
    return directives;
  }

  static int? _seconds(String? value) {
    final seconds = int.tryParse(value ?? '');
    return seconds == null || seconds < 0 ? null : seconds;
  }

  static int? _expiresLifetime(Map<String, String> headers, DateTime now) {
    final expires = headers['expires'];
    if (expires == null) {
      return null;
    }
    try {
      final date = headers['date'];
      final base = date == null ? now : HttpDate.parse(date);
      return math.max(0, HttpDate.parse(expires).difference(base).inSeconds);
    } on HttpException {
      // An Expires that is not a date means already expired (RFC 9111 5.3)
      return 0;
    } on FormatException {
      return 0;
    }
  }
}

/// A cached body on disk
@immutable
class CachedImage {
  const CachedImage(this.key, this.file, this.meta, this.length);

  final String key;
  final File file;
  final CacheMeta meta;

  /// The length of the body
  final int length;

  CachedImage withMeta(CacheMeta meta) => CachedImage(key, file, meta, length);
}

/// A body being written, made visible by [commit] only
class CacheWriter {
  CacheWriter._(this._cache, this._key, this._temporary, this._sink, this._limit);

  final RemoteImageCache _cache;
  final String _key;
  final File _temporary;
  final IOSink _sink;
  final int _limit;
  int _length = 0;
  bool _failed = false;

  void add(List<int> chunk) {
    if (_failed) {
      return;
    }
    _length += chunk.length;
    if (_length > _limit) {
      // Too large to keep: one original must not push hundreds of thumbnails out
      _failed = true;
      return;
    }
    _sink.add(chunk);
  }

  Future<void> commit() async {
    try {
      await _sink.close();
      if (_failed) {
        await _delete(_temporary);
        return;
      }
      final file = _cache._fileOf(_key);
      await _temporary.rename(file.path);
      _cache._added(_key, RemoteImageCache.headerSize + _length);
    } catch (error) {
      // A full disk, or on Windows the old file open by a reader at that moment: the next request writes it again
      _log.fine('An image was not kept in the cache: $error');
      await _delete(_temporary);
    }
  }

  Future<void> discard() async {
    try {
      await _sink.close();
    } catch (_) {
      // Already failed: only the file is left to remove
    }
    await _delete(_temporary);
  }

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // Gone already, or held by the system for a moment; the next clear removes it
    }
  }
}

class RemoteImageCache {
  RemoteImageCache({Future<Directory> Function()? folder, this.maxBytes = defaultMaxBytes})
    : _folderOf = folder ?? _defaultFolder;

  static final instance = RemoteImageCache();

  /// The size of the phones' image caches
  static const defaultMaxBytes = 1024 * 1024 * 1024;

  static const headerSize = 512;
  static const _magic = [0x49, 0x52, 0x43, 0x31]; // "IRC1"

  final int maxBytes;
  final Future<Directory> Function() _folderOf;
  Directory? _folder;
  Future<Directory>? _folderReady;

  /// Size and last use of each file, read from the folder once, kept up to date afterwards
  final Map<String, ({int size, DateTime used})> _index = {};

  /// Temporary files named after a later time are this run's writes
  final int _startedAt = DateTime.now().microsecondsSinceEpoch;
  Future<void>? _indexed;
  bool _indexReady = false;
  int _total = 0;
  bool _evicting = false;

  static Future<Directory> _defaultFolder() async =>
      Directory(p.join((await getApplicationCacheDirectory()).path, 'remote_images'));

  int get maxEntryBytes => maxBytes ~/ 8;

  /// The bytes the cache holds, once the folder was read
  int get totalBytes => _total;

  String keyOf(String url) => sha256.convert(utf8.encode(url)).toString();

  Future<Directory> _ensureFolder() => _folderReady ??= _openFolder();

  Future<Directory> _openFolder() async {
    final folder = _folder = await _folderOf();
    await folder.create(recursive: true);
    unawaited(_ensureIndex());
    return folder;
  }

  File _fileOf(String key) => File(p.join(_folder!.path, '$key.img'));

  /// The entry of [key], null when there is none or it cannot be read
  Future<CachedImage?> lookup(String key) async {
    await _ensureFolder();
    final file = _fileOf(key);
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final length = await raf.length();
      if (length < headerSize) {
        return null;
      }
      final header = await raf.read(headerSize);
      final meta = _readHeader(header);
      if (meta == null) {
        return null;
      }
      return CachedImage(key, file, meta, length - headerSize);
    } on FileSystemException {
      return null;
    } finally {
      await raf?.close();
    }
  }

  /// The body of [entry] in a buffer of `package:ffi`'s malloc, which the image loader frees; null when the file
  /// went away meanwhile
  Future<({Pointer<Uint8> pointer, int length})?> readBody(CachedImage entry) async {
    if (entry.length <= 0) {
      return null;
    }
    final pointer = malloc<Uint8>(entry.length);
    RandomAccessFile? raf;
    try {
      raf = await entry.file.open();
      await raf.setPosition(headerSize);
      final target = pointer.asTypedList(entry.length);
      var read = 0;
      while (read < entry.length) {
        final count = await raf.readInto(target, read);
        if (count <= 0) {
          throw const FileSystemException('The cached image is shorter than its header says');
        }
        read += count;
      }
      _used(entry.key);
      return (pointer: pointer, length: entry.length);
    } on FileSystemException {
      malloc.free(pointer);
      return null;
    } finally {
      await raf?.close();
    }
  }

  /// Rewrites the metadata of [entry] after a 304, in place
  Future<void> updateMeta(CachedImage entry, CacheMeta meta) async {
    final header = _header(meta);
    if (header == null) {
      return;
    }
    RandomAccessFile? raf;
    try {
      // append opens for writing without truncating; the header is rewritten at the start
      raf = await entry.file.open(mode: FileMode.append);
      await raf.setPosition(0);
      await raf.writeFrom(header);
      _used(entry.key);
    } on FileSystemException catch (error) {
      _log.fine('The cache metadata of an image was not refreshed: $error');
    } finally {
      await raf?.close();
    }
  }

  /// Starts writing the body of [key] with [meta]; null when it cannot be kept
  Future<CacheWriter?> begin(String key, CacheMeta meta) async {
    final header = _header(meta);
    if (header == null) {
      return null;
    }
    try {
      final folder = await _ensureFolder();
      final temporary = File(p.join(folder.path, '$key.${DateTime.now().microsecondsSinceEpoch}.tmp'));
      // Closed by the writer's commit or discard
      // ignore: close_sinks
      final sink = temporary.openWrite()..add(header);
      return CacheWriter._(this, key, temporary, sink, maxEntryBytes);
    } on FileSystemException catch (error) {
      _log.fine('An image cannot be kept in the cache: $error');
      return null;
    }
  }

  /// Removes every file; the bytes freed, as the phones' clearCache answers
  Future<int> clear() async {
    final folder = await _ensureFolder();
    await _ensureIndex();
    var freed = 0;
    await for (final entry in folder.list()) {
      if (entry is! File) {
        continue;
      }
      try {
        final size = await entry.length();
        await entry.delete();
        freed += size;
      } on FileSystemException {
        // Open by a reader right now; it goes at the next clear
        continue;
      }
    }
    _index.clear();
    _total = 0;
    return freed;
  }

  Uint8List? _header(CacheMeta meta) {
    final json = utf8.encode(jsonEncode(meta.toJson()));
    if (json.length > headerSize - 6) {
      return null;
    }
    final header = Uint8List(headerSize)..fillRange(0, headerSize, 0x20);
    header.setAll(0, _magic);
    ByteData.sublistView(header).setUint16(4, json.length);
    header.setAll(6, json);
    return header;
  }

  static CacheMeta? _readHeader(Uint8List header) {
    if (header.length < headerSize || !listEquals(header.sublist(0, 4), _magic)) {
      return null;
    }
    final length = ByteData.sublistView(header).getUint16(4);
    if (length > headerSize - 6) {
      return null;
    }
    try {
      return CacheMeta.fromJson(jsonDecode(utf8.decode(header.sublist(6, 6 + length))));
    } on FormatException {
      return null;
    }
  }

  Future<void> _ensureIndex() => _indexed ??= _readIndex();

  Future<void> _readIndex() async {
    final path = _folder!.path;
    final startedAt = _startedAt;
    try {
      // A full cache holds tens of thousands of files: their sizes and dates are read off the UI isolate
      final found = await Isolate.run(() => _scanFolder(path, startedAt));
      for (final (:key, :size, :used) in found) {
        // A write of this run may have come first
        if (!_index.containsKey(key)) {
          _index[key] = (size: size, used: used);
          _total += size;
        }
      }
    } on FileSystemException catch (error) {
      _log.warning('The image cache folder cannot be read: $error');
    }
    _indexReady = true;
    await _evictIfNeeded();
  }

  /// The entries of the folder at [path]; removes the temporary files left by a crash or a closed app in the middle of
  /// a write, those written since [startedAt] (microseconds) being this run's writes in progress
  static List<({String key, int size, DateTime used})> _scanFolder(String path, int startedAt) {
    final found = <({String key, int size, DateTime used})>[];
    for (final entry in Directory(path).listSync()) {
      if (entry is! File) {
        continue;
      }
      final name = p.basename(entry.path);
      if (name.endsWith('.tmp')) {
        final parts = name.split('.');
        final writtenAt = parts.length >= 3 ? int.tryParse(parts[parts.length - 2]) : null;
        if (writtenAt == null || writtenAt < startedAt) {
          try {
            entry.deleteSync();
          } on FileSystemException {
            // Held by the system for a moment: the next start removes it
          }
        }
        continue;
      }
      if (!name.endsWith('.img')) {
        continue;
      }
      try {
        final stat = entry.statSync();
        found.add((key: p.basenameWithoutExtension(name), size: stat.size, used: stat.modified));
      } on FileSystemException {
        // Removed meanwhile
        continue;
      }
    }
    return found;
  }

  void _added(String key, int size) {
    final previous = _index[key];
    _total += size - (previous?.size ?? 0);
    _index[key] = (size: size, used: DateTime.now());
    unawaited(_evictIfNeeded());
  }

  void _used(String key) {
    final entry = _index[key];
    if (entry == null) {
      return;
    }
    final now = DateTime.now();
    // The modification time is the last use the next start reads: refreshed once a day at most
    if (now.difference(entry.used) > const Duration(days: 1)) {
      unawaited(_touch(key, now));
    }
    _index[key] = (size: entry.size, used: now);
  }

  Future<void> _touch(String key, DateTime now) async {
    try {
      await _fileOf(key).setLastModified(now);
    } on FileSystemException {
      // Only the order of eviction after a restart depends on it
    }
  }

  Future<void> _evictIfNeeded() async {
    if (_evicting || !_indexReady || _total <= maxBytes) {
      return;
    }
    _evicting = true;
    try {
      final target = maxBytes * 9 ~/ 10;
      final oldestFirst = _index.entries.toList()..sort((a, b) => a.value.used.compareTo(b.value.used));
      for (final MapEntry(:key, :value) in oldestFirst) {
        if (_total <= target) {
          break;
        }
        try {
          await _fileOf(key).delete();
        } on FileSystemException {
          // Open by a reader on Windows: kept for now
          continue;
        }
        _index.remove(key);
        _total -= value.size;
      }
    } finally {
      _evicting = false;
    }
  }
}
