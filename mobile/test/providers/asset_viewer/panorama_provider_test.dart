import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/immersive_navigation.service.dart';
import 'package:immich_mobile/domain/services/local_panorama.service.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';

import '../../unit/factories/local_asset_factory.dart';
import '../../unit/factories/remote_asset_factory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Drift db;
  late StoreService store;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  /// A container on [storeService], or the store of the test, where the exif of each asset of [exif] carries the
  /// projection given for it, and every other asset has no exif
  ProviderContainer createContainer({
    StoreService? storeService,
    Map<BaseAsset, ProjectionType?> exif = const {},
    ForcedPanoramaAssets Function()? forced,
  }) {
    final container = ProviderContainer(
      overrides: [
        storeServiceProvider.overrideWithValue(storeService ?? store),
        for (final MapEntry(key: asset, value: projectionType) in exif.entries)
          assetExifProvider(asset).overrideWith((ref) => Stream.value(ExifInfo(projectionType: projectionType))),
        if (forced != null) forcedPanoramaAssetsProvider.overrideWith(forced),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('ForcedPanoramaAssets', () {
    test('holds no asset at first', () {
      final container = createContainer();

      expect(container.read(forcedPanoramaAssetsProvider), isEmpty);
      expect(container.read(forcedPanoramaAssetsProvider.notifier).contains(RemoteAssetFactory.create()), isFalse);
    });

    test('remembers the assets in the store, the latest choice last, and reads them back after a restart', () async {
      final first = RemoteAssetFactory.create();
      final second = RemoteAssetFactory.create();
      final notifier = createContainer().read(forcedPanoramaAssetsProvider.notifier);

      await notifier.add(first);
      await notifier.add(second);
      await notifier.add(first);

      expect(notifier.contains(first), isTrue);
      expect(notifier.contains(second), isTrue);
      expect(
        store.tryGet(StoreKey.forcedPanoramaAssets),
        '["${second.id}","${first.id}"]',
        reason: 'the latest choice goes last',
      );

      // Read back from the database, as after a restart
      final restarted = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
      addTearDown(restarted.dispose);
      final afterRestart = createContainer(storeService: restarted);
      expect(afterRestart.read(forcedPanoramaAssetsProvider), [second.id, first.id]);
      expect(afterRestart.read(forcedPanoramaAssetsProvider.notifier).contains(first), isTrue);
    });

    test('forgets an asset, and leaves the store alone for an asset it does not hold', () async {
      final first = RemoteAssetFactory.create();
      final second = RemoteAssetFactory.create();
      final notifier = createContainer().read(forcedPanoramaAssetsProvider.notifier);
      await notifier.add(first);
      await notifier.add(second);

      await notifier.remove(first);
      await notifier.remove(RemoteAssetFactory.create());

      expect(notifier.contains(first), isFalse);
      expect(notifier.contains(second), isTrue);
      expect(store.tryGet(StoreKey.forcedPanoramaAssets), '["${second.id}"]');
    });

    test('keys an asset by its server id when it has one, else by its id on the device', () async {
      final remote = RemoteAssetFactory.create(localId: 'local-1');
      final localOnly = LocalAssetFactory.create();
      final notifier = createContainer().read(forcedPanoramaAssetsProvider.notifier);

      await notifier.add(remote);
      await notifier.add(localOnly);

      expect(store.tryGet(StoreKey.forcedPanoramaAssets), '["${remote.id}","${localOnly.id}"]');
    });

    test('still finds an asset chosen while it was only on the device, once uploaded, and forgets it', () async {
      final local = LocalAssetFactory.create();
      final notifier = createContainer().read(forcedPanoramaAssetsProvider.notifier);
      await notifier.add(local);

      final uploaded = RemoteAssetFactory.create(localId: local.id);
      expect(notifier.contains(uploaded), isTrue);

      await notifier.remove(uploaded);
      expect(notifier.contains(local), isFalse);
      expect(store.tryGet(StoreKey.forcedPanoramaAssets), '[]');
    });

    test('forgets the assets chosen first past its limit', () async {
      final assets = List.generate(4, (_) => RemoteAssetFactory.create());
      final notifier = createContainer(
        forced: () => ForcedPanoramaAssets(maxEntries: 3),
      ).read(forcedPanoramaAssetsProvider.notifier);

      for (final asset in assets) {
        await notifier.add(asset);
      }

      expect(notifier.contains(assets.first), isFalse);
      expect(assets.skip(1).every(notifier.contains), isTrue);
    });

    test('holds no asset, without failing, when the store is not initialised', () {
      // Thumbnails ask for it before anything else, and widget tests seldom set the store up
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(forcedPanoramaAssetsProvider), isEmpty);
    });

    test('holds at most 1000 assets by default', () {
      expect(ForcedPanoramaAssets().maxEntries, 1000);
    });

    test('skips a damaged value, and anything but asset keys in it', () async {
      await store.put(StoreKey.forcedPanoramaAssets, 'not json');
      expect(createContainer().read(forcedPanoramaAssetsProvider), isEmpty);

      await store.put(StoreKey.forcedPanoramaAssets, '{"asset-1":true}');
      expect(createContainer().read(forcedPanoramaAssetsProvider), isEmpty);

      await store.put(StoreKey.forcedPanoramaAssets, '["asset-1",2,null,"asset-2"]');
      expect(createContainer().read(forcedPanoramaAssetsProvider), {'asset-1', 'asset-2'});
    });
  });

  group('360° providers', () {
    test('view an asset as 360° once the user chose so, though its exif says nothing', () async {
      final photo = RemoteAssetFactory.create();
      final video = RemoteAssetFactory.create(type: .video);
      final container = createContainer(exif: {photo: null, video: ProjectionType.none});
      final isPhotoPanorama = container.listen(isPanoramaProvider(photo), (_, _) {});
      final isPhoto360 = container.listen(isEquirectangularProvider(photo), (_, _) {});
      final isVideo360 = container.listen(isEquirectangularProvider(video), (_, _) {});
      final isVideoPanorama = container.listen(isPanoramaProvider(video), (_, _) {});
      final isPhotoFlagged = container.listen(hasEquirectangularExifProvider(photo), (_, _) {});
      await container.read(assetExifProvider(photo).future);
      await container.read(assetExifProvider(video).future);

      expect(isPhotoPanorama.read(), isFalse);
      expect(isVideo360.read(), isFalse);

      final notifier = container.read(forcedPanoramaAssetsProvider.notifier);
      await notifier.add(photo);
      await notifier.add(video);

      expect(isPhotoPanorama.read(), isTrue);
      expect(isPhoto360.read(), isTrue);
      expect(isVideo360.read(), isTrue);
      expect(isVideoPanorama.read(), isFalse, reason: '360° videos are not photos, whatever the user chose');
      expect(isPhotoFlagged.read(), isFalse, reason: 'the choice of the user is not what the server says');

      await notifier.remove(photo);
      expect(isPhotoPanorama.read(), isFalse);
      expect(isPhoto360.read(), isFalse);
      expect(isVideo360.read(), isTrue);
    });

    test('view an asset the user chose as 360° before its exif has loaded', () {
      final photo = RemoteAssetFactory.create();
      final container = createContainer(exif: {photo: null}, forced: () => _SeededForcedPanoramas({photo.id}));

      expect(container.read(isPanoramaProvider(photo)), isTrue);
    });

    test('view as 360° a photo or a video whose file on the device declares it', () async {
      await store.put(
        StoreKey.localPanoramaAssets,
        encodeLocalPanoramaRecords({
          'photo': LocalPanoramaRecord(isPanorama: true, checkedAt: DateTime(2024)),
          'video': LocalPanoramaRecord(isPanorama: true, halfSphere: true, checkedAt: DateTime(2024)),
          'flat': LocalPanoramaRecord(isPanorama: false, checkedAt: DateTime(2024)),
        }),
      );
      final photo = LocalAssetFactory.create(id: 'photo');
      final video = RemoteAssetFactory.create(type: .video, localId: 'video');
      final flat = LocalAssetFactory.create(id: 'flat');
      final container = createContainer(exif: {photo: null, video: ProjectionType.none, flat: null});

      expect(container.read(isEquirectangularProvider(photo)), isTrue);
      expect(container.read(isPanoramaProvider(photo)), isTrue);
      expect(container.read(isEquirectangularProvider(video)), isTrue, reason: 'found under its id on the device');
      expect(container.read(isEquirectangularProvider(flat)), isFalse);
      expect(container.read(hasEquirectangularExifProvider(photo)), isFalse, reason: 'the file is not the server');
      expect(container.read(isForcedPanoramaProvider(photo)), isFalse);
    });

    test('still view as 360° what the server flags, whatever the user chose', () async {
      final photo = RemoteAssetFactory.create();
      final container = createContainer(exif: {photo: ProjectionType.equirectangular});
      final isPanorama = container.listen(isPanoramaProvider(photo), (_, _) {});
      await container.read(assetExifProvider(photo).future);

      expect(isPanorama.read(), isTrue);
      expect(container.read(hasEquirectangularExifProvider(photo)), isTrue);
      expect(container.read(isForcedPanoramaProvider(photo)), isFalse);

      await container.read(forcedPanoramaAssetsProvider.notifier).remove(photo);
      expect(isPanorama.read(), isTrue);
    });
  });

  group('raw360LayoutProvider', () {
    test('tells the raw files of Insta360 cameras by their name, and a video by its frame', () {
      final photo = RemoteAssetFactory.create(name: 'IMG_20240908_133036_00_001.insp');
      final video = RemoteAssetFactory.create(type: .video, name: 'VID_00_002.insv', width: 5760, height: 2880);
      final split = RemoteAssetFactory.create(type: .video, name: 'VID_10_002.insv', width: 2880, height: 2880);
      final jpeg = RemoteAssetFactory.create(name: 'IMG_001.jpg');
      final container = createContainer(exif: {photo: null, video: null, split: null, jpeg: null});

      expect(container.read(raw360LayoutProvider(photo)), Raw360Layout.dualFisheye);
      expect(container.read(raw360LayoutProvider(video)), Raw360Layout.dualFisheye);
      expect(container.read(raw360LayoutProvider(split)), Raw360Layout.separateLenses);
      expect(container.read(raw360LayoutProvider(jpeg)), isNull);
    });

    test('makes a raw photo a 360° photo before its exif has loaded, and not a raw video', () {
      final photo = RemoteAssetFactory.create(name: 'IMG_001.insp');
      final video = RemoteAssetFactory.create(type: .video, name: 'VID_002.insv', width: 5760, height: 2880);
      final container = createContainer(exif: {photo: null, video: null});

      expect(container.read(isPanoramaProvider(photo)), isTrue);
      expect(container.read(isPanoramaProvider(video)), isFalse);
      expect(
        container.read(isEquirectangularProvider(photo)),
        isFalse,
        reason: 'no player reads it as equirectangular',
      );
    });

    test('tells a file of the device found raw by reading it, renamed from .insp', () async {
      await store.put(
        StoreKey.localPanoramaAssets,
        encodeLocalPanoramaRecords({
          'renamed': LocalPanoramaRecord(isPanorama: true, rawDualFisheye: true, checkedAt: DateTime(2024)),
          'pano': LocalPanoramaRecord(isPanorama: true, checkedAt: DateTime(2024)),
        }),
      );
      final renamed = LocalAssetFactory.create(id: 'renamed', name: 'IMG_001.jpg');
      final pano = LocalAssetFactory.create(id: 'pano', name: 'PANO_001.jpg');
      final container = createContainer(exif: {renamed: null, pano: null});

      expect(container.read(raw360LayoutProvider(renamed)), Raw360Layout.dualFisheye);
      expect(container.read(raw360LayoutProvider(pano)), isNull);
    });

    test('never takes for equirectangular the raw files the scan of the device found, which it lists still', () async {
      await store.put(
        StoreKey.localPanoramaAssets,
        encodeLocalPanoramaRecords({
          'insv': LocalPanoramaRecord(isPanorama: true, rawDualFisheye: true, checkedAt: DateTime(2024)),
          'renamed': LocalPanoramaRecord(isPanorama: true, rawDualFisheye: true, checkedAt: DateTime(2024)),
        }),
      );
      // A 2:1 video of the device, both lenses side by side
      final video = LocalAsset(
        id: 'insv',
        name: 'VID_20240908_133036_00_002.insv',
        type: AssetType.video,
        createdAt: DateTime(2024),
        updatedAt: DateTime(2024),
        width: 5760,
        height: 2880,
        playbackStyle: .video,
        isEdited: false,
      );
      final renamed = RemoteAssetFactory.create(localId: 'renamed', name: 'IMG_001.jpg');
      final container = createContainer(exif: {video: null, renamed: null});

      expect(container.read(raw360LayoutProvider(video)), Raw360Layout.dualFisheye);
      expect(
        container.read(isEquirectangularProvider(video)),
        isFalse,
        reason: 'the Spatial 2.5D player would wrap the lenses on the sphere as they are',
      );
      expect(container.read(isEquirectangularProvider(renamed)), isFalse);

      await container.read(forcedPanoramaAssetsProvider.notifier).add(video);
      expect(container.read(isEquirectangularProvider(video)), isFalse, reason: 'whatever the user chose');

      // Still a 360° photo for its badge, still on the 360° page of the device, still where the immersive viewer goes
      expect(container.read(isPanoramaProvider(renamed)), isTrue);
      final localIds = container.read(localPanoramaIdsProvider);
      expect(localIds, containsAll(['insv', 'renamed']));
      for (final asset in [video, renamed]) {
        expect(isImmersiveCandidate(asset, all360: false, forced: const {}, localIds: localIds), isTrue);
      }
    });
  });
}

class _SeededForcedPanoramas extends ForcedPanoramaAssets {
  _SeededForcedPanoramas(this._keys);

  final Set<String> _keys;

  @override
  Set<String> build() => _keys;
}
