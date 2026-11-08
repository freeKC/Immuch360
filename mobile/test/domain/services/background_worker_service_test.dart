import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/data/data_controller.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/background_worker.service.dart';
import 'package:immich_mobile/domain/services/hash.service.dart';
import 'package:immich_mobile/domain/services/local_sync.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/sync_stream.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/sync.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../fixtures/user.stub.dart';
import '../../service.mocks.dart';

class MockDataController extends Mock implements DataController {}

class MockLocalSyncService extends Mock implements LocalSyncService {}

class MockSyncStreamService extends Mock implements SyncStreamService {}

class MockHashService extends Mock implements HashService {}

void main() {
  late BackgroundWorkerBgService sut;
  late MockLocalSyncService mockLocalSyncService;
  late MockHashService mockHashService;
  late MockSyncStreamService mockRemoteSyncService;
  late MockBackgroundUploadService mockBackgroundUploadService;
  late MockDataController mockDataController;
  late MockNativeSyncApi mockNativeSyncApi;
  late Drift db;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await SettingsRepository.ensureInitialized(db);
    await SettingsRepository.instance.write(SettingsKey.backupEnabled, true);
    // Immuch360 runs the remote sync, the hashing and the backup with a server session only
    await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
    await Store.put(StoreKey.accessToken, 'token');
  });

  tearDownAll(() async {
    debugDefaultTargetPlatformOverride = null;
    await db.close();
  });

  setUp(() async {
    // The cleanup of an earlier test disposed the store: it comes back from the database
    await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
    await Store.populateCache();

    mockLocalSyncService = MockLocalSyncService();
    mockHashService = MockHashService();
    final mockUserService = MockUserService();
    mockRemoteSyncService = MockSyncStreamService();
    mockBackgroundUploadService = MockBackgroundUploadService();

    when(() => mockLocalSyncService.sync()).thenAnswer((_) async {});
    when(() => mockHashService.hashAssets()).thenAnswer((_) async {});
    when(() => mockUserService.tryGetMyUser()).thenReturn(UserStub.admin);
    when(() => mockUserService.watchMyUser()).thenAnswer((_) => const Stream.empty());
    when(() => mockBackgroundUploadService.getActiveTasks(kBackupGroup)).thenAnswer((_) async => []);
    when(() => mockBackgroundUploadService.uploadBackupCandidates(any())).thenAnswer((_) async {});
    when(() => mockBackgroundUploadService.resume()).thenAnswer((_) async {});
    mockDataController = MockDataController();
    when(() => mockDataController.close()).thenAnswer((_) async {});
    mockNativeSyncApi = MockNativeSyncApi();
    when(() => mockNativeSyncApi.cancelHashing()).thenAnswer((_) async {});

    sut = BackgroundWorkerBgService(
      dataController: mockDataController,
      apiService: MockApiService(),
      overrides: [
        // The cleanup goes through to the close of the databases
        nativeSyncApiProvider.overrideWithValue(mockNativeSyncApi),
        localSyncServiceProvider.overrideWithValue(mockLocalSyncService),
        syncStreamServiceProvider.overrideWithValue(mockRemoteSyncService),
        hashServiceProvider.overrideWithValue(mockHashService),
        currentUserProvider.overrideWith((ref) => CurrentUserProvider(mockUserService)),
        foregroundUploadServiceProvider.overrideWithValue(MockForegroundUploadService()),
        backgroundUploadServiceProvider.overrideWithValue(mockBackgroundUploadService),
      ],
    );
  });

  group('onIosUpload', () {
    test('lists a new batch only after the remote sync finished', () async {
      final remoteSync = Completer<bool>();
      when(() => mockRemoteSyncService.sync()).thenAnswer((_) => remoteSync.future);

      final upload = sut.onIosUpload(true, 20);
      await pumpEventQueue();
      verifyNever(() => mockBackgroundUploadService.uploadBackupCandidates(any()));

      remoteSync.complete(true);
      await upload;
      verify(() => mockBackgroundUploadService.uploadBackupCandidates(UserStub.admin.id)).called(1);
    });

    test('does not list a new batch when the remote sync fails', () async {
      when(() => mockRemoteSyncService.sync()).thenAnswer((_) async => false);

      await sut.onIosUpload(true, 20);

      verifyNever(() => mockBackgroundUploadService.uploadBackupCandidates(any()));
    });

    test('does not list a new batch when the run times out before the remote sync finished', () {
      fakeAsync((async) {
        final remoteSync = Completer<bool>();
        when(() => mockRemoteSyncService.sync()).thenAnswer((_) => remoteSync.future);

        unawaited(sut.onIosUpload(true, 20));
        async.elapse(const Duration(seconds: 20));
        // a cancelled sync can still return true
        remoteSync.complete(true);
        async.flushMicrotasks();

        verifyNever(() => mockBackgroundUploadService.uploadBackupCandidates(any()));
      });
    });

    test('resumes pending uploads without waiting for the remote sync', () async {
      final remoteSync = Completer<bool>();
      when(() => mockRemoteSyncService.sync()).thenAnswer((_) => remoteSync.future);
      when(
        () => mockBackgroundUploadService.getActiveTasks(kBackupGroup),
      ).thenAnswer((_) async => [UploadTask(url: 'https://example.com', filename: 'photo.jpg')]);

      final upload = sut.onIosUpload(true, 20);
      await pumpEventQueue();
      verify(() => mockBackgroundUploadService.resume()).called(1);

      remoteSync.complete(true);
      await upload;
    });

    test('without a server session indexes the device only', () async {
      await Store.delete(StoreKey.accessToken);
      addTearDown(() => Store.put(StoreKey.accessToken, 'token'));

      await sut.onIosUpload(true, 20);

      verify(() => mockLocalSyncService.sync()).called(1);
      verifyNever(() => mockRemoteSyncService.sync());
      verifyNever(() => mockHashService.hashAssets());
      verifyNever(() => mockBackgroundUploadService.getActiveTasks(any()));
    });
  });

  // The native side destroys the engine on the answer of cancel(): until then the databases stay open for the work
  // still running, and they close once
  group('cancel', () {
    test('during the Android upload closes the databases once, after the running local sync returned', () async {
      final localSync = Completer<void>();
      when(() => mockLocalSyncService.sync()).thenAnswer((_) => localSync.future);
      when(() => mockRemoteSyncService.sync()).thenAnswer((_) async => true);

      final upload = sut.onAndroidUpload(20);
      await pumpEventQueue();
      final cancel = sut.cancel();
      await pumpEventQueue();
      verifyNever(() => mockDataController.close());

      localSync.complete();
      await cancel;
      await upload;
      verify(() => mockDataController.close()).called(1);
      // Cancelled: nothing more starts after the local sync
      verifyNever(() => mockRemoteSyncService.sync());
    });

    test('during the iOS upload closes the databases once, after the running local sync returned', () async {
      final localSync = Completer<void>();
      when(() => mockLocalSyncService.sync()).thenAnswer((_) => localSync.future);
      when(() => mockRemoteSyncService.sync()).thenAnswer((_) async => true);

      final upload = sut.onIosUpload(true, 20);
      await pumpEventQueue();
      final cancel = sut.cancel();
      await pumpEventQueue();
      verifyNever(() => mockDataController.close());

      localSync.complete();
      await cancel;
      await upload;
      verify(() => mockDataController.close()).called(1);
    });

    test('before any work closes the databases at once', () async {
      await sut.cancel();

      verify(() => mockDataController.close()).called(1);
    });

    test('closes the databases at the wait limit when the running sync never returns', () {
      fakeAsync((async) {
        when(() => mockLocalSyncService.sync()).thenAnswer((_) => Completer<void>().future);
        unawaited(sut.onAndroidUpload(20));
        async.flushMicrotasks();

        var answered = false;
        unawaited(sut.cancel().then((_) => answered = true));
        async.elapse(BackgroundWorkerBgService.cancelWaitLimit - const Duration(seconds: 1));
        verifyNever(() => mockDataController.close());
        expect(answered, isFalse);

        async.elapse(const Duration(seconds: 2));
        verify(() => mockDataController.close()).called(1);
        expect(answered, isTrue);
      });
    });

    test('twice closes the databases once', () async {
      await Future.wait([sut.cancel(), sut.cancel()]);

      verify(() => mockDataController.close()).called(1);
    });

    test('makes an upload asked afterwards answer once the cleanup is done, without running', () async {
      final cancel = sut.cancel();
      final upload = sut.onAndroidUpload(20);

      expect(await upload, isFalse);
      await cancel;
      verifyNever(() => mockLocalSyncService.sync());
      verify(() => mockDataController.close()).called(1);
    });
  });
}
