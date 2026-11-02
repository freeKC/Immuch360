// The "AV2" badge of the thumbnails of the folder library (av2_badge.dart; store/m2/av2-2026-11-02/plan-2026-11-02.md,
// section 1.2): read from the index, again when a local sync ends, on a video the scan found AV2, in the primary colour
// as the "3D splat" badge; nothing on another video, a photo, or a phone.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/library/stereo_badge.dart';
import 'package:immich_mobile/desktop/library/folder_library_controller.dart';
import 'package:immich_mobile/desktop/video/av2_badge.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:path/path.dart' as p;

import '../../../unit/presentation/presentation_context.dart';
import '../../library/library_test_support.dart';

LocalAsset _video(String id, String name, {AssetType type = AssetType.video}) => LocalAsset(
  id: id,
  name: name,
  type: type,
  createdAt: DateTime(2026, 11, 2),
  updatedAt: DateTime(2026, 11, 2),
  width: 256,
  height: 144,
  durationMs: 400,
  playbackStyle: type == AssetType.video ? AssetPlaybackStyle.video : AssetPlaybackStyle.image,
  isEdited: false,
);

void main() {
  group('the AV2 videos of the library', () {
    late TestLibrary fixture;

    setUp(() {
      fixture = TestLibrary();
      fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
    });
    tearDown(() => fixture.dispose());

    test('are read from the index again when a local sync ends, so that a new one shows its badge', () async {
      fixture.write('Clips/old.ivf', File(p.join('test/fixtures/av2', 'av2-256x144-8bit.ivf')).readAsBytesSync());
      final library = fixture.library();
      final root = library.addRoot(p.join(fixture.files.path, 'Clips'));
      await fixture.scan();
      final container = ProviderContainer(overrides: [folderLibraryProvider.overrideWith((ref) async => library)]);
      addTearDown(container.dispose);
      expect(await container.read(av2LibraryVideosProvider.future), {fixture.ids.file(root.id, 'old.ivf')});

      fixture.write('Clips/new.obu', File(p.join('test/fixtures/av2', 'av2-256x144-10bit.obu')).readAsBytesSync());
      await fixture.scan();
      final sync = container.read(syncStatusProvider.notifier);
      sync.startLocalSync();
      sync.completeLocalSync();
      expect(await container.read(av2LibraryVideosProvider.future), {
        fixture.ids.file(root.id, 'old.ivf'),
        fixture.ids.file(root.id, 'new.obu'),
      });
    });
  });

  group('the badge of a thumbnail', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late PresentationContext context;

    setUp(() async => context = await PresentationContext.create());
    tearDown(() async => context.dispose());

    Future<void> pumpBadge(WidgetTester tester, BaseAsset asset, Set<String> av2) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpTestWidget(
        context,
        ColoredBox(
          color: Colors.black,
          child: DesktopAv2Badge(asset: asset),
        ),
        overrides: [av2LibraryVideosProvider.overrideWith((ref) async => av2)],
      );
    }

    testWidgets('"AV2" in the primary colour, as the 3D splat badge, on a video the index knows as AV2', (
      tester,
    ) async {
      await pumpBadge(tester, _video('v1', 'clip.ivf'), {'v1'});
      expect(find.text('AV2'), findsOneWidget);
      final text = tester.widget<Text>(find.text('AV2'));
      final theme = Theme.of(tester.element(find.text('AV2')));
      expect(text.style?.color, theme.colorScheme.primary);
      expect(text.style?.fontWeight, FontWeight.w700);
    });

    testWidgets('nothing on another video, on a photo, nor on a video the index does not hold', (tester) async {
      await pumpBadge(tester, _video('v2', 'clip.mp4'), {'v1'});
      expect(find.text('AV2'), findsNothing);
      await pumpBadge(tester, _video('v1', 'photo.jpg', type: AssetType.image), {'v1'});
      expect(find.text('AV2'), findsNothing);
      await pumpBadge(tester, _video('v3', 'other.ivf'), {});
      expect(find.text('AV2'), findsNothing);
    });

    Future<void> pumpTile(WidgetTester tester, BaseAsset asset) async {
      await tester.pumpTestWidget(
        context,
        SizedBox.square(dimension: 200, child: ThumbnailTile(asset)),
        overrides: [
          av2LibraryVideosProvider.overrideWith((ref) async => {'v1'}),
          generatedVersionsProvider.overrideWith((ref) async => {}),
          isPanoramaProvider(asset).overrideWith((ref) => false),
        ],
        expectSettle: false,
      );
      await tester.pump();
      // The thumbnail itself does not load in a test
      tester.takeException();
    }

    testWidgets('the thumbnail of a computer shows it beside the other badges', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pumpTile(tester, _video('v1', 'clip.ivf'));
        expect(find.byType(DesktopAv2Badge), findsOneWidget);
        expect(find.text('AV2'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('the thumbnail of a phone does not', (tester) async {
      await pumpTile(tester, _video('v1', 'clip.ivf'));
      expect(find.byType(DesktopAv2Badge), findsNothing);
      expect(find.text('AV2'), findsNothing);
    });
  });
}
