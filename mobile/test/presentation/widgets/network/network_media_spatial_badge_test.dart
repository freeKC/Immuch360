import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/generated_panorama.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';

import '../../../domain/ai_immersive/stereo_photo_fixtures.dart';
import '../../../unit/presentation/presentation_context.dart';

/// No upload under way
class _IdleUpload extends NetworkUploadNotifier {
  @override
  NetworkUploadState build() => const NetworkUploadState();
}

/// No file of the share sent to the server yet: the records are not read from a store
class _NoRecords extends NetworkUploadRecordsNotifier {
  @override
  Map<String, UploadRecord> build() => const {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  const pair = HeicStereoPair(
    primaryItemId: 37,
    leftItemId: 37,
    rightItemId: 74,
    pitmIdOffset: 129,
    pitmIdBytes: 2,
    width: 3072,
    height: 3072,
  );
  final spatialBadge = find.byKey(const Key('network_media_spatial_badge'));
  final badge360 = find.byKey(const Key('network_media_360_badge'));

  NetworkEntry entry(String path) =>
      NetworkEntry(sourceId: 'nas', path: path, isDirectory: false, size: 1000, modified: DateTime.utc(2026, 10, 1));

  /// The tile of [file], whose file declares [info]
  Future<void> pumpTile(WidgetTester tester, NetworkEntry file, NetworkMediaInfo? info) => tester.pumpTestWidget(
    context,
    SizedBox(
      width: 120,
      height: 120,
      child: NetworkMediaTile(entry: file, url: null, onTap: () {}),
    ),
    overrides: [
      networkMediaInfoProvider(networkMediaKey(file)).overrideWith((ref) async => info),
      networkUploadRecordsProvider.overrideWith(_NoRecords.new),
      networkUploadProvider.overrideWith(_IdleUpload.new),
    ],
  );

  testWidgets('a spatial photo gets a 3D badge', (tester) async {
    await pumpTile(tester, entry('/IMG_0001.HEIC'), const NetworkMediaInfo(stereoPair: pair));

    expect(spatialBadge, findsOneWidget);
    expect(find.descendant(of: spatialBadge, matching: find.text('3D')), findsOneWidget);
    expect(badge360, findsNothing);
  });

  testWidgets('a spatial video gets a 3D badge', (tester) async {
    await pumpTile(
      tester,
      entry('/IMG_0002.MOV'),
      const NetworkMediaInfo(
        probe: SphericalProbe(codec: 'hvc1', multiview: MultiviewInfo(heroEye: 1)),
      ),
    );

    expect(spatialBadge, findsOneWidget);
  });

  testWidgets('a flat photo gets none', (tester) async {
    await pumpTile(tester, entry('/IMG_0003.HEIC'), const NetworkMediaInfo());

    expect(spatialBadge, findsNothing);
  });

  testWidgets('a file not read yet gets none', (tester) async {
    await pumpTile(tester, entry('/IMG_0004.HEIC'), null);

    expect(spatialBadge, findsNothing);
  });

  group('flat 3D photos', () {
    final aiBadge = find.byKey(const Key('network_media_ai_3d_badge'));

    testWidgets('one of ours gets the 3D AI badge: its relief was estimated', (tester) async {
      await pumpTile(
        tester,
        entry('/salon_3D_LRF_Full_SBS.jpg'),
        NetworkMediaInfo(
          stereoPhoto: FlatStereoPhoto(eyes: StereoEyes.full, xmp: ourXmp()),
        ),
      );

      expect(aiBadge, findsOneWidget);
      expect(find.descendant(of: aiBadge, matching: find.text('3D AI')), findsOneWidget);
      expect(spatialBadge, findsNothing);
    });

    testWidgets('the side by side file of another tool gets the plain 3D badge', (tester) async {
      await pumpTile(
        tester,
        entry('/trip_LRF_Full_SBS.png'),
        const NetworkMediaInfo(stereoPhoto: FlatStereoPhoto(eyes: StereoEyes.full)),
      );

      expect(spatialBadge, findsOneWidget);
      expect(find.descendant(of: spatialBadge, matching: find.text('3D')), findsOneWidget);
      expect(aiBadge, findsNothing);
    });

    test('the badge of each kind of file', () {
      expect(networkStereoBadgeOf(null), isNull);
      expect(networkStereoBadgeOf(const NetworkMediaInfo()), isNull);
      expect(networkStereoBadgeOf(const NetworkMediaInfo(stereoPair: pair)), NetworkStereoBadge.stereo);
      expect(
        networkStereoBadgeOf(const NetworkMediaInfo(stereoPhoto: FlatStereoPhoto(eyes: StereoEyes.half))),
        NetworkStereoBadge.stereo,
      );
      expect(
        networkStereoBadgeOf(
          NetworkMediaInfo(
            stereoPhoto: FlatStereoPhoto(eyes: StereoEyes.full, xmp: ourXmp()),
          ),
        ),
        NetworkStereoBadge.estimated,
      );
    });
  });

  testWidgets('a photo that carries a 3D scene gets the "3D scene" badge, never the 3D one', (tester) async {
    final scene =
        ImmersiveXmp.parse(File('test/fixtures/ai_immersive/xmp_v1_scene_sample.xmp').readAsStringSync())! as SceneXmp;
    await pumpTile(tester, entry('/salon_scene3D.jpg'), NetworkMediaInfo(scene: scene));

    final sceneBadge = find.byKey(const Key('network_media_scene_badge'));
    expect(sceneBadge, findsOneWidget);
    expect(find.descendant(of: sceneBadge, matching: find.text('3D scene')), findsOneWidget);
    expect(spatialBadge, findsNothing);
    expect(networkStereoBadgeOf(NetworkMediaInfo(scene: scene)), NetworkStereoBadge.scene);
  });

  group('panoramas generated beyond the edges of a photo', () {
    final panoramaSample = File('test/fixtures/ai_immersive/xmp_v1_panorama_sample.xmp').readAsStringSync();
    final stereoSample = File('test/fixtures/ai_immersive/xmp_v1_stereo_panorama_sample.xmp').readAsStringSync();
    const gpano = (projectionType: 'equirectangular', crop: null, initialView: null);

    testWidgets('a panorama of ours gets the "360° AI" badge next to the 360° one, its honesty label', (tester) async {
      final panorama = generatedPanoramaOfHead(jpegFile(width: 8192, height: 4096, xmpText: panoramaSample));
      await pumpTile(tester, entry('/salon_360.jpg'), NetworkMediaInfo(gpano: gpano, panorama: panorama));

      final aiBadge360 = find.byKey(const Key('network_media_ai_360_badge'));
      expect(aiBadge360, findsOneWidget);
      expect(find.descendant(of: aiBadge360, matching: find.text('360° AI')), findsOneWidget);
      expect(badge360, findsOneWidget);
      expect(tester.getTopRight(aiBadge360).dx, lessThan(tester.getTopLeft(badge360).dx));
      expect(spatialBadge, findsNothing);
    });

    test('its 3D version gets "360° AI" too, the 3D version of a 360° photo of the user "3D AI"', () {
      final stereo = generatedPanoramaOfHead(jpegFile(width: 4096, height: 4096, xmpText: stereoSample));
      final user = generatedPanoramaOfHead(
        jpegFile(
          width: 4096,
          height: 4096,
          xmpText: stereoSample
              .replaceFirst('Immuch360:Origin="GeneratedContent"', 'Immuch360:Origin="EstimatedDepth"')
              .replaceFirst(RegExp(r'\s*Immuch360:Relief="[^"]*"'), ''),
        ),
      );

      expect(
        networkStereoBadgeOf(NetworkMediaInfo(gpano: gpano, panorama: stereo)),
        NetworkStereoBadge.generatedPanorama,
      );
      expect(networkStereoBadgeOf(NetworkMediaInfo(gpano: gpano, panorama: user)), NetworkStereoBadge.estimated);
      // An ordinary 360° photo keeps its 360° badge alone
      expect(networkStereoBadgeOf(const NetworkMediaInfo(gpano: gpano)), isNull);
    });
  });

  testWidgets('next to the 360° badge when both show', (tester) async {
    await pumpTile(
      tester,
      entry('/both.mov'),
      const NetworkMediaInfo(
        probe: SphericalProbe(hasSphericalMetadata: true, codec: 'hvc1', multiview: MultiviewInfo(heroEye: 1)),
      ),
    );

    expect(spatialBadge, findsOneWidget);
    expect(badge360, findsOneWidget);
    expect(tester.getTopRight(spatialBadge).dx, lessThan(tester.getTopLeft(badge360).dx));
  });

  group('flat 3D media told by their file name', () {
    test('a video named as holding two eyes, or a photo of two eyes one above the other, gets the 3D badge', () {
      const videos = ['Movie_SBS.mp4', 'Movie.3D.Half-SBS.mkv', 'clip_LR.mp4', 'Movie.Half-OU.mkv', 'clip_TB.mp4'];
      for (final name in videos) {
        expect(
          networkStereoBadgeOf(null, name: name, isVideo: true, byName: true),
          NetworkStereoBadge.stereo,
          reason: name,
        );
      }
      expect(networkStereoBadgeOf(null, name: 'street_TB.jpg', byName: true), NetworkStereoBadge.stereo);
      expect(networkStereoBadgeOf(const NetworkMediaInfo(), name: 'street_HTB.jpg', byName: true), isNotNull);
    });

    test('nothing for an ordinary or a 360° file, with the switch off, nor by name for a side by side photo', () {
      expect(networkStereoBadgeOf(null, name: 'clip.mp4', isVideo: true, byName: true), isNull);
      expect(networkStereoBadgeOf(null, name: 'trip_360_SBS.mp4', isVideo: true, byName: true), isNull);
      expect(
        networkStereoBadgeOf(
          const NetworkMediaInfo(probe: SphericalProbe(hasSphericalMetadata: true)),
          name: 'trip_SBS.mp4',
          isVideo: true,
          byName: true,
        ),
        isNull,
        reason: 'its file declares 360°',
      );
      expect(networkStereoBadgeOf(null, name: 'Movie_SBS.mp4', isVideo: true), isNull, reason: 'switch off');
      // A side by side photo waits for its head, which our XMP may make "3D AI"
      expect(networkStereoBadgeOf(null, name: 'beach-da2-SBS.png', byName: true), isNull);
    });

    testWidgets('the tile of such a video shows it before anything is read', (tester) async {
      await pumpTile(tester, entry('/Movie.3D.Half-SBS.mkv'), null);

      expect(spatialBadge, findsOneWidget);
      expect(find.descendant(of: spatialBadge, matching: find.text('3D')), findsOneWidget);
    });
  });
}
