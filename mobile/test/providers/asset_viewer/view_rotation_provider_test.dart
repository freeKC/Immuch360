// The one-key rotation: which photos turn and how (never a 360°, 180° or 3D one, nor one the app cannot tell yet), and
// the turns kept on this device.

import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/local_panorama.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/providers/asset_viewer/apple_spatial.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../service.mocks.dart';
import '../../unit/factories/local_asset_factory.dart';
import '../../unit/factories/remote_asset_factory.dart';
import '../../unit/factories/user_factory.dart';

const _userId = 'me';

class _ServerInfo extends ServerInfoNotifier {
  _ServerInfo(ServerVersion version) : super(MockServerInfoService()) {
    state = state.copyWith(serverVersion: version);
  }
}

class _ReadOnly extends ReadOnlyModeNotifier {
  _ReadOnly(this.on);

  final bool on;

  @override
  bool build() => on;
}

class _Records extends LocalPanoramaAssets {
  _Records(this.records);

  final Map<String, LocalPanoramaRecord> records;

  @override
  Map<String, LocalPanoramaRecord> build() => records;
}

class _Sources extends NetworkSourcesNotifier {
  _Sources(this.initial);

  final List<NetworkSource> initial;

  @override
  List<NetworkSource> build() => initial;

  void set(List<NetworkSource> sources) => state = sources;
}

