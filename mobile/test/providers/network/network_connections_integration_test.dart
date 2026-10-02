// The network shares through the providers, with the real WebDAV client and the real media bridge, against the test
// WebDAV server of the development machine (only there: IMMUCH_NET_TESTS=1, http://localhost:1880/, Basic auth
// tester / testpass). No widget binding here: it would answer every HTTP request with an error.

import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';

import 'fakes.dart';

void main() {
  late Drift db;
  late StoreService store;
  late FakeSecureStorage secureStorage;

  const source = NetworkSource(
    id: 'dav-test',
    type: NetworkSourceType.webdav,
    name: 'Test WebDAV',
    host: 'localhost',
    port: 1880,
    username: 'tester',
  );

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    secureStorage = FakeSecureStorage();
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  ProviderContainer createContainer() {
    final container = ProviderContainer(
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        secureStorageServiceProvider.overrideWithValue(secureStorage),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<(int, List<int>)> get(Uri url, {String? range}) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      if (range != null) {
        request.headers.set(HttpHeaders.rangeHeader, range);
      }
      final response = await request.close();
      final bytes = await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
      return (response.statusCode, bytes);
    } finally {
      client.close(force: true);
    }
  }

  group(
    'Network shares on the test WebDAV server',
    skip: Platform.environment['IMMUCH_NET_TESTS'] == '1'
        ? false
        : 'Set IMMUCH_NET_TESTS=1 to run against the test servers of the development machine',
    () {
      test('testConnection counts the entries of the start folder, and refuses a wrong password', () async {
        final connections = createContainer().read(networkConnectionsProvider);

        expect(await connections.testConnection(source, 'testpass'), greaterThan(0));
        await expectLater(
          connections.testConnection(source, 'wrong'),
          throwsA(isA<NetworkFileSystemException>().having((e) => e.isAuthentication, 'isAuthentication', isTrue)),
        );
      });

      test('a saved share plays through the media bridge, until it is removed', () async {
        final container = createContainer();
        await container.read(networkSourcesProvider.notifier).add(source, password: 'testpass');
        final connections = container.read(networkConnectionsProvider);

        final entries = await (await connections.fileSystem(source.id)).list('/');
        final photo = entries.firstWhere((entry) => entry.isImage && entry.extension == 'jpg');
        final url = await connections.mediaUrl(source.id, photo.path);
        expect(url.host, '127.0.0.1');

        final (status, bytes) = await get(url, range: 'bytes=0-1');
        expect(status, HttpStatus.partialContent);
        expect(bytes, [0xFF, 0xD8], reason: 'the start of a JPEG file');

        await container.read(networkSourcesProvider.notifier).remove(source.id);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(connections.opened(source.id), isNull);
        final (statusAfter, _) = await get(url, range: 'bytes=0-1');
        expect(statusAfter, isNot(anyOf(HttpStatus.ok, HttpStatus.partialContent)));
      });
    },
  );
}
