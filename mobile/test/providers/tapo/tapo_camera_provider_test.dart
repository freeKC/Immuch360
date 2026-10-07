// The providers of the camera pages over the real sources and connections: nothing opened without the TP-Link
// password, the connection of the source otherwise (opened again when the source changes), what a login learned saved
// with the camera, the days and clips with their refresh, the size of the cache, the time where the camera stands; and,
// with the real connection of a camera and the fake camera, a refused password tried once for the whole page.

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_control_client.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_file_system.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_login.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_session_cache.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/tapo/tapo_camera.provider.dart';
import 'package:immich_mobile/providers/tapo/tapo_infrastructure.provider.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:timezone/data/latest.dart';

import '../../infrastructure/tapo/fake_tapo_camera.dart';
import '../../presentation/pages/camera/camera_fakes.dart';
import '../network/fakes.dart';

/// The connection of a camera: its recordings in memory, and a share that lists nothing
class _CameraFileSystem extends FakeTapoRecordings implements NetworkFileSystem {
  _CameraFileSystem(this.source, {super.info});

  @override
  final NetworkSource source;
  bool closed = false;

  @override
  Future<List<NetworkEntry>> list(String path) async => const [];

  @override
  Future<NetworkEntry> stat(String path) =>
      throw NetworkFileSystemException('No fetched clip at $path', isNotFound: true);

  @override
  Future<Uint8List> readRange(String path, int offset, int length) =>
      throw NetworkFileSystemException('No fetched clip at $path', isNotFound: true);

  @override
  Future<void> close() async => closed = true;
}

