import 'package:flutter/painting.dart';
import 'package:immich_mobile/presentation/widgets/images/local_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumb_hash_provider.dart';

/// [ImageCache] that uses two caches for small and large images
/// so that a single large image does not evict all small images
final class CustomImageCache implements ImageCache {
  final _thumbhash = ImageCache()..maximumSize = 0;
  final _small = ImageCache();
  final _large = ImageCache()..maximumSize = 5; // Maximum 5 images

  /// Smaller caches on a TV, whose memory is smaller and whose pictures are larger: the thumbnails and the grid
  /// previews up to [televisionSmallBytes] rather than 100 MB, and [televisionLargeCount] full images rather than 5 (the
  /// one shown and its two neighbours, see AssetPreloader), up to the same bytes
  void limitForTelevision() {
    _small.maximumSizeBytes = televisionSmallBytes;
    _large.maximumSize = televisionLargeCount;
    _large.maximumSizeBytes = televisionSmallBytes;
  }

  static const televisionSmallBytes = 64 << 20;
  static const televisionLargeCount = 3;

  @override
  int get maximumSize => _small.maximumSize + _large.maximumSize;

  @override
  int get maximumSizeBytes => _small.maximumSizeBytes + _large.maximumSizeBytes;

  @override
  set maximumSize(int value) => _small.maximumSize = value;

  @override
  set maximumSizeBytes(int value) => _small.maximumSizeBytes = value;

  @override
  void clear() {
    _small.clear();
    _large.clear();
  }

  @override
  void clearLiveImages() {
    _small.clearLiveImages();
    _large.clearLiveImages();
  }

  /// Gets the cache for the given key
  ImageCache _cacheForKey(Object key) {
    return switch (key) {
      LocalFullImageProvider() || RemoteFullImageProvider() => _large,
      ThumbHashProvider() => _thumbhash,
      _ => _small,
    };
  }

  @override
  bool containsKey(Object key) {
    // [ImmichLocalImageProvider] and [ImmichRemoteImageProvider] are both
    // large size images while the other thumbnail providers are small
    return _cacheForKey(key).containsKey(key);
  }

  @override
  int get currentSize => _small.currentSize + _large.currentSize;

  @override
  int get currentSizeBytes => _small.currentSizeBytes + _large.currentSizeBytes;

  @override
  bool evict(Object key, {bool includeLive = true}) => _cacheForKey(key).evict(key, includeLive: includeLive);

  @override
  int get liveImageCount => _small.liveImageCount + _large.liveImageCount;

  @override
  int get pendingImageCount => _small.pendingImageCount + _large.pendingImageCount;

  @override
  ImageStreamCompleter? putIfAbsent(
    Object key,
    ImageStreamCompleter Function() loader, {
    ImageErrorListener? onError,
  }) => _cacheForKey(key).putIfAbsent(key, loader, onError: onError);

  @override
  ImageCacheStatus statusForKey(Object key) => _cacheForKey(key).statusForKey(key);
}
