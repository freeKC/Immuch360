// A folder picked in the system picker of Android, read as a share: a DJI drone or a card reader plugged in over USB
// (a USB drive), a DJI RC 2 or another phone in File transfer mode (MTP), or a folder of the device itself chosen with
// "Browse a folder" of On this device (NetworkSourceType.deviceFolder). The Kotlin side (DocumentTreePlugin) lists a
// folder in one query and reads files at a position when they allow it; this side turns its document ids into the paths
// of the shares, so that the browser tiles, the viewers, the media bridge and "Upload to Immich" work on it as they are.
//
// Paths are the names of the folders from the one picked ("/DCIM/DJI_001/DJI_0001.JPG"); the ids the provider gives
// are learned from the listings (an MTP id means nothing once the device is plugged in again, a name does).

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/exif_head.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/document_tree_api.g.dart';
import 'package:logging/logging.dart';

final _log = Logger('DocumentTreeFileSystem');

/// The picked folder of [source] (its tree URI in [NetworkSource.share]) through [_api]
class DocumentTreeFileSystem implements NetworkFileSystem, NetworkThumbnailSource, NetworkSequentialReads {
  DocumentTreeFileSystem(
    this.source,
    this._api, {
    String Function()? unpluggedMessage,
    String Function()? stalledMessage,
    this.readTimeout = const Duration(seconds: 90),
  }) : _unpluggedMessage = unpluggedMessage ?? (() => StaticTranslations.instance.dji_import_unplugged),
       _stalledMessage = stalledMessage ?? (() => StaticTranslations.instance.dji_import_not_answering);

  /// Opens the folder of [source], a source of type [NetworkSourceType.documentTree]; no password
  static Future<NetworkFileSystem> open(NetworkSource source, String? password) async =>
      DocumentTreeFileSystem(source, DocumentTreeApi());

  /// The folder of [source], a folder of this device (a source of type [NetworkSourceType.deviceFolder]): the same
  /// reads, with the words of a folder rather than those of a drone when it goes or stops answering
  factory DocumentTreeFileSystem.deviceFolder(
    NetworkSource source,
    DocumentTreeApi api, {
    Duration readTimeout = const Duration(seconds: 90),
  }) => DocumentTreeFileSystem(
    source,
    api,
    unpluggedMessage: () => StaticTranslations.instance.device_folder_gone,
    stalledMessage: () => StaticTranslations.instance.device_folder_not_answering,
    readTimeout: readTimeout,
  );

  /// Opens the folder of [source], a source of type [NetworkSourceType.deviceFolder]; no password
  static Future<NetworkFileSystem> openDeviceFolder(NetworkSource source, String? password) async =>
      DocumentTreeFileSystem.deviceFolder(source, DocumentTreeApi());

  @override
  final NetworkSource source;
  final DocumentTreeApi _api;
  final String Function() _unpluggedMessage;
  final String Function() _stalledMessage;

  /// Longest wait for one read of the bridge (8 MB at most). The Kotlin side stops a read that made no progress for
  /// 30 s; this is the net under it, for a device that does not let go even then.
  final Duration readTimeout;

  /// The reads that ran past [readTimeout] and have not ended yet: meanwhile the device is taken as not answering, and
  /// every read fails at once rather than wait behind them
  int _stalledReads = 0;

  /// The folders the device had not finished listing when it gave its list (MTP, see DocListing.complete)
  final _incomplete = <String>{};

  /// Whether the files of the folder can be read at a position, once a listing told (see DocEntry.seekable)
  bool? _seekable;

  /// The document ids of the paths listed so far, and whether the provider makes a thumbnail of each
  final _ids = <String, String>{};
  final _thumbnails = <String, bool>{};

  /// Set once the folder stopped answering: every call fails at once with the same message, the page opens the folder
  /// again once it is plugged back
  bool _unplugged = false;

  /// Whether the drive or the device stopped answering
  bool get isUnplugged => _unplugged;

  /// Whether a folder listed was still being sent by the device when its list was given: files may be missing
  bool get hasIncompleteListing => _incomplete.isNotEmpty;

  /// Whether the device sends files from their start only (MTP without partial reads): a frame of a video without
  /// proxy, or its moov box at the end, would cost a read of the whole file
  @override
  bool get readsFromStartOnly => _seekable == false;

  String get treeUri => source.share;

  @override
  Future<List<NetworkEntry>> list(String path) async {
    final folder = _normalize(path);
    final id = await _documentId(folder);
    final listing = await _call(() => _api.list(treeUri, id));
    if (listing.complete) {
      _incomplete.remove(folder);
    } else {
      _log.info('${source.name} was still listing $folder: files may be missing');
      _incomplete.add(folder);
    }
    for (final document in listing.entries) {
      final seekable = document.seekable;
      if (!document.isDirectory && seekable != null) {
        _seekable = seekable;
      }
    }
    final entries = [for (final document in listing.entries) _entry(folder, document)]..sort(compareNetworkEntries);
    return entries;
  }

