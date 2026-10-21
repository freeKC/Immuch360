import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/cache/custom_image_cache.dart';

void main() {
  test('a TV keeps fewer pictures: the thumbnails up to 64 MB, three full images', () {
    final cache = CustomImageCache();
    final phone = CustomImageCache();

    cache.limitForTelevision();

    // The thumbnails take the bytes of the cache, the full images their own
    expect(phone.maximumSizeBytes, 2 * ImageCache().maximumSizeBytes);
    expect(cache.maximumSizeBytes, 2 * CustomImageCache.televisionSmallBytes);
    expect(cache.maximumSize, phone.maximumSize - 5 + CustomImageCache.televisionLargeCount);
  });
}
