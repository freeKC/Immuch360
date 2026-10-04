import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/network_upload.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/widgets/network/network_upload.widget.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/user.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/services/auth.service.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:immich_mobile/services/widget.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../presentation/pages/network/network_viewer_fakes.dart';
import '../../repository.mocks.dart';
import '../../service.mocks.dart';

class _MemoryRecords extends UploadRecordStore {
  _MemoryRecords() : super(() => throw UnimplementedError('in memory'));

  final Map<String, UploadRecord> records = {};

  @override
  Future<Map<String, UploadRecord>> load() async => records;

  @override
  Future<void> add(NetworkEntry entry, String remoteId, {DateTime? sentAt}) async {
    records[UploadRecordStore.keyOf(entry)] = UploadRecord(remoteId: remoteId, sentAt: DateTime.utc(2026, 10, 2));
  }

  @override
  Future<void> remove(NetworkEntry entry) async {
    records.remove(UploadRecordStore.keyOf(entry));
  }
}

UserDto _user(String id) => UserDto(id: id, email: '$id@test.dev', name: id, profileChangedAt: DateTime(2026));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'Home NAS', host: 'nas.local');
  late MemoryShare share;
  late MockForegroundUploadService uploads;
  late _MemoryRecords records;
  late StateProvider<bool> server;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbackValue(Completer<void>());
    registerFallbackValue(const SourceUploadCallbacks());
  });

  /// A container of the share, the uploads and the records of the test, with [extra] overrides
  ProviderContainer makeContainer([List<Override> extra = const []]) {
    final made = ProviderContainer(
      overrides: [
        overrideConnections((ref) => FakeConnections(ref, share)),
        foregroundUploadServiceProvider.overrideWithValue(uploads),
        uploadRecordStoreProvider.overrideWithValue(records),
        hasServerProvider.overrideWith((ref) => ref.watch(server)),
        ...extra,
      ],
    );
    addTearDown(made.dispose);
    made.listen(networkUploadProvider, (_, _) {});
    return made;
  }

  setUp(() {
    share = MemoryShare(source, files: {'/a.jpg': fakePhoto(), '/b.jpg': fakePhoto(), '/c.mp4': fakePhoto()});
    uploads = MockForegroundUploadService();
    records = _MemoryRecords();
    server = StateProvider<bool>((_) => true);
    container = makeContainer();
  });

  /// Answers each upload file by file: [onFile] runs before the answer of each, [failing] are the paths that fail
  void stubUploads({
    Future<void> Function(NetworkUploadItem item, Completer<void> cancelToken)? onFile,
    Set<String> failing = const {},
  }) {
    when(
      () => uploads.uploadNetworkFiles(
        any(),
        cancelToken: any(named: 'cancelToken'),
        callbacks: any(named: 'callbacks'),
      ),
    ).thenAnswer((invocation) async {
      final items = invocation.positionalArguments.single as List<NetworkUploadItem>;
      final cancelToken = invocation.namedArguments[#cancelToken] as Completer<void>;
      final callbacks = invocation.namedArguments[#callbacks] as SourceUploadCallbacks;
      for (final item in items) {
        if (cancelToken.isCompleted) {
          return;
        }
        await onFile?.call(item, cancelToken);
        if (cancelToken.isCompleted) {
          return;
        }
        if (failing.contains(item.entry.path)) {
          callbacks.onError?.call(item.id, 'Quota has been exceeded!');
        } else {
          callbacks.onSuccess?.call(item.id, 'remote-${item.entry.path}', isDuplicate: false);
        }
      }
    });
  }

  NetworkUploadNotifier notifier() => container.read(networkUploadProvider.notifier);
  NetworkUploadState state() => container.read(networkUploadProvider);

  test('follows the files as they are sent, and the record knows them after', () async {
    final halfway = Completer<void>();
    final release = Completer<void>();
    stubUploads(
      onFile: (item, _) async {
        if (item.entry.path == '/a.jpg') {
          halfway.complete();
          await release.future;
        }
      },
    );

    final upload = notifier().upload('nas', [share.file('/a.jpg'), share.folder('/sub'), share.file('/b.jpg')]);
    await halfway.future;

    expect(state().isRunning, isTrue);
    expect(state().total, 2, reason: 'the folder is left out');
    expect(state().current, 1);
    expect(state().progress.keys, [networkUploadId(share.file('/a.jpg')), networkUploadId(share.file('/b.jpg'))]);

    release.complete();
    final summary = await upload;
    await pumpEventQueue();

    expect(summary?.sent, 2);
    expect(state().isRunning, isFalse);
    expect(state().progress, isEmpty);
    expect(container.read(networkUploadRecordsProvider).keys, {
      UploadRecordStore.keyOf(share.file('/a.jpg')),
      UploadRecordStore.keyOf(share.file('/b.jpg')),
    });
  });

  test('sends one upload at a time', () async {
    final release = Completer<void>();
    stubUploads(onFile: (_, _) => release.future);

    final first = notifier().upload('nas', [share.file('/a.jpg')]);
    await pumpEventQueue();

    expect(await notifier().upload('nas', [share.file('/b.jpg')]), isNull);

    release.complete();
    expect((await first)?.sent, 1);
    verify(
      () => uploads.uploadNetworkFiles(
        any(),
        cancelToken: any(named: 'cancelToken'),
        callbacks: any(named: 'callbacks'),
      ),
    ).called(1);
  });

  test('keeps the failures marked once the upload ends', () async {
    stubUploads(failing: {'/b.jpg'});

    final summary = await notifier().upload('nas', [share.file('/a.jpg'), share.file('/b.jpg')]);

    expect(summary?.failed, 1);
    expect(summary?.lastError, 'Quota has been exceeded!');
    expect(state().progress, {networkUploadId(share.file('/b.jpg')): NetworkUploadState.failed});
  });

  test('a cancel stops the upload, and the files not sent go back to normal', () async {
    final started = Completer<void>();
    stubUploads(
      onFile: (_, cancelToken) async {
        if (!started.isCompleted) {
          started.complete();
        }
        await cancelToken.future;
      },
    );

    final upload = notifier().upload('nas', [share.file('/a.jpg'), share.file('/b.jpg')]);
    await started.future;
    notifier().cancel();
    final summary = await upload;

    expect(summary?.cancelled, isTrue);
    expect(summary?.sent, 0);
    expect(state().isRunning, isFalse);
    expect(state().progress, isEmpty);
  });

  test('stops the upload once there is no server anymore', () async {
    Completer<void>? token;
    final started = Completer<void>();
    stubUploads(
      onFile: (_, cancelToken) async {
        token = cancelToken;
        if (!started.isCompleted) {
          started.complete();
        }
        await cancelToken.future;
      },
    );

    final upload = notifier().upload('nas', [share.file('/a.jpg')]);
    await started.future;
    container.read(server.notifier).state = false;
    await pumpEventQueue();

    expect(token?.isCompleted, isTrue);
    expect((await upload)?.cancelled, isTrue);
  });

  test('stop ends the request in flight and forgets the upload at once, whatever it reports after', () async {
    final first = Completer<Completer<void>>();
    final release = Completer<void>();
    final second = Completer<void>();
    final releaseSecond = Completer<void>();
    when(
      () => uploads.uploadNetworkFiles(
        any(),
        cancelToken: any(named: 'cancelToken'),
        callbacks: any(named: 'callbacks'),
      ),
    ).thenAnswer((invocation) async {
      final item = (invocation.positionalArguments.single as List<NetworkUploadItem>).single;
      final callbacks = invocation.namedArguments[#callbacks] as SourceUploadCallbacks;
      if (item.entry.path == '/a.jpg') {
        first.complete(invocation.namedArguments[#cancelToken] as Completer<void>);
        await release.future;
        // The request stopped answers late
        callbacks.onProgress?.call(item.id, 5, 10);
        callbacks.onError?.call(item.id, 'aborted');
      } else {
        second.complete();
        await releaseSecond.future;
        callbacks.onSuccess?.call(item.id, 'remote-b', isDuplicate: false);
      }
    });

    final stopped = notifier().upload('nas', [share.file('/a.jpg')]);
    final token = await first.future;
    notifier().stop();

    expect(token.isCompleted, isTrue);
    expect(state().isRunning, isFalse);
    expect(state().progress, isEmpty);

    final next = notifier().upload('nas', [share.file('/b.jpg')]);
    await second.future;
    release.complete();
    await stopped;

    expect(state().isRunning, isTrue, reason: 'the end of the upload stopped leaves the next one alone');
    expect(state().finished, 0);
    expect(state().progress, {networkUploadId(share.file('/b.jpg')): 0.0});

    releaseSecond.complete();
    expect((await next)?.sent, 1);
    expect(state().isRunning, isFalse);
  });

  test('a logout stops the upload in flight', () async {
    final authService = MockAuthService();
    final secureStorage = MockSecureStorageService();
    final widgets = MockWidgetService();
    final backgroundUploads = MockBackgroundUploadService();
    when(authService.logout).thenAnswer((_) async {});
    when(() => secureStorage.delete(any())).thenAnswer((_) async {});
    when(widgets.clearCredentials).thenAnswer((_) async {});
    when(backgroundUploads.cancel).thenAnswer((_) async => 0);
    when(uploads.cancel).thenReturn(null);
    container = makeContainer([
      authServiceProvider.overrideWithValue(authService),
      apiServiceProvider.overrideWithValue(MockApiService()),
      userServiceProvider.overrideWithValue(MockUserService()),
      secureStorageServiceProvider.overrideWithValue(secureStorage),
      widgetServiceProvider.overrideWithValue(widgets),
      backgroundUploadServiceProvider.overrideWithValue(backgroundUploads),
    ]);
    final started = Completer<Completer<void>>();
    stubUploads(
      onFile: (_, cancelToken) async {
        started.complete(cancelToken);
        await cancelToken.future;
      },
    );

    final upload = notifier().upload('nas', [share.file('/a.jpg')]);
    final token = await started.future;
    await container.read(authProvider.notifier).logout();

    expect(token.isCompleted, isTrue);
    expect(state().isRunning, isFalse);
    expect((await upload)?.cancelled, isTrue);
  });

  test('asks the server about a file recorded before, and sends it again once the server lost it', () async {
    final assets = MockAssetApiRepository();
    when(() => assets.isInLibrary('lost')).thenAnswer((_) async => false);
    container = makeContainer([assetApiRepositoryProvider.overrideWithValue(assets)]);
    await records.add(share.file('/a.jpg'), 'lost');
    stubUploads();

    final summary = await notifier().upload('nas', [share.file('/a.jpg')]);

    expect(summary?.sent, 1);
    expect(records.records.values.single.remoteId, 'remote-/a.jpg');
  });

  test('throws when the share cannot be reached, and is ready for the next upload', () async {
    stubUploads();

    await expectLater(notifier().upload('other', [share.file('/a.jpg')]), throwsA(isA<Exception>()));

    expect(state().isRunning, isFalse);
    expect((await notifier().upload('nas', [share.file('/a.jpg')]))?.sent, 1);
  });

  group('uploadRecordStoreProvider', () {
    late Directory support;
    late StreamController<UserDto?> users;
    late ProviderContainer scoped;

    setUpAll(() async {
      final db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
      await StoreService.init(storeRepository: StoreRepository(db));
    });

    setUp(() async {
      support = Directory.systemTemp.createTempSync('network_upload_records');
      addTearDown(() => support.deleteSync(recursive: true));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
      await Store.put(StoreKey.serverUrl, 'https://photos.example.org');
      users = StreamController<UserDto?>.broadcast();
      addTearDown(users.close);
      final userService = MockUserService();
      when(userService.tryGetMyUser).thenReturn(_user('alice'));
      when(userService.watchMyUser).thenAnswer((_) => users.stream);
      scoped = ProviderContainer(
        overrides: [currentUserProvider.overrideWith((ref) => CurrentUserProvider(userService))],
      );
      addTearDown(scoped.dispose);
    });

    test('keeps a record per user, which the next user does not see', () async {
      await scoped.read(uploadRecordStoreProvider).add(share.file('/a.jpg'), 'asset-of-alice');

      users.add(_user('bob'));
      await pumpEventQueue();

      expect(await scoped.read(uploadRecordStoreProvider).find(share.file('/a.jpg')), isNull);

      users.add(_user('alice'));
      await pumpEventQueue();

      expect((await scoped.read(uploadRecordStoreProvider).find(share.file('/a.jpg')))?.remoteId, 'asset-of-alice');
    });

    test('keeps a record per server for the same user', () async {
      await scoped.read(uploadRecordStoreProvider).add(share.file('/a.jpg'), 'asset-1');

      await Store.put(StoreKey.serverUrl, 'https://other.example.org');
      scoped.invalidate(uploadRecordStoreProvider);

      expect(await scoped.read(uploadRecordStoreProvider).find(share.file('/a.jpg')), isNull);
    });
  });

  group('networkUploadResultMessage', () {
    final t = StaticTranslations.instance;

    test('says how many were sent, were there already, and failed', () {
      expect(
        networkUploadResultMessage(t, const NetworkUploadSummary(sent: 2, duplicates: 1, failed: 3)),
        '${t.network_upload_done(count: 2)} · ${t.network_upload_duplicates(count: 1)} · '
        '${t.network_upload_failed(count: 3)}',
      );
    });

    test('says why a single failure failed', () {
      expect(
        networkUploadResultMessage(t, const NetworkUploadSummary(failed: 1, lastError: 'offline')),
        t.network_upload_error(error: 'offline'),
      );
    });

    test('says that the upload was cancelled, and nothing when nothing happened', () {
      expect(
        networkUploadResultMessage(t, const NetworkUploadSummary(sent: 1, cancelled: true)),
        '${t.network_upload_cancelled} · ${t.network_upload_done(count: 1)}',
      );
      expect(networkUploadResultMessage(t, const NetworkUploadSummary()), isNull);
    });
  });
}
