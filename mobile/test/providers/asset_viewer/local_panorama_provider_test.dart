import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/local_panorama.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';

import '../../medium/repository_context.dart';
import '../../unit/factories/local_asset_factory.dart';
import '../../unit/factories/remote_asset_factory.dart';

final _checkedAt = DateTime(2024, 7, 1);

LocalPanoramaRecord _record({bool isPanorama = true}) =>
    LocalPanoramaRecord(isPanorama: isPanorama, checkedAt: _checkedAt);

// A 2:1 photo of the device, a candidate for the scan, [age] days old
LocalAsset _candidate(String id, {int age = 0}) => LocalAsset(
  id: id,
  name: '$id.jpg',
  type: AssetType.image,
  createdAt: DateTime(2024, 6, 1).subtract(Duration(days: age)),
  updatedAt: DateTime(2024, 6, 1).subtract(Duration(days: age)),
  width: 4000,
  height: 2000,
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MediumRepositoryContext ctx;
  late StoreService store;

  setUp(() async {
    ctx = MediumRepositoryContext();
    store = await StoreService.create(storeRepository: StoreRepository(ctx.db), listenUpdates: false);
  });

  tearDown(() async {
    await store.dispose();
    await ctx.dispose();
  });

  /// A container on the store of the test, whose scans see [assets] (the newest first) and find 360° the ids in
  /// [panoramas]. [probe] replaces the reading of the files.
  ProviderContainer createContainer({
    List<LocalAsset> assets = const [],
    Set<String> panoramas = const {},
    LocalPanoramaFileProbe? probe,
    List<int>? pageReads,
  }) {
    Future<List<LocalPanoramaProbe?>> defaultProbe(List<LocalPanoramaFile> files) async => [
      for (final file in files)
        (isPanorama: panoramas.contains(file.path.split('/').last), halfSphere: null, rawDualFisheye: false),
    ];
    final container = ProviderContainer(
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        localPanoramaServiceProvider.overrideWith(
          (ref) => LocalPanoramaService(
            assets: (offset, limit) async {
              pageReads?.add(offset);
              return assets.skip(offset).take(limit).toList();
            },
            file: (id) async => File('/files/$id'),
            probe: probe ?? defaultProbe,
            now: () => _checkedAt,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('LocalPanoramaAssets', () {
    test('holds nothing at first, and nothing without failing when the store is not initialised', () {
      expect(createContainer().read(localPanoramaAssetsProvider), isEmpty);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(localPanoramaAssetsProvider), isEmpty);
      expect(container.read(localPanoramaIdsProvider), isEmpty);
    });

    test('reads the records back from the store, and skips a damaged value', () async {
      await store.put(StoreKey.localPanoramaAssets, encodeLocalPanoramaRecords({'a': _record()}));
      expect(createContainer().read(localPanoramaAssetsProvider), {'a': _record()});

      await store.put(StoreKey.localPanoramaAssets, 'not json');
      expect(createContainer().read(localPanoramaAssetsProvider), isEmpty);
    });

    test('scans the assets of the device and remembers what it found in the store', () async {
      final container = createContainer(assets: [_candidate('pano'), _candidate('flat', age: 1)], panoramas: {'pano'});

      await scanLocalPanoramasFor(container);

      final expected = {'pano': _record(), 'flat': _record(isPanorama: false)};
      expect(container.read(localPanoramaAssetsProvider), expected);
      expect(decodeLocalPanoramaRecords(store.tryGet(StoreKey.localPanoramaAssets)), expected);
      expect(container.read(foundLocalPanoramaIdsProvider), {'pano'});
    });

    test('reads again once a record of the store written before the raw files were told, and finds it raw', () async {
      // A photo of an X3 renamed .jpg, which build 15 found flat: no version, no raw flag
      await store.put(
        StoreKey.localPanoramaAssets,
        jsonEncode({
          'renamed': {'p': false, 't': _checkedAt.millisecondsSinceEpoch},
        }),
      );
      final probed = <String>[];
      final container = createContainer(
        assets: [_candidate('renamed')],
        probe: (files) async {
          probed.addAll([for (final file in files) file.path.split('/').last]);
          return [for (final _ in files) (isPanorama: true, halfSphere: null, rawDualFisheye: true)];
        },
      );
      expect(container.read(foundLocalPanoramaIdsProvider), isEmpty);

      await scanLocalPanoramasFor(container);

      final expected = {'renamed': LocalPanoramaRecord(isPanorama: true, rawDualFisheye: true, checkedAt: _checkedAt)};
      expect(probed, ['renamed']);
      expect(container.read(localPanoramaAssetsProvider), expected);
      expect(decodeLocalPanoramaRecords(store.tryGet(StoreKey.localPanoramaAssets)), expected);
      expect(container.read(foundLocalPanoramaIdsProvider), {'renamed'});

      await scanLocalPanoramasFor(container);
      expect(probed, ['renamed'], reason: 'read again once');
    });

    test('runs one scan at a time, and another one after it when asked meanwhile', () async {
      final gate = Completer<void>();
      final pageReads = <int>[];
      final container = createContainer(
        assets: [_candidate('a')],
        pageReads: pageReads,
        probe: (files) async {
          await gate.future;
          return [for (final _ in files) (isPanorama: true, halfSphere: null, rawDualFisheye: false)];
        },
      );
      final notifier = container.read(localPanoramaAssetsProvider.notifier);

      final first = notifier.scan();
      final second = notifier.scan();
      await pumpEventQueue();
      expect(pageReads, [0], reason: 'the second scan waits for the first');

      gate.complete();
      await Future.wait([first, second]);

      expect(pageReads, [0, 0], reason: 'the assets a sync added meanwhile are read');
      expect(container.read(localPanoramaAssetsProvider).keys, ['a']);
    });

    test('logs a failed scan rather than failing', () async {
      final container = createContainer(probe: (_) async => throw StateError('broken'), assets: [_candidate('a')]);

      await container.read(localPanoramaAssetsProvider.notifier).scan();

      expect(container.read(localPanoramaAssetsProvider), isEmpty);
    });
  });

  group('360° ids of the device', () {
    test('tells the ids found 360°, and only notifies when they change', () async {
      await store.put(
        StoreKey.localPanoramaAssets,
        encodeLocalPanoramaRecords({'pano': _record(), 'flat': _record(isPanorama: false)}),
      );
      final container = createContainer(
        assets: [_candidate('pano'), _candidate('flat', age: 1), _candidate('new', age: 2)],
      );
      var changes = 0;
      final ids = container.listen(localPanoramaIdsProvider, (_, _) => changes++);

      expect(ids.read(), {'pano'});

      // A scan that finds nothing more
      await scanLocalPanoramasFor(container);
      expect(container.read(localPanoramaAssetsProvider).keys, contains('new'));
      expect(changes, 0);
      expect(ids.read(), {'pano'});
    });

    test('include the assets the user chose to view as 360°', () async {
      await store.put(StoreKey.localPanoramaAssets, encodeLocalPanoramaRecords({'pano': _record()}));
      final container = createContainer();
      final forced = LocalAssetFactory.create();

      await container.read(forcedPanoramaAssetsProvider.notifier).add(forced);

      expect(container.read(localPanoramaIdsProvider), {'pano', forced.id});
      expect(container.read(foundLocalPanoramaIdsProvider), {'pano'});
    });

    test('tell whether the file of an asset on the device was found 360°', () async {
      await store.put(StoreKey.localPanoramaAssets, encodeLocalPanoramaRecords({'pano': _record()}));
      final container = createContainer();

      expect(container.read(isFoundLocalPanoramaProvider(LocalAssetFactory.create(id: 'pano'))), isTrue);
      expect(container.read(isFoundLocalPanoramaProvider(RemoteAssetFactory.create(localId: 'pano'))), isTrue);
      expect(container.read(isFoundLocalPanoramaProvider(LocalAssetFactory.create())), isFalse);
      expect(container.read(isFoundLocalPanoramaProvider(RemoteAssetFactory.create())), isFalse);
    });
  });

  group('newestLocalAssets', () {
    test('reads the assets of the device in pages, the newest first', () async {
      for (final (index, id) in ['b', 'a', 'c'].indexed) {
        await ctx.newLocalAsset(id: id, createdAt: DateTime(2024, 1, 10 - index));
      }

      final first = await newestLocalAssets(ctx.db, offset: 0, limit: 2);
      final second = await newestLocalAssets(ctx.db, offset: 2, limit: 2);

      expect(first.map((asset) => asset.id), ['b', 'a']);
      expect(second.map((asset) => asset.id), ['c']);
    });
  });
}

// Runs scanLocalPanoramas with the Ref of a provider of [container], as the callers do
Future<void> scanLocalPanoramasFor(ProviderContainer container) =>
    container.read(FutureProvider<void>((ref) => scanLocalPanoramas(ref)).future);
