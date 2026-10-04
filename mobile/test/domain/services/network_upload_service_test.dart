import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_upload.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../service.mocks.dart';

class _NoShare implements NetworkFileSystem {
  @override
  final source = const NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'NAS', host: 'nas.local');

  @override
  Future<List<NetworkEntry>> list(String path) => throw UnimplementedError();

  @override
  Future<NetworkEntry> stat(String path) => throw UnimplementedError();

  @override
  Future<Uint8List> readRange(String path, int offset, int length) => throw UnimplementedError();

  @override
  Future<void> close() async {}
}

/// What the server says of a file, by its name
typedef _Answer = ({String? remoteId, bool isDuplicate, String? error});

void main() {
  late Directory directory;
  late UploadRecordStore records;
  late MockForegroundUploadService uploads;
  late NetworkUploadService sut;
  late List<List<String>> sent;
  late Map<String, _Answer> answers;

  /// What the server says of the assets of the files recorded, by asset id: there by default
  late Map<String, Future<bool> Function()> assets;
  late List<String> asked;
  final fileSystem = _NoShare();

  NetworkEntry file(String path, {int size = 10}) =>
      NetworkEntry(sourceId: 'nas', path: path, isDirectory: false, size: size, modified: DateTime.utc(2026, 10, 1));

  setUpAll(() {
    registerFallbackValue(Completer<void>());
    registerFallbackValue(const SourceUploadCallbacks());
  });

  setUp(() {
    directory = Directory.systemTemp.createTempSync('network_upload');
    records = UploadRecordStore(() async => File('${directory.path}/records.json'));
    uploads = MockForegroundUploadService();
    assets = {};
    asked = [];
    sut = NetworkUploadService(uploads, records, (remoteId) {
      asked.add(remoteId);
      return assets[remoteId]?.call() ?? Future.value(true);
    });
    sent = [];
    answers = {};
    when(
      () => uploads.uploadNetworkFiles(
        any(),
        cancelToken: any(named: 'cancelToken'),
        callbacks: any(named: 'callbacks'),
      ),
    ).thenAnswer((invocation) async {
      final items = invocation.positionalArguments.single as List<NetworkUploadItem>;
      final callbacks = invocation.namedArguments[#callbacks] as SourceUploadCallbacks;
      sent.add([for (final item in items) item.entry.path]);
      for (final item in items) {
        callbacks.onProgress?.call(item.id, 5, 10);
        final answer =
            answers[item.entry.name] ?? (remoteId: 'new-${item.entry.name}', isDuplicate: false, error: null);
        final remoteId = answer.remoteId;
        if (remoteId != null) {
          callbacks.onSuccess?.call(item.id, remoteId, isDuplicate: answer.isDuplicate);
        } else {
          callbacks.onError?.call(item.id, answer.error!);
        }
      }
    });
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('sends the files and records them with their asset', () async {
    answers['b.jpg'] = (remoteId: 'old-b', isDuplicate: true, error: null);
    final progress = <String, double>{};
    final outcomes = <String, NetworkUploadOutcome>{};

    final summary = await sut.upload(
      fileSystem,
      [file('/a.jpg'), file('/b.jpg')],
      cancelToken: Completer<void>(),
      listener: NetworkUploadListener(
        onProgress: (id, value) => progress[id] = value,
        onFinished: (id, outcome) => outcomes[id] = outcome,
      ),
    );

    expect(sent, [
      ['/a.jpg', '/b.jpg'],
    ]);
    expect(summary.sent, 1);
    expect(summary.duplicates, 1);
    expect(summary.failed, 0);
    expect(summary.cancelled, isFalse);
    expect(progress, {'nas:/a.jpg': 0.5, 'nas:/b.jpg': 0.5});
    expect(outcomes, {'nas:/a.jpg': NetworkUploadOutcome.sent, 'nas:/b.jpg': NetworkUploadOutcome.duplicate});
    expect((await records.find(file('/a.jpg')))?.remoteId, 'new-a.jpg');
    expect((await records.find(file('/b.jpg')))?.remoteId, 'old-b', reason: 'the server has it too');
  });

  test('does not read again a file sent before, unchanged since, that the server still has', () async {
    await records.add(file('/a.jpg'), 'earlier');
    final outcomes = <String, NetworkUploadOutcome>{};

    final summary = await sut.upload(
      fileSystem,
      [file('/a.jpg'), file('/b.jpg')],
      cancelToken: Completer<void>(),
      listener: NetworkUploadListener(onFinished: (id, outcome) => outcomes[id] = outcome),
    );

    expect(asked, ['earlier'], reason: 'only the file recorded is asked about');
    expect(sent, [
      ['/b.jpg'],
    ]);
    expect(summary.sent, 1);
    expect(summary.duplicates, 1);
    expect(outcomes['nas:/a.jpg'], NetworkUploadOutcome.duplicate);
  });

  test('sends again a file whose asset the server deleted or trashed, and forgets the old asset', () async {
    await records.add(file('/a.jpg'), 'deleted');
    assets['deleted'] = () async => false;
    answers['a.jpg'] = (remoteId: null, isDuplicate: false, error: 'offline');

    final summary = await sut.upload(fileSystem, [file('/a.jpg')], cancelToken: Completer<void>());

    expect(sent, [
      ['/a.jpg'],
    ]);
    expect(summary.duplicates, 0);
    expect(summary.failed, 1);
    expect(await records.find(file('/a.jpg')), isNull, reason: 'not on the server, whatever became of the send');
  });

  test('sends again a file the server cannot tell about, and keeps its record until it answers', () async {
    await records.add(file('/a.jpg'), 'earlier');
    assets['earlier'] = () async => throw Exception('offline');
    answers['a.jpg'] = (remoteId: null, isDuplicate: false, error: 'offline');

    await sut.upload(fileSystem, [file('/a.jpg')], cancelToken: Completer<void>());

    expect(sent, [
      ['/a.jpg'],
    ]);
    expect((await records.find(file('/a.jpg')))?.remoteId, 'earlier');
  });

  test('records a file as it was right before it was sent, not as it was listed', () async {
    final listed = file('/a.jpg', size: 10);
    final grown = NetworkEntry(
      sourceId: 'nas',
      path: '/a.jpg',
      isDirectory: false,
      size: 25,
      modified: DateTime.utc(2026, 10, 1, 0, 5),
    );
    when(
      () => uploads.uploadNetworkFiles(
        any(),
        cancelToken: any(named: 'cancelToken'),
        callbacks: any(named: 'callbacks'),
      ),
    ).thenAnswer((invocation) async {
      final item = (invocation.positionalArguments.single as List<NetworkUploadItem>).single;
      final callbacks = invocation.namedArguments[#callbacks] as SourceUploadCallbacks;
      callbacks.onSending?.call(item.id, grown);
      callbacks.onSuccess?.call(item.id, 'new-a', isDuplicate: false);
    });

    await sut.upload(fileSystem, [listed], cancelToken: Completer<void>());

    expect((await records.find(grown))?.remoteId, 'new-a');
    expect(await records.find(listed), isNull);
  });

  test('stops asking the server about the files recorded once cancelled', () async {
    final cancelToken = Completer<void>();
    await records.add(file('/a.jpg'), 'asset-a');
    await records.add(file('/b.jpg'), 'asset-b');
    assets['asset-a'] = () async {
      cancelToken.complete();
      return true;
    };

    final summary = await sut.upload(fileSystem, [file('/a.jpg'), file('/b.jpg')], cancelToken: cancelToken);

    expect(asked, ['asset-a']);
    expect(summary.cancelled, isTrue);
  });

  test('sends again a file that changed since it was sent', () async {
    await records.add(file('/a.jpg'), 'earlier');

    await sut.upload(fileSystem, [file('/a.jpg', size: 11)], cancelToken: Completer<void>());

    expect(sent, [
      ['/a.jpg'],
    ]);
    expect(asked, isEmpty, reason: 'no record of the file as it is now');
  });

  test('counts the failures, says why the last one failed, and does not record them', () async {
    answers['a.jpg'] = (remoteId: null, isDuplicate: false, error: 'Quota has been exceeded!');

    final summary = await sut.upload(fileSystem, [file('/a.jpg')], cancelToken: Completer<void>());

    expect(summary.failed, 1);
    expect(summary.lastError, 'Quota has been exceeded!');
    expect(await records.find(file('/a.jpg')), isNull);
  });

  test('leaves out the folders and the files given twice', () async {
    await sut.upload(fileSystem, [
      file('/a.jpg'),
      const NetworkEntry(sourceId: 'nas', path: '/Holidays', isDirectory: true),
      file('/a.jpg'),
    ], cancelToken: Completer<void>());

    expect(sent, [
      ['/a.jpg'],
    ]);
  });

  test('says when it was cancelled', () async {
    final summary = await sut.upload(fileSystem, [file('/a.jpg')], cancelToken: Completer<void>()..complete());

    expect(summary.cancelled, isTrue);
  });
}
