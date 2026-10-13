// Files opened with the program on a computer: "Open with" in the file manager, files or a folder dropped on the
// program or on its window, its command line, and the files a later start hands over (single_instance.dart). Each one
// becomes a local asset read with the rules of the folder library and of its 360° scan, so that it shows as the same
// file found in a chosen folder: its frame, date, place and duration (library_metadata.dart), and whether it is 360°,
// VR180, 3D or the raw file of a 360° camera (probeLocalPanoramaFile). It never joins the library: nothing is written
// to its index or to the local tables, and the viewers find its file here (DesktopStorageRepository).
//
// Its id is the one a scan gives the same file (FolderLibrary.idOfPath), so that the choices made on it (viewed as
// 360°, a 3D layout, a coverage) hold the next time it is opened, and once its folder is added to the library.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_metadata.dart';
import 'package:immich_mobile/desktop/library/placeholder_check.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/local_panorama.service.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('OpenedFiles');

/// The most photos and videos one opening shows: a folder of a camera card holds a few thousand
const maxOpenedFiles = 5000;

/// A photo or a video opened with the program: its [file] for the code that reads it, the [asset] the viewers show,
/// and what its content told of its projection ([record], the same as the 360° scan writes)
class OpenedFile {
  const OpenedFile({required this.file, required this.asset, required this.record});

  final LibraryFile file;
  final LocalAsset asset;
  final LocalPanoramaRecord record;

  String get path => file.path;

  /// Whether it opens in 360°: it declares a 360° projection, or it is the raw file of a 360° camera
  bool get is360 => record.isPanorama;
}

/// The photos and videos found in what the program was given at once, in their order: each file as given, then the
/// files of each folder by name. [fromFolder] tells whether a folder was among what was given.
class OpenedBatch {
  const OpenedBatch(this.files, {required this.fromFolder});

  final List<OpenedFile> files;
  final bool fromFolder;

  List<LocalAsset> get assets => [for (final file in files) file.asset];
}

/// The files opened with the program in this session, by their ids as local assets. Kept until the app closes: a
/// viewer, a thumbnail or the 360° player may read a file long after it was opened.
abstract final class OpenedFiles {
  static final _files = <String, LibraryFile>{};

  /// The file opened with the program whose asset is [assetId], null for any other asset
  static LibraryFile? file(String assetId) => _files[assetId];

  /// Keeps [files] for the code that reads them by their asset ids
  static void remember(Iterable<OpenedFile> files) {
    for (final opened in files) {
      _files[opened.asset.id] = opened.file;
    }
  }

  /// The file named [siblingName] next to the opened file [assetId], as an opened file itself: the other lens of a
  /// split Insta360 recording (an X3 pair), which the raw video player needs. Null when [assetId] was not opened with
  /// the program, or when no such file is there. [ids] as for [readOpenedPaths].
  static Future<LocalAsset?> sibling(String assetId, String siblingName, {OpenedFileIds? ids}) async {
    final opened = _files[assetId];
    if (opened == null) {
      return null;
    }
    final path = p.join(p.dirname(opened.path), siblingName);
    // ignore: avoid_slow_async_io
    if (!await File(path).exists()) {
      return null;
    }
    final batch = await readOpenedPaths([path], ids: ids);
    remember(batch.files);
    return batch.files.firstOrNull?.asset;
  }

  @visibleForTesting
  static void clear() => _files.clear();
}

/// The ids of the files at [paths] as local assets, by path (see FolderLibrary.idOfPath)
typedef OpenedFileIds = Future<Map<String, String>> Function(List<String> paths);

/// Reads what the program was given at once ([given], the paths of files and folders), in a background isolate: see
/// [listOpenedPaths] for what is taken, then each file as the folder library and its 360° scan read it. Never throws for
/// a file that cannot be read: it is left out. [ids] gives the ids of the files, those of the folder library by default.
Future<OpenedBatch> readOpenedPaths(Iterable<String> given, {OpenedFileIds? ids, int maxFiles = maxOpenedFiles}) async {
  final paths = given.toList();
  final reads = await Isolate.run(() => _readInBackground(paths, maxFiles));
  final byPath = await (ids ?? libraryIdsOf)([for (final read in reads.files) read.path]);
  final now = DateTime.now();
  return OpenedBatch([
    for (final read in reads.files)
      if (byPath[read.path] case final id?) read.withId(id, checkedAt: now),
  ], fromFolder: reads.fromFolder);
}

