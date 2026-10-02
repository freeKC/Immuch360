// The video thumbnails of the network share browser kept on disk, so that a folder shown again does not have its
// videos read again from the share.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('VideoThumbnailDiskCache');

/// JPEG thumbnails in a folder of their own, one file per video, named after the source, the path, the size and the
/// date of the video: a video changed on its share gets a new thumbnail. At most [maxBytes] in all: past that, the
/// files used the longest ago go first. Reading a thumbnail counts as a use.
///
/// Any error of the file system is a miss: the thumbnail is taken again from the video.
class VideoThumbnailDiskCache {
  VideoThumbnailDiskCache(this._directory, {this.maxBytes = defaultMaxBytes});

  /// 200 MB, some 7000 thumbnails of 400 pixels
  static const defaultMaxBytes = 200 * 1024 * 1024;

  static const _extension = '.jpg';

  final Future<Directory> Function() _directory;
  final int maxBytes;

  Future<_Index?>? _index;

  /// The thumbnail of the video [key], null when there is none
  Future<Uint8List?> read(NetworkMediaKey key) async {
    final index = await _ready();
    final name = fileNameOf(key);
    if (index == null || !index.entries.containsKey(name)) {
      return null;
    }
    final file = File(p.join(index.directory.path, name));
    try {
      final bytes = await file.readAsBytes();
      final now = DateTime.now();
      index.used(name, now);
      // The last use, for the next time the app starts
      unawaited(file.setLastModified(now).catchError((_) {}));
      return bytes.isEmpty ? null : bytes;
    } catch (error) {
      _log.fine('Cannot read the thumbnail $name: $error');
      index.remove(name);
      return null;
    }
  }

  /// Keeps [bytes] as the thumbnail of the video [key], then drops the thumbnails used the longest ago while there
  /// are more than [maxBytes] in all
  Future<void> write(NetworkMediaKey key, Uint8List bytes) async {
    final index = await _ready();
    if (index == null || bytes.isEmpty) {
      return;
    }
    final name = fileNameOf(key);
    final file = File(p.join(index.directory.path, name));
    // Written aside then renamed: a read meanwhile, or the app stopped meanwhile, never sees half a file
    final partial = File('${file.path}.part');
    try {
      await partial.writeAsBytes(bytes, flush: true);
      await partial.rename(file.path);
    } catch (error) {
      _log.fine('Cannot write the thumbnail $name: $error');
      await _deleteQuietly(partial);
      return;
    }
    index.add(name, bytes.length, DateTime.now());
    await _evict(index);
  }

  /// How many bytes of thumbnails are kept
  Future<int> get totalBytes async => (await _ready())?.totalBytes ?? 0;

  /// The name of the file of the thumbnail of the video [key]
  static String fileNameOf(NetworkMediaKey key) {
    final modified = key.modified?.toUtc().microsecondsSinceEpoch;
    final id = [key.sourceId, key.path, key.size ?? '', modified ?? ''].join('\n');
    return '${sha1.convert(utf8.encode(id))}$_extension';
  }

  Future<_Index?> _ready() => _index ??= _load();

  /// The files of the folder, read once
  Future<_Index?> _load() async {
    try {
      final directory = await _directory();
      await directory.create(recursive: true);
      final index = _Index(directory);
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        final name = p.basename(entity.path);
        if (!name.endsWith(_extension)) {
          // A write the app did not finish
          await _deleteQuietly(entity);
          continue;
        }
        final stat = entity.statSync();
        index.add(name, stat.size, stat.modified);
      }
      await _evict(index);
      return index;
    } catch (error) {
      _log.warning('No disk cache for the video thumbnails: $error');
      return null;
    }
  }

  Future<void> _evict(_Index index) async {
    if (index.totalBytes <= maxBytes) {
      return;
    }
    final oldestFirst = index.entries.entries.toList()..sort((a, b) => a.value.used.compareTo(b.value.used));
    for (final entry in oldestFirst) {
      if (index.totalBytes <= maxBytes) {
        break;
      }
      index.remove(entry.key);
      await _deleteQuietly(File(p.join(index.directory.path, entry.key)));
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // Gone already
    }
  }
}

typedef _Entry = ({int size, DateTime used});

/// What the folder holds, kept up to date by the cache
class _Index {
  _Index(this.directory);

  final Directory directory;
  final entries = <String, _Entry>{};
  int totalBytes = 0;

  void add(String name, int size, DateTime used) {
    remove(name);
    entries[name] = (size: size, used: used);
    totalBytes += size;
  }

  void used(String name, DateTime when) {
    final entry = entries[name];
    if (entry != null) {
      entries[name] = (size: entry.size, used: when);
    }
  }

  void remove(String name) {
    final entry = entries.remove(name);
    if (entry != null) {
      totalBytes -= entry.size;
    }
  }
}
