// The rows of the details panel of a computer for the 3D versions of a photo: "Versions" on an original, each one with
// what it is and its folder, greyed on a drive that is not connected; "Made from" or "Original not found" on a
// version; a row that opens its file; and nothing of it on a phone.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/library/versions.provider.dart';
import 'package:immich_mobile/desktop/ai/library/versions_section.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details/technical_details.widget.dart';
import 'package:path/path.dart' as p;

import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

VersionFile _file(String path, {IndexedOrigin? origin, bool available = true}) => VersionFile(
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
          _file(moved, origin: IndexedOrigin.other),
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
        self: _file(here, origin: IndexedOrigin.other),
        original: _file(original, available: false),
      ),
    );
    expect(find.text('Made from salon.jpg'), findsOneWidget);
    expect(find.text('3D photo  •  Unavailable: its drive is not connected'), findsOneWidget);
    await tester.tap(find.text('Made from salon.jpg'));
    await tester.pump();
    expect(opened, isEmpty);
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
