// The badges of the thumbnails of a computer for the photos of two eyes side by side: "3D AI" by the origin the index
// keeps from our XMP, "3D" for another tool's file by its name and frame, nothing for an ordinary photo or a 360°
// one, and nothing on a phone.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/library/stereo_badge.dart';
import 'package:immich_mobile/desktop/library/folder_library_controller.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
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
    test('a relief estimated by AI is "3D AI", whatever its name, even renamed', () {
      expect(
        stereoBadgeOf(origin: IndexedOrigin.estimated, name: 'living room.jpg', width: 8000, height: 3000),
        StereoBadge.estimatedRelief,
      );
      expect(
        stereoBadgeOf(origin: IndexedOrigin.estimated, name: 'salon_3D_LRF_Full_SBS.jpg', isPanorama: true),
        StereoBadge.estimatedRelief,
      );
    });

    test('another photo of two eyes is "3D", by its name and a frame that fits', () {
      expect(
        stereoBadgeOf(origin: null, name: 'beach_LRF_Full_SBS.png', width: 7680, height: 2160),
        StereoBadge.stereo,
      );
      expect(stereoBadgeOf(origin: null, name: 'trip_sbs.jpg', width: 3840, height: 1080), StereoBadge.stereo);
      expect(stereoBadgeOf(origin: null, name: 'scene_rl.jpg', width: 1920, height: 1080), StereoBadge.stereo);
      // A file the app made from something else than one photo, of a later format
      expect(stereoBadgeOf(origin: IndexedOrigin.other, name: 'later.jpg'), StereoBadge.stereo);
    });

    test('an ordinary photo, a flat 3:1 panorama and a 360° photo have none', () {
      expect(stereoBadgeOf(origin: null, name: 'IMG_0001.jpg', width: 4000, height: 3000), isNull);
      expect(stereoBadgeOf(origin: null, name: 'pano.jpg', width: 6000, height: 2000), isNull);
      expect(stereoBadgeOf(origin: null, name: 'trip_sbs.jpg', width: 8000, height: 2000, isPanorama: true), isNull);
      // A generated panorama keeps the 360° badge
      expect(stereoBadgeOf(origin: IndexedOrigin.generated, name: 'sky.jpg', width: 8000, height: 4000), isNull);
    });
  });

  group('the origins the badges read', () {
    late TestLibrary fixture;
    setUp(() {
      fixture = TestLibrary();
      fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
    });
    tearDown(() => fixture.dispose());

    test('are read from the index again when a local sync ends, so that a new version shows "3D AI"', () async {
      final original = jpegBytes(width: 40, height: 30);
      fixture.write('Photos/salon.jpg', original);
      final library = fixture.library();
      final root = library.addRoot(p.join(fixture.files.path, 'Photos'));
      await fixture.scan();
      final container = ProviderContainer(overrides: [folderLibraryProvider.overrideWith((ref) async => library)]);
      addTearDown(container.dispose);
      expect(await container.read(generatedOriginsProvider.future), isEmpty);

      // A 3D photo made meanwhile, which the scan of the next sync finds
      fixture.write('Photos/salon_3D_LRF_Full_SBS.jpg', fakeSbsJpeg(xmp: versionXmp(original)));
      await fixture.scan();
      final sync = container.read(syncStatusProvider.notifier);
      sync.startLocalSync();
      sync.completeLocalSync();

      final id = fixture.ids.file(root.id, 'salon_3D_LRF_Full_SBS.jpg');
      expect(await container.read(generatedOriginsProvider.future), {id: IndexedOrigin.estimated});
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
      Map<String, IndexedOrigin> origins = const {},
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
          generatedOriginsProvider.overrideWith((ref) async => origins),
          isPanoramaProvider(asset).overrideWith((ref) => panorama),
        ],
      );
    }

    testWidgets('"3D AI" with the honesty label for a version the index knows', (tester) async {
      final version = _photo('f1', 'salon_3D_LRF_Full_SBS.jpg', width: 16, height: 6);
      await pumpBadge(tester, version, origins: {'f1': IndexedOrigin.estimated});

      expect(find.text('3D AI'), findsOneWidget);
      expect(find.byKey(const Key('desktop_badge_3d')), findsNothing);
      final tooltip = tester.widget<Tooltip>(find.ancestor(of: find.text('3D AI'), matching: find.byType(Tooltip)));
      expect(tooltip.message, 'Relief estimated by AI');
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

    Future<void> pumpTile(WidgetTester tester, BaseAsset asset, Map<String, IndexedOrigin> origins) async {
      await tester.pumpTestWidget(
        context,
        SizedBox.square(dimension: 200, child: ThumbnailTile(asset)),
        overrides: [
          generatedOriginsProvider.overrideWith((ref) async => origins),
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
        await pumpTile(tester, version, {'f1': IndexedOrigin.estimated});
        expect(find.byType(DesktopStereoBadge), findsOneWidget);
        expect(find.text('3D AI'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('the thumbnail of a phone does not', (tester) async {
      final version = _photo('f1', 'salon_3D_LRF_Full_SBS.jpg', width: 16, height: 6);
      await pumpTile(tester, version, {'f1': IndexedOrigin.estimated});
      expect(find.byType(DesktopStereoBadge), findsNothing);
      expect(find.text('3D AI'), findsNothing);
    });
  });
}
