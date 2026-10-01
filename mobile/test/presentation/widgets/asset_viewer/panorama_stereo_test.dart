import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';

void main() {
  group('guessStereoLayout', () {
    test('a square frame holds two 2:1 eyes, one above the other', () {
      expect(guessStereoLayout(width: 5760, height: 5760), StereoLayout.topBottom);
      expect(guessStereoLayout(width: 4096, height: 4096), StereoLayout.topBottom);
      // Within 10% of square
      expect(guessStereoLayout(width: 3840, height: 3500), StereoLayout.topBottom);
      expect(guessStereoLayout(width: 3500, height: 3840), StereoLayout.topBottom);
    });

    test('a 4:1 frame holds two 2:1 eyes side by side', () {
      expect(guessStereoLayout(width: 7680, height: 1920), StereoLayout.leftRight);
      expect(guessStereoLayout(width: 8192, height: 2048), StereoLayout.leftRight);
      // Within 10% of 4:1
      expect(guessStereoLayout(width: 7400, height: 2000), StereoLayout.leftRight);
      expect(guessStereoLayout(width: 8600, height: 2000), StereoLayout.leftRight);
    });

    test('a regular 2:1 panorama is mono', () {
      expect(guessStereoLayout(width: 5760, height: 2880), StereoLayout.mono);
      expect(guessStereoLayout(width: 11968, height: 5984), StereoLayout.mono);
    });

    test('other aspect ratios are mono', () {
      for (final (width, height) in [(3000, 2000), (2000, 3000), (8000, 1000), (4500, 4000), (3200, 1000)]) {
        expect(
          guessStereoLayout(width: width, height: height),
          StereoLayout.mono,
          reason: '$width x $height',
        );
      }
    });

    test('unknown or empty dimensions are mono', () {
      expect(guessStereoLayout(width: null, height: null), StereoLayout.mono);
      expect(guessStereoLayout(width: 4096, height: null), StereoLayout.mono);
      expect(guessStereoLayout(width: null, height: 4096), StereoLayout.mono);
      expect(guessStereoLayout(width: 0, height: 0), StereoLayout.mono);
      expect(guessStereoLayout(width: 4096, height: 0), StereoLayout.mono);
    });

    test('a partial panorama is mono, whatever its aspect ratio', () {
      expect(guessStereoLayout(width: 4096, height: 4096, hasGPanoCrop: true), StereoLayout.mono);
      expect(guessStereoLayout(width: 7680, height: 1920, hasGPanoCrop: true), StereoLayout.mono);
    });
  });

  group('isPartialSphere', () {
    test('a crop covering the whole sphere, within rounding, is no partial panorama', () {
      expect(isPartialSphere(const Rect.fromLTWH(0, 0, 1, 1)), isFalse);
      expect(isPartialSphere(const Rect.fromLTWH(0, 0, 4095 / 4096, 2047 / 2048)), isFalse);
    });

    test('a crop leaving part of the sphere out is a partial panorama', () {
      expect(isPartialSphere(const Rect.fromLTWH(0, 2035 / 4601, 4460 / 9202, 1667 / 4601)), isTrue);
      expect(isPartialSphere(const Rect.fromLTWH(0.25, 0, 0.5, 1)), isTrue);
      expect(isPartialSphere(const Rect.fromLTWH(0, 0.1, 1, 0.8)), isTrue);
    });
  });

  group('StereoLayout', () {
    test('the left eye is the top half, the left half, or the whole frame', () {
      expect(StereoLayout.topBottom.leftEyeRect, const Rect.fromLTWH(0, 0, 1, 0.5));
      expect(StereoLayout.leftRight.leftEyeRect, const Rect.fromLTWH(0, 0, 0.5, 1));
      expect(StereoLayout.mono.leftEyeRect, const Rect.fromLTWH(0, 0, 1, 1));
    });

    test('the left eye of a 3D panorama is a 2:1 equirectangular image', () {
      for (final (layout, width, height) in [
        (StereoLayout.topBottom, 5760.0, 5760.0),
        (StereoLayout.leftRight, 7680.0, 1920.0),
        (StereoLayout.mono, 5760.0, 2880.0),
      ]) {
        final eye = layout.leftEyeRect;
        expect(width * eye.width / (height * eye.height), 2, reason: '$layout');
      }
    });

    test('the 3D control goes through mono, top and bottom, side by side, and back', () {
      expect(StereoLayout.mono.next, StereoLayout.topBottom);
      expect(StereoLayout.topBottom.next, StereoLayout.leftRight);
      expect(StereoLayout.leftRight.next, StereoLayout.mono);
    });

    test('maps to the same layout of the immersive viewer', () {
      expect(StereoLayout.mono.toImmersive(), ImmersiveStereoLayout.mono);
      expect(StereoLayout.topBottom.toImmersive(), ImmersiveStereoLayout.topBottom);
      expect(StereoLayout.leftRight.toImmersive(), ImmersiveStereoLayout.leftRight);
    });
  });
}
