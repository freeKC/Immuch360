import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/library/decode_queue.dart';
import 'package:immich_mobile/desktop/library/desktop_storage_repository.dart';
import 'package:immich_mobile/desktop/library/local_image_codec.dart';
import 'package:immich_mobile/desktop/library/thumbnail_cache.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:thumbhash/thumbhash.dart' as thumbhash_codec;

/// LocalImageApi on the computers. The images of the folder library are files: the answer is always encoded bytes in
/// a malloc buffer, {pointer, length}, which LocalImageRequest decodes at the requested size and frees.
///
/// - Thumbnails (a box up to 1024 pixels) come from the thumbnail cache, made on first use by the engine's decoder at
///   the size of their bucket, a few at a time, the latest requested first, so that a fast scroll does not queue the
///   whole timeline.
/// - Larger and unsized requests, and animated images (preferEncoded), get the file itself: the engine decodes it at
///   the requested size (EXIF orientation included).
/// - A video, until the desktop player grabs frames, and a file the engine cannot decode (HEIC or a camera raw file
///   without a decoder of the system) get a tile: a film icon, or the format's name.
class DesktopLocalImageApi implements LocalImageApi {
  DesktopLocalImageApi({
    Future<File?> Function(String assetId)? fileForAsset,
    ThumbnailCache? thumbnails,
    int concurrentDecodes = 3,
  }) : _fileForAsset = fileForAsset ?? _libraryFile,
       _thumbnails = thumbnails ?? ThumbnailCache.shared,
       _queue = DecodeQueue(concurrentDecodes);

  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  /// The largest image file read whole; beyond it (a gigapixel panorama, a mislabelled file) the tile is shown rather
  /// than hundreds of megabytes held in memory for one picture
  static const maxImageBytes = 256 * 1024 * 1024;

  static final _storage = DesktopStorageRepository();
  static final _log = Logger('DesktopLocalImageApi');

  static Future<File?> _libraryFile(String assetId) => _storage.getFileForAsset(assetId);

  final Future<File?> Function(String assetId) _fileForAsset;
  final ThumbnailCache _thumbnails;
  final DecodeQueue _queue;

  final _running = <int>{};
  final _cancelled = <int>{};
  final _tiles = <String, Future<Uint8List>>{};

  /// Files the engine could not decode in this session, by file version, so that they are not read again
  final _undecodable = <String>{};
  final _writes = <Future<void>>{};

  @override
  Future<Map<String, int>?> requestImage(
    String assetId, {
    required int requestId,
    required int width,
    required int height,
    required bool isVideo,
    required bool preferEncoded,
  }) async {
    _running.add(requestId);
    try {
      final bytes = await _encodedImage(assetId, requestId, width, height, isVideo, preferEncoded);
      if (bytes == null || bytes.isEmpty || _cancelled.contains(requestId)) {
        return null;
      }
      return encodedBuffer(bytes);
    } on FileSystemException catch (error) {
      // Moved, deleted or locked since the last scan: nothing to show, and the next scan tells the timeline
      _log.fine('No image for a file of the library: ${error.message}');
      return null;
    } finally {
      _running.remove(requestId);
      _cancelled.remove(requestId);
    }
  }

  @override
  Future<void> cancelRequest(int requestId) async {
    if (_running.contains(requestId)) {
      _cancelled.add(requestId);
      _queue.cancel(requestId);
    }
  }

  /// {pointer, width, height, rowBytes} of the RGBA pixels of [thumbhash] (base64) in a malloc buffer, the shape the phones
  /// answer with, decoded by the same pure Dart package the app uses elsewhere; ThumbhashImageRequest frees it
  @override
  Future<Map<String, int>> getThumbhash(String thumbhash) async {
    final image = thumbhash_codec.thumbHashToRGBA(base64Decode(thumbhash));
    final pixels = image.rgba;
    final pointer = malloc<Uint8>(pixels.length);
    pointer.asTypedList(pixels.length).setAll(0, pixels);
    return {'pointer': pointer.address, 'width': image.width, 'height': image.height, 'rowBytes': image.width * 4};
  }

