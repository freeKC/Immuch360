// The thumbnails of the folder library on disk, so that a timeline of thousands of photos scrolls without decoding
// every original again at each start (the phones get theirs from the system: MediaStore, PhotoKit).
//
// One file per photo and size bucket under <cache folder>/thumbs (a JPEG, or a PNG for a picture with transparency,
// see renderThumbnail), named from the asset id, the bucket and the size and modification date of the file: a file
// edited in place gets new thumbnails, and the old ones age out. The cache is
// kept under a size limit by removing the files used longest ago; the measuring and the removing run in a background
// isolate, since the folder can hold hundreds of thousands of files.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The file behind a thumbnail, as the cache tells its versions apart
@immutable
class ThumbnailSource {
  final String assetId;
  final int length;
  final DateTime modified;

  const ThumbnailSource({required this.assetId, required this.length, required this.modified});
}

class ThumbnailCache {
  ThumbnailCache({Future<Directory> Function()? directory, this.maxBytes = defaultMaxBytes})
    : _directory = directory ?? _defaultDirectory;

  /// The one the app uses (DesktopLocalImageApi); [clear] empties it
  static final shared = ThumbnailCache();

  /// The size the cache is brought back under, by removing the thumbnails used longest ago
  static const defaultMaxBytes = 2 * 1024 * 1024 * 1024;

  /// The boxes thumbnails are made for: the timeline's tiles (kThumbnailResolution) and a larger one for the other
  /// small views. A request larger than the last one reads the file itself.
  static const buckets = [320, 1024];

  static final _log = Logger('ThumbnailCache');

  final int maxBytes;
  final Future<Directory> Function() _directory;
  Future<Directory>? _root;

  /// The shard folders made in this session
  final _shards = <String>{};

  /// The thumbnails already marked as used in this session (one date change per file and session, not per read)
  final _touched = <String>{};

  /// The bytes in the cache, once measured; null until then
  int? _knownBytes;
  Future<void>? _measuring;
  Future<void>? _trimming;

  static Future<Directory> _defaultDirectory() async =>
      Directory(p.join((await getApplicationCacheDirectory()).path, 'thumbs'));

  /// The bucket that serves a request for a [width] by [height] box, null for a request that needs the file itself
  /// (unsized, the whole image, or larger than the largest bucket)
  static int? bucketFor(int width, int height) {
    if (width <= 0 || height <= 0) {
      return null;
    }
    final longest = math.max(width, height);
    for (final bucket in buckets) {
      if (longest <= bucket) {
        return bucket;
      }
    }
    return null;
  }

  /// The extension of the thumbnails, whatever their format: the engine reads the format from the bytes, and one
  /// name per thumbnail means one file to open per read
  static const extension = '.thumb';

  /// The path of a thumbnail inside the cache folder: a shard folder of 256, then the name, which never holds the
  /// asset id itself (ids of the folder library are already hashes, but the cache does not rely on it)
  static String relativePath(ThumbnailSource source, int bucket) {
    final key = sha1.convert(utf8.encode(source.assetId)).toString();
    final version = '${source.length.toRadixString(36)}-${source.modified.millisecondsSinceEpoch.toRadixString(36)}';
    return p.join(key.substring(0, 2), '$key-$bucket-$version$extension');
  }

  Future<Directory> get root => _root ??= _directory();

  /// The cached thumbnail of [source] in [bucket], null when there is none
  Future<Uint8List?> read(ThumbnailSource source, int bucket) async {
    final relative = relativePath(source, bucket);
    final file = File(p.join((await root).path, relative));
    try {
      final bytes = await file.readAsBytes();
      if (_touched.add(relative)) {
        // The modification date says when it was last used, for the trimming
        unawaited(file.setLastModified(DateTime.now()).catchError((_) {}));
      }
      return bytes.isEmpty ? null : bytes;
    } on FileSystemException {
      return null;
    }
  }

  /// Keeps [encoded] as the thumbnail of [source] in [bucket]: written beside its name, then renamed, so that a
  /// reader never sees half a file
  Future<void> write(ThumbnailSource source, int bucket, Uint8List encoded) async {
    final folder = (await root).path;
    final relative = relativePath(source, bucket);
    final file = File(p.join(folder, relative));
    final shard = p.dirname(relative);
    final partial = File('${file.path}.${math.Random().nextInt(1 << 30).toRadixString(36)}.part');
    try {
      if (_shards.add(shard)) {
        await Directory(p.join(folder, shard)).create(recursive: true);
      }
      await partial.writeAsBytes(encoded);
      await partial.rename(file.path);
      _touched.add(relative);
    } on FileSystemException catch (error) {
      _log.fine('A thumbnail could not be kept: ${error.message}');
      try {
        await partial.delete();
      } on FileSystemException {
        // never written
      }
      return;
    }
    _added(encoded.length);
  }

