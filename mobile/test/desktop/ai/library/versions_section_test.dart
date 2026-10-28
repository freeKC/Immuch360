// The rows of the details panel of a computer for the versions of a photo: "Versions" on an original, each one with
// what it is in the words of its honesty label and its folder, greyed on a drive that is not connected; "Made from" or
// "Original not found" on a version; a row that opens its file; "Export for other 3D apps (.glb)" on a 3D scene, on
// its row and on its own; and nothing of it on a phone.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/library/versions.provider.dart';
import 'package:immich_mobile/desktop/ai/library/versions_section.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details/technical_details.widget.dart';
import 'package:path/path.dart' as p;

import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';
import '../fakes/fake_scene_engine.dart';

/// The save dialog of the test: it answers [answer]
class _Pickers implements FilePickers {
  String? answer;

  @override
  Future<String?> folder({String? initialDirectory, String? confirmButtonText}) async => null;

  @override
  Future<String?> saveLocation({
    required String suggestedName,
    String? initialDirectory,
    String? typeLabel,
    List<String> extensions = const [],
  }) async => answer;
}

VersionFile _file(String path, {IndexedOrigin? origin, ImmersiveKind? kind, bool available = true}) => VersionFile(
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
    available: available,
  ),
  origin: origin,
  kind: kind,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PresentationContext context;
  late List<String> opened;

  setUp(() async {
    context = await PresentationContext.create();
    opened = [];
  });
  tearDown(() async => context.dispose());

  final photo = RemoteAssetFactory.create(name: 'salon.jpg', localId: 'f-salon');
  final here = p.join('Photos', 'salon_3D_LRF_Full_SBS.jpg');
  final moved = p.join('Photos', '3D', 'salon_3D_LRF_Full_SBS (1).jpg');
  final away = p.join('E', 'Backup', 'salon_3D_LRF_Full_SBS.jpg');
  final original = p.join('Photos', 'salon.jpg');

  Future<void> pump(WidgetTester tester, Widget widget, BaseAsset asset, PhotoVersions versions) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpTestWidget(
      context,
      SingleChildScrollView(child: widget),
      overrides: [
        photoVersionsProvider(asset).overrideWith((ref) async => versions),
        versionThumbnailProvider.overrideWithValue((file) => const ColoredBox(color: Colors.grey)),
        versionOpenerProvider.overrideWithValue(opened.add),
      ],
    );
  }

  testWidgets('an original lists its versions, what they are and where, greyed on a drive not connected', (
    tester,
  ) async {
    await pump(
      tester,
      DesktopVersionsTiles(asset: photo),
      photo,
      PhotoVersions(
        versions: [
          _file(here, origin: IndexedOrigin.estimated),
          _file(moved, origin: IndexedOrigin.other, kind: ImmersiveKind.stereoPhoto),
          _file(away, origin: IndexedOrigin.estimated, available: false),
        ],
      ),
    );

    expect(find.text('Versions'), findsOneWidget);
    expect(find.text('salon_3D_LRF_Full_SBS (1).jpg'), findsOneWidget);
    expect(find.text('salon_3D_LRF_Full_SBS.jpg'), findsNWidgets(2));
    expect(find.text('3D photo, relief estimated by AI\n${p.dirname(here)}'), findsOneWidget);
    expect(find.text('3D photo\n${p.dirname(moved)}'), findsOneWidget);
    expect(
      find.text('3D photo, relief estimated by AI\nUnavailable: its drive is not connected\n${p.dirname(away)}'),
      findsOneWidget,
    );
    final greyed = find.ancestor(
      of: find.textContaining('Unavailable: its drive is not connected'),
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(greyed).opacity, 0.5);

    await tester.tap(find.text('salon_3D_LRF_Full_SBS (1).jpg'));
    await tester.tap(find.textContaining('Unavailable'));
    await tester.pump();
    expect(opened, [moved]);
  });

  testWidgets('a version tells the photo it was made from and opens it', (tester) async {
    await pump(
      tester,
      DesktopVersionsTiles(asset: photo),
      photo,
      PhotoVersions(
        self: _file(here, origin: IndexedOrigin.estimated),
        original: _file(original),
      ),
    );

    expect(find.text('Made from salon.jpg'), findsOneWidget);
    expect(find.text('3D photo, relief estimated by AI'), findsOneWidget);
    expect(find.text('Versions'), findsNothing);
    await tester.tap(find.text('Made from salon.jpg'));
    await tester.pump();
    expect(opened, [original]);
  });

  testWidgets('a version whose original is gone says so, one on a drive not connected greys the link', (tester) async {
    await pump(
      tester,
      DesktopVersionsTiles(asset: photo),
      photo,
      PhotoVersions(self: _file(here, origin: IndexedOrigin.estimated)),
    );
    expect(find.text('Original not found'), findsOneWidget);
    await tester.tap(find.text('Original not found'));

    await pump(
      tester,
      DesktopVersionsTiles(asset: photo),
      photo,
      PhotoVersions(
        self: _file(here, origin: IndexedOrigin.other, kind: ImmersiveKind.stereoPhoto),
        original: _file(original, available: false),
      ),
    );
    expect(find.text('Made from salon.jpg'), findsOneWidget);
    expect(find.text('3D photo  •  Unavailable: its drive is not connected'), findsOneWidget);
    await tester.tap(find.text('Made from salon.jpg'));
    await tester.pump();
    expect(opened, isEmpty);
  });

  testWidgets('each kind of version says what it is in the words of its honesty label, and how to delete it', (
    tester,
  ) async {
    final scene = p.join('Photos', 'salon_scene3D.jpg');
    final panorama = p.join('Photos', 'salon_360.jpg');
    final stereoPanorama = p.join('Photos', 'salon_360_3D.jpg');
    final stereo360 = p.join('Photos', 'Trips', 'salon_3D.jpg');
    final later = p.join('Photos', 'salon_hologram.jpg');
    final photo3d = _file(here, origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPhoto);
    final files = [
      photo3d,
      _file(scene, origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene),
      _file(panorama, origin: IndexedOrigin.generated, kind: ImmersiveKind.panorama360),
      _file(stereoPanorama, origin: IndexedOrigin.generated, kind: ImmersiveKind.stereoPanorama360),
      _file(stereo360, origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPanorama360),
      _file(later, origin: IndexedOrigin.other),
    ];
    await pump(tester, DesktopVersionsTiles(asset: photo), photo, PhotoVersions(versions: files));

    for (final (path, words) in [
      (here, '3D photo, relief estimated by AI'),
      (scene, '3D scene, reconstructed from one photo'),
      (panorama, "360° panorama, generated by AI beyond the photo's edges"),
      (stereoPanorama, "360° 3D panorama, generated by AI beyond the photo's edges"),
      (stereo360, '3D version of a 360° photo, relief estimated by AI'),
      (later, 'Made by a newer version of Immuch360: shown flat'),
    ]) {
      expect(find.text('$words\n${p.dirname(path)}'), findsOneWidget, reason: path);
    }
    String deleteTooltip(VersionFile file) =>
        tester.widget<IconButton>(find.byKey(ValueKey('desktop_version_delete_${file.asset.id}'))).tooltip!;
    expect(deleteTooltip(photo3d), 'Delete this 3D photo');
    for (final file in files.skip(1)) {
      expect(deleteTooltip(file), 'Delete this version', reason: file.path);
    }

    // Asked in the same words, then nothing deleted on Cancel
    await tester.tap(find.byKey(ValueKey('desktop_version_delete_${files[1].asset.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Delete this version? The original stays as it is.\nsalon_scene3D.jpg'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('desktop_version_delete_${photo3d.asset.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Delete this 3D photo? The original stays as it is.\nsalon_3D_LRF_Full_SBS.jpg'), findsOneWidget);
  });

  testWidgets('a scene tells the photo it was made from, in its own words', (tester) async {
    await pump(
      tester,
      DesktopVersionsTiles(asset: photo),
      photo,
      PhotoVersions(
        self: _file(
          p.join('Photos', 'salon_scene3D.jpg'),
          origin: IndexedOrigin.reconstructed,
          kind: ImmersiveKind.volumetricScene,
        ),
        original: _file(original),
      ),
    );
    expect(find.text('Made from salon.jpg'), findsOneWidget);
    expect(find.text('3D scene, reconstructed from one photo'), findsOneWidget);
  });

  testWidgets('a 3D scene is exported for other 3D apps, from its row and from its own; no other version is', (
    tester,
  ) async {
    final folder = Directory.systemTemp.createTempSync('versions_export');
    addTearDown(() => folder.deleteSync(recursive: true));
    final path = File('test/fixtures/ai_immersive/tiny_scene3D.jpg').copySync(p.join(folder.path, 'salon_scene3D.jpg'));
    final pickers = _Pickers()..answer = p.join(folder.path, 'for blender.glb');
    filePickers = pickers;
    addTearDown(() => filePickers = const SystemFilePickers());
    final scene = _file(path.path, origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene);
    final photo3d = _file(here, origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPhoto);
    await pump(tester, DesktopVersionsTiles(asset: photo), photo, PhotoVersions(versions: [photo3d, scene]));

    final export = find.byKey(ValueKey('desktop_version_export_${scene.asset.id}'));
    expect(export, findsOneWidget);
    expect(tester.widget<IconButton>(export).tooltip, 'Export for other 3D apps (.glb)');
    expect(find.byKey(ValueKey('desktop_version_export_${photo3d.asset.id}')), findsNothing);

    final written = File(p.join(folder.path, 'for blender.glb'));
    await tester.tap(export);
    for (var step = 0; step < 300 && !written.existsSync(); step++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(written.readAsBytesSync(), FakeSceneTail.fixture.glb);
    expect(opened, isEmpty, reason: 'the export does not open the version');

    await pump(
      tester,
      DesktopVersionsTiles(asset: photo),
      photo,
      PhotoVersions(self: scene, original: _file(original)),
    );
    expect(find.byKey(ValueKey('desktop_version_export_${scene.asset.id}')), findsOneWidget);
    await pump(
      tester,
      DesktopVersionsTiles(asset: photo),
      photo,
      PhotoVersions(self: photo3d, original: _file(original)),
    );
    expect(find.byKey(ValueKey('desktop_version_export_${photo3d.asset.id}')), findsNothing);
  });

  testWidgets('a version not read again since the index learnt the kinds is told by its origin', (tester) async {
    await pump(
      tester,
      DesktopVersionsTiles(asset: photo),
      photo,
      PhotoVersions(
        versions: [
          _file(p.join('Photos', 'salon_scene3D.jpg'), origin: IndexedOrigin.reconstructed),
          _file(p.join('Photos', 'salon_360.jpg'), origin: IndexedOrigin.generated),
        ],
      ),
    );
    expect(find.text('3D scene, reconstructed from one photo\nPhotos'), findsOneWidget);
    expect(find.text("360° panorama, generated by AI beyond the photo's edges\nPhotos"), findsOneWidget);
  });

  testWidgets('a photo without versions shows nothing', (tester) async {
    await pump(tester, DesktopVersionsTiles(asset: photo), photo, PhotoVersions.none);
    expect(find.byKey(const Key('desktop_versions')), findsNothing);
    expect(find.byKey(const Key('desktop_made_from')), findsNothing);
  });

  group('the details panel', () {
    final versions = PhotoVersions(versions: [_file(here, origin: IndexedOrigin.estimated)]);

    testWidgets('of a computer has the versions of a photo', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pump(tester, TechnicalDetails(asset: photo), photo, versions);
        expect(find.byKey(const Key('desktop_versions')), findsOneWidget);
        expect(find.text('3D photo, relief estimated by AI\n${p.dirname(here)}'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('of a phone does not', (tester) async {
      await pump(tester, TechnicalDetails(asset: photo), photo, versions);
      expect(find.byKey(const Key('desktop_versions')), findsNothing);
      expect(find.text('Versions'), findsNothing);
    });
  });
}
