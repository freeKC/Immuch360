import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../api.mocks.dart';
import '../fixtures/asset.stub.dart';
import '../infrastructure/repository.mock.dart';
import '../mocks/asset_entity.mock.dart';
import '../repository.mocks.dart';
import '../service.mocks.dart';

/// A share in memory with the files of [files]; [stat] gives their size, or the one of [statSizes], and their date of
/// [modified]
class _MemoryShare implements NetworkFileSystem {
  _MemoryShare(this.files);

  final Map<String, Uint8List> files;
  final Map<String, int> statSizes = {};
  final Map<String, DateTime> modified = {};
  final List<String> statted = [];

  @override
  final source = const NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'NAS', host: 'nas.local');

  @override
  Future<NetworkEntry> stat(String path) async {
    statted.add(path);
    return NetworkEntry(
      sourceId: source.id,
      path: path,
      isDirectory: false,
      size: statSizes[path] ?? files[path]!.length,
      modified: modified[path],
    );
  }

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    final bytes = files[path]!;
    final start = math.min(offset, bytes.length);
    return Uint8List.sublistView(bytes, start, math.min(start + length, bytes.length));
  }

  @override
  Future<List<NetworkEntry>> list(String path) => throw UnimplementedError();

  @override
  Future<void> close() async {}
}

