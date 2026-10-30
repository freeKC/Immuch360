// The versions of a photo of a share on a computer: "Versions" on the page of the photo lists those its folder holds
// (a 3D photo made next to it, in the words of its honesty label), each opening its own page, and the page of a
// version says what it was made from; both found again once a version is put in the folder, as the tile of the new
// file with its badge in the browser. A phone shows none of it.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/desktop/ai/creator/share_publisher.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/pages/network/network_photo.page.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';

import '../../../domain/ai_immersive/stereo_photo_fixtures.dart';
import '../../../presentation/pages/network/network_viewer_fakes.dart';

/// The record of the files sent, in memory
class _MemoryRecords extends UploadRecordStore {
  _MemoryRecords() : super(() => throw UnimplementedError('in memory'));

  @override
  Future<Map<String, UploadRecord>> load() async => {};
}

/// An image that never comes: the thumbnails stay blank
class _PendingImage extends ImageProvider<_PendingImage> {
  const _PendingImage(this.url);

  final Uri url;

  @override
  Future<_PendingImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_PendingImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Completer<ImageInfo>().future);

  @override
  bool operator ==(Object other) => other is _PendingImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

void main() {
  const source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'Home NAS', host: 'nas.local');
  late Drift db;
  late StoreService store;
  late MemoryShare share;
  late Uint8List salon;
  late Uint8List version;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [source]));
    salon = jpegFile(width: 4000, height: 3000);
    version = jpegFile(width: 8000, height: 3000, xmp: ourXmp(sourceSize: salon.length));
    share = MemoryShare(source, files: {'/2024/salon.jpg': salon});
    share.folders['/2024'] = [share.file('/2024/salon.jpg')];
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await store.dispose();
    await db.close();
  });

  /// Puts the 3D photo of salon.jpg next to it, as a computer did
  void putVersion() {
    share.files['/2024/salon_3D_LRF_Full_SBS.jpg'] = version;
    share.folders['/2024'] = [share.file('/2024/salon.jpg'), share.file('/2024/salon_3D_LRF_Full_SBS.jpg')];
  }

  List<Override> overrides() => [
    storeServiceProvider.overrideWithValue(store),
    overrideConnections((ref) => FakeConnections(ref, share)),
    isHorizonOsProvider.overrideWith((ref) async => false),
    networkMediaServiceProvider.overrideWith((ref) => NetworkMediaService()),
    uploadRecordStoreProvider.overrideWithValue(_MemoryRecords()),
    networkThumbnailImageProvider.overrideWithValue(_PendingImage.new),
    // The settings of the app are not read here: the AI features off, no entry of Make 3D (AI)
    aiFeaturesEnabledProvider.overrideWith((ref) => false),
  ];

  /// Runs [body] as on a Windows computer
  Future<void> onComputer(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  /// Lets the reads of the page end
  Future<void> settle(WidgetTester tester) async {
    for (var step = 0; step < 20; step++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  Future<RootStackRouter> pumpPhoto(WidgetTester tester, String path) async {
    final router = await pumpNetworkRouter(
      tester,
      home: NetworkPhotoPage(sourceId: 'nas', path: path),
      settle: false,
      overrides: overrides(),
    );
    await settle(tester);
    return router;
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(NetworkPhotoPage).first));

  group('the page of a photo of a share', () {
    testWidgets('lists the versions next to it, each opening its own page', (tester) async {
      putVersion();
      await onComputer(() async {
        await pumpPhoto(tester, '/2024/salon.jpg');

        await tester.tap(find.byKey(const Key('desktop_share_versions')));
        await tester.pumpAndSettle();

        expect(find.text('Versions'), findsWidgets);
        expect(find.text('salon_3D_LRF_Full_SBS.jpg'), findsOneWidget);
        expect(find.text('3D photo, relief estimated by AI'), findsOneWidget);

        await tester.tap(find.text('salon_3D_LRF_Full_SBS.jpg'));
        await tester.pumpAndSettle();
        expect(find.text('photo nas /2024/salon_3D_LRF_Full_SBS.jpg'), findsOneWidget);
        await endRealIo(tester);
      });
    });

    testWidgets('finds a version put next to it while it shows', (tester) async {
      await onComputer(() async {
        await pumpPhoto(tester, '/2024/salon.jpg');
        expect(find.byKey(const Key('desktop_share_versions')), findsNothing);

        putVersion();
        containerOf(tester).read(shareFolderChangesProvider.notifier).changed('nas', '/2024');
        await settle(tester);

        expect(find.byKey(const Key('desktop_share_versions')), findsOneWidget);
        await endRealIo(tester);
      });
    });

    testWidgets('of a version: what it was made from, which opens', (tester) async {
      putVersion();
      await onComputer(() async {
        await pumpPhoto(tester, '/2024/salon_3D_LRF_Full_SBS.jpg');

        await tester.tap(find.byKey(const Key('desktop_share_versions')));
        await tester.pumpAndSettle();
        expect(find.text('Made from salon.jpg'), findsOneWidget);

        await tester.tap(find.text('Made from salon.jpg'));
        await tester.pumpAndSettle();
        expect(find.text('photo nas /2024/salon.jpg'), findsOneWidget);
        await endRealIo(tester);
      });
    });

    testWidgets('shows none of it on a phone', (tester) async {
      putVersion();
      await pumpPhoto(tester, '/2024/salon.jpg');

      expect(find.byKey(const Key('desktop_share_versions')), findsNothing);
      await endRealIo(tester);
    });
  });

  testWidgets('the browser of the folder shows the version put there, with its badge', (tester) async {
    await onComputer(() async {
      await pumpNetworkRouter(
        tester,
        home: const NetworkBrowserPage(sourceId: 'nas', path: '/2024'),
        overrides: overrides(),
      );
      await settle(tester);
      expect(find.byType(NetworkMediaTile), findsOneWidget);

      putVersion();
      ProviderScope.containerOf(
        tester.element(find.byType(NetworkBrowserPage)),
      ).read(shareFolderChangesProvider.notifier).changed('nas', '/2024');
      await settle(tester);

      expect(find.byType(NetworkMediaTile), findsNWidgets(2));
      expect(find.byKey(const Key('network_media_ai_3d_badge')), findsOneWidget);
      expect(find.text('3D AI'), findsOneWidget);
      await endRealIo(tester);
    });
  });
}
