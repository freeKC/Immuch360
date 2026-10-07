// The clips fetched from the Tapo cameras live in the cache directory of the app, one folder per camera: the system
// may reclaim them, and removing a camera deletes its folder. Layout (Tapo design 3.7):
// `<cache>/tapo/<sourceId>/clips/<start>-<end>.mov` and `<cache>/tapo/<sourceId>/thumbs/<start>.jpg`, the bounds in UTC
// seconds: only validated ids and integers make a path, never a text the camera sent. The clips of all the cameras
// together stay under [tapoClipCacheLimit]; the ones played least recently go first.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The form of NetworkSourcesNotifier.newId. Only such an id becomes a folder name, so that no stored value can point
/// a deletion elsewhere.
final _sourceId = RegExp(r'^[0-9a-f]{16}$');

/// The most bytes of clips kept, all cameras together: about 110 minutes at the 1.2 Mbit/s of a C510W
const tapoClipCacheLimit = 1024 * 1024 * 1024;

/// `<cache directory of the app>/tapo`; [cacheRoot] gives that directory (another one in the tests, and for the file
/// system of a camera in them)
Future<Directory> tapoCacheRoot({Future<Directory> Function() cacheRoot = getApplicationCacheDirectory}) async =>
    Directory(p.join((await cacheRoot()).path, 'tapo'));

/// `<cache directory of the app>/tapo/<sourceId>`; not created here. Throws an [ArgumentError] for an id that is not
/// 16 lower case hex digits.
Future<Directory> tapoCameraCacheDirectory(
  String sourceId, {
  Future<Directory> Function() cacheRoot = getApplicationCacheDirectory,
}) async {
  if (!_sourceId.hasMatch(sourceId)) {
    throw ArgumentError.value(sourceId, 'sourceId', 'Not the id of a network source');
  }
  return Directory(p.join((await tapoCacheRoot(cacheRoot: cacheRoot)).path, sourceId));
}

/// Deletes what was fetched from the camera of [sourceId], see [tapoCameraCacheDirectory]
Future<void> deleteTapoCameraCache(
  String sourceId, {
  Future<Directory> Function() cacheRoot = getApplicationCacheDirectory,
}) async {
  final directory = await tapoCameraCacheDirectory(sourceId, cacheRoot: cacheRoot);
  try {
    await directory.delete(recursive: true);
  } on PathNotFoundException {
    // Nothing was fetched from this camera
  }
}

/// The fetched clip from [start] to [end] (UTC seconds) of the camera whose folder is [camera]
File tapoClipFile(Directory camera, int start, int end) => File(p.join(camera.path, 'clips', '$start-$end.mov'));

/// The picture of the recording that starts at [start]
File tapoThumbnailFile(Directory camera, int start) => File(p.join(camera.path, 'thumbs', '$start.jpg'));

/// The bytes the files of the camera whose folder is [camera] take
Future<int> tapoCameraCacheBytes(Directory camera) async {
  var total = 0;
  try {
    await for (final entity in camera.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
  } on PathNotFoundException {
    return 0;
  }
  return total;
}

/// Deletes the clips played least recently (their modification time, which a play sets) until the clips of all the
/// cameras under [root] take [limit] bytes at most; [keep] is never deleted (the clip just fetched)
Future<void> trimTapoClipCache(Directory root, {int limit = tapoClipCacheLimit, String? keep}) async {
  final clips = <(File, int, DateTime)>[];
  var total = 0;
  try {
    await for (final camera in root.list(followLinks: false)) {
      if (camera is! Directory) {
        continue;
      }
      final folder = Directory(p.join(camera.path, 'clips'));
      if (!folder.existsSync()) {
        continue;
      }
      await for (final entity in folder.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.mov')) {
          final stat = entity.statSync();
          clips.add((entity, stat.size, stat.modified));
          total += stat.size;
        }
      }
    }
  } on PathNotFoundException {
    return;
  }
  if (total <= limit) {
    return;
  }
  clips.sort((a, b) => a.$3.compareTo(b.$3));
  for (final (file, size, _) in clips) {
    if (total <= limit) {
      break;
    }
    if (file.path == keep) {
      continue;
    }
    try {
      await file.delete();
      total -= size;
    } on FileSystemException {
      // Gone already, or in use: the next trim tries again
    }
  }
}