/// The ids the folder library gives the files at [paths], the volume of each folder read once; a file whose volume
/// cannot be read gets an id of its own (see [openedFileId])
Future<Map<String, String>> libraryIdsOf(List<String> paths) async {
  if (paths.isEmpty) {
    return const {};
  }
  final library = await FolderLibrary.shared();
  final context = library.rules.context;
  final folders = <String, String Function(String name)?>{};
  final ids = <String, String>{};
  for (final path in paths) {
    final absolute = context.normalize(context.absolute(path));
    final idsInFolder = folders.putIfAbsent(
      context.dirname(absolute),
      () => library.idsInFolder(context.dirname(absolute)),
    );
    ids[path] = idsInFolder?.call(context.basename(absolute)) ?? openedFileId(library, absolute);
  }
  return ids;
}

/// The id of a file opened with the program on a volume the library cannot read: "o" and the first 20 bytes of
/// HMAC-SHA-256 of its full path, with the key of the library's ids (see LibraryIds), so that it never carries the
/// path itself and never meets the id of a file of the library ("f")
String openedFileId(FolderLibrary library, String path) {
  final absolute = library.rules.context.normalize(library.rules.context.absolute(path));
  return 'o${library.index.ids.file('opened:', library.rules.caseFold ? absolute.toLowerCase() : absolute).substring(1)}';
}

/// What [given] holds, as the program shows it: a photo or a video as it is; the photos and videos of a folder, by
/// name, without its subfolders; anything else, hidden files, the files a cloud client keeps online only (reading
/// them would download them, see placeholder_check.dart) and the same file twice left out; at most [maxFiles].
({List<String> paths, bool fromFolder}) listOpenedPaths(
  Iterable<String> given, {
  int maxFiles = maxOpenedFiles,
  FileAttributesReader? attributes,
}) {
  final read = attributes ?? systemFileAttributesReader();
  final paths = <String>[];
  final seen = <String>{};
  var fromFolder = false;

  void take(String path) {
    if (paths.length < maxFiles && seen.add(p.normalize(path))) {
      paths.add(path);
    }
  }

  for (final path in given) {
    if (paths.length >= maxFiles) {
      break;
    }
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.file) {
      if (mediaKindOfName(p.basename(path)) != null) {
        take(path);
      }
      continue;
    }
    if (type != FileSystemEntityType.directory) {
      continue;
    }
    fromFolder = true;
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(path).listSync(followLinks: false);
    } on FileSystemException catch (error) {
      _log.info('Cannot list a folder opened with the program: ${error.message}');
      continue;
    }
    final files = [
      for (final entry in entries)
        if (entry is File) entry.path,
    ]..sort((a, b) => compareNatural(p.basename(a), p.basename(b)));
    for (final file in files) {
      final name = p.basename(file);
      if (mediaKindOfName(name) == null || isSkippedFileName(name)) {
        continue;
      }
      final fileAttributes = read?.call(file);
      if (fileAttributes != null && isCloudPlaceholder(fileAttributes)) {
        continue;
      }
      take(file);
    }
  }
  if (paths.length >= maxFiles) {
    _log.info('Opened with the program: the first $maxFiles photos and videos only');
  }
  return (paths: paths, fromFolder: fromFolder);
}

/// [a] before [b] as a file manager sorts names: the digits as numbers ("IMG_2" before "IMG_10"), case aside
int compareNatural(String a, String b) {
  final digits = RegExp(r'\d+');
  final partsA = _naturalParts(a.toLowerCase(), digits);
  final partsB = _naturalParts(b.toLowerCase(), digits);
  for (var i = 0; i < math.min(partsA.length, partsB.length); i++) {
    final x = partsA[i];
    final y = partsB[i];
    final order = x is int && y is int ? x.compareTo(y) : x.toString().compareTo(y.toString());
    if (order != 0) {
      return order;
    }
  }
  final byLength = partsA.length.compareTo(partsB.length);
  return byLength != 0 ? byLength : a.compareTo(b);
}

List<Object> _naturalParts(String name, RegExp digits) {
  final parts = <Object>[];
  var start = 0;
  for (final match in digits.allMatches(name)) {
    if (match.start > start) {
      parts.add(name.substring(start, match.start));
    }
    // Beyond what an int holds, compared as text
    parts.add(int.tryParse(match.group(0)!) ?? match.group(0)!);
    start = match.end;
  }
  if (start < name.length) {
    parts.add(name.substring(start));
  }
  return parts;
}

/// A file opened with the program as [readOpenedFile] read it, before it gets its id
class OpenedFileRead {
  const OpenedFileRead({required this.file, required this.asset, required this.probe});

