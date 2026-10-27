// The badges of the thumbnails of a computer: "3D AI", "3D scene" and "360° AI" by the kind and the origin the index
// keeps from our XMP, "3D" for another tool's file by its name and frame, nothing for an ordinary photo or a 360° one,
// nothing for a file of ours of a later format, and nothing on a phone.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/library/stereo_badge.dart';
import 'package:immich_mobile/desktop/library/folder_library_controller.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:path/path.dart' as p;

import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';
import '../../library/library_fixtures.dart';
import '../../library/library_test_support.dart';
import '../fakes/fake_immersive_engine.dart';
import 'version_fixtures.dart';

LocalAsset _photo(String id, String name, {int? width, int? height}) => LocalAsset(
  id: id,
  name: name,
  type: AssetType.image,
  createdAt: DateTime(2026, 10, 27),
  updatedAt: DateTime(2026, 10, 27),
  width: width,
  height: height,
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);

void main() {
  group('stereoBadgeOf', () {
    const estimatedPhoto = (origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPhoto);

    test('a relief estimated by AI is "3D AI", whatever its name, even renamed', () {
      expect(
        stereoBadgeOf(version: estimatedPhoto, name: 'living room.jpg', width: 8000, height: 3000),
        StereoBadge.estimatedRelief,
      );
      expect(
        stereoBadgeOf(version: estimatedPhoto, name: 'salon_3D_LRF_Full_SBS.jpg', isPanorama: true),
        StereoBadge.estimatedRelief,
      );
      // The 3D version of a 360° photo of the user: its relief is estimated, beside the 360° badge
      expect(
        stereoBadgeOf(
          version: (origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPanorama360),
          name: 'PANO_0001_3D.jpg',
          isPanorama: true,
        ),
        StereoBadge.estimatedRelief,
      );
    });

    test('a 3D scene is "3D scene", a generated panorama and its 3D version "360° AI", whatever their names', () {
      expect(
        stereoBadgeOf(
          version: (origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene),
          name: 'salon_scene3D.jpg',
          width: 2048,
          height: 1536,
        ),
        StereoBadge.scene,
      );
      expect(
        stereoBadgeOf(
          version: (origin: IndexedOrigin.generated, kind: ImmersiveKind.panorama360),
          name: 'sky.jpg',
          width: 8192,
          height: 4096,
          isPanorama: true,
        ),
        StereoBadge.generatedPanorama,
      );
      expect(
        stereoBadgeOf(
          version: (origin: IndexedOrigin.generated, kind: ImmersiveKind.stereoPanorama360),
          name: 'salon_360_3D.jpg',
          isPanorama: true,
        ),
        StereoBadge.generatedPanorama,
      );
    });

    test('a version not read again since the index learnt the kinds is told by its origin', () {
      expect(
        stereoBadgeOf(version: (origin: IndexedOrigin.estimated, kind: null), name: 'salon_3D_LRF_Full_SBS.jpg'),
        StereoBadge.estimatedRelief,
      );
      expect(
        stereoBadgeOf(version: (origin: IndexedOrigin.generated, kind: null), name: 'salon_360.jpg'),
        StereoBadge.generatedPanorama,
      );
      expect(
        stereoBadgeOf(version: (origin: IndexedOrigin.reconstructed, kind: null), name: 'salon_scene3D.jpg'),
        StereoBadge.scene,
      );
    });

    test('a file of ours whose origin this build does not know is no pair: no "3D", unless its kind says so', () {
      // A 3D scene a build of phase 1 indexed as "other", or a kind of a later format
      expect(
        stereoBadgeOf(version: (origin: IndexedOrigin.other, kind: null), name: 'salon_3D_LRF_Full_SBS.jpg'),
        isNull,
      );
      expect(
        stereoBadgeOf(
          version: (origin: IndexedOrigin.other, kind: null),
          name: 'beach_LRF_Full_SBS.png',
          width: 7680,
          height: 2160,
        ),
        isNull,
      );
      expect(
        stereoBadgeOf(version: (origin: IndexedOrigin.other, kind: ImmersiveKind.stereoPhoto), name: 'later.jpg'),
        StereoBadge.stereo,
      );
    });

    test('another photo of two eyes is "3D", by its name and a frame that fits', () {
      expect(
        stereoBadgeOf(version: null, name: 'beach_LRF_Full_SBS.png', width: 7680, height: 2160),
        StereoBadge.stereo,
      );
      expect(stereoBadgeOf(version: null, name: 'trip_sbs.jpg', width: 3840, height: 1080), StereoBadge.stereo);
      expect(stereoBadgeOf(version: null, name: 'scene_rl.jpg', width: 1920, height: 1080), StereoBadge.stereo);
    });

    test('an ordinary photo, a flat 3:1 panorama and another 360° photo have none', () {
      expect(stereoBadgeOf(version: null, name: 'IMG_0001.jpg', width: 4000, height: 3000), isNull);
      expect(stereoBadgeOf(version: null, name: 'pano.jpg', width: 6000, height: 2000), isNull);
      expect(stereoBadgeOf(version: null, name: 'trip_sbs.jpg', width: 8000, height: 2000, isPanorama: true), isNull);
    });
  });

  group('the versions the badges read', () {
    late TestLibrary fixture;
    setUp(() {
      fixture = TestLibrary();
      fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
    });
    tearDown(() => fixture.dispose());

    test('are read from the index again when a local sync ends, so that a new version shows its badge', () async {
      final original = jpegBytes(width: 40, height: 30);
      fixture.write('Photos/salon.jpg', original);
      final library = fixture.library();
      final root = library.addRoot(p.join(fixture.files.path, 'Photos'));
      await fixture.scan();
      final container = ProviderContainer(overrides: [folderLibraryProvider.overrideWith((ref) async => library)]);
      addTearDown(container.dispose);
      expect(await container.read(generatedVersionsProvider.future), isEmpty);

      // A 3D photo made meanwhile, which the scan of the next sync finds
      fixture.write('Photos/salon_3D_LRF_Full_SBS.jpg', fakeSbsJpeg(xmp: versionXmp(original)));
      await fixture.scan();
      final sync = container.read(syncStatusProvider.notifier);
      sync.startLocalSync();
      sync.completeLocalSync();

      final id = fixture.ids.file(root.id, 'salon_3D_LRF_Full_SBS.jpg');
      expect(await container.read(generatedVersionsProvider.future), {
        id: (origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPhoto),
      });
    });
  });

  group('the badge of a thumbnail', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late PresentationContext context;

    setUp(() async {
      context = await PresentationContext.create();
    });
    tearDown(() async => context.dispose());

    Future<void> pumpBadge(
      WidgetTester tester,
      BaseAsset asset, {
      Map<String, IndexedVersion> versions = const {},
      bool panorama = false,
    }) async {
      // A new tree each time: the overrides of a scope cannot change
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpTestWidget(
        context,
        ColoredBox(
          color: Colors.black,
          child: DesktopStereoBadge(asset: asset),
        ),
        overrides: [
          generatedVersionsProvider.overrideWith((ref) async => versions),
          isPanoramaProvider(asset).overrideWith((ref) => panorama),
        ],
      );
    }

    String tooltipOf(WidgetTester tester, String text) =>
        tester.widget<Tooltip>(find.ancestor(of: find.text(text), matching: find.byType(Tooltip))).message!;

    testWidgets('"3D AI" with the honesty label for a version the index knows', (tester) async {
      final version = _photo('f1', 'salon_3D_LRF_Full_SBS.jpg', width: 16, height: 6);
      await pumpBadge(
        tester,
        version,
        versions: {'f1': (origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPhoto)},
      );

      expect(find.text('3D AI'), findsOneWidget);
      expect(find.byKey(const Key('desktop_badge_3d')), findsNothing);
      expect(tooltipOf(tester, '3D AI'), 'Relief estimated by AI');
    });

    testWidgets('"3D scene" and "360° AI" with their honesty labels', (tester) async {
      await pumpBadge(
        tester,
        _photo('f5', 'salon_scene3D.jpg', width: 2048, height: 1536),
        versions: {'f5': (origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene)},
      );
      expect(find.byKey(const Key('desktop_badge_scene')), findsOneWidget);
      expect(find.text('3D scene'), findsOneWidget);
      expect(tooltipOf(tester, '3D scene'), 'Reconstructed from one photo, explore within its limits');

      // The 360° rules are not asked of a file of ours
      await pumpBadge(
        tester,
        _photo('f6', 'salon_360.jpg', width: 8192, height: 4096),
        versions: {'f6': (origin: IndexedOrigin.generated, kind: ImmersiveKind.panorama360)},
        panorama: true,
      );
      expect(find.byKey(const Key('desktop_badge_360_ai')), findsOneWidget);
      expect(find.text('360° AI'), findsOneWidget);
      expect(tooltipOf(tester, '360° AI'), "Generated by AI beyond the photo's edges");
    });

    testWidgets('nothing for a file of ours of a later format, even named like a 3D photo', (tester) async {
      await pumpBadge(
        tester,
        _photo('f7', 'salon_3D_LRF_Full_SBS.jpg', width: 16, height: 6),
        versions: {'f7': (origin: IndexedOrigin.other, kind: null)},
      );
      for (final key in ['desktop_badge_3d', 'desktop_badge_3d_ai', 'desktop_badge_scene', 'desktop_badge_360_ai']) {
        expect(find.byKey(Key(key)), findsNothing, reason: key);
      }
    });

    testWidgets('"3D" for another tool\'s file, and for a file named like ours the index does not hold', (
      tester,
    ) async {
      await pumpBadge(tester, _photo('f2', 'beach_LRF_Full_SBS.jpg', width: 7680, height: 2160));
      expect(find.text('3D'), findsOneWidget);
      expect(find.text('3D AI'), findsNothing);

      // A server asset: no local id, the name and the frame tell
      await pumpBadge(tester, RemoteAssetFactory.create(name: 'trip_sbs.jpg', width: 3840, height: 1080));
      expect(find.text('3D'), findsOneWidget);
    });

    testWidgets('nothing for an ordinary photo, a 360° photo, or a video', (tester) async {
      await pumpBadge(tester, _photo('f3', 'IMG_0001.jpg', width: 4000, height: 3000));
      expect(find.byKey(const Key('desktop_badge_3d')), findsNothing);
      expect(find.byKey(const Key('desktop_badge_3d_ai')), findsNothing);

      await pumpBadge(tester, _photo('f4', 'trip_sbs.jpg', width: 8000, height: 2000), panorama: true);
      expect(find.byKey(const Key('desktop_badge_3d')), findsNothing);

      await pumpBadge(
        tester,
        RemoteAssetFactory.create(name: 'clip_sbs.mp4', type: AssetType.video, width: 3840, height: 1080),
      );
      expect(find.byKey(const Key('desktop_badge_3d')), findsNothing);
    });

    Future<void> pumpTile(WidgetTester tester, BaseAsset asset, Map<String, IndexedVersion> versions) async {
      await tester.pumpTestWidget(
        context,
        SizedBox.square(dimension: 200, child: ThumbnailTile(asset)),
        overrides: [
          generatedVersionsProvider.overrideWith((ref) async => versions),
          isPanoramaProvider(asset).overrideWith((ref) => false),
        ],
        expectSettle: false,
      );
      await tester.pump();
      // The thumbnail itself does not load in a test
      tester.takeException();
    }

    testWidgets('the thumbnail of a computer shows it beside the other badges', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final version = _photo('f1', 'salon_3D_LRF_Full_SBS.jpg', width: 16, height: 6);
        await pumpTile(tester, version, {'f1': (origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPhoto)});
        expect(find.byType(DesktopStereoBadge), findsOneWidget);
        expect(find.text('3D AI'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('the thumbnail of a phone does not', (tester) async {
      final version = _photo('f1', 'salon_3D_LRF_Full_SBS.jpg', width: 16, height: 6);
      await pumpTile(tester, version, {'f1': (origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPhoto)});
      expect(find.byType(DesktopStereoBadge), findsNothing);
      expect(find.text('3D AI'), findsNothing);
    });
  });
}