  @override
  Future<NetworkEntry> stat(String path) async {
    final normalized = _normalize(path);
    final id = await _documentId(normalized);
    final document = await _call(() => _api.stat(treeUri, id));
    return _entry(_parentOf(normalized), document, path: normalized);
  }

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    if (length <= 0) {
      return Uint8List(0);
    }
    final id = await _documentId(_normalize(path));
    if (id == null) {
      throw NetworkFileSystemException('$path is a folder');
    }
    if (length <= maxBridgeRead) {
      return _read(id, offset, length);
    }
    // The bridge reads at most 8 MB at once (a whole moov box may be asked): the rest in more reads
    final bytes = BytesBuilder(copy: false);
    var position = offset;
    var remaining = length;
    while (remaining > 0) {
      final wanted = math.min(remaining, maxBridgeRead);
      final chunk = await _read(id, position, wanted);
      bytes.add(chunk);
      position += chunk.length;
      remaining -= chunk.length;
      if (chunk.length < wanted) {
        break;
      }
    }
    return bytes.takeBytes();
  }

  /// The most bytes the bridge reads at once (DocumentTreePlugin's MAX_READ)
  static const maxBridgeRead = 8 * 1024 * 1024;

  /// One read of the bridge, given up after [readTimeout]: the files of the folder are then closed, which stops the
  /// read stuck on the Kotlin side, and the reads fail at once until it ended (see [_stalledReads])
  Future<Uint8List> _read(String id, int offset, int length) async {
    if (_stalledReads > 0) {
      throw NetworkFileSystemException(_stalledMessage());
    }
    return _call(() {
      final read = _api.read(treeUri, id, offset, length);
      return read.timeout(
        readTimeout,
        onTimeout: () {
          _log.warning('${source.name} did not answer a read for ${readTimeout.inSeconds} s');
          _stalledReads++;
          unawaited(read.then<void>((_) {}, onError: (_) {}).whenComplete(() => _stalledReads--));
          unawaited(close());
          throw NetworkFileSystemException(_stalledMessage());
        },
      );
    });
  }

  /// The thumbnail of a photo from its EXIF (see [parseExifThumbnail]), else the one the provider makes, else none: the
  /// tile then decodes the photo, or takes a frame of the video
  @override
  Future<Uint8List?> thumbnail(NetworkEntry entry, int size) async {
    if (_unplugged) {
      return null;
    }
    if (entry.isImage && (entry.extension == 'jpg' || entry.extension == 'jpeg')) {
      try {
        final exif = parseExifThumbnail(await readRange(entry.path, 0, exifThumbnailHeadLength));
        if (exif != null) {
          return exif;
        }
      } catch (error) {
        _log.fine('No EXIF thumbnail for ${entry.name}: $error');
      }
    }
    final path = _normalize(entry.path);
    final id = _ids[path];
    if (id == null || _thumbnails[path] != true) {
      return null;
    }
    try {
      return await _api.thumbnail(treeUri, id, size);
    } catch (error) {
      _log.fine('No thumbnail from the provider for ${entry.name}: $error');
      return null;
    }
  }

  @override
  Future<void> close() async {
    try {
      await _api.closeTree(treeUri);
    } catch (error) {
      _log.fine('Could not close the files of ${source.name}: $error');
    }
  }

  /// The document id of the file at [path], for the copies into the gallery (see DocumentTreeApi.copyToGallery)
  Future<String> documentIdOf(String path) async {
    final id = await _documentId(_normalize(path));
    if (id == null) {
      throw NetworkFileSystemException('$path is a folder');
    }
    return id;
  }

  /// Fails at once once the folder stopped answering (see [isUnplugged]), with the message the page shows
  void checkPlugged() {
    if (_unplugged) {
      throw NetworkFileSystemException(_unpluggedMessage());
    }
  }

  /// The document id of [path], null for the folder picked; the folders on the way are listed when it is not known
  /// yet
  Future<String?> _documentId(String path) async {
    if (path == '/') {
      return null;
    }
    final known = _ids[path];
    if (known != null) {
      return known;
    }
    await list(_parentOf(path));
    final id = _ids[path];
    if (id == null) {
      throw NetworkFileSystemException('$path is not on ${source.name}', isNotFound: true);
    }
    return id;
  }

  NetworkEntry _entry(String folder, DocEntry document, {String? path}) {
    final entryPath = path ?? (folder == '/' ? '/${document.name}' : '$folder/${document.name}');
    _ids[entryPath] = document.documentId;
    _thumbnails[entryPath] = document.supportsThumbnail;
    final modified = document.lastModifiedMs;
    return NetworkEntry(
      sourceId: source.id,
      path: entryPath,
      isDirectory: document.isDirectory,
      size: document.isDirectory ? null : document.size,
      modified: modified == null ? null : DateTime.fromMillisecondsSinceEpoch(modified, isUtc: true),
      mimeType: document.isDirectory ? null : document.mimeType,
    );
  }

  Future<T> _call<T>(Future<T> Function() call) async {
    if (_unplugged) {
      throw NetworkFileSystemException(_unpluggedMessage());
    }
    try {
      return await call();
    } on PlatformException catch (error) {
      if (error.code == 'unplugged') {
        _unplugged = true;
        _log.info('${source.name} was unplugged: ${error.message}');
        throw NetworkFileSystemException(_unpluggedMessage());
      }
      if (error.code == 'stalled') {
        _log.info('${source.name} stopped answering: ${error.message}');
        throw NetworkFileSystemException(_stalledMessage());
      }
      throw NetworkFileSystemException(error.message ?? error.code);
    }
  }

  static String _normalize(String path) {
    var normalized = path.trim();
    if (!normalized.startsWith('/')) {
      normalized = '/$normalized';
    }
    while (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  static String _parentOf(String path) {
    final slash = path.lastIndexOf('/');
    return slash <= 0 ? '/' : path.substring(0, slash);
  }
}