  /// Removes every thumbnail; the bytes freed
  Future<int> clear() async {
    final folder = await root;
    await _measuring;
    await _trimming;
    final freed = await _Background.deleteAll(folder.path);
    _knownBytes = 0;
    _shards.clear();
    _touched.clear();
    return freed;
  }

  /// Brings the cache under [maxBytes] now; the bytes it holds after
  @visibleForTesting
  Future<int> trimNow() async {
    final folder = (await root).path;
    final limit = maxBytes;
    final left = await _Background.trim(folder, limit, (limit * 0.9).floor());
    _knownBytes = left;
    return left;
  }

  void _added(int bytes) {
    final known = _knownBytes;
    if (known == null) {
      // Measured once per session, the first time a thumbnail is written
      _measuring ??= () async {
        final folder = (await root).path;
        try {
          _knownBytes = await _Background.measure(folder);
        } catch (error) {
          _log.fine('The thumbnail cache could not be measured: $error');
          _knownBytes = 0;
        }
        _checkLimit();
      }();
      return;
    }
    _knownBytes = known + bytes;
    _checkLimit();
  }

  void _checkLimit() {
    final known = _knownBytes;
    if (known == null || known <= maxBytes || _trimming != null) {
      return;
    }
    _trimming = trimNow()
        .catchError((Object error) {
          _log.fine('The thumbnail cache could not be trimmed: $error');
          return _knownBytes ?? 0;
        })
        .whenComplete(() => _trimming = null);
  }
}

/// The folder walks in a background isolate. Each closure sent there captures only its strings and numbers: a closure
/// made inside a method of the cache would carry the cache along, futures included, which cannot be sent.
abstract final class _Background {
  static Future<int> measure(String folder) => Isolate.run(() => _measure(folder));

  static Future<int> trim(String folder, int limit, int target) => Isolate.run(() => _trim(folder, limit, target));

  static Future<int> deleteAll(String folder) => Isolate.run(() => _deleteAll(folder));
}

/// The bytes of the thumbnails under [folder]
int _measure(String folder) {
  var total = 0;
  final root = Directory(folder);
  if (!root.existsSync()) {
    return 0;
  }
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is File && entity.path.endsWith(ThumbnailCache.extension)) {
      total += entity.statSync().size;
    }
  }
  return total;
}

/// Removes the thumbnails used longest ago until the cache holds [target] bytes or less, when it holds more than
/// [limit]; also removes the leftovers of interrupted writes. The bytes left.
int _trim(String folder, int limit, int target) {
  final root = Directory(folder);
  if (!root.existsSync()) {
    return 0;
  }
  final files = <(File, int, DateTime)>[];
  var total = 0;
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    final stat = entity.statSync();
    if (entity.path.endsWith('.part')) {
      // An interrupted write of an earlier session (a running one is younger than a minute)
      if (DateTime.now().difference(stat.modified) > const Duration(minutes: 1)) {
        _deleteQuietly(entity);
      }
      continue;
    }
    files.add((entity, stat.size, stat.modified));
    total += stat.size;
  }
  if (total <= limit) {
    return total;
  }
  files.sort((a, b) => a.$3.compareTo(b.$3));
  for (final (file, size, _) in files) {
    if (total <= target) {
      break;
    }
    if (_deleteQuietly(file)) {
      total -= size;
    }
  }
  return total;
}

/// Removes everything under [folder]; the bytes freed
int _deleteAll(String folder) {
  final root = Directory(folder);
  if (!root.existsSync()) {
    return 0;
  }
  final freed = _measure(folder);
  try {
    root.deleteSync(recursive: true);
  } on FileSystemException {
    // A thumbnail being read stays (Windows keeps open files); the others are gone
  }
  return freed;
}

bool _deleteQuietly(File file) {
  try {
    file.deleteSync();
    return true;
  } on FileSystemException {
    // in use by a reader, or already gone
    return false;
  }
}
