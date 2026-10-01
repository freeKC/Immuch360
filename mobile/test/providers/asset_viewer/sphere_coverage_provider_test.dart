import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';

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

  ProviderContainer createContainer({StoreService? storeService, int? maxEntries}) {
    final container = ProviderContainer(
      overrides: [
        storeServiceProvider.overrideWithValue(storeService ?? store),
        if (maxEntries != null)
          sphereCoverageOverridesProvider.overrideWith(() => SphereCoverageOverrides(maxEntries: maxEntries)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('SphereCoverageOverrides', () {
    test('has no coverage for an asset the user never changed', () {
      final container = createContainer();

      expect(container.read(sphereCoverageOverridesProvider.notifier).get(RemoteAssetFactory.create()), isNull);
      expect(container.read(sphereCoverageOverrideProvider(RemoteAssetFactory.create())), isNull);
    });

    test('remembers a coverage per asset in the store, and reads it back after a restart', () async {
      final first = RemoteAssetFactory.create(id: 'asset-1');
      final second = RemoteAssetFactory.create(id: 'asset-2');
      final container = createContainer();
      final overrides = container.read(sphereCoverageOverridesProvider.notifier);

      await overrides.set(first, SphereCoverage.half);
      await overrides.set(second, SphereCoverage.full);
      await overrides.set(first, SphereCoverage.half);

      expect(overrides.get(first), SphereCoverage.half);
      expect(overrides.get(second), SphereCoverage.full);
      expect(container.read(sphereCoverageOverrideProvider(first)), SphereCoverage.half);
      expect(
        store.tryGet(StoreKey.sphereCoverageOverrides),
        '{"asset-2":"full","asset-1":"half"}',
        reason: 'the latest choice goes last',
      );

      // Read back from the database, as after a restart
      final restarted = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
      addTearDown(restarted.dispose);
      final restartedOverrides = createContainer(
        storeService: restarted,
      ).read(sphereCoverageOverridesProvider.notifier);
      expect(restartedOverrides.get(first), SphereCoverage.half);
      expect(restartedOverrides.get(second), SphereCoverage.full);
    });

    test('forgets a coverage', () async {
      final first = RemoteAssetFactory.create(id: 'asset-1');
      final second = RemoteAssetFactory.create(id: 'asset-2');
      final overrides = createContainer().read(sphereCoverageOverridesProvider.notifier);
      await overrides.set(first, SphereCoverage.half);
      await overrides.set(second, SphereCoverage.half);

      await overrides.clear(first);
      await overrides.clear(RemoteAssetFactory.create(id: 'asset-3'));

      expect(overrides.get(first), isNull);
      expect(overrides.get(second), SphereCoverage.half);
      expect(store.tryGet(StoreKey.sphereCoverageOverrides), '{"asset-2":"half"}');
    });

    test('updates the viewers that watch an asset', () async {
      final asset = RemoteAssetFactory.create();
      final container = createContainer();
      final coverage = container.listen(sphereCoverageOverrideProvider(asset), (_, _) {});

      await container.read(sphereCoverageOverridesProvider.notifier).set(asset, SphereCoverage.half);
      expect(coverage.read(), SphereCoverage.half);

      await container.read(sphereCoverageOverridesProvider.notifier).clear(asset);
      expect(coverage.read(), isNull);
    });

    test('forgets the oldest choices past its limit', () async {
      final assets = [for (var i = 1; i <= 3; i++) RemoteAssetFactory.create(id: 'asset-$i')];
      final overrides = createContainer(maxEntries: 2).read(sphereCoverageOverridesProvider.notifier);

      await overrides.set(assets[0], SphereCoverage.half);
      await overrides.set(assets[1], SphereCoverage.half);
      await overrides.set(assets[0], SphereCoverage.full);
      await overrides.set(assets[2], SphereCoverage.half);

      expect(overrides.get(assets[1]), isNull);
      expect(overrides.get(assets[0]), SphereCoverage.full);
      expect(overrides.get(assets[2]), SphereCoverage.half);
    });

    test('keeps a choice made before the upload once the asset is on the server', () async {
      final onDevice = LocalAsset(
        id: 'local-1',
        name: 'VID_180.mp4',
        type: AssetType.video,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        playbackStyle: AssetPlaybackStyle.video,
        isEdited: false,
      );
      final uploaded = RemoteAssetFactory.create(id: 'remote-1', localId: 'local-1', type: .video);
      final overrides = createContainer().read(sphereCoverageOverridesProvider.notifier);

      await overrides.set(onDevice, SphereCoverage.full);
      expect(overrides.get(uploaded), SphereCoverage.full);

      // A new choice replaces the one made on the device
      await overrides.set(uploaded, SphereCoverage.half);
      expect(store.tryGet(StoreKey.sphereCoverageOverrides), '{"remote-1":"half"}');

      await overrides.clear(uploaded);
      expect(overrides.get(onDevice), isNull);
    });

    test('ignores a damaged stored value', () async {
      await store.put(StoreKey.sphereCoverageOverrides, 'not json');
      final asset = RemoteAssetFactory.create();
      final overrides = createContainer().read(sphereCoverageOverridesProvider.notifier);

      expect(overrides.get(asset), isNull);
      await overrides.set(asset, SphereCoverage.half);
      expect(overrides.get(asset), SphereCoverage.half);
    });

    test('remembers only a coverage the user changed, and forgets it back on the guess', () async {
      final asset = RemoteAssetFactory.create(id: 'asset-1');
      final overrides = createContainer().read(sphereCoverageOverridesProvider.notifier);

      await overrides.remember(asset, SphereCoverage.full, opened: SphereCoverage.full, guess: SphereCoverage.full);
      expect(store.tryGet(StoreKey.sphereCoverageOverrides), isNull, reason: 'nothing changed');

      await overrides.remember(asset, SphereCoverage.half, opened: SphereCoverage.full, guess: SphereCoverage.full);
      expect(overrides.get(asset), SphereCoverage.half);

      await overrides.remember(asset, SphereCoverage.full, opened: SphereCoverage.half, guess: SphereCoverage.full);
      expect(overrides.get(asset), isNull, reason: 'back on the guess');

      // A full sphere picked over a wrong guess of a half sphere
      await overrides.remember(asset, SphereCoverage.full, opened: SphereCoverage.half, guess: SphereCoverage.half);
      expect(overrides.get(asset), SphereCoverage.full);
    });
  });

  group('SphericalVideoSession', () {
    test('remembers the coverage the user picked in the 360° player', () async {
      final asset = RemoteAssetFactory.create(id: 'asset-1', type: .video);
      final container = createContainer();
      final session = SphericalVideoSession(container.read(sphereCoverageOverridesProvider.notifier));

      session.start(asset: asset, coverage: SphereCoverage.full, coverageGuess: SphereCoverage.full);
      expect(session.isOpen, isTrue);
      session.closed(StereoLayout.leftRight, SphereCoverage.half);
      await pumpEventQueue();

      expect(session.isOpen, isFalse);
      expect(container.read(sphereCoverageOverrideProvider(asset)), SphereCoverage.half);
    });

    test('remembers nothing when the coverage did not change, nor after a close it did not see open', () async {
      final asset = RemoteAssetFactory.create(id: 'asset-1', type: .video);
      final container = createContainer();
      final session = SphericalVideoSession(container.read(sphereCoverageOverridesProvider.notifier));

      session.closed(StereoLayout.mono, SphereCoverage.half);
      session.start(asset: asset, coverage: SphereCoverage.half, coverageGuess: SphereCoverage.half);
      session.closed(StereoLayout.mono, SphereCoverage.half);
      session.closed(StereoLayout.mono, SphereCoverage.full);
      session.start(asset: asset, coverage: SphereCoverage.full, coverageGuess: SphereCoverage.full);
      session.cancel();
      session.closed(StereoLayout.mono, SphereCoverage.half);
      await pumpEventQueue();

      expect(store.tryGet(StoreKey.sphereCoverageOverrides), isNull);
    });

    test('the session provider receives the closed event of the native player', () async {
      final asset = RemoteAssetFactory.create(id: 'asset-1', type: .video);
      final container = ProviderContainer(overrides: [storeServiceProvider.overrideWithValue(store)]);
      container
          .read(sphericalVideoSessionProvider)
          .start(asset: asset, coverage: SphereCoverage.full, coverageGuess: SphereCoverage.full);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'dev.flutter.pigeon.immich_mobile.SphericalVideoEvents.closed',
        SphericalVideoEvents.pigeonChannelCodec.encodeMessage(<Object?>[StereoLayout.leftRight, SphereCoverage.half]),
        (_) {},
      );
      await pumpEventQueue();

      expect(container.read(sphereCoverageOverridesProvider.notifier).get(asset), SphereCoverage.half);

      // Disposing the provider unregisters it
      container.dispose();
      ByteData? reply;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'dev.flutter.pigeon.immich_mobile.SphericalVideoEvents.closed',
        SphericalVideoEvents.pigeonChannelCodec.encodeMessage(<Object?>[StereoLayout.mono, SphereCoverage.full]),
        (data) => reply = data,
      );
      expect(reply, isNull);
    });
  });
}