  /// Waits for the thumbnails being written to the cache
  @visibleForTesting
  Future<void> idle() => Future.wait(_writes.toList());

  Future<Uint8List?> _encodedImage(
    String assetId,
    int requestId,
    int width,
    int height,
    bool isVideo,
    bool preferEncoded,
  ) async {
    final file = await _fileForAsset(assetId);
    if (file == null || _cancelled.contains(requestId)) {
      return null;
    }

    final bucket = preferEncoded ? null : ThumbnailCache.bucketFor(width, height);
    final tileSize = bucket ?? ThumbnailCache.buckets.last;
    if (isVideo) {
      return _tile(tileSize, video: true);
    }

    final FileStat stat;
    try {
      // ignore: avoid_slow_async_io
      stat = await file.stat();
    } on FileSystemException {
      return null;
    }
    if (stat.type != FileSystemEntityType.file || _cancelled.contains(requestId)) {
      return null;
    }
    final label = formatLabel(file.path);
    final version = '${file.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    if (stat.size == 0 || stat.size > maxImageBytes || _undecodable.contains(version)) {
      return _tile(tileSize, label: label);
    }

    if (bucket == null) {
      final bytes = await file.readAsBytes();
      if (_cancelled.contains(requestId)) {
        return null;
      }
      if (await engineCanDecode(bytes)) {
        return bytes;
      }
      _undecodable.add(version);
      return _tile(tileSize, label: label);
    }

    final source = ThumbnailSource(assetId: assetId, length: stat.size, modified: stat.modified);
    final cached = await _thumbnails.read(source, bucket);
    if (cached != null || _cancelled.contains(requestId)) {
      return cached;
    }
    return _queue.run('$version|$bucket', requestId, () async {
      final thumbnail = await renderThumbnail(await file.readAsBytes(), bucket);
      if (thumbnail == null) {
        _undecodable.add(version);
        return _tile(bucket, label: label);
      }
      final write = _thumbnails.write(source, bucket, thumbnail);
      _writes.add(write);
      unawaited(write.whenComplete(() => _writes.remove(write)));
      return thumbnail;
    });
  }

  /// The tile for a video, or for a file of the [label] format the engine cannot show; made once per kind and size
  Future<Uint8List> _tile(int size, {bool video = false, String? label}) {
    final key = '$video|${video ? '' : label}|$size';
    return _tiles.putIfAbsent(key, () async => _drawTile(key, size, video ? null : label, video: video));
  }

  Future<Uint8List> _drawTile(String key, int size, String? label, {required bool video}) async {
    try {
      return await renderTile(
        size: size,
        icon: video ? Icons.movie_outlined : Icons.image_not_supported_outlined,
        label: label,
      );
    } catch (_) {
      // A failed drawing is tried again next time rather than kept
      // (the entry removed is this very drawing, whose failure the caller sees)
      _tiles.remove(key)?.ignore();
      rethrow;
    }
  }
}

/// The format of [path] as the tile shows it: its extension in capitals (HEIC, DNG), null without one
String? formatLabel(String path) {
  final extension = p.extension(path).replaceFirst('.', '').toUpperCase();
  if (extension.isEmpty) {
    return null;
  }
  return extension.length > 6 ? extension.substring(0, 6) : extension;
}

/// [bytes] copied into a malloc buffer, {pointer, length}: the encoded shape the image requests read, then free with
/// malloc.free (image_request.dart)
Map<String, int> encodedBuffer(Uint8List bytes) {
  final pointer = malloc<Uint8>(bytes.length);
  pointer.asTypedList(bytes.length).setAll(0, bytes);
  return {'pointer': pointer.address, 'length': bytes.length};
}
