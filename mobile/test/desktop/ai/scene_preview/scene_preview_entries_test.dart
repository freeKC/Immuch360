// Where "Preview in 3D" opens on a computer (design-final 2026-10-27, sections 2.7 and 9.1): the top bar of the
// viewer on a photo that carries a 3D scene (its head read only when the index or its name says it may be one, greyed
// with its reason for a later format), the row of a scene in "Versions" of its original, and the line of a finished
// scene in the panel of the conversions, the panel staying under the preview.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/library/stereo_badge.dart';
import 'package:immich_mobile/desktop/ai/library/versions.provider.dart';
import 'package:immich_mobile/desktop/ai/library/versions_section.dart';
import 'package:immich_mobile/desktop/ai/scene_preview/scene_preview.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:path/path.dart' as p;

import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';
import '../../../widget_tester_extensions.dart';
import '../fakes/fake_conversion_engines.dart';
import '../fakes/fake_conversion_output.dart';
import '../fakes/fake_immersive_engine.dart';
import '../fakes/fake_scene_engine.dart';
import '../scene/glb_reader_test_files.dart';
import '../ui/settle_still.dart';

LocalAsset _photo(String id, String name) => LocalAsset(
  id: id,
  name: name,
  type: AssetType.image,
  createdAt: DateTime(2026, 10, 28),
  updatedAt: DateTime(2026, 10, 28),
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);

/// The files of the computer by the id of their asset, and the ids asked
class _Storage extends StorageRepository {
  _Storage(this.files);

  final Map<String, String> files;
  final asked = <String>[];

  @override
  Future<File?> getFileForAsset(String assetId) async {
    asked.add(assetId);
    final path = files[assetId];
    return path == null ? null : File(path);
  }
}

