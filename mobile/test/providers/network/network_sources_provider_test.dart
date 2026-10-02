import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Drift db;
  late StoreService store;
  late FakeSecureStorage secureStorage;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    secureStorage = FakeSecureStorage();
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
}
