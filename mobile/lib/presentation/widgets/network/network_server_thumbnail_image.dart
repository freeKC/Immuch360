// The picture a server makes of one of its media (a Plex server), read through the open connection of its share
// (see NetworkThumbnailSource) rather than from a URL: the request carries the credentials of the share, which must
// never reach an image widget, whose errors print the URL they failed on.

import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';

/// The server picture of [entry], about [size] pixels on its long side, loaded through [source]. Known to the image
/// cache by the file and the size alone (its source id, path, size and date), not by the connection, which is opened
/// again after a change of the share.
class NetworkServerThumbnailImage extends ImageProvider<NetworkServerThumbnailImage> {
  const NetworkServerThumbnailImage(this.source, this.entry, {this.size = defaultSize});

  final NetworkThumbnailSource source;
  final NetworkEntry entry;
  final int size;

  static const defaultSize = 256;

  /// Most pictures asked for at once, so that a folder shown at once does not send hundreds of requests together
  static const maxConcurrent = 3;

  static int _loading = 0;
  static final _waiting = Queue<Completer<void>>();

  @override
  Future<NetworkServerThumbnailImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(NetworkServerThumbnailImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(key, decode), scale: 1, debugLabel: entry.path);

  Future<ui.Codec> _load(NetworkServerThumbnailImage key, ImageDecoderCallback decode) async {
    await _takeTurn();
    try {
      final bytes = await source.thumbnail(entry, size);
      if (bytes == null || bytes.isEmpty) {
        // Fails the load, so that the tile shows its own picture instead
        throw StateError('No server picture for ${entry.path}');
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      return await decode(
        buffer,
        getTargetSize: (width, height) => width >= height
            ? (width > size ? ui.TargetImageSize(width: size) : const ui.TargetImageSize())
            : (height > size ? ui.TargetImageSize(height: size) : const ui.TargetImageSize()),
      );
    } catch (_) {
      // Asked for again the next time it is shown
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    } finally {
      _endTurn();
    }
  }

  static Future<void> _takeTurn() async {
    if (_loading < maxConcurrent) {
      _loading++;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    // Handed over by _endTurn, the count of loads under way staying the same
    await turn.future;
  }

  static void _endTurn() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
      return;
    }
    _loading--;
  }

  @override
  bool operator ==(Object other) =>
      other is NetworkServerThumbnailImage &&
      other.entry.sourceId == entry.sourceId &&
      other.entry.path == entry.path &&
      other.entry.modified == entry.modified &&
      other.size == size;

  @override
  int get hashCode => Object.hash(entry.sourceId, entry.path, entry.modified, size);

  @override
  String toString() => 'NetworkServerThumbnailImage(${entry.path}, size: $size)';
}
