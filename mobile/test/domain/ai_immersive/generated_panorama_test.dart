// What the viewers read of a panorama a computer generated beyond the edges of a photo (design-final 2026-10-27,
// section 5, lot P4): our packet at the head of its file, the samples of the contract (xmp_v1_panorama_sample.xmp,
// xmp_v1_stereo_panorama_sample.xmp), the outline of its photo as pano-v1 placed it, and the labels the immersive
// viewer of the Quest gets.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/generated_panorama.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';

import '../../widget_tester_extensions.dart';
import 'stereo_photo_fixtures.dart';

void main() {
  final panoramaSample = File('test/fixtures/ai_immersive/xmp_v1_panorama_sample.xmp').readAsStringSync();
  final stereoSample = File('test/fixtures/ai_immersive/xmp_v1_stereo_panorama_sample.xmp').readAsStringSync();
  final sceneSample = File('test/fixtures/ai_immersive/xmp_v1_scene_sample.xmp').readAsStringSync();
  final sbsSample = File('test/fixtures/ai_immersive/xmp_v1_sample.xmp').readAsStringSync();

  String withField(String packet, String field, String value) =>
      packet.replaceFirst(RegExp('Immuch360:$field="[^"]*"'), 'Immuch360:$field="$value"');

  /// The 3D version of a 360° photo of the user: the stereo sample made from a photo of the user, no Relief field
  String userStereo360() =>
      withField(stereoSample, 'Origin', 'EstimatedDepth').replaceFirst(RegExp(r'\s*Immuch360:Relief="[^"]*"'), '');

  const photo = PhotoRegion(yaw: 0, pitch: 0, hfov: 65.4, vfov: 50.6);

  group('the packet at the head of a file', () {
    test('a panorama we generated: its photo and its flags', () {
      final info = generatedPanoramaOfHead(jpegFile(width: 8192, height: 4096, xmpText: panoramaSample))!;

      expect(info.kind, ImmersiveKind.panorama360);
      expect(info.isGenerated, isTrue);
      expect(info.isEstimatedRelief, isFalse);
      expect(info.region, photo);
      expect(info.flags, [ReliefQualityFlag.fovGuessed]);
    });

    test('its 3D version: generated too, the photo copied from the panorama', () {
      final info = generatedPanoramaOfHead(jpegFile(width: 4096, height: 4096, xmpText: stereoSample))!;

      expect(info.kind, ImmersiveKind.stereoPanorama360);
      expect(info.isGenerated, isTrue);
      expect(info.region, photo);
    });

    test('the 3D version of a 360° photo of the user: a relief estimated by AI, nothing generated', () {
      final info = generatedPanoramaOfHead(jpegFile(width: 4096, height: 4096, xmpText: userStereo360()))!;

      expect(info.isGenerated, isFalse);
      expect(info.isEstimatedRelief, isTrue);
    });

    test('nothing for a photo without our packet, a 3D photo, a scene, nor a panorama of an unknown origin', () {
      expect(generatedPanoramaOfHead(jpegFile(width: 8192, height: 4096, segments: [gpanoSegment()])), isNull);
      expect(generatedPanoramaOfHead(jpegFile(width: 8000, height: 3000, xmpText: sbsSample)), isNull);
      expect(generatedPanoramaOfHead(jpegFile(width: 2048, height: 1536, xmpText: sceneSample)), isNull);
      final unknown = withField(panoramaSample, 'Origin', 'Unknown');
      expect(generatedPanoramaOfHead(jpegFile(width: 8192, height: 4096, xmpText: unknown)), isNull);
    });

    test('a packet of a newer format still says generated, its photo is not used', () {
      final newer = withField(panoramaSample, 'FormatVersion', '2');
      final info = generatedPanoramaOfHead(jpegFile(width: 8192, height: 4096, xmpText: newer))!;

      expect(info.isGenerated, isTrue);
      expect(info.region, isNull);
    });

    test('our panoramas write no initial view: the viewers open on the photo, at the centre column', () {
      expect(parseGPanoInitialView(panoramaSample), isNull);
      expect(parseGPanoInitialView(stereoSample), isNull);
    });
  });

  group('the outline of the photo', () {
    double radians(double degrees) => degrees * math.pi / 180;

    /// The direction of a point of the sphere, x right, y up, z ahead
    List<double> direction(SpherePoint point) => [
      math.cos(radians(point.latitude)) * math.sin(radians(point.longitude)),
      math.sin(radians(point.latitude)),
      math.cos(radians(point.latitude)) * math.cos(radians(point.longitude)),
    ];

    test('its arcs stay on the edges of the photo as the golden projection places them', () {
      final t = math.tan(radians(65.4) / 2);
      final s = math.tan(radians(50.6) / 2);
      final arcs = photoRegionOutline(photo, segments: 16);

      expect(arcs, hasLength(4));
      for (final (k, arc) in arcs.indexed) {
        expect(arc, hasLength(17));
        for (final point in arc) {
          final d = direction(point);
          final a = d[0] / d[2];
          final b = d[1] / d[2];
          final (onEdge, expected) = switch (k) {
            0 => (b, s),
            1 => (a, t),
            2 => (b, -s),
            _ => (a, -t),
          };
          expect(onEdge, closeTo(expected, 1e-9), reason: 'arc $k');
        }
        // From one corner to the next
        expect(arc.last, arcs[(k + 1) % 4].first);
      }
      // The middle of the top edge is straight above the centre, half the vertical field higher
      expect(arcs[0][8].longitude, closeTo(0, 1e-9));
      expect(arcs[0][8].latitude, closeTo(25.3, 1e-9));
      expect(arcs[0][0].latitude, lessThan(25.3), reason: 'the top edge bends down towards the corners');
    });

    test('a photo turned to the right and looking up turns its outline with it', () {
      final arcs = photoRegionOutline(const PhotoRegion(yaw: 40, pitch: 20, hfov: 60, vfov: 45), segments: 2);

      expect(arcs[0][1].longitude, closeTo(40, 1e-9));
      expect(arcs[0][1].latitude, closeTo(42.5, 1e-9));
      expect(arcs[1][1].longitude, greaterThan(40));
    });
  });

  /// The English texts, from a widget under the app's localisation, which loads them for the static translations too
  Future<Translations> english(WidgetTester tester) async {
    late Translations t;
    await tester.pumpConsumerWidget(
      Builder(
        builder: (context) {
          t = context.t;
          return const SizedBox();
        },
      ),
    );
    return t;
  }

  testWidgets('every opening of the immersive viewer carries them, a label of the opener winning', (tester) async {
    await english(tester);
    final labels = immersiveOpeningLabels({'stereo': '3D', generatedNoticeLabelKey: 'Made beyond the edges'});

    expect(labels['stereo'], '3D');
    expect(labels[generatedNoticeLabelKey], 'Made beyond the edges');
    expect(labels[photoRegionLabelKey], 'The original photo');
    expect(labels['panoramaFlag_seam'], 'The seam may be visible');
  });

  testWidgets('the immersive viewer of the Quest gets the texts of a panorama of ours, under the keys it reads', (
    tester,
  ) async {
    final labels = generatedPanoramaViewerLabels(await english(tester));

    expect(labels[generatedNoticeLabelKey], "Generated by AI beyond the photo's edges");
    expect(labels[photoRegionLabelKey], 'The original photo');
    expect(labels['aiReliefEstimated'], 'Relief estimated by AI');
    expect(labels['panoramaFlag_seam'], 'The seam may be visible');
    expect(labels['panoramaFlag_mostlyInvented'], 'Most of this panorama is invented');
    expect(labels.keys.where((key) => key.startsWith(panoramaFlagLabelPrefix)), {
      'panoramaFlag_lowRelief',
      'panoramaFlag_hiddenAreas',
      'panoramaFlag_fovGuessed',
      'panoramaFlag_seam',
      'panoramaFlag_mostlyInvented',
    });
  });
}
