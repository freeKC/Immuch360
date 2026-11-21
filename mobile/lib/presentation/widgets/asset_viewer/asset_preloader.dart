import 'dart:async';

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';

class AssetPreloader {
  static final _dummyListener = ImageStreamListener((image, _) => image.dispose());

  final TimelineService timelineService;
  final bool Function() mounted;
  final ImageProvider Function(BaseAsset asset, Size size, Size? thumbnailSize) _imageProvider;

  Timer? _timer;
  ImageStream? _prevStream;
  ImageStream? _nextStream;

  /// The number of the last [preload]: the neighbours of a page left behind, read while the viewer moved on, are not
  /// loaded over those of the page on screen
  int _generation = 0;
  bool _disposed = false;

  AssetPreloader({
    required this.timelineService,
    required this.mounted,
    // The full image of an asset; the tests count the resolutions
    ImageProvider Function(BaseAsset asset, Size size, Size? thumbnailSize)? imageProvider,
  }) : _imageProvider = imageProvider ?? _fullImageProvider;

  static ImageProvider _fullImageProvider(BaseAsset asset, Size size, Size? thumbnailSize) =>
      getFullImageProvider(asset, size: size, remoteThumbnailSize: thumbnailSize);

  /// Preloads adjacent images with the current thumbnail size.
  void preload(int index, Size size, {Size? thumbnailSize}) {
    if (_disposed) {
      return;
    }
    final generation = ++_generation;
    unawaited(timelineService.preloadAssets(index));
    _timer?.cancel();
    _timer = Timer(Durations.medium4, () async {
      if (_disposed || generation != _generation || !mounted()) {
        return;
      }
      final (prev, next) = await (
        timelineService.getAssetAsync(index - 1),
        timelineService.getAssetAsync(index + 1),
      ).wait;
      if (_disposed || generation != _generation || !mounted()) {
        return;
      }
      _prevStream?.removeListener(_dummyListener);
      _nextStream?.removeListener(_dummyListener);
      _prevStream = prev != null ? _resolveImage(prev, size, thumbnailSize) : null;
      _nextStream = next != null ? _resolveImage(next, size, thumbnailSize) : null;
    });
  }

  ImageStream _resolveImage(BaseAsset asset, Size size, Size? thumbnailSize) {
    return _imageProvider(asset, size, thumbnailSize).resolve(ImageConfiguration.empty)..addListener(_dummyListener);
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _prevStream?.removeListener(_dummyListener);
    _nextStream?.removeListener(_dummyListener);
    _prevStream = null;
    _nextStream = null;
  }
}