void main() {
  setUpAll(initializeTimeZones);

  late Drift db;
  late StoreService store;
  late FakeSecureStorage secureStorage;
  late List<(NetworkSource, String?)> opened;
  late List<_CameraFileSystem> fileSystems;
  TapoCameraInfo learned = const TapoCameraInfo();

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    secureStorage = FakeSecureStorage();
    opened = [];
    fileSystems = [];
    learned = const TapoCameraInfo(model: 'C200', firmware: '1.4.6', zoneId: 'Europe/Brussels');
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  Future<ProviderContainer> container({NetworkSource? source, String? password = cameraCloudPassword}) async {
    final camera = source ?? cameraSource(camera: null);
    await store.put(StoreKey.networkSourcesExtra, NetworkSource.encodeList([camera]));
    if (password != null) {
      secureStorage.values[camera.secretKey] = password;
    }
    final container = ProviderContainer(
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        secureStorageServiceProvider.overrideWithValue(secureStorage),
        mediaBridgeProvider.overrideWithValue(FakeMediaBridge()),
        networkFileSystemOpenersProvider.overrideWithValue({
          NetworkSourceType.tapo: (source, password) async {
            opened.add((source, password));
            final fileSystem = _CameraFileSystem(source, info: learned);
            fileSystems.add(fileSystem);
            return fileSystem;
          },
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('opens nothing without the TP-Link password', () async {
    final ref = await container(password: null);
    expect(await ref.read(tapoCameraHasCloudPasswordProvider(cameraId).future), isFalse);
    expect(await ref.read(tapoRecordingsProvider(cameraId).future), isNull);
    expect(await ref.read(tapoCameraStatusProvider(cameraId).future), isNull);
    expect(await ref.read(tapoCameraDaysProvider(cameraId).future), isEmpty);
    expect(opened, isEmpty);
  });

  test('gives the connection of the source, opened with its password', () async {
    final ref = await container();
    final recordings = await ref.read(tapoRecordingsProvider(cameraId).future);
    expect(recordings, same(fileSystems.single));
    expect(opened.single.$2, cameraCloudPassword);
    expect(identical(ref.read(networkConnectionsProvider).opened(cameraId), recordings), isTrue);
  });

  test('saves what the connection learned, then opens the connection again for the new source', () async {
    final ref = await container();
    final subscription = ref.listen(tapoCameraStatusProvider(cameraId), (_, _) {});
    addTearDown(subscription.close);
    final status = await ref.read(tapoCameraStatusProvider(cameraId).future);
    expect(status?.details.model, 'C200');
    await pumpEventQueue();
    final saved = ref.read(networkSourceProvider(cameraId))!.camera;
    expect(saved?.model, 'C200');
    expect(saved?.zoneId, 'Europe/Brussels');
    expect(fileSystems.first.closed, isTrue);
    await ref.read(tapoCameraStatusProvider(cameraId).future);
    expect(opened, hasLength(2));
    // The source now holds what was learned: nothing more to save
    await pumpEventQueue();
    expect(opened, hasLength(2));
  });

  test('lists the days and refreshes them on demand', () async {
    final ref = await container();
    final subscription = ref.listen(tapoCameraDaysProvider(cameraId), (_, _) {});
    addTearDown(subscription.close);
    expect(await ref.read(tapoCameraDaysProvider(cameraId).future), ['2026-09-18', '2026-09-17', '2026-08-30']);
    await ref.read(tapoCameraDaysProvider(cameraId).notifier).refresh();
    expect(fileSystems.last.daysRefreshes, [false, true]);
  });

  test('lists the clips of a day', () async {
    final ref = await container();
    final clip = fakeClip(1789683060, 1789683144);
    final subscription = ref.listen(tapoCameraClipsProvider((cameraId, '2026-09-18')), (_, _) {});
    addTearDown(subscription.close);
    final recordings = (await ref.read(tapoRecordingsProvider(cameraId).future))! as _CameraFileSystem;
    recordings.clipsByDay['2026-09-18'] = [clip];
    await ref.read(tapoCameraClipsProvider((cameraId, '2026-09-18')).notifier).refresh();
    expect(ref.read(tapoCameraClipsProvider((cameraId, '2026-09-18'))).valueOrNull, [clip]);
  });

  test('tells the size of what was fetched', () async {
    final ref = await container();
    final recordings = (await ref.read(tapoRecordingsProvider(cameraId).future))! as _CameraFileSystem;
    recordings.cacheSize = 1234;
    expect(await ref.read(tapoCameraCacheBytesProvider(cameraId).future), 1234);
  });

  test('tries a refused password once for the whole camera page, and once more on Retry', () async {
    // The camera holds another TP-Link password than the one stored
    final camera = FakeTapoCamera(cloudPassword: 'changed-in-the-tapo-app');
    final sessions = TapoSessionCache();
    final root = await Directory.systemTemp.createTemp('immuch360-tapo-provider');
    addTearDown(() => root.delete(recursive: true));
    final source = cameraSource(camera: const TapoCameraInfo(certificateSha256: fakeCameraCertificate));
    await store.put(StoreKey.networkSourcesExtra, NetworkSource.encodeList([source]));
    secureStorage.values[source.secretKey] = cameraCloudPassword;
    final ref = ProviderContainer(
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        secureStorageServiceProvider.overrideWithValue(secureStorage),
        mediaBridgeProvider.overrideWithValue(FakeMediaBridge()),
        networkFileSystemOpenersProvider.overrideWithValue({
          NetworkSourceType.tapo: (source, password) => TapoFileSystem.openWith(
            source,
            password,
            client: TapoControlClient(
              sourceId: source.id,
              host: source.host,
              password: password!,
              known: source.camera ?? const TapoCameraInfo(),
              transport: (host, pin) => camera,
              login: (transport) =>
                  TapoLogin(transport, spake2p: (input) async => spake2pClient(input), reloginDelay: Duration.zero),
              cache: sessions,
            ),
            cacheRoot: () async => root,
          ),
        }),
        tapoRefusalsForgetterProvider.overrideWithValue(sessions.forgetRefusals),
      ],
    );
    addTearDown(ref.dispose);
    final refused = throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.wrongPassword));

    // What the camera page watches, side by side
    final status = ref.listen(tapoCameraStatusProvider(cameraId), (_, _) {});
    final days = ref.listen(tapoCameraDaysProvider(cameraId), (_, _) {});
    addTearDown(status.close);
    addTearDown(days.close);
    await expectLater(ref.read(tapoCameraStatusProvider(cameraId).future), refused);
    await expectLater(ref.read(tapoCameraDaysProvider(cameraId).future), refused);
    await ref.read(tapoCameraDaysProvider(cameraId).notifier).refresh();
    expect(camera.shares, 2);

    // Retry of the page: one more login, remembered again
    ref.read(tapoRefusalsForgetterProvider)(cameraId);
    ref.invalidate(tapoRecordingsProvider(cameraId));
    await expectLater(ref.read(tapoCameraStatusProvider(cameraId).future), refused);
    await expectLater(ref.read(tapoCameraDaysProvider(cameraId).future), refused);
    expect(camera.shares, 4);
  });

  test('tells the time where the camera stands', () {
    final instant = DateTime.utc(2026, 9, 17, 22, 11);
    final local = cameraLocalTime(const TapoCameraInfo(zoneId: 'Europe/Brussels'), instant);
    expect((local.day, local.hour, local.minute), (18, 0, 11));
    final winter = cameraLocalTime(const TapoCameraInfo(zoneId: 'Europe/Brussels'), DateTime.utc(2026, 12, 1, 12));
    expect(winter.hour, 13);
  });
}
