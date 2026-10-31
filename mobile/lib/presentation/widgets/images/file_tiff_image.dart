// A TIFF file opened with "Open with" on a device without TIFF decoder (Android, see photoDecodePath): decoded in Dart
// rather than by the engine, which refuses it

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';

/// The TIFF at [path] decoded in Dart at most [maxSide] pixels on its long side; one that does not decode fails at
/// once the next times in the session, without reading its file again
class FileTiffImage extends ImageProvider<FileTiffImage> {
  const FileTiffImage(this.path, {this.maxSide = 8192});

  final String path;
  final int maxSide;

  /// The key of the TIFF at [path] among the photos that did not decode in the session (see UndecodablePhotos)
  static String undecodableKey(String path) => 'file:$path';

  @override
  Future<FileTiffImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(FileTiffImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(key), scale: 1, debugLabel: path);

  Future<ui.Codec> _load(FileTiffImage key) async {
    final undecodable = undecodableKey(path);
    try {
      final failure = UndecodablePhotos.instance.failureOf(undecodable);
      if (failure != null) {
        throw failure;
      }
      final bytes = await File(path).readAsBytes();
      try {
        return await codecOfTiffPixels(await decodeTiff(bytes, maxSide: maxSide));
      } on TiffDecodeException catch (error) {
        UndecodablePhotos.instance.remember(undecodable, error);
        rethrow;
      }
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) => other is FileTiffImage && other.path == path && other.maxSide == maxSide;

  @override
  int get hashCode => Object.hash(path, maxSide);

  @override
  String toString() => 'FileTiffImage($path, maxSide: $maxSide)';
}
