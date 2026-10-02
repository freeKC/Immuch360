import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../service.mocks.dart';

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

  ProviderContainer createContainer({StoreService? storeService, List<Override> overrides = const []}) {
    final container = ProviderContainer(
      overrides: [storeServiceProvider.overrideWithValue(storeService ?? store), ...overrides],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('LocalSessionNotifier', () {
    test('starts with a server', () {
      final container = createContainer();

      expect(container.read(localSessionProvider), isFalse);
      expect(container.read(hasServerProvider), isTrue);
    });

    test('enter starts a session without a server and remembers it after a restart', () async {
      final container = createContainer();

      await container.read(localSessionProvider.notifier).enter();

      expect(container.read(localSessionProvider), isTrue);
      expect(container.read(hasServerProvider), isFalse);
      expect(store.tryGet(StoreKey.localSession), isTrue);

      // Read back from the database, as after a restart
      final restarted = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
      addTearDown(restarted.dispose);
      final afterRestart = createContainer(storeService: restarted);
      expect(afterRestart.read(localSessionProvider), isTrue);
      expect(afterRestart.read(hasServerProvider), isFalse);
    });

    test('leave ends it, for good', () async {
      final container = createContainer();
      await container.read(localSessionProvider.notifier).enter();

      await container.read(localSessionProvider.notifier).leave();

      expect(container.read(localSessionProvider), isFalse);
      expect(container.read(hasServerProvider), isTrue);
      expect(store.tryGet(StoreKey.localSession), isNull);

      final restarted = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
      addTearDown(restarted.dispose);
      expect(createContainer(storeService: restarted).read(localSessionProvider), isFalse);
    });

    test('leave without a session changes nothing', () async {
      final container = createContainer();

      await container.read(localSessionProvider.notifier).leave();

      expect(container.read(localSessionProvider), isFalse);
      expect(store.tryGet(StoreKey.localSession), isNull);
    });

    test('is off when the store is not initialised', () {
      // No override: the global store of this test was never initialised
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(localSessionProvider), isFalse);
      expect(container.read(hasServerProvider), isTrue);
    });
  });

  group('localSessionRefreshProvider', () {
    late MockBackgroundSyncManager backgroundSync;
    late List<String> calls;

    setUp(() {
      backgroundSync = MockBackgroundSyncManager();
      calls = [];
      when(() => backgroundSync.syncLocal(full: any(named: 'full'))).thenAnswer((_) async => calls.add('syncLocal'));
    });

    ProviderContainer createRefreshContainer({Future<void> Function()? scan}) {
      return createContainer(
        overrides: [
          backgroundSyncProvider.overrideWithValue(backgroundSync),
          localPanoramaScanProvider.overrideWithValue(scan ?? () async => calls.add('scan')),
        ],
      );
    }

    test('indexes the device, then looks for 360° photos and videos', () async {
      final container = createRefreshContainer();

      await container.read(localSessionRefreshProvider)(full: true);

      verify(() => backgroundSync.syncLocal(full: true)).called(1);
      expect(calls, ['syncLocal', 'scan']);
    });

    test('runs a delta sync by default', () async {
      final container = createRefreshContainer();

      await container.read(localSessionRefreshProvider)();

      verify(() => backgroundSync.syncLocal(full: false)).called(1);
    });

    test('still scans when the sync fails, and never throws', () async {
      when(() => backgroundSync.syncLocal(full: any(named: 'full'))).thenThrow(StateError('sync failed'));
      final container = createRefreshContainer();

      await expectLater(container.read(localSessionRefreshProvider)(full: true), completes);

      expect(calls, ['scan']);
    });

    test('does not throw when the scan fails', () async {
      final container = createRefreshContainer(scan: () async => throw StateError('scan failed'));

      await expectLater(container.read(localSessionRefreshProvider)(full: true), completes);

      expect(calls, ['syncLocal']);
    });
  });
}