void main() {
  late ForegroundUploadService sut;
  late MockUploadRepository mockUploadRepository;
  late MockStorageRepository mockStorageRepository;
  late MockBackupRepository mockBackupRepository;
  late MockConnectivityApi mockConnectivityApi;
  late MockAssetMediaRepository mockAssetMediaRepository;
  late MockAssetService mockAssetService;
  late Drift db;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async => 'test',
    );
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db));
    await SettingsRepository.ensureInitialized(db);

    await Store.put(StoreKey.serverEndpoint, 'http://demo.immich.app');
    await Store.put(StoreKey.deviceId, 'device-id');

    registerFallbackValue(File('file'));
    registerFallbackValue(<String, String>{});
    registerFallbackValue(() => const Stream<List<int>>.empty());
  });

  setUp(() {
    mockUploadRepository = MockUploadRepository();
    mockStorageRepository = MockStorageRepository();
    mockBackupRepository = MockBackupRepository();
    mockConnectivityApi = MockConnectivityApi();
    mockAssetMediaRepository = MockAssetMediaRepository();
    mockAssetService = MockAssetService();
    when(() => mockAssetService.stackEditedUpload(any(), any(), any())).thenAnswer((_) async {});

    sut = ForegroundUploadService(
      mockUploadRepository,
      mockStorageRepository,
      mockBackupRepository,
      mockConnectivityApi,
      mockAssetMediaRepository,
      mockAssetService,
    );
  });

  List<Map<String, String>> captureFields() {
    final captured = <Map<String, String>>[];
    when(
      () => mockUploadRepository.uploadFile(
        file: any(named: 'file'),
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: any(named: 'logContext'),
      ),
    ).thenAnswer((invocation) async {
      final fields = invocation.namedArguments[#fields] as Map<String, String>;
      captured.add(Map.of(fields));
      return UploadResult.success(remoteAssetId: 'remote-${captured.length}');
    });
    return captured;
  }

  List<String> captureOriginalFileNames() {
    final captured = <String>[];
    when(
      () => mockUploadRepository.uploadFile(
        file: any(named: 'file'),
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: any(named: 'logContext'),
      ),
    ).thenAnswer((invocation) async {
      captured.add(invocation.namedArguments[#originalFileName] as String);
      return UploadResult.success(remoteAssetId: 'remote-${captured.length}');
    });
    return captured;
  }

  group('uploadSingleAsset', () {
    test('should upload the motion part hidden and keep the still image visible', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/still.heic');
      final videoFile = File('/path/to/motion.mov');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockStorageRepository.getMotionFileForAsset(asset)).thenAnswer((_) async => videoFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'live.heic');

      final captured = captureFields();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(captured, hasLength(2));
      expect(captured[0]['visibility'], equals('hidden'));
      expect(captured[0].containsKey('livePhotoVideoId'), isFalse);
      expect(captured[1].containsKey('visibility'), isFalse);
      expect(captured[1]['livePhotoVideoId'], equals('remote-1'));
    });

    test('should not set visibility for a regular photo', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/photo.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'photo.jpg');

      final captured = captureFields();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(captured, hasLength(1));
      expect(captured[0].containsKey('visibility'), isFalse);
    });

    test('corrects the extension when iOS returns a rendered file for a .dng asset', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/IMG_6499.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'IMG_6499.dng');

      final names = captureOriginalFileNames();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(names, equals(['IMG_6499.jpg']));
    });

    test('keeps the .dng extension for a genuine RAW original', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/IMG_5210.dng');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'IMG_5210.dng');

      final names = captureOriginalFileNames();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(names, equals(['IMG_5210.dng']));
    });

    test('borrows the extension from the asset name for an extensionless name (DJI/Fusion)', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/DJI_0001');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'DJI_0001');

      final names = captureOriginalFileNames();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(names, equals(['DJI_0001.jpg']));
    });

    test('stacks a plain photo after its upload', () async {
      final asset = LocalAssetStub.image1.copyWith(checksum: 'sha');
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/photo.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'photo.jpg');
      captureFields();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      verify(() => mockAssetService.stackEditedUpload(asset.localId!, 'remote-1', 'sha')).called(1);
      verifyNoMoreInteractions(mockAssetService);
    });

    test('stacks the still of a live photo, not its video', () async {
      final asset = LocalAssetStub.image1.copyWith(checksum: 'sha');
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/still.heic');
      final videoFile = File('/path/to/motion.mov');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockStorageRepository.getMotionFileForAsset(asset)).thenAnswer((_) async => videoFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'live.heic');
      captureFields();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      verify(() => mockAssetService.stackEditedUpload(asset.localId!, 'remote-2', 'sha')).called(1);
      verifyNoMoreInteractions(mockAssetService);
    });
  });

  group('uploadNetworkFiles', () {
    final modified = DateTime.utc(2026, 10, 1, 12, 30);
    late _MemoryShare share;

    NetworkUploadItem item(String path, {bool withSize = true, int? listedSize}) => NetworkUploadItem(
      fileSystem: share,
      entry: NetworkEntry(
        sourceId: 'nas',
        path: path,
        isDirectory: false,
        size: withSize ? listedSize ?? share.files[path]!.length : null,
        modified: modified,
      ),
    );

    /// The uploads asked of the repository, answered by [answer] (a new asset by default)
    List<Invocation> stubUploads({Future<UploadResult> Function(Invocation invocation)? answer}) {
      final calls = <Invocation>[];
      when(
        () => mockUploadRepository.uploadStream(
          openRead: any(named: 'openRead'),
          length: any(named: 'length'),
          filename: any(named: 'filename'),
          fields: any(named: 'fields'),
          headers: any(named: 'headers'),
          cancelToken: any(named: 'cancelToken'),
          onProgress: any(named: 'onProgress'),
          logContext: any(named: 'logContext'),
        ),
      ).thenAnswer((invocation) {
        calls.add(invocation);
        return answer?.call(invocation) ?? Future.value(UploadResult.success(remoteAssetId: 'remote-${calls.length}'));
      });
      return calls;
    }

    setUp(() {
      share = _MemoryShare({
        '/Holidays/beach.jpg': Uint8List.fromList(List.generate(1000, (i) => i % 256)),
        '/Holidays/trip.mp4': Uint8List.fromList(List.generate(3000, (i) => i % 7)),
      });
    });

    test('sends each file with its name, its date and an id of its place on the share', () async {
      final calls = stubUploads();

      await sut.uploadNetworkFiles([item('/Holidays/beach.jpg')], cancelToken: Completer<void>());

      final call = calls.single;
      expect(call.namedArguments[#filename], 'beach.jpg');
      expect(call.namedArguments[#length], 1000);
      expect(call.namedArguments[#headers], isEmpty, reason: 'no checksum header');
      expect(call.namedArguments[#fields], {
        'deviceAssetId': 'share-${sha1.convert(utf8.encode('nas/Holidays/beach.jpg'))}',
        'deviceId': 'device-id',
        'fileCreatedAt': '2026-10-01T12:30:00.000Z',
        'fileModifiedAt': '2026-10-01T12:30:00.000Z',
        'isFavorite': 'false',
        'duration': '0',
      });
      verifyNever(() => mockStorageRepository.clearCache());
    });

    test('streams the file from the share, again from its start at each send', () async {
      final calls = stubUploads();

      await sut.uploadNetworkFiles([item('/Holidays/trip.mp4')], cancelToken: Completer<void>());

      final openRead = calls.single.namedArguments[#openRead] as Stream<List<int>> Function();
      final first = await openRead().expand((chunk) => chunk).toList();
      final again = await openRead().expand((chunk) => chunk).toList();
      expect(first, share.files['/Holidays/trip.mp4']);
      expect(again, first);
    });

    test('asks the share for the size of a file listed without one', () async {
      final calls = stubUploads();

      await sut.uploadNetworkFiles([item('/Holidays/trip.mp4', withSize: false)], cancelToken: Completer<void>());

      expect(share.statted, ['/Holidays/trip.mp4']);
      expect(calls.single.namedArguments[#length], 3000);
    });

    test('announces the size and the date of a stat made right before the send, not those of the listing', () async {
      final calls = stubUploads();
      final grownAt = DateTime.utc(2026, 10, 1, 12, 45);
      share.modified['/Holidays/trip.mp4'] = grownAt;
      final sending = <(String, NetworkEntry)>[];

      await sut.uploadNetworkFiles(
        [item('/Holidays/trip.mp4', listedSize: 1000)],
        cancelToken: Completer<void>(),
        callbacks: SourceUploadCallbacks(onSending: (id, entry) => sending.add((id, entry))),
      );

      final call = calls.single;
      expect(call.namedArguments[#length], 3000, reason: 'the file grew since it was listed');
      expect((call.namedArguments[#fields] as Map)['fileModifiedAt'], '2026-10-01T12:45:00.000Z');
      final openRead = call.namedArguments[#openRead] as Stream<List<int>> Function();
      expect(await openRead().expand((chunk) => chunk).toList(), share.files['/Holidays/trip.mp4']);
      final (id, entry) = sending.single;
      expect(id, 'nas:/Holidays/trip.mp4');
      expect((entry.path, entry.size, entry.modified), ('/Holidays/trip.mp4', 3000, grownAt));
    });

    test('says that a file is still being written when it reads short of a size other than the listed one', () async {
      // Listed with 1000 bytes, 5000 by the stat, 3000 when read
      share.statSizes['/Holidays/trip.mp4'] = 5000;
      stubUploads(
        answer: (invocation) async {
          final openRead = invocation.namedArguments[#openRead] as Stream<List<int>> Function();
          try {
            await openRead().drain<void>();
            return UploadResult.success(remoteAssetId: 'remote');
          } catch (error) {
            // What an HTTP client makes of the error of the body stream
            return UploadResult.error(errorMessage: 'ClientException: $error');
          }
        },
      );
      final errors = <(String, String)>[];

      await sut.uploadNetworkFiles(
        [item('/Holidays/trip.mp4', listedSize: 1000)],
        cancelToken: Completer<void>(),
        callbacks: SourceUploadCallbacks(onError: (id, message) => errors.add((id, message))),
      );

      expect(errors, [
        (
          'nas:/Holidays/trip.mp4',
          'trip.mp4 is still being written on the share (1000 bytes listed, 5000 when its upload started, then fewer '
              'could be read): send it again once it is complete',
        ),
      ]);
    });

    test('keeps the error of the server when the share gave every byte asked', () async {
      share.statSizes['/Holidays/trip.mp4'] = 3000;
      stubUploads(answer: (_) async => UploadResult.error(errorMessage: 'boom', statusCode: 500));
      final errors = <String>[];

      await sut.uploadNetworkFiles(
        [item('/Holidays/trip.mp4', listedSize: 1000)],
        cancelToken: Completer<void>(),
        callbacks: SourceUploadCallbacks(onError: (_, message) => errors.add(message)),
      );

      expect(errors, ['boom']);
    });

    test('sends one file at a time', () async {
      var sending = 0;
      var most = 0;
      stubUploads(
        answer: (_) async {
          sending++;
          most = math.max(most, sending);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          sending--;
          return UploadResult.success(remoteAssetId: 'remote');
        },
      );

      await sut.uploadNetworkFiles([
        item('/Holidays/beach.jpg'),
        item('/Holidays/trip.mp4'),
        item('/Holidays/beach.jpg'),
      ], cancelToken: Completer<void>());

      expect(most, 1);
    });

    test('tells a new asset from a file the server already had, and a failure', () async {
      stubUploads(
        answer: (invocation) async => switch (invocation.namedArguments[#filename]) {
          'beach.jpg' => UploadResult.success(remoteAssetId: 'old', isDuplicate: true),
          _ => UploadResult.error(errorMessage: 'boom', statusCode: 500),
        },
      );
      final successes = <(String, String, bool)>[];
      final errors = <(String, String)>[];

      await sut.uploadNetworkFiles(
        [item('/Holidays/beach.jpg'), item('/Holidays/trip.mp4')],
        cancelToken: Completer<void>(),
        callbacks: SourceUploadCallbacks(
          onSuccess: (id, remoteId, {required isDuplicate}) => successes.add((id, remoteId, isDuplicate)),
          onError: (id, message) => errors.add((id, message)),
        ),
      );

      expect(successes, [('nas:/Holidays/beach.jpg', 'old', true)]);
      expect(errors, [('nas:/Holidays/trip.mp4', 'boom')]);
    });

    test('stops at a cancel without reporting it as a failure', () async {
      final cancelToken = Completer<void>();
      final calls = stubUploads(
        answer: (_) async {
          cancelToken.complete();
          return UploadResult.cancelled();
        },
      );
      final errors = <String>[];

      await sut.uploadNetworkFiles(
        [item('/Holidays/beach.jpg'), item('/Holidays/trip.mp4')],
        cancelToken: cancelToken,
        callbacks: SourceUploadCallbacks(onError: (id, _) => errors.add(id)),
      );

      expect(calls, hasLength(1));
      expect(errors, isEmpty);
    });

    test('stops once the quota is exceeded', () async {
      final calls = stubUploads(answer: (_) async => UploadResult.error(errorMessage: 'Quota has been exceeded!'));

      await sut.uploadNetworkFiles([
        item('/Holidays/beach.jpg'),
        item('/Holidays/trip.mp4'),
      ], cancelToken: Completer<void>());

      expect(calls, hasLength(1));
      expect(sut.shouldAbortNetworkUpload, isTrue);
      expect(sut.shouldAbortUpload, isFalse, reason: 'the backup may go on');
    });

    test('goes on while a backup was cancelled, and leaves the backup cancelled', () async {
      final calls = stubUploads();
      sut.shouldAbortUpload = true;

      await sut.uploadNetworkFiles([
        item('/Holidays/beach.jpg'),
        item('/Holidays/trip.mp4'),
      ], cancelToken: Completer<void>());

      expect(calls, hasLength(2));
      expect(sut.shouldAbortUpload, isTrue);
    });

    test('a cancelled upload from the shares leaves the next backup alone', () async {
      final cancelToken = Completer<void>();
      stubUploads(
        answer: (_) async {
          cancelToken.complete();
          return UploadResult.cancelled();
        },
      );

      await sut.uploadNetworkFiles([item('/Holidays/beach.jpg')], cancelToken: cancelToken);

      expect(sut.shouldAbortNetworkUpload, isTrue);
      expect(sut.shouldAbortUpload, isFalse);
    });

    test('cancelNetworkUploads stops the shares only, a logout stops both', () {
      sut.cancelNetworkUploads();
      expect(sut.shouldAbortNetworkUpload, isTrue);
      expect(sut.shouldAbortUpload, isFalse);

      sut.shouldAbortNetworkUpload = false;
      sut.cancel();
      expect(sut.shouldAbortNetworkUpload, isTrue);
      expect(sut.shouldAbortUpload, isTrue);
    });
  });

  group('uploadShareIntent', () {
    test('streams a shared file with its name, its size and its dates', () async {
      final directory = Directory.systemTemp.createTempSync('share_intent');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/shared.jpg')..writeAsBytesSync(List.filled(42, 7));
      when(() => mockStorageRepository.clearCache()).thenAnswer((_) async {});
      final calls = <Invocation>[];
      when(
        () => mockUploadRepository.uploadStream(
          openRead: any(named: 'openRead'),
          length: any(named: 'length'),
          filename: any(named: 'filename'),
          fields: any(named: 'fields'),
          headers: any(named: 'headers'),
          cancelToken: any(named: 'cancelToken'),
          onProgress: any(named: 'onProgress'),
          logContext: any(named: 'logContext'),
        ),
      ).thenAnswer((invocation) async {
        calls.add(invocation);
        return UploadResult.success(remoteAssetId: 'remote-1');
      });
      final successes = <String>[];

      await sut.uploadShareIntent([file], onSuccess: (_, remoteId) => successes.add(remoteId));

      final call = calls.single;
      expect(call.namedArguments[#filename], 'shared.jpg');
      expect(call.namedArguments[#length], 42);
      final fields = call.namedArguments[#fields] as Map<String, String>;
      expect(fields['fileModifiedAt'], file.statSync().modified.toUtc().toIso8601String());
      final openRead = call.namedArguments[#openRead] as Stream<List<int>> Function();
      expect(await openRead().expand((chunk) => chunk).toList(), List.filled(42, 7));
      expect(successes, ['remote-1']);
    });
  });
}
