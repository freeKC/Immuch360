// The image stream of a TIFF decoded in Dart (see decodeTiff): once no widget wants the image any more (its page gone,
// its tile scrolled away), its download is stopped and its decode skipped, and the image cache lets it go, to load it
// again the next time it shows.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/presentation/widgets/images/cache_aware_listener_tracker.mixin.dart';

class TiffImageStreamCompleter extends MultiFrameImageStreamCompleter with CacheAwareListenerTrackerMixin {
  TiffImageStreamCompleter._({
    required super.codec,
    required super.scale,
    super.chunkEvents,
    super.debugLabel,
    required void Function() onLastListenerRemoved,
  }) {
    setupListenerTracking(hadInitialImage: false, onLastListenerRemoved: onLastListenerRemoved);
  }

  /// The image of the provider [key], whose codec [load] makes, given what cancels it ([TiffCancel]); [chunkEvents]
  /// tell how far it is
  factory TiffImageStreamCompleter.load(
    Object key,
    Future<ui.Codec> Function(TiffCancel cancel) load, {
    Stream<ImageChunkEvent>? chunkEvents,
    String? debugLabel,
  }) {
    final cancel = TiffCancel();
    var done = false;
    final codec = load(cancel).whenComplete(() => done = true);
    return TiffImageStreamCompleter._(
      codec: codec,
      scale: 1,
      chunkEvents: chunkEvents,
      debugLabel: debugLabel,
      onLastListenerRemoved: () {
        if (done) {
          return;
        }
        cancel.cancel();
        PaintingBinding.instance.imageCache.evict(key);
      },
    );
  }
}
