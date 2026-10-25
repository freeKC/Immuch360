// The DJI settings no longer read since the build of 25 October (every switch on by default, kept as "turned off" under
// keys of their own): what an earlier build stored under the old keys is removed at the start, the rest is kept.

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';

void main() {
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

  test('the old keys of an earlier build are removed, the switches read today are kept', () async {
    for (final key in djiRetiredSettings) {
      await store.put(key, true);
    }
    await store.put(StoreKey.djiObstacleRingOff, true);
    await store.put(StoreKey.djiObstacleSoundOff, true);
    await store.put(StoreKey.djiObstacleFarCm, 250);

    await djiForgetRetiredSettings(store);

    for (final key in djiRetiredSettings) {
      expect(store.tryGet(key), isNull, reason: key.name);
    }
    expect(store.tryGet(StoreKey.djiObstacleRingOff), isTrue);
    expect(store.tryGet(StoreKey.djiObstacleSoundOff), isTrue);
    expect(store.tryGet(StoreKey.djiObstacleFarCm), 250);
    // Gone from the database too, not only from the cache: a new start reads none of them
    final again = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    addTearDown(again.dispose);
    for (final key in djiRetiredSettings) {
      expect(again.tryGet(key), isNull, reason: key.name);
    }
    expect(again.tryGet(StoreKey.djiObstacleRingOff), isTrue);
  });

  test('the five keep their numbers in StoreKey, so that they are never given again', () {
    expect(djiRetiredSettings.map((key) => key.id), [5032, 5034, 5044, 5045, 5046]);
    for (final key in djiRetiredSettings) {
      expect(StoreKey.values, contains(key));
    }
  });

  test('a store with none of them is left as it is', () async {
    await store.put(StoreKey.djiObstacleHapticOff, true);
    await djiForgetRetiredSettings(store);
    expect(store.tryGet(StoreKey.djiObstacleHapticOff), isTrue);
  });
}
