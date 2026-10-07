import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';

void main() {
  group('guessSphereCoverage', () {
    SphereCoverage guess({
      String? fileName = 'clip.mp4',
      int? width = 5760,
      int? height = 2880,
      StereoLayout layout = StereoLayout.mono,
      Rect? gpanoCrop,
      SphericalProbe? probe,
    }) => guessSphereCoverage(
      fileName: fileName,
      width: width,
      height: height,
      layout: layout,
      gpanoCrop: gpanoCrop,
      probe: probe,
    );

    test('is a full sphere when nothing tells otherwise', () {
      expect(guess(), SphereCoverage.full);
      expect(guess(fileName: null, width: null, height: null), SphereCoverage.full);
      expect(guess(probe: const SphericalProbe()), SphereCoverage.full);
    });

    test('is a half sphere when the file declares one', () {
      expect(guess(probe: const SphericalProbe(halfSphere: true, hasSphericalMetadata: true)), SphereCoverage.half);
      expect(guess(probe: const SphericalProbe(halfSphere: false, hasSphericalMetadata: true)), SphereCoverage.full);
    });

    test('keeps the full sphere the file declares over square eyes and a 180 in the name', () {
      // A side by side 360° video squeezed into a 2:1 frame has square eyes too
      const fullBounds = SphericalProbe(halfSphere: false, hasSphericalMetadata: true);
      expect(guess(width: 3840, height: 1920, layout: StereoLayout.leftRight, probe: fullBounds), SphereCoverage.full);
      expect(guess(fileName: 'trip_vr180.mp4', probe: fullBounds), SphereCoverage.full);
    });

    test('is a half sphere when the GPano crop covers half the width and the whole height', () {
      for (final crop in [
        const Rect.fromLTWH(0.25, 0, 0.5, 1),
        const Rect.fromLTWH(0.3, 0.02, 0.45, 0.95),
        const Rect.fromLTWH(0, 0, 0.55, 1),
      ]) {
        expect(guess(gpanoCrop: crop), SphereCoverage.half, reason: '$crop');
      }
      for (final crop in [
        const Rect.fromLTWH(0, 0, 1, 1),
        const Rect.fromLTWH(0.25, 0.25, 0.5, 0.5),
        const Rect.fromLTWH(0.3, 0, 0.4, 1),
        const Rect.fromLTWH(0.2, 0, 0.6, 1),
        const Rect.fromLTWH(0, 2035 / 4601, 4460 / 9202, 1667 / 4601),
      ]) {
        expect(guess(gpanoCrop: crop), SphereCoverage.full, reason: '$crop');
      }
    });

    test('is a half sphere when the eyes of a 3D layout are square', () {
      expect(guess(layout: StereoLayout.leftRight), SphereCoverage.half, reason: 'two 2880 x 2880 eyes');
      expect(guess(width: 2880, height: 5760, layout: StereoLayout.topBottom), SphereCoverage.half);
      // Two 2:1 eyes
      expect(guess(width: 5760, height: 5760, layout: StereoLayout.topBottom), SphereCoverage.full);
      expect(guess(width: 7680, height: 1920, layout: StereoLayout.leftRight), SphereCoverage.full);
      // A mono square frame is no layout to go by
      expect(guess(width: 4096, height: 4096), SphereCoverage.full);
      expect(guess(width: null, height: null, layout: StereoLayout.leftRight), SphereCoverage.full);
    });

    test('reads VR180 marks in the file name, in any case', () {
      for (final name in [
        'VR180_clip.mp4',
        'trip.vr180.jpg',
        'Concert_180_3D_SBS.mp4',
        'beach-180_3d.mp4',
        'scene 180x180.mp4',
        'trip_180.mp4',
        'trip-180-sbs.mp4',
        'Tokyo 180°.mov',
        'clip.180.mp4',
        'CALF_180.MP4',
      ]) {
        expect(guess(fileName: name), SphereCoverage.half, reason: name);
      }
    });

    test('ignores 180 inside longer numbers and words', () {
      for (final name in [
        'IMG_1801.JPG',
        'DSC_0180.jpg',
        'PXL_20240101_180512.mp4',
        'VID_20240101_120000.mp4',
        '3f2a-180b-4c1d.mp4',
        'remote_180fps.mp4',
        'clip180.mp4',
        '360_clip.mp4',
        '',
      ]) {
        expect(guess(fileName: name), SphereCoverage.full, reason: name);
      }
    });
  });

  group('resolveSphereView', () {
    SphereView resolve({
      String fileName = 'clip.mp4',
      int? width = 5760,
      int? height = 2880,
      Rect? gpanoCrop,
      SphericalProbe? probe,
      StereoLayout? chosenLayout,
      SphereCoverage? chosenCoverage,
    }) => resolveSphereView(
      fileName: fileName,
      width: width,
      height: height,
      gpanoCrop: gpanoCrop,
      probe: probe,
      chosenLayout: chosenLayout,
      chosenCoverage: chosenCoverage,
    );

    test('shows a regular 2:1 panorama mono over the whole sphere', () {
      expect(resolve(), (layout: StereoLayout.mono, coverage: SphereCoverage.full, coverageGuess: SphereCoverage.full));
    });

    test('shows a VR180 file as two square eyes side by side over the front half', () {
      expect(resolve(fileName: 'clip_VR180.mp4'), (
        layout: StereoLayout.leftRight,
        coverage: SphereCoverage.half,
        coverageGuess: SphereCoverage.half,
      ));
    });

    test('prefers what the file declares to the guesses', () {
      final view = resolve(
        probe: const SphericalProbe(stereo: StereoLayout.topBottom, halfSphere: true, hasSphericalMetadata: true),
      );

      expect(view.layout, StereoLayout.topBottom);
      expect(view.coverage, SphereCoverage.half);
    });

    test('takes a 2:1 frame the file declares side by side for a half sphere', () {
      final view = resolve(probe: const SphericalProbe(stereo: StereoLayout.leftRight));

      expect(view.layout, StereoLayout.leftRight);
      expect(view.coverage, SphereCoverage.half);
    });

    test('prefers what the user picked, and keeps the guess apart', () {
      final view = resolve(fileName: 'clip_vr180.mp4', chosenCoverage: SphereCoverage.full);
      expect(view, (layout: StereoLayout.mono, coverage: SphereCoverage.full, coverageGuess: SphereCoverage.half));

      final picked = resolve(chosenLayout: StereoLayout.leftRight);
      expect(picked.layout, StereoLayout.leftRight);
      expect(picked.coverage, SphereCoverage.half, reason: 'two square eyes');

      final both = resolve(chosenLayout: StereoLayout.topBottom, chosenCoverage: SphereCoverage.half);
      expect(both.layout, StereoLayout.topBottom);
      expect(both.coverage, SphereCoverage.half);
    });

    test('shows a partial panorama mono, a half sphere one included', () {
      final view = resolve(width: 4096, height: 4096, gpanoCrop: const Rect.fromLTWH(0.25, 0, 0.5, 1));

      expect(view.layout, StereoLayout.mono);
      expect(view.coverage, SphereCoverage.half);
    });
  });

  group('sphereCrop', () {
    test('is the whole sphere, or its front half, without a GPano crop', () {
      expect(sphereCrop(SphereCoverage.full), const Rect.fromLTWH(0, 0, 1, 1));
      expect(sphereCrop(SphereCoverage.half), const Rect.fromLTWH(0.25, 0, 0.5, 1));
    });

    test('is the GPano crop of a partial panorama, whatever the coverage', () {
      const crop = Rect.fromLTWH(0, 0.25, 1, 0.5);

      expect(sphereCrop(SphereCoverage.full, gpanoCrop: crop), crop);
      expect(sphereCrop(SphereCoverage.half, gpanoCrop: crop), crop);
    });

    test('takes the front half over a GPano crop that covers the whole sphere', () {
      const crop = Rect.fromLTWH(0, 0, 4095 / 4096, 1);

      expect(sphereCrop(SphereCoverage.full, gpanoCrop: crop), crop);
      expect(sphereCrop(SphereCoverage.half, gpanoCrop: crop), halfSphereCrop);
    });

    test('the front half spans longitudes -90° to +90° and all latitudes', () {
      // The sphere painter maps the column u of the full sphere to the longitude 360 * (u - 0.5)
      expect(360 * (halfSphereCrop.left - 0.5), -90);
      expect(360 * (halfSphereCrop.right - 0.5), 90);
      expect(halfSphereCrop.top, 0);
      expect(halfSphereCrop.bottom, 1);
    });
  });

  group('isPartialSphere', () {
    test('a crop covering the whole sphere, within rounding, is no partial panorama', () {
      expect(isPartialSphere(const Rect.fromLTWH(0, 0, 1, 1)), isFalse);
      expect(isPartialSphere(const Rect.fromLTWH(0, 0, 4095 / 4096, 2047 / 2048)), isFalse);
      expect(isPartialSphere(halfSphereCrop), isTrue);
    });
  });

  group('SphereCoverage', () {
    test('the coverage control goes through the full sphere and the front half', () {
      expect(SphereCoverage.full.next, SphereCoverage.half);
      expect(SphereCoverage.half.next, SphereCoverage.full);
      expect(SphereCoverage.full.shortLabel, '360°');
      expect(SphereCoverage.half.shortLabel, '180°');
    });

    test('maps to the coverage of the immersive viewer and back', () {
      expect(SphereCoverage.full.toImmersive(), ImmersiveSphereCoverage.full);
      expect(SphereCoverage.half.toImmersive(), ImmersiveSphereCoverage.half);
      for (final coverage in SphereCoverage.values) {
        expect(sphereCoverageOfImmersive(coverage.toImmersive()), coverage);
      }
    });

    test('maps to the projection of the Spatial 2.5D player and back', () {
      expect(SphereCoverage.full.toSpatialProjection(), SpatialProjection.equirectangular);
      expect(SphereCoverage.half.toSpatialProjection(), SpatialProjection.equirectangular180);
      for (final coverage in SphereCoverage.values) {
        expect(sphereCoverageOfSpatialProjection(coverage.toSpatialProjection()), coverage);
      }
      expect(sphereCoverageOfSpatialProjection(SpatialProjection.flat), isNull);
    });
  });

  test('the native viewers get the labels of their 3D and coverage controls, and the hint for a remote', () {
    expect(sphereCoverageLabels(StaticTranslations.instance).keys, {'coverage', 'coverage_full', 'coverage_half'});
    expect(sphereViewerLabels(StaticTranslations.instance).keys, {
      'stereo',
      'mono',
      'topBottom',
      'leftRight',
      'coverage',
      'coverage_full',
      'coverage_half',
      'spatial3d',
      'spatial2d',
      'spatialNoNavigation',
      'spatialSecondEyeFailed',
      'remoteLookHint',
    });
  });

  group('remembered coverages', () {
    test('survive their JSON form, with the coverage names', () {
      final coverages = {'asset-1': SphereCoverage.half, 'asset-2': SphereCoverage.full};

      final json = encodeSphereCoverages(coverages);

      expect(json, '{"asset-1":"half","asset-2":"full"}');
      expect(decodeSphereCoverages(json), coverages);
    });

    test('read as none from a missing or damaged value, and skip unknown names', () {
      for (final json in [null, '', '{', '[]', '"half"', '42']) {
        expect(decodeSphereCoverages(json), isEmpty, reason: '$json');
      }
      expect(decodeSphereCoverages('{"asset-1":"half","asset-2":"quarter","asset-3":1}'), {
        'asset-1': SphereCoverage.half,
      });
    });
  });
}