NetworkSource _source(String id) => NetworkSource(id: id, type: NetworkSourceType.webdav, name: id, host: 'nas');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Drift db;
  late StoreService store;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    ViewRotations.resetPrune();
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  const flatExif = ExifInfo(width: 4000, height: 3000, make: 'Canon', model: 'EOS');

  /// A container where the exif of each asset of [exif] is the one given (an asset of the server not in it has its exif
  /// still loading), the server runs [server], the signed in user is [_userId], and the read only mode is [readOnly]
  ProviderContainer createContainer({
    Map<BaseAsset, ExifInfo?> exif = const {},
    ServerVersion server = const ServerVersion(major: 2, minor: 6, patch: 0),
    bool readOnly = false,
    Map<String, LocalPanoramaRecord> records = const {},
    Map<BaseAsset, Future<AppleSpatialInfo?>> spatial = const {},
    _Sources Function()? sources,
    Future<Set<String>?> Function(Set<String> ids)? existing,
  }) {
    final users = MockUserService();
    when(users.tryGetMyUser).thenReturn(UserFactory.createDto(id: _userId));
    when(users.watchMyUser).thenAnswer((_) => const Stream.empty());
    final container = ProviderContainer(
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        serverInfoProvider.overrideWith((ref) => _ServerInfo(server)),
        currentUserProvider.overrideWith((ref) => CurrentUserProvider(users)),
        readonlyModeProvider.overrideWith(() => _ReadOnly(readOnly)),
        localPanoramaAssetsProvider.overrideWith(() => _Records(records)),
        networkSourcesProvider.overrideWith(sources ?? () => _Sources(const [])),
        viewRotationAssetIdsProvider.overrideWithValue(existing ?? (_) async => null),
        for (final MapEntry(key: asset, value: info) in exif.entries)
          assetExifProvider(asset).overrideWith((ref) => Stream.value(info)),
        for (final asset in [...spatial.keys]) appleSpatialInfoProvider(asset).overrideWith((ref) => spatial[asset]!),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// The mode of [asset] once its exif had the time to load
  Future<RotationMode> modeOf(ProviderContainer container, BaseAsset asset) async {
    final subscription = container.listen(rotationModeProvider(asset), (_, _) {});
    addTearDown(subscription.close);
    await pumpEventQueue();
    return container.read(rotationModeProvider(asset));
  }

  group('rotationModeProvider', () {
    test('turns a flat photo of the user on the server, and keeps it on the device on an older server', () async {
      final photo = RemoteAssetFactory.create(ownerId: _userId);
      expect(await modeOf(createContainer(exif: {photo: flatExif}), photo), RotationMode.server);
      expect(
        await modeOf(
          createContainer(exif: {photo: flatExif}, server: const ServerVersion(major: 2, minor: 5, patch: 6)),
          photo,
        ),
        RotationMode.device,
      );
    });

    test('keeps the rotation on the device for a photo of someone else, a GIF, and in the read only mode', () async {
      final partner = RemoteAssetFactory.create(ownerId: 'partner');
      final gif = RemoteAssetFactory.create(ownerId: _userId, name: 'cat.GIF');
      final mine = RemoteAssetFactory.create(ownerId: _userId);
      expect(await modeOf(createContainer(exif: {partner: flatExif}), partner), RotationMode.device);
      expect(await modeOf(createContainer(exif: {gif: flatExif}), gif), RotationMode.device);
      expect(await modeOf(createContainer(exif: {mine: flatExif}, readOnly: true), mine), RotationMode.device);
    });

    test('turns a photo of the device only on the device', () async {
      final local = LocalAssetFactory.create();
      expect(await modeOf(createContainer(), local), RotationMode.device);
    });

    test('never turns a video, nor a photo in the trash', () async {
      final video = RemoteAssetFactory.create(ownerId: _userId, type: AssetType.video);
      final trashed = RemoteAssetFactory.create(ownerId: _userId, deletedAt: DateTime(2026));
      expect(await modeOf(createContainer(exif: {video: flatExif}), video), RotationMode.none);
      expect(await modeOf(createContainer(exif: {trashed: flatExif}), trashed), RotationMode.none);
    });

    test('never turns a photo whose exif is still loading or missing', () async {
      final photo = RemoteAssetFactory.create(ownerId: _userId);
      expect(await modeOf(createContainer(), photo), RotationMode.none, reason: 'still loading');
      expect(await modeOf(createContainer(exif: {photo: null}), photo), RotationMode.none, reason: 'no exif row');
    });

    test('never turns a 360° photo, whatever makes it so', () async {
      final tagged = RemoteAssetFactory.create(ownerId: _userId);
      const taggedExif = ExifInfo(width: 4000, height: 2000, projectionType: ProjectionType.equirectangular);
      expect(await modeOf(createContainer(exif: {tagged: taggedExif}), tagged), RotationMode.none, reason: 'GPano');

      final goPro = RemoteAssetFactory.create(ownerId: _userId, width: 5760, height: 2880);
      const goProExif = ExifInfo(width: 5760, height: 2880, make: 'GoPro', model: 'GoPro MAX');
      expect(await modeOf(createContainer(exif: {goPro: goProExif}), goPro), RotationMode.none, reason: 'camera rule');

      final p36 = RemoteAssetFactory.create(ownerId: _userId, name: 'GS010001.36p');
      expect(await modeOf(createContainer(exif: {p36: flatExif}), p36), RotationMode.none, reason: '.36p');

      final insp = RemoteAssetFactory.create(ownerId: _userId, name: 'IMG_1.insp');
      expect(await modeOf(createContainer(exif: {insp: flatExif}), insp), RotationMode.none, reason: 'raw .insp');

      final forced = RemoteAssetFactory.create(ownerId: _userId);
      final container = createContainer(exif: {forced: flatExif});
      expect(await modeOf(container, forced), RotationMode.server);
      await container.read(forcedPanoramaAssetsProvider.notifier).add(forced);
      await pumpEventQueue();
      expect(container.read(rotationModeProvider(forced)), RotationMode.none, reason: 'viewed as 360° by choice');
    });

    test('waits for the scan of a device file that may be 360°, and turns it once found flat', () async {
      final candidate = LocalAsset(
        id: 'pano-local',
        name: 'PANO_0001.jpg',
        type: AssetType.image,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        playbackStyle: AssetPlaybackStyle.image,
        isEdited: false,
      );
      expect(await modeOf(createContainer(), candidate), RotationMode.none, reason: 'not read yet');
      final flat = LocalPanoramaRecord(isPanorama: false, checkedAt: DateTime(2026));
      expect(await modeOf(createContainer(records: {'pano-local': flat}), candidate), RotationMode.device);
      final found = LocalPanoramaRecord(isPanorama: true, checkedAt: DateTime(2026));
      expect(await modeOf(createContainer(records: {'pano-local': found}), candidate), RotationMode.none);
    });

    test('waits for the stereo check of a HEIF photo, and never turns an Apple spatial one', () async {
      final heic = RemoteAssetFactory.create(ownerId: _userId, name: 'IMG_0001.HEIC');
      final pending = Completer<AppleSpatialInfo?>();
      final container = createContainer(exif: {heic: flatExif}, spatial: {heic: pending.future});
      expect(await modeOf(container, heic), RotationMode.none, reason: 'still reading its head');
      pending.complete(null);
      await pumpEventQueue();
      expect(container.read(rotationModeProvider(heic)), RotationMode.server);

      const pair = HeicStereoPair(
        primaryItemId: 1,
        leftItemId: 1,
        rightItemId: 2,
        pitmIdOffset: 0,
        pitmIdBytes: 2,
        width: 100,
        height: 100,
      );
      final spatial = createContainer(
        exif: {heic: flatExif},
        spatial: {heic: Future.value(const AppleSpatialInfo.photo(pair))},
      );
      expect(await modeOf(spatial, heic), RotationMode.none);

      final failing = Completer<AppleSpatialInfo?>();
      final failed = createContainer(exif: {heic: flatExif}, spatial: {heic: failing.future});
      expect(await modeOf(failed, heic), RotationMode.none);
      failing.completeError(Exception('unreadable'));
      await pumpEventQueue();
      expect(failed.read(rotationModeProvider(heic)), RotationMode.none, reason: 'a check that failed tells nothing');
    });

    test(
      'never turns a 360° photo of an Insta360 camera, raw or stitched, but turns the others of the brand',
      () async {
        // Only on the server, named .jpg: a raw dual fisheye photo renamed, or one the camera stitched without GPano
        final sphere = RemoteAssetFactory.create(
          ownerId: _userId,
          name: 'IMG_20250101_101010_00_001.jpg',
          width: 5760,
          height: 2880,
        );
        const x4 = ExifInfo(width: 5760, height: 2880, make: 'Arashi Vision', model: 'Insta360 X4');
        expect(await modeOf(createContainer(exif: {sphere: x4}), sphere), RotationMode.none);

        final action = RemoteAssetFactory.create(ownerId: _userId, width: 4000, height: 3000);
        const acePro = ExifInfo(width: 4000, height: 3000, make: 'Arashi Vision', model: 'Insta360 Ace Pro');
        expect(await modeOf(createContainer(exif: {action: acePro}), action), RotationMode.server, reason: '4:3');
      },
    );

    test('reads the shape of the file, never the size the server gave a photo it turned', () async {
      // A 1:2 photo of a phone (18:9 screen), turned once on the server, which now sizes it 2:1. Its file was never a
      // 360° candidate, so the scan of the device has no record of it to wait for.
      final turned = RemoteAssetFactory.create(
        ownerId: _userId,
        localId: 'phone-1',
        width: 2160,
        height: 1080,
      ).copyWith(isEdited: true);
      const tall = ExifInfo(width: 1080, height: 2160, make: 'Google', model: 'Pixel 8');
      final container = createContainer(exif: {turned: tall});
      expect(await modeOf(container, turned), RotationMode.server);
      expect(container.read(rotationModeProvider(turned.copyWith(isFavorite: true))), RotationMode.server);

      // A 2:1 file turned is still one that may be 360°, until the scan read it
      final wide = RemoteAssetFactory.create(
        ownerId: _userId,
        localId: 'phone-2',
        width: 2000,
        height: 4000,
      ).copyWith(isEdited: true);
      const wideFile = ExifInfo(width: 4000, height: 2000);
      expect(await modeOf(createContainer(exif: {wide: wideFile}), wide), RotationMode.none);
    });

    test('never turns a photo of the locked folder, where the editor is not offered either', () async {
      final locked = RemoteAssetFactory.create(ownerId: _userId, visibility: AssetVisibility.locked);
      expect(await modeOf(createContainer(exif: {locked: flatExif}), locked), RotationMode.none);
    });

    test('keeps the mode of a copy of the asset that differs only in what the mode does not read', () async {
      final photo = RemoteAssetFactory.create(ownerId: _userId);
      final container = createContainer(exif: {photo: flatExif});
      expect(await modeOf(container, photo), RotationMode.server);
      final favourite = photo.copyWith(isFavorite: true, thumbHash: 'new');
      expect(container.read(rotationModeProvider(favourite)), RotationMode.server, reason: 'no frame of "not known"');
    });
  });

  group('ViewRotations', () {
    test('keeps the turns of an asset in the store, and 0 removes them', () async {
      final photo = LocalAssetFactory.create();
      final container = createContainer();
      final rotations = container.read(viewRotationsProvider.notifier);

      await rotations.rotateAsset(photo, 1);
      await rotations.rotateAsset(photo, 1);
      expect(rotations.assetTurns(photo), 2);
      expect(store.tryGet(StoreKey.viewRotations), '{"a:${photo.id}":2}');

      await rotations.rotateAsset(photo, 2);
      expect(rotations.assetTurns(photo), 0);
      expect(store.tryGet(StoreKey.viewRotations), isNull, reason: 'nothing left to keep');
    });

    test('finds a rotation made before the upload, and moves it under the server id', () async {
      final local = LocalAssetFactory.create();
      final container = createContainer();
      final rotations = container.read(viewRotationsProvider.notifier);
      await rotations.rotateAsset(local, 3);

      final uploaded = RemoteAssetFactory.create(localId: local.id);
      expect(rotations.assetTurns(uploaded), 3);
      await rotations.rotateAsset(uploaded, 1);
      expect(rotations.assetTurns(uploaded), 0);
      await rotations.rotateAsset(uploaded, 1);
      expect(store.tryGet(StoreKey.viewRotations), '{"a:${uploaded.id}":{"t":1,"u":"$_userId"}}');
    });

    test('keeps a file of the device apart from the server picture of its copy once that is edited', () async {
      final container = createContainer();
      final rotations = container.read(viewRotationsProvider.notifier);
      // A device album shows the file, never what an edit of the server made of its copy
      final inAlbum = LocalAssetFactory.create(id: 'local-1', remoteId: 'remote-1');
      await rotations.rotateAsset(inAlbum, 1);
      expect(store.tryGet(StoreKey.viewRotations), '{"a:local-1":1}');

      final copy = RemoteAssetFactory.create(id: 'remote-1', localId: 'local-1', ownerId: _userId);
      expect(rotations.assetTurns(copy), 1, reason: 'the same picture while the server has no edit of it');
      expect(rotations.assetTurns(copy.copyWith(isEdited: true)), 0, reason: 'no longer the picture turned');

      await rotations.rotateAsset(copy, 1);
      expect(store.tryGet(StoreKey.viewRotations), '{"a:remote-1":{"t":2,"u":"$_userId"}}', reason: 'with its user');
    });

    test('forgets the files of a share removed while nothing read the rotations', () async {
      await store.put(StoreKey.viewRotations, '{"n:gone:/a.jpg":{"t":1},"n:s1:/b.jpg":{"t":2},"a:x":1}');
      final container = createContainer(sources: () => _Sources([_source('s1')]));
      expect(container.read(viewRotationsProvider).keys, ['n:s1:/b.jpg', 'a:x']);
      await pumpEventQueue();
      expect(store.tryGet(StoreKey.viewRotations), '{"n:s1:/b.jpg":{"t":2},"a:x":1}');
    });

    test('keeps a share file by its path, and forgets it with its share', () async {
      final sources = _Sources([_source('s1'), _source('s2')]);
      final container = createContainer(sources: () => sources);
      final rotations = container.read(viewRotationsProvider.notifier);
      await rotations.rotateShare('s1', '/a.jpg', 1, size: 10, modifiedMs: 20);
      await rotations.rotateShare('s2', '/b.jpg', -1, size: 30, modifiedMs: 40);
      expect(rotations.shareTurns('s1', '/a.jpg', size: 10, modifiedMs: 20), 1);
      expect(rotations.shareTurns('s2', '/b.jpg', size: 30, modifiedMs: 40), 3);
      expect(rotations.shareTurns('s1', '/a.jpg', size: 11, modifiedMs: 20), 0, reason: 'another file');

      container.read(networkSourcesProvider.notifier);
      sources.set([_source('s2')]);
      await pumpEventQueue();
      expect(rotations.shareTurns('s1', '/a.jpg', size: 10, modifiedMs: 20), 0);
      expect(store.tryGet(StoreKey.viewRotations), '{"n:s2:/b.jpg":{"t":3,"s":30,"m":40}}');
    });

    test('drops the assets gone from the library once per run, once a sync of the server finished', () async {
      await store.put(
        StoreKey.viewRotations,
        '{"a:gone":{"t":1,"u":"$_userId"},"a:kept":2,"a:elsewhere":{"t":1,"u":"other"},"n:s1:/a.jpg":{"t":1}}',
      );
      final asked = <Set<String>>[];
      final container = createContainer(
        sources: () => _Sources([_source('s1')]),
        existing: (ids) async {
          asked.add(ids);
          return {'kept', 'new'};
        },
      );
      final rotations = container.read(viewRotationsProvider.notifier);
      final sync = container.read(syncStatusProvider.notifier);

      await rotations.rotateAsset(LocalAssetFactory.create(id: 'new'), 1);
      await pumpEventQueue();
      expect(asked, isEmpty, reason: 'no sync finished in this run: the database may not hold every asset yet');
      sync.startRemoteSync();
      await rotations.rotateAsset(LocalAssetFactory.create(id: 'new'), 1);
      await pumpEventQueue();
      expect(asked, isEmpty, reason: 'a sync running, after a sign in for example');

      sync.completeRemoteSync();
      await rotations.rotateAsset(LocalAssetFactory.create(id: 'new'), 1);
      await pumpEventQueue();
      expect(asked.single, {'gone', 'kept', 'new'}, reason: 'not the asset turned under another account');
      expect(container.read(viewRotationsProvider).keys, ['a:kept', 'a:elsewhere', 'n:s1:/a.jpg', 'a:new']);
      await rotations.rotateAsset(LocalAssetFactory.create(id: 'new'), 1);
      await pumpEventQueue();
      expect(asked, hasLength(1), reason: 'once per run');
    });
  });

  group('displayQuarterTurnsProvider', () {
    test('draws the turns kept on the device, and none for a photo that does not turn, whatever is kept', () async {
      final flat = LocalAssetFactory.create();
      final video = RemoteAssetFactory.create(type: AssetType.video, ownerId: _userId);
      await store.put(StoreKey.viewRotations, '{"a:${flat.id}":1,"a:${video.id}":2}');
      final container = createContainer(exif: {video: flatExif});
      await modeOf(container, flat);
      expect(container.read(displayQuarterTurnsProvider(flat)), 1);
      expect(container.read(displayQuarterTurnsProvider(video)), 0);
    });
  });
}
