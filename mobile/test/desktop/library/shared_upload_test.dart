import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/desktop/library/shared_file.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;

class _MockHttpClient extends Mock implements http.Client {}

class _FakeBaseRequest extends Fake implements http.BaseRequest {}

// Keeps the FileDownloader singleton off the disk and off the platform channels
class _NoStorage extends Fake implements PersistentStorage {
  @override
  Future<void> initialize() async {}
}

/// Where [part] starts in [whole], or -1
int _indexOf(List<int> whole, List<int> part) {
  for (var i = 0; i + part.length <= whole.length; i++) {
    var j = 0;
    while (j < part.length && whole[i + j] == part[j]) {
      j++;
    }
    if (j == part.length) {
      return i;
    }
  }
  return -1;
}

void main() {
  late Directory dir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FileDownloader(persistentStorage: _NoStorage());
    final db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db));
    await Store.put(StoreKey.serverEndpoint, 'http://demo.immich.app/api');
    registerFallbackValue(_FakeBaseRequest());
  });

  setUp(() => dir = Directory.systemTemp.createTempSync('shared_upload_test_'));
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    dir.deleteSync(recursive: true);
  });

  test('on Windows an upload from a folder lets the user rename and delete the file while it is sent', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final bytes = Uint8List.fromList(List.generate(2 * sharedReadChunkLength + 5, (i) => (i * 13) % 251));
    final file = File(p.join(dir.path, 'VID_0001.insv'))..writeAsBytesSync(bytes);
    final client = _MockHttpClient();
    final body = <int>[];
    when(() => client.send(any())).thenAnswer((invocation) async {
      final request = invocation.positionalArguments.single as http.BaseRequest;
      var renamed = false;
      await for (final chunk in request.finalize()) {
        body.addAll(chunk);
        // Once the file's first bytes went out, the user moves the file away and deletes it
        if (!renamed && body.length > sharedReadChunkLength) {
          renamed = true;
          File(file.renameSync(p.join(dir.path, 'moved.insv')).path).deleteSync();
        }
      }
      return http.StreamedResponse(Stream.value(utf8.encode('{"id":"remote-1"}')), 201);
    });

    final result = await UploadRepository().uploadFile(
      file: file,
      originalFileName: 'VID_0001.insv',
      fields: const {'deviceAssetId': 'f1'},
      cancelToken: null,
      logContext: 'f1',
      httpClient: client,
    );

    expect(result.isSuccess, isTrue);
    expect(file.existsSync(), isFalse);
    final start = _indexOf(body, bytes.sublist(0, 64));
    expect(start, isNot(-1));
    expect(body.sublist(start, start + bytes.length), bytes, reason: 'the whole file, as it was when it was opened');
  });
}
