import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';

void main() {
  late Directory directory;
  late File file;

  NetworkEntry entry(String path, {int size = 100, DateTime? modified, String sourceId = 'nas'}) => NetworkEntry(
    sourceId: sourceId,
    path: path,
    isDirectory: false,
    size: size,
    modified: modified ?? DateTime.utc(2026, 10, 1, 12),
  );

  UploadRecordStore open() => UploadRecordStore(() async => file);

  setUp(() {
    directory = Directory.systemTemp.createTempSync('upload_records');
    file = File('${directory.path}/support/network_uploads.json');
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('knows no file before any was sent, without a record file', () async {
    final store = open();

    expect(await store.load(), isEmpty);
    expect(await store.find(entry('/a.jpg')), isNull);
    expect(file.existsSync(), isFalse);
  });

  test('keeps the files sent across launches, with their asset and date', () async {
    final sentAt = DateTime.utc(2026, 10, 2, 8, 30);
    await open().add(entry('/a.jpg'), 'asset-1', sentAt: sentAt);

    final record = await open().find(entry('/a.jpg'));

    expect(record, UploadRecord(remoteId: 'asset-1', sentAt: sentAt));
  });

  test('forgets a file once it changed on its share', () async {
    final store = open();
    await store.add(entry('/a.jpg'), 'asset-1');

    expect(await store.find(entry('/a.jpg', size: 101)), isNull, reason: 'another size');
    expect(await store.find(entry('/a.jpg', modified: DateTime.utc(2026, 10, 3))), isNull, reason: 'another date');
    expect(await store.find(entry('/a.jpg', sourceId: 'other')), isNull, reason: 'another share');
    expect(await store.find(entry('/b.jpg')), isNull, reason: 'another path');
    expect(await store.find(entry('/a.jpg')), isNotNull);
  });

  test('forgets a file the server does not have anymore, across launches', () async {
    final store = open();
    await store.add(entry('/a.jpg'), 'asset-1');
    await store.add(entry('/b.jpg'), 'asset-2');

    await store.remove(entry('/a.jpg'));

    expect(await store.find(entry('/a.jpg')), isNull);
    expect((await open().load()).keys, [UploadRecordStore.keyOf(entry('/b.jpg'))]);
  });

  test('gives each server and each user a record file of its own', () {
    final name = UploadRecordStore.fileNameFor('https://photos.example.org', 'user-1');

    expect(name, matches(RegExp(r'^network_uploads_[0-9a-f]{40}\.json$')), reason: 'a plain file name');
    expect(UploadRecordStore.fileNameFor('https://photos.example.org', 'user-1'), name);
    expect(UploadRecordStore.fileNameFor('https://other.example.org', 'user-1'), isNot(name), reason: 'another server');
    expect(UploadRecordStore.fileNameFor('https://photos.example.org', 'user-2'), isNot(name), reason: 'another user');
  });

  test('reads and writes nothing without a record file', () async {
    final store = UploadRecordStore(() async => null);

    await store.add(entry('/a.jpg'), 'asset-1');

    expect(await UploadRecordStore(() async => null).load(), isEmpty);
    expect(directory.listSync(recursive: true), isEmpty);
  });

  test('matches the same date given in another time zone', () async {
    final store = open();
    final modified = DateTime.utc(2026, 10, 1, 12);
    await store.add(entry('/a.jpg', modified: modified), 'asset-1');

    expect(await store.find(entry('/a.jpg', modified: modified.toLocal())), isNotNull);
  });

  test('keeps every write when several files are recorded at once', () async {
    final store = open();
    await Future.wait([for (var i = 0; i < 20; i++) store.add(entry('/$i.jpg'), 'asset-$i')]);

    final records = await open().load();

    expect(records, hasLength(20));
    expect(records[UploadRecordStore.keyOf(entry('/7.jpg'))]?.remoteId, 'asset-7');
    expect(File('${file.path}.tmp').existsSync(), isFalse, reason: 'renamed over the record');
  });

  test('starts over from a record that cannot be read, and writes it anew', () async {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{ not json');
    final store = open();

    expect(await store.load(), isEmpty);
    await store.add(entry('/a.jpg'), 'asset-1');

    final json = jsonDecode(file.readAsStringSync()) as Map;
    expect(json['version'], 1);
    expect((json['files'] as Map).values.single, containsPair('id', 'asset-1'));
  });

  test('leaves out the entries of the record it does not understand', () async {
    file.parent.createSync(recursive: true);
    final key = UploadRecordStore.keyOf(entry('/a.jpg'));
    file.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'files': {
          key: {'id': 'asset-1', 'at': '2026-10-02T08:30:00.000Z'},
          'broken': {'id': 3},
        },
      }),
    );

    final records = await open().load();

    expect(records.keys, [key]);
  });
}