VersionFile _version(String path, {IndexedOrigin? origin, ImmersiveKind? kind}) => VersionFile(
  file: LibraryFile(
    assetId: 'f${path.hashCode.toRadixString(16)}',
    path: path,
    name: p.basename(path),
    kind: LibraryMediaKind.image,
    size: 1000,
    modifiedMs: 0,
    createdSeconds: 0,
    mimeType: 'image/jpeg',
    cloudOnly: false,
    available: true,
  ),
  origin: origin,
  kind: kind,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late List<String> previewed;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('scene_preview_entries');
    previewed = [];
  });
  tearDown(() => folder.deleteSync(recursive: true));

  String fileOf(String name, List<int> bytes) {
    final path = p.join(folder.path, name);
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  group('the photos whose head is read for a scene', () {
    test('our index says a scene, or, for a file it does not hold, the word scene3D of its name', () {
      const scene = (origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene);
      const oldScene = (origin: IndexedOrigin.reconstructed, kind: null);
      const photo3d = (origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPhoto);
      expect(mayCarryScene(name: 'renamed.jpg', version: scene), isTrue);
      expect(mayCarryScene(name: 'renamed.jpg', version: oldScene), isTrue);
      expect(mayCarryScene(name: 'salon_scene3D.jpg', version: photo3d), isFalse);
      expect(mayCarryScene(name: 'salon_scene3D.jpg'), isTrue);
      expect(mayCarryScene(name: 'salon_scene3D (1).JPG'), isTrue);
      expect(mayCarryScene(name: 'Salon-Scene3D.jpeg'), isTrue);
      expect(mayCarryScene(name: 'IMG_1234.jpg'), isFalse);
      expect(mayCarryScene(name: 'salonscene3D.jpg'), isFalse);
      expect(mayCarryScene(name: 'salon_3D_LRF_Full_SBS.jpg'), isFalse);
      expect(isSceneVersion(ImmersiveKind.volumetricScene, IndexedOrigin.other), isTrue);
      expect(isSceneVersion(ImmersiveKind.panorama360, IndexedOrigin.reconstructed), isFalse);
    });

    test('the scene of a photo of the computer, read from its head; none for any other photo', () async {
      final scene = fileOf('salon_scene3D.jpg', tinySceneFile());
      final renamed = fileOf('renamed.jpg', tinySceneFile());
      final plain = fileOf('plain_scene3D.jpg', tinyImages()[0]);
      final ordinary = fileOf('IMG_1.jpg', tinySceneFile());
      // A packet of a later format: the same file, FormatVersion 2
      final text = latin1.decode(tinySceneFile());
      final later = fileOf(
        'later_scene3D.jpg',
        latin1.encode(text.replaceFirst('FormatVersion="1"', 'FormatVersion="2"')),
      );
      final storage = _Storage({'a': scene, 'b': renamed, 'c': plain, 'd': ordinary, 'e': later});
      final container = ProviderContainer(
        overrides: [
          storageRepositoryProvider.overrideWithValue(storage),
          generatedVersionsProvider.overrideWith(
            (ref) async => {'b': (origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene)},
          ),
        ],
      );
      addTearDown(container.dispose);
      Future<SceneFile?> of(BaseAsset asset) => container.read(sceneFileOfAssetProvider(asset).future);

      final found = (await of(_photo('a', 'salon_scene3D.jpg')))!;
      expect(found.path, scene);
      expect(found.canPreview, isTrue);
      expect(found.xmp.sceneTriangles, 10);
      expect((await of(_photo('b', 'renamed.jpg')))?.path, renamed);
      expect(await of(_photo('c', 'plain_scene3D.jpg')), isNull);
      // An ordinary name the index does not hold as a scene: never read
      expect(await of(_photo('d', 'IMG_1.jpg')), isNull);
      expect(storage.asked, isNot(contains('d')));
      // A later format keeps its button, greyed
      expect((await of(_photo('e', 'later_scene3D.jpg')))!.canPreview, isFalse);
      // A photo of the server only is not read
      expect(await of(RemoteAssetFactory.create(name: 'salon_scene3D.jpg')), isNull);
      expect(storage.asked, ['a', 'b', 'c', 'e']);
    });
  });

  group('the viewer', () {
    late PresentationContext context;

    setUp(() async => context = await PresentationContext.create());
    tearDown(() async => context.dispose());

    Future<void> pump(WidgetTester tester, BaseAsset asset, SceneFile? scene) async {
      await tester.pumpTestWidget(
        context,
        DesktopScenePreviewButton(asset: asset),
        overrides: [
          sceneFileOfAssetProvider(asset).overrideWith((ref) async => scene),
          scenePreviewOpenerProvider.overrideWithValue((context, path) => previewed.add(path)),
        ],
      );
    }

    testWidgets('"Preview in 3D" on a photo that carries a scene opens it', (tester) async {
      final asset = _photo('a', 'salon_scene3D.jpg');
      final xmp = scenePreviewOf(tinySceneFile()).xmp;
      await pump(tester, asset, SceneFile(path: '/photos/salon_scene3D.jpg', xmp: xmp));

      expect(find.byTooltip('Preview in 3D'), findsOneWidget);
      await tester.tap(find.byKey(const Key('desktop_scene_preview')));
      await tester.pump();
      expect(previewed, ['/photos/salon_scene3D.jpg']);
    });

    testWidgets('greyed with its reason for a later format', (tester) async {
      final asset = _photo('a', 'later_scene3D.jpg');
      final packet = scenePreviewOf(tinySceneFile()).xmp.toXml();
      final newer = ImmersiveXmp.parse(packet.replaceFirst('FormatVersion="1"', 'FormatVersion="2"'))! as SceneXmp;
      expect(newer.isNewerFormat, isTrue);
      await pump(tester, asset, SceneFile(path: '/photos/later_scene3D.jpg', xmp: newer));
      final button = tester.widget<IconButton>(find.byKey(const Key('desktop_scene_preview')));
      expect(button.onPressed, isNull);
      expect(find.byTooltip('Made by a newer version of Immuch360: shown flat'), findsOneWidget);
    });

    testWidgets('nothing on another photo', (tester) async {
      await pump(tester, _photo('b', 'IMG_1.jpg'), null);
      expect(find.byKey(const Key('desktop_scene_preview')), findsNothing);
      expect(find.byType(IconButton), findsNothing);
    });
  });

  group('the versions of a photo', () {
    late PresentationContext context;

    setUp(() async => context = await PresentationContext.create());
    tearDown(() async => context.dispose());

    testWidgets('a scene has "Preview in 3D", a 3D photo has not', (tester) async {
      final photo = RemoteAssetFactory.create(name: 'salon.jpg', localId: 'f-salon');
      final scene = p.join('Photos', 'salon_scene3D.jpg');
      final older = p.join('Photos', 'salon_scene3D (1).jpg');
      final sbs = p.join('Photos', 'salon_3D_LRF_Full_SBS.jpg');
      final versions = [
        _version(scene, origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene),
        // Indexed before the kinds: told by its origin
        _version(older, origin: IndexedOrigin.reconstructed),
        _version(sbs, origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPhoto),
      ];
      await tester.pumpTestWidget(
        context,
        SingleChildScrollView(child: DesktopVersionsTiles(asset: photo)),
        overrides: [
          photoVersionsProvider(photo).overrideWith((ref) async => PhotoVersions(versions: versions)),
          versionThumbnailProvider.overrideWithValue((file) => const ColoredBox(color: Colors.grey)),
          versionOpenerProvider.overrideWithValue((path) {}),
          scenePreviewOpenerProvider.overrideWithValue((context, path) => previewed.add(path)),
        ],
      );

      Finder previewOf(VersionFile version) => find.byKey(ValueKey('desktop_version_preview_${version.asset.id}'));
      expect(previewOf(versions[0]), findsOneWidget);
      expect(previewOf(versions[1]), findsOneWidget);
      expect(previewOf(versions[2]), findsNothing);
      // Each row keeps its Delete
      for (final version in versions) {
        expect(find.byKey(ValueKey('desktop_version_delete_${version.asset.id}')), findsOneWidget);
      }
      expect(find.byTooltip('Preview in 3D'), findsNWidgets(2));

      await tester.tap(previewOf(versions[1]));
      await tester.pump();
      expect(previewed, [older]);
    });
  });

  group('the panel of the conversions', () {
    testWidgets('a scene made has "Preview in 3D", which leaves the panel open; a 3D photo made has not', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final photos = Directory(p.join(folder.path, 'Photos'))..createSync();
      ConversionRequest photo(String name, ConversionKind kind) {
        final path = p.join(photos.path, name);
        File(path).writeAsBytesSync(List.generate(100, (i) => (i * 5 + name.length) & 0xff));
        return ConversionRequest(
          source: LocalFileSource(path),
          target: ConversionTarget.nextTo(path, kind: kind),
        );
      }

      await tester.pumpConsumerWidget(
        const Scaffold(body: ConversionsPanel()),
        overrides: [
          conversionToolsProvider.overrideWithValue(
            ConversionTools(
              engine: FakeImmersiveEngine(),
              engines: fakeConversionEngines(scene: FakeSceneEngine()),
              output: FakeConversionOutput(),
              finder: ExistingVersionFinder(),
              creatorTool: 'Immuch360 Desktop 3.4.0 (linux)',
            ),
          ),
          conversionThumbnailProvider.overrideWithValue((asset) => const ColoredBox(color: Colors.grey)),
          aiFeaturesEnabledProvider.overrideWith((ref) => true),
          scenePreviewOpenerProvider.overrideWithValue((context, path) => previewed.add(path)),
        ],
      );
      final container = ProviderScope.containerOf(tester.element(find.byType(ConversionsPanel)));
      final queue = container.read(conversionQueueProvider.notifier);
      final sceneId = queue.add([
        photo('salon.jpg', ConversionKind.sceneFromPhoto),
      ], kind: ConversionKind.sceneFromPhoto);
      final sbsId = queue.add([photo('jardin.jpg', ConversionKind.sbsFromPhoto)]);
      bool ended() => container.read(conversionQueueProvider).jobs.every((job) => job.state.isEnded);
      await settleStill(tester, until: ended);

      final jobs = container.read(conversionQueueProvider);
      final written = jobs.byId(sceneId.single)!.writtenPath!;
      expect(p.basename(written), 'salon_scene3D.jpg');
      final sceneRow = find.byKey(ValueKey('ai_job_${sceneId.single}'));
      final sbsRow = find.byKey(ValueKey('ai_job_${sbsId.single}'));
      final preview = find.descendant(of: sceneRow, matching: find.byKey(const Key('ai_job_preview_3d')));
      expect(preview, findsOneWidget);
      expect(find.descendant(of: sbsRow, matching: find.byKey(const Key('ai_job_preview_3d'))), findsNothing);
      expect(find.descendant(of: sceneRow, matching: find.byKey(const Key('ai_job_view'))), findsOneWidget);

      await tester.tap(preview);
      await tester.pump();
      expect(previewed, [written]);
      expect(find.byKey(const Key('ai_conversions_panel')), findsOneWidget);
      // The file the fake engine wrote is a scene the preview reads
      expect(scenePreviewOf(File(written).readAsBytesSync()).scene.triangles, 10);
    });
  });
}
