// The 360° files of the shares for the 360° list: what the media service finds goes there and into the Store, a new
// start reads it back, a removed share takes its files along, and the filters of the 360° page apply.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_panorama_file.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/panorama_360.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_panoramas.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/panorama_360.provider.dart';
import 'package:immich_mobile/providers/tapo/tapo_infrastructure.provider.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';

import 'fakes.dart';

NetworkEntry _entry(String path, {String sourceId = 'smb-1', DateTime? modified}) => NetworkEntry(
  sourceId: sourceId,
  path: path,
  isDirectory: false,
  size: 1000,
  modified: modified ?? DateTime.utc(2026, 10, 5, 9),
);

/// A JPEG-like file whose GPano tags say equirectangular, or none
Uint8List _photo({bool equirectangular = true}) => Uint8List.fromList([
  0xff,
  0xd8,
  ...ascii.encode(equirectangular ? '<rdf:Description GPano:ProjectionType="equirectangular"/>' : 'no tags'),
  ...List.filled(256, 0),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Drift db;
  late StoreService store;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [smbSource, webDavSource]));
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  ProviderContainer createContainer({StoreService? storeService}) {
    final container = ProviderContainer(
      overrides: [
        storeServiceProvider.overrideWithValue(storeService ?? store),
        secureStorageServiceProvider.overrideWithValue(FakeSecureStorage()),
        tapoCameraCacheDeleterProvider.overrideWithValue((_) async {}),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  List<String> storedPaths() =>
      NetworkPanoramaFile.decodeList(store.tryGet(StoreKey.networkPanoramaFiles)).map((file) => file.path).toList();

  test('a 360° photo the media service reads goes to the list and the Store, a flat one does not', () async {
    final container = createContainer();
    final service = container.read(networkMediaServiceProvider);
    final files = {'/pano.jpg': _photo(), '/flat.jpg': _photo(equirectangular: false)};

    for (final path in files.keys) {
      await service.detect(
        _entry(path),
        (offset, length) async => Uint8List.sublistView(files[path]!, offset, (offset + length).clamp(0, 260)),
      );
    }
    await pumpEventQueue();

    expect(container.read(networkPanoramasProvider).map((file) => file.path), ['/pano.jpg']);
    expect(storedPaths(), ['/pano.jpg']);
  });

  test('a new start reads the list back, without the files of a share that is gone', () async {
    await store.put(
      StoreKey.networkPanoramaFiles,
      NetworkPanoramaFile.encodeList([
        NetworkPanoramaFile.of(_entry('/a.jpg')),
        NetworkPanoramaFile.of(_entry('/gone.jpg', sourceId: 'removed-before')),
      ]),
    );

    final container = createContainer();

    expect(container.read(networkPanoramasProvider).map((file) => file.path), ['/a.jpg']);
    await pumpEventQueue();
    expect(storedPaths(), ['/a.jpg'], reason: 'written back without the share that is gone');
  });

  test('removing a share forgets its files', () async {
    final container = createContainer();
    final panoramas = container.read(networkPanoramasProvider.notifier);
    panoramas.record(_entry('/a.jpg'), is360: true);
    panoramas.record(_entry('/b.jpg', sourceId: webDavSource.id), is360: true);
    await pumpEventQueue();

    await container.read(networkSourcesProvider.notifier).remove(smbSource.id);
    await pumpEventQueue();

    expect(container.read(networkPanoramasProvider).map((file) => file.sourceId), [webDavSource.id]);
    expect(storedPaths(), ['/b.jpg']);
  });

  test('a file read again and no longer 360° leaves the list', () async {
    final container = createContainer();
    final panoramas = container.read(networkPanoramasProvider.notifier);
    panoramas.record(_entry('/a.jpg'), is360: true);
    await pumpEventQueue();

    panoramas.record(_entry('/a.jpg'), is360: false);
    await pumpEventQueue();

    expect(container.read(networkPanoramasProvider), isEmpty);
    expect(store.tryGet(StoreKey.networkPanoramaFiles), isNull);
  });

  group('the files the 360° page shows', () {
    late ProviderContainer container;

    setUp(() async {
      container = createContainer();
      final panoramas = container.read(networkPanoramasProvider.notifier);
      panoramas.record(_entry('/2025.jpg', modified: DateTime(2025, 6, 1, 12)), is360: true);
      panoramas.record(_entry('/2026.insv', modified: DateTime(2026, 8, 1, 12)), is360: true);
      panoramas.record(_entry('/2026.jpg', modified: DateTime(2026, 9, 1, 12)), is360: true);
      await pumpEventQueue();
    });

    List<String> shown() => container.read(panorama360ShareFilesProvider).map((file) => file.path).toList();

    test('newest first, all of them without a filter', () {
      expect(shown(), ['/2026.jpg', '/2026.insv', '/2025.jpg']);
    });

    test('photos or videos, and the period by the date of the file', () {
      final filter = container.read(panorama360FilterProvider.notifier);
      filter.toggleKind(Panorama360Kind.video);
      expect(shown(), ['/2026.insv']);

      filter.toggleKind(Panorama360Kind.video);
      filter.setPeriod(const Panorama360Year(2025));
      expect(shown(), ['/2025.jpg']);

      filter.setPeriod(const Panorama360Month(2026, 9));
      expect(shown(), ['/2026.jpg']);
    });

    test('none while 3D, VR180 or a camera is picked: a file of a share does not tell', () {
      container.read(panorama360FilterProvider.notifier).toggleTrait(Panorama360Trait.vr180);

      expect(shown(), isEmpty);
    });
  });
}