  final LibraryFile file;
  final LocalAsset asset;
  final LocalPanoramaProbe? probe;

  String get path => file.path;

  OpenedFile withId(String id, {required DateTime checkedAt}) {
    final probe = this.probe;
    return OpenedFile(
      file: LibraryFile(
        assetId: id,
        path: file.path,
        name: file.name,
        kind: file.kind,
        size: file.size,
        modifiedMs: file.modifiedMs,
        createdSeconds: file.createdSeconds,
        mimeType: file.mimeType,
        cloudOnly: false,
        available: true,
        width: file.width,
        height: file.height,
        durationMs: file.durationMs,
      ),
      asset: asset.copyWith(id: id),
      record: LocalPanoramaRecord(
        isPanorama: probe?.isPanorama ?? false,
        halfSphere: probe?.halfSphere,
        raw360: probe?.raw360 ?? false,
        checkedAt: checkedAt,
      ),
    );
  }
}

Future<({List<OpenedFileRead> files, bool fromFolder})> _readInBackground(List<String> given, int maxFiles) async {
  final listing = listOpenedPaths(given, maxFiles: maxFiles);
  final files = <OpenedFileRead>[];
  for (final path in listing.paths) {
    try {
      final read = await readOpenedFile(path);
      if (read != null) {
        files.add(read);
      }
    } catch (error) {
      _log.info('Cannot read a file opened with the program: $error');
    }
  }
  return (files: files, fromFolder: listing.fromFolder);
}

/// Reads the photo or the video at [path] as a scan of the folder library reads it (see LibraryScanner and
/// FolderLibrarySyncApi): the frame as shown, the date it was taken or else the date of the file, the place, the
/// duration and whether it is animated; then, for a file whose name or frame hints at 360° (isLocalPanoramaCandidate),
/// what it declares of its projection, as the 360° scan reads it (probeLocalPanoramaFile). Null for anything else.
Future<OpenedFileRead?> readOpenedFile(String path) async {
  final name = p.basename(path);
  final kind = mediaKindOfName(name);
  if (kind == null) {
    return null;
  }
  final stat = File(path).statSync();
  if (stat.type != FileSystemEntityType.file) {
    return null;
  }
  final metadata = readMediaMetadataSync(path, kind);
  final modifiedMs = stat.modified.millisecondsSinceEpoch;
  // "changed" is the creation date on Windows, the last change of the inode elsewhere: the earlier stands for when the
  // file was made, as for the scan
  final fileCreatedMs = math.min(modifiedMs, stat.changed.millisecondsSinceEpoch);
  final createdSeconds = (metadata.takenAt?.millisecondsSinceEpoch ?? fileCreatedMs) ~/ 1000;
  final isVideo = kind == LibraryMediaKind.video;
  final asset = LocalAsset(
    id: '',
    name: name,
    type: isVideo ? AssetType.video : AssetType.image,
    createdAt: DateTime.fromMillisecondsSinceEpoch(createdSeconds * 1000, isUtc: true),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(modifiedMs ~/ 1000 * 1000, isUtc: true),
    width: metadata.displayWidth,
    height: metadata.displayHeight,
    durationMs: metadata.durationMs,
    playbackStyle: isVideo
        ? AssetPlaybackStyle.video
        : metadata.animated
        ? AssetPlaybackStyle.imageAnimated
        : AssetPlaybackStyle.image,
    adjustmentTime: DateTime.fromMillisecondsSinceEpoch(modifiedMs ~/ 1000 * 1000, isUtc: true),
    latitude: metadata.latitude,
    longitude: metadata.longitude,
    isEdited: false,
  );
  LocalPanoramaProbe? probe;
  if (isLocalPanoramaCandidate(asset)) {
    try {
      probe = await probeLocalPanoramaFile(path, isVideo: isVideo, width: asset.width, height: asset.height);
    } catch (error) {
      // As the scan does: unread for now, flat until it is opened again
      _log.info('Cannot read the projection of $name: $error');
    }
  }
  return OpenedFileRead(
    file: LibraryFile(
      assetId: '',
      path: path,
      name: name,
      kind: kind,
      size: stat.size,
      modifiedMs: modifiedMs,
      createdSeconds: createdSeconds,
      mimeType: mimeTypeOfName(name),
      cloudOnly: false,
      available: true,
      width: metadata.displayWidth,
      height: metadata.displayHeight,
      durationMs: metadata.durationMs,
    ),
    asset: asset,
    probe: probe,
  );
}
