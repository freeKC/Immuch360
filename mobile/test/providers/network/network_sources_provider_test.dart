import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/network/plex_learned_addresses.provider.dart';
import 'package:immich_mobile/providers/tapo/tapo_infrastructure.provider.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Drift db;
  late StoreService store;
  late FakeSecureStorage secureStorage;
  late List<String> deletedCameraCaches;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    secureStorage = FakeSecureStorage();
    deletedCameraCaches = [];
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  ProviderContainer createContainer({StoreService? storeService}) {
    final container = ProviderContainer(
      overrides: [
        storeServiceProvider.overrideWithValue(storeService ?? store),
        secureStorageServiceProvider.overrideWithValue(secureStorage),
        tapoCameraCacheDeleterProvider.overrideWithValue((sourceId) async => deletedCameraCaches.add(sourceId)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// The sources as a new start of the app reads them from the database
  Future<List<NetworkSource>> afterRestart() async {
    final restarted = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    addTearDown(restarted.dispose);
    return createContainer(storeService: restarted).read(networkSourcesProvider);
  }

  group('NetworkSourcesNotifier', () {
    test('starts without any share', () {
      final container = createContainer();

      expect(container.read(networkSourcesProvider), isEmpty);
      expect(container.read(networkSourcesProvider.notifier).byId(smbSource.id), isNull);
    });

    test('add keeps the share in the store and its password in the secure storage only', () async {
      final container = createContainer();
      final sources = container.read(networkSourcesProvider.notifier);

      await sources.add(smbSource, password: 's3cret');
      await sources.add(webDavSource);

      expect(container.read(networkSourcesProvider).map((s) => s.id), [smbSource.id, webDavSource.id]);
      expect(container.read(networkSourceProvider(smbSource.id))?.name, 'NAS');
      expect(secureStorage.values, {smbSource.secretKey: 's3cret'});
      final stored = store.tryGet(StoreKey.networkSources);
      expect(stored, isNotNull);
      expect(stored, isNot(contains('s3cret')));
      expect(stored, isNot(contains('password')));
      expect(await sources.readPassword(smbSource.id), 's3cret');
      expect(await sources.readPassword(webDavSource.id), isNull);

      final restarted = await afterRestart();
      expect(restarted.map((s) => s.id), [smbSource.id, webDavSource.id]);
      final dav = restarted.last;
      expect(dav.type, NetworkSourceType.webdav);
      expect(dav.host, 'cloud.example.com');
      expect(dav.share, '/remote.php/dav/files/alice');
      expect(dav.rootPath, '/Photos');
      expect(dav.username, 'alice');
      expect(dav.useTls, isTrue);
    });

    test('add refuses a second share with the same id', () async {
      final sources = createContainer().read(networkSourcesProvider.notifier);
      await sources.add(smbSource);

      await expectLater(sources.add(smbSource.copyWith(name: 'Other')), throwsArgumentError);
    });

    test('update keeps the place of the share, and its password unless told otherwise', () async {
      final container = createContainer();
      final sources = container.read(networkSourcesProvider.notifier);
      await sources.add(smbSource, password: 'first');
      await sources.add(webDavSource, password: 'dav');

      await sources.update(smbSource.copyWith(name: 'Renamed', port: 1445));

      expect(container.read(networkSourcesProvider).map((s) => s.name), ['Renamed', 'Cloud']);
      expect(container.read(networkSourcesProvider).first.port, 1445);
      expect(await sources.readPassword(smbSource.id), 'first', reason: 'a null password keeps the stored one');

      await sources.update(smbSource, password: 'second');
      expect(await sources.readPassword(smbSource.id), 'second');

      await sources.update(smbSource, password: '');
      expect(await sources.readPassword(smbSource.id), isNull, reason: 'an empty password forgets it');
      expect(secureStorage.values.containsKey(smbSource.secretKey), isFalse);
      expect(await sources.readPassword(webDavSource.id), 'dav');

      expect((await afterRestart()).map((s) => s.name), ['NAS', 'Cloud']);
    });

    test('update of an unknown share fails', () async {
      final sources = createContainer().read(networkSourcesProvider.notifier);

      await expectLater(sources.update(smbSource), throwsArgumentError);
    });

    test('remove forgets the share and its password', () async {
      final container = createContainer();
      final sources = container.read(networkSourcesProvider.notifier);
      await sources.add(smbSource, password: 'smb');
      await sources.add(webDavSource, password: 'dav');

      await sources.remove(smbSource.id);

      expect(container.read(networkSourcesProvider).map((s) => s.id), [webDavSource.id]);
      expect(container.read(networkSourceProvider(smbSource.id)), isNull);
      expect(secureStorage.values, {webDavSource.secretKey: 'dav'});
      expect(await sources.readPassword(smbSource.id), isNull);
      expect((await afterRestart()).map((s) => s.id), [webDavSource.id]);

      await sources.remove(webDavSource.id);
      expect(container.read(networkSourcesProvider), isEmpty);
      expect(store.tryGet(StoreKey.networkSources), isNull);
      expect(secureStorage.values, isEmpty);

      // Removing an unknown share changes nothing
      await sources.remove('unknown');
      expect(container.read(networkSourcesProvider), isEmpty);
    });

    test('ignores a broken value in the store', () async {
      await store.put(StoreKey.networkSources, 'not json');

      expect(createContainer().read(networkSourcesProvider), isEmpty);
    });

    test('newId gives 16 hexadecimal digits, a new one each time', () {
      final ids = List.generate(20, (_) => NetworkSourcesNotifier.newId());

      for (final id in ids) {
        expect(id, matches(RegExp(r'^[0-9a-f]{16}$')));
      }
      expect(ids.toSet(), hasLength(ids.length));
    });
  });

  group('Plex servers and Tapo cameras', () {
    const plexServer = NetworkSource(
      id: '0123456789abcdef',
      type: NetworkSourceType.plex,
      name: 'Test Plex',
      host: '192.0.2.20',
      useTls: true,
      discoveryId: '0000000000000000000000000000000000000001',
      plex: PlexServerInfo(hash: '0123456789abcdef0123456789abcdef'),
    );
    const camera = NetworkSource(
      id: '1123456789abcdef',
      type: NetworkSourceType.tapo,
      name: 'Garden',
      host: '192.0.2.30',
      username: 'viewer',
      useTls: true,
      discoveryId: '02-00-00-00-00-01',
      camera: TapoCameraInfo(model: 'C200'),
    );

    List<String> storedIds(StoreKey<String> key) =>
        NetworkSource.decodeStored(store.tryGet(key)).sources.map((source) => source.id).toList();

    test('keeps the types older builds know under their key, the later ones under the new key', () async {
      final container = createContainer();
      final sources = container.read(networkSourcesProvider.notifier);

      await sources.add(plexServer, password: 'TEST-TOKEN-0000000000');
      await sources.add(smbSource, password: 'p4ss-smb');
      await sources.add(camera, password: 'p4ss-cloud', cameraPassword: 'p4ss-live');
      await sources.add(webDavSource);

      expect(storedIds(StoreKey.networkSources), [smbSource.id, webDavSource.id]);
      expect(storedIds(StoreKey.networkSourcesExtra), [plexServer.id, camera.id]);
      expect(container.read(networkSourcesProvider).map((s) => s.id), [
        smbSource.id,
        webDavSource.id,
        plexServer.id,
        camera.id,
      ], reason: 'the shares of the old types first, as after a restart');
      expect((await afterRestart()).map((s) => s.id), [smbSource.id, webDavSource.id, plexServer.id, camera.id]);
      for (final key in [StoreKey.networkSources, StoreKey.networkSourcesExtra]) {
        final stored = store.tryGet(key)!;
        for (final secret in ['TEST-TOKEN-0000000000', 'p4ss-smb', 'p4ss-cloud', 'p4ss-live']) {
          expect(stored, isNot(contains(secret)));
        }
      }
    });

    test('build 19 never sees the new types, and they are all there again afterwards', () async {
      final container = createContainer();
      final sources = container.read(networkSourcesProvider.notifier);
      await sources.add(smbSource, password: 'smb');
      await sources.add(plexServer, password: 'TEST-TOKEN-0000000000');
      await sources.add(camera, password: 'cloud', cameraPassword: 'live');

      // Build 19 loads the key it knows only, drops the types it does not know, and writes its list back with a new
      // share; it never loads the new key
      final build19 = NetworkSource.decodeList(store.tryGet(StoreKey.networkSources));
      expect(build19.map((s) => s.id), [smbSource.id]);
      const added = NetworkSource(id: 'smb-2', type: NetworkSourceType.smb, name: 'Other', host: 'other.local');
      await store.put(
        StoreKey.networkSources,
        jsonEncode([
          for (final s in [...build19, added]) s.toJson(),
        ]),
      );

      final restarted = await afterRestart();
      expect(restarted.map((s) => s.id), [smbSource.id, 'smb-2', plexServer.id, camera.id]);
      expect(secureStorage.values[plexServer.secretKey], 'TEST-TOKEN-0000000000');
      expect(secureStorage.values[camera.secretKey], 'cloud');
      expect(secureStorage.values[camera.cameraSecretKey], 'live');
    });

    test('writes back, each in its key, the entries of a type this build does not know', () async {
      final legacyUnknown = {'id': 'a', 'type': 'nfs', 'name': 'NFS', 'host': '192.0.2.60'};
      final extraUnknown = {'id': 'b', 'type': 'jellyfin', 'name': 'Media', 'host': '192.0.2.61', 'more': true};
      await store.put(StoreKey.networkSources, jsonEncode([smbSource.toJson(), legacyUnknown]));
      await store.put(StoreKey.networkSourcesExtra, jsonEncode([extraUnknown, plexServer.toJson()]));
      final container = createContainer();
      final sources = container.read(networkSourcesProvider.notifier);
      expect(container.read(networkSourcesProvider).map((s) => s.id), [smbSource.id, plexServer.id]);

      await sources.add(camera);
      await sources.remove(smbSource.id);
      await sources.remove(plexServer.id);
      await sources.remove(camera.id);

      expect(jsonDecode(store.tryGet(StoreKey.networkSources)!), [legacyUnknown]);
      expect(jsonDecode(store.tryGet(StoreKey.networkSourcesExtra)!), [extraUnknown]);
    });

    test('deletes a key once nothing is left in it', () async {
      final sources = createContainer().read(networkSourcesProvider.notifier);
      await sources.add(smbSource);
      await sources.add(plexServer, password: 'TEST-TOKEN-0000000000');

      await sources.remove(plexServer.id);
      expect(store.tryGet(StoreKey.networkSourcesExtra), isNull);
      expect(store.tryGet(StoreKey.networkSources), isNotNull);

      await sources.remove(smbSource.id);
      expect(store.tryGet(StoreKey.networkSources), isNull);
    });

    test('moves a source stored under the other key to its own, and keeps one of two with the same id', () async {
      await store.put(StoreKey.networkSources, jsonEncode([plexServer.toJson(), smbSource.toJson()]));
      await store.put(
        StoreKey.networkSourcesExtra,
        jsonEncode([smbSource.copyWith(name: 'Twin').toJson(), camera.toJson()]),
      );
      final container = createContainer();

      expect(container.read(networkSourcesProvider).map((s) => s.name), ['NAS', 'Test Plex', 'Garden']);

      await container.read(networkSourcesProvider.notifier).update(smbSource.copyWith(name: 'Renamed'));
      expect(storedIds(StoreKey.networkSources), [smbSource.id]);
      expect(storedIds(StoreKey.networkSourcesExtra), [plexServer.id, camera.id]);
    });

    test(
      'the secrets of a Plex server and a camera stay on this device, those of the other shares as before',
      () async {
        final sources = createContainer().read(networkSourcesProvider.notifier);

        await sources.add(smbSource, password: 'smb');
        await sources.add(plexServer, password: 'TEST-TOKEN-0000000000');
        await sources.add(camera, password: 'cloud', cameraPassword: 'live');

        expect(secureStorage.writtenDeviceOnly, {plexServer.secretKey, camera.secretKey, camera.cameraSecretKey});

        await sources.update(plexServer, password: '');
        await sources.remove(camera.id);
        await sources.remove(smbSource.id);
        expect(secureStorage.deletedDeviceOnly, {plexServer.secretKey, camera.secretKey, camera.cameraSecretKey});
        expect(secureStorage.values, isEmpty);
      },
    );

    test('the camera account password is added, kept, forgotten, and ignored for the other types', () async {
      final sources = createContainer().read(networkSourcesProvider.notifier);

      await sources.add(camera, password: 'cloud', cameraPassword: 'live');
      expect(await sources.readPassword(camera.id), 'cloud');
      expect(await sources.readCameraPassword(camera.id), 'live');

      await sources.update(camera.copyWith(name: 'Back door'));
      expect(await sources.readCameraPassword(camera.id), 'live', reason: 'a null password keeps the stored one');
      await sources.update(camera, cameraPassword: 'new');
      expect(await sources.readCameraPassword(camera.id), 'new');
      expect(await sources.readPassword(camera.id), 'cloud');
      await sources.update(camera, cameraPassword: '');
      expect(await sources.readCameraPassword(camera.id), isNull);
      expect(secureStorage.values.containsKey(camera.cameraSecretKey), isFalse);

      await sources.add(smbSource, password: 'smb', cameraPassword: 'ignored');
      expect(secureStorage.values.containsKey(smbSource.cameraSecretKey), isFalse);
      expect(await sources.readCameraPassword('unknown'), isNull);
    });

    test('remove forgets both secrets, the learned Plex address and what was fetched from a camera', () async {
      final container = createContainer();
      final sources = container.read(networkSourcesProvider.notifier);
      final learned = container.read(plexLearnedAddressStoreProvider);
      await sources.add(plexServer, password: 'TEST-TOKEN-0000000000');
      await sources.add(camera, password: 'cloud', cameraPassword: 'live');
      await sources.add(smbSource, password: 'smb');
      final address = PlexLearnedAddress(
        host: '203.0.113.7',
        port: 32400,
        mapping: 'mapped',
        at: DateTime.utc(2026, 10),
      );
      await learned.write(plexServer.id, address);
      await learned.write('other', address);
      expect(learned.read(plexServer.id), address);

      await sources.remove(plexServer.id);
      await sources.remove(camera.id);
      await sources.remove(smbSource.id);

      expect(secureStorage.values, isEmpty);
      expect(learned.read(plexServer.id), isNull);
      expect(learned.read('other'), address, reason: 'only the entry of the removed server');
      expect(deletedCameraCaches, [camera.id]);
    });

    test('a failure to delete what a camera fetched does not stop its removal', () async {
      final container = ProviderContainer(
        overrides: [
          storeServiceProvider.overrideWithValue(store),
          secureStorageServiceProvider.overrideWithValue(secureStorage),
          tapoCameraCacheDeleterProvider.overrideWithValue((_) async => throw const FileSystemException('busy')),
        ],
      );
      addTearDown(container.dispose);
      final sources = container.read(networkSourcesProvider.notifier);
      await sources.add(camera, password: 'cloud', cameraPassword: 'live');

      await sources.remove(camera.id);

      expect(container.read(networkSourcesProvider), isEmpty);
      expect(secureStorage.values, isEmpty);
    });
  });
}
