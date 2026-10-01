import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';

/// What the decoders make of a [width] x [height] image asked to decode at [request]: the smallest size that covers
/// it, never larger than the source. Same rule on Android (decodeBitmap with exactSize), iOS (the longest side of
/// that size as kCGImageSourceThumbnailMaxPixelSize) and in the Dart fallback (ImageRequest._targetSize).
(int, int) _decoded(int width, int height, Size request) {
  final scale = math.min(1.0, math.max(request.width.ceil() / width, request.height.ceil() / height));
  return ((width * scale).ceil(), (height * scale).ceil());
}

/// Decodes a [width] x [height] panorama with the aspect ratio of its [preview], as the viewer does
(int, int) _texture(int width, int height, {(int, int)? preview}) {
  final (previewWidth, previewHeight) = preview ?? (width, height);
  return _decoded(width, height, textureDecodeSize(previewWidth / previewHeight));
}

void main() {
  group('textureDecodeSize', () {
    test('caps a full 2:1 sphere at 8192 x 4096, without shrinking it more than needed', () {
      final (width, height) = _texture(11968, 5984, preview: (2880, 1440));
      expect(width, inInclusiveRange(8190, 8192));
      expect(height, inInclusiveRange(4094, 4096));
    });

    test('never scales up a smaller image', () {
      expect(_texture(5760, 2880, preview: (2880, 1440)), (5760, 2880));
      expect(_texture(2880, 1440), (2880, 1440));
    });

    test('caps the width of a wide partial panorama', () {
      final (width, height) = _texture(16000, 4000, preview: (5760, 1440));
      expect(width, lessThanOrEqualTo(8192));
      expect(height, lessThanOrEqualTo(4096));
      expect(width, greaterThanOrEqualTo(8190));
    });

    test('caps the height of a tall image', () {
      final (width, height) = _texture(10000, 10000);
      expect(width, lessThanOrEqualTo(8192));
      expect(height, inInclusiveRange(4094, 4096));
    });

    test('keeps the long side under 8192 when the preview rounds the aspect ratio', () {
      // Slightly wider or narrower than 2:1, with a thumbnail 250 pixels high that rounds it the other way
      for (final (width, height, preview) in [
        (12000, 5995, (500, 250)),
        (12000, 6005, (500, 250)),
        (12000, 5990, (499, 250)),
        (12020, 6000, (501, 250)),
      ]) {
        final (decodedWidth, decodedHeight) = _texture(width, height, preview: preview);
        expect(decodedWidth, lessThanOrEqualTo(8192), reason: '$width x $height');
        expect(decodedHeight, lessThanOrEqualTo(4096 * 1.01), reason: '$width x $height');
      }
    });

    test('leaves each eye of a large 3D panorama about 4096 x 2048 pixels', () {
      for (final (layout, width, height) in [
        (StereoLayout.topBottom, 11520, 11520),
        (StereoLayout.leftRight, 15360, 3840),
      ]) {
        final (decodedWidth, decodedHeight) = _texture(width, height);
        final eye = layout.leftEyeRect;
        expect(decodedWidth * eye.width, inInclusiveRange(4094, 4096), reason: '$layout');
        expect(decodedHeight * eye.height, inInclusiveRange(2047, 2048), reason: '$layout');
      }
    });
  });
}
