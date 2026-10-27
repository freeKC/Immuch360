import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

void main() {
  group('the words of the format', () {
    test('XMP and JSON values are those of the design', () {
      expect(immuch360XmpNamespace, 'http://ns.aprogsys.com/immuch360/1.0/');
      expect(ImmersiveKind.values.map((kind) => kind.xmp), [
        'StereoPhoto',
        'Panorama360',
        'StereoPanorama360',
        'VolumetricScene',
      ]);
      expect(StereoEyes.full.xmp, 'SideBySideFull');
      expect(StereoEyes.half.json, 'half');
      expect(EyeOrder.rightLeft.xmp, 'RightLeft');
      expect(EyeOrder.leftRight.json, 'leftRight');
      expect(ImmersiveOrigin.estimatedDepth.xmp, 'EstimatedDepth');
      expect(ImmersiveOrigin.unknown.json, 'unknown');
      expect(LeftEyeSource.original.xmp, 'Original');
      expect(LeftEyeSource.unknown.json, 'unknown');
    });

    test('unknown values read as null', () {
      expect(ImmersiveKind.fromXmp('Hologram'), isNull);
      expect(StereoEyes.fromJson('quarter'), isNull);
      expect(EyeOrder.fromJson(null), isNull);
      expect(ImmersiveOrigin.fromXmp('estimateddepth'), isNull);
      expect(LeftEyeSource.fromJson(1), isNull);
    });

    test('quality flags are written in a fixed order and read leniently', () {
      expect(
        qualityFlagsToXmp([ReliefQualityFlag.dark, ReliefQualityFlag.lowRelief, ReliefQualityFlag.dark]),
        'lowRelief,dark',
      );
      expect(qualityFlagsToXmp(const []), '');
      expect(qualityFlagsFromXmp(' hiddenAreas, dark  sparkles '), [
        ReliefQualityFlag.hiddenAreas,
        ReliefQualityFlag.dark,
      ]);
      expect(qualityFlagsFromXmp(null), isEmpty);
    });

    test('each kind has its name, the end of which a shortened name keeps whole', () {
      expect(
        {for (final kind in ImmersiveKind.values) kind: derivedFileNameFor(kind, 'salon.jpg')},
        {
          ImmersiveKind.stereoPhoto: 'salon_3D_LRF_Full_SBS.jpg',
          ImmersiveKind.volumetricScene: 'salon_scene3D.jpg',
          ImmersiveKind.panorama360: 'salon_360.jpg',
          ImmersiveKind.stereoPanorama360: 'salon_360_3D.jpg',
        },
      );
      // The 3D version of a 360° photo whose name says so only adds _3D
      expect(derivedFileNameFor(ImmersiveKind.stereoPanorama360, 'PANO_0001.jpg'), 'PANO_0001_3D.jpg');
      expect(derivedFileNameFor(ImmersiveKind.stereoPanorama360, 'trip 360.jpg'), 'trip 360_3D.jpg');
      expect(derivedFileNameFor(ImmersiveKind.stereoPanorama360, 'IMG_1360.jpg'), 'IMG_1360_360_3D.jpg');
      expect(derivedNameEnd(ImmersiveKind.volumetricScene, 'salon.jpg'), '_scene3D.jpg');
      expect(derivedFileNameFor(ImmersiveKind.stereoPhoto, 'salon.jpg'), sbsFileNameFor('salon.jpg'));
    });

    test('each kind raises its own flags, in the order of the XMP; the flags of phase 1 keep their place', () {
      expect(ReliefQualityFlag.values.take(3), [
        ReliefQualityFlag.lowRelief,
        ReliefQualityFlag.hiddenAreas,
        ReliefQualityFlag.dark,
      ]);
      expect(qualityFlagsOf(ImmersiveKind.stereoPhoto), ReliefQualityFlag.values.take(3));
      expect(qualityFlagsOf(ImmersiveKind.volumetricScene), contains(ReliefQualityFlag.smallZone));
      expect(qualityFlagsOf(ImmersiveKind.panorama360), contains(ReliefQualityFlag.mostlyInvented));
      for (final kind in ImmersiveKind.values) {
        final flags = qualityFlagsOf(kind);
        expect(flags, [...flags]..sort((a, b) => a.index - b.index), reason: '$kind');
      }
      expect(qualityFlagsFromXmp('seam, sky mostlyInvented'), [
        ReliefQualityFlag.seam,
        ReliefQualityFlag.sky,
        ReliefQualityFlag.mostlyInvented,
      ]);
      expect(qualityFlagsToXmp([ReliefQualityFlag.seam, ReliefQualityFlag.sky]), 'sky,seam');
    });

    test('the origin of a scene, its safe zone and the honesty of each kind', () {
      expect(ImmersiveOrigin.reconstructedFromPhoto.xmp, 'ReconstructedFromPhoto');
      expect(ImmersiveOrigin.fromJson('reconstructedFromPhoto'), ImmersiveOrigin.reconstructedFromPhoto);
      const zone = SceneSafeZone(lateral: 0.22, vertical: 0.13, forward: 0.48, backward: 0.11);
      expect(SceneSafeZone.fromJson(zone.toJson()), zone);
      expect(SceneSafeZone.fromJson({'lateral': 0.2}), isNull);
      expect(sceneDescription, contains(sceneHonesty));
      expect(panoramaDescription, contains(panoramaHonesty));
      expect(stereoPanoramaDescription, contains(panoramaHonesty));
      expect(SceneV1.format, glbLayersV1);
      expect(SceneV1.breakThreshold, ReliefV1.linkThreshold);
      expect(Relief360V1.maxShiftDegrees, 1.0);
    });

    test('the stem of a name drops only the last extension', () {
      expect(fileStem('salon.jpg'), 'salon');
      expect(fileStem('archive.tar.gz'), 'archive.tar');
      expect(fileStem('.hidden'), '.hidden');
      expect(fileStem('README'), 'README');
    });
  });

  group('the golden fixture of relief-v1', () {
    final golden =
        jsonDecode(File('test/fixtures/ai_immersive/relief_golden_v1.json').readAsStringSync()) as Map<String, dynamic>;
    final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();
    Map<String, dynamic> named(String name) => cases.firstWhere((entry) => entry['name'] == name);

    test('holds the settings and thresholds of ReliefV1', () {
      expect(golden['pipeline'], ReliefV1.pipeline);
      expect(golden['linkThreshold'], ReliefV1.linkThreshold);
      expect(golden['dilationWindow'], ReliefV1.dilationWindow);
      expect(golden['percentiles'], [ReliefV1.lowPercentile, ReliefV1.highPercentile]);
      expect(golden['lowReliefRatio'], ReliefV1.lowReliefRatio);
      expect(golden['hiddenAreasRatio'], ReliefV1.hiddenAreasRatio);
      expect(golden['darkLuma'], ReliefV1.darkLuma);
      expect(named('production')['parallax'], ReliefV1.parallax);
      expect(named('production')['convergence'], ReliefV1.convergence);
    });

    test('every case is a 32 x 8 photo, a 16 x 4 map, a right eye and a mask Dart reads', () {
      final eyeWidth = golden['eyeWidth'] as int;
      final eyeHeight = golden['eyeHeight'] as int;
      final mapWidth = golden['mapWidth'] as int;
      final mapHeight = golden['mapHeight'] as int;
      expect([eyeWidth, eyeHeight, mapWidth, mapHeight], [32, 8, 16, 4]);
      for (final entry in cases) {
        final reason = entry['name'] as String;
        for (final key in ['image', 'rightEye']) {
          final rows = (entry[key] as List).cast<List<dynamic>>();
          expect(rows, hasLength(eyeHeight), reason: reason);
          for (final row in rows) {
            expect(row.cast<int>(), hasLength(eyeWidth * 3), reason: reason);
            expect(row.cast<int>().every((value) => value >= 0 && value <= 255), isTrue, reason: reason);
          }
        }
        for (final key in ['depth', 'normalized', 'dilated']) {
          final rows = (entry[key] as List).cast<List<dynamic>>();
          expect(rows, hasLength(mapHeight), reason: reason);
          expect(
            rows.every((row) => row.length == mapWidth && row.every((value) => value is double)),
            isTrue,
            reason: reason,
          );
        }
        final eyeDepth = (entry['eyeDepth'] as List).cast<List<dynamic>>();
        expect(
          eyeDepth.every((row) => row.length == eyeWidth && row.every((value) => value is double)),
          isTrue,
          reason: reason,
        );
        final holes = (entry['holes'] as List).cast<String>();
        expect(holes.every((row) => RegExp('^[01]{$eyeWidth}\$').hasMatch(row)), isTrue, reason: reason);
        expect(holes.join().split('').where((cell) => cell == '1').length, entry['filledPixels'], reason: reason);
        final flags = (entry['flags'] as List).cast<String>();
        expect(flags.map(ReliefQualityFlag.fromXmp), everyElement(isNotNull), reason: reason);
        expect(
          qualityFlagsToXmp(flags.map((flag) => ReliefQualityFlag.fromXmp(flag)!)),
          flags.join(','),
          reason: reason,
        );
      }
    });

    test('covers the cases the ports must meet', () {
      expect(cases.map((entry) => entry['name']), ['production', 'strong', 'flat', 'dark']);
      expect(named('production')['filledPixels'], 0);
      expect(named('strong')['flags'], ['hiddenAreas']);
      expect(named('flat')['flags'], ['lowRelief']);
      expect(named('dark')['flags'], ['lowRelief', 'dark']);
    });
  });
}
