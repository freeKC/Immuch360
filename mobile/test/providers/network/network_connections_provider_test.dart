import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Drift db;
  late StoreService store;
  late FakeSecureStorage secureStorage;
  late FakeMediaBridge bridge;

  /// Every file system the openers gave, in order
  late List<FakeFileSystem> opened;

  /// Thrown by the next opening when set
  Exception? openError;

  /// Completes the openings when set, to look at the state while they are pending
  Completer<void>? openGate;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    secureStorage = FakeSecureStorage();
    bridge = FakeMediaBridge();
    opened = [];
    openError = null;
    openGate = null;
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  Future<NetworkFileSystem> fakeOpen(NetworkSource source, String? password) async {
    final gate = openGate;
    if (gate != null) {
      await gate.future;
    }
    final error = openError;
    if (error != null) {
      throw error;
    }
    final fileSystem = FakeFileSystem(
      source,
      password: password,
      entries: {
        '/': [
          fakeEntry(source.id, '/sub', isDirectory: true),
          fakeEntry(source.id, '/a.jpg'),
          fakeEntry(source.id, '/b.mp4'),
        ],
        '/Photos': [fakeEntry(source.id, '/Photos/c.jpg')],
      },
    );
    opened.add(fileSystem);
    return fileSystem;
  }

  ProviderContainer createContainer() {
    final container = ProviderContainer(
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        secureStorageServiceProvider.overrideWithValue(secureStorage),
        mediaBridgeProvider.overrideWithValue(bridge),
        networkFileSystemOpenersProvider.overrideWithValue({
          NetworkSourceType.smb: fakeOpen,
          NetworkSourceType.webdav: fakeOpen,
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<ProviderContainer> withSources() async {
    final container = createContainer();
    final sources = container.read(networkSourcesProvider.notifier);
    await sources.add(smbSource, password: 'smb-password');
    await sources.add(webDavSource);
    return container;
  }

  test('opens the shares of each type with their client, DLNA media servers included', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(networkFileSystemOpenersProvider).keys.toSet(), NetworkSourceType.values.toSet());
  });

  group('NetworkConnections', () {
    test('opens a share on first use with its stored password, once, and registers it on the bridge', () async {
      final container = await withSources();
      final connections = container.read(networkConnectionsProvider);
      expect(connections.opened(smbSource.id), isNull);

      final results = await Future.wait([connections.fileSystem(smbSource.id), connections.fileSystem(smbSource.id)]);
      final again = await connections.fileSystem(smbSource.id);

      expect(opened, hasLength(1));
      expect(results, everyElement(same(opened.single)));
      expect(again, same(opened.single));
      expect(connections.opened(smbSource.id), same(opened.single));
      expect(opened.single.password, 'smb-password');
      expect(opened.single.source.id, smbSource.id);
      expect(bridge.starts, greaterThanOrEqualTo(1));
      expect(bridge.registered, {smbSource.id: opened.single});
    });

    test('opens a share without a stored password with none', () async {
      final container = await withSources();

      await container.read(networkConnectionsProvider).fileSystem(webDavSource.id);

      expect(opened.single.password, isNull);
      expect(bridge.registered.keys, [webDavSource.id]);
    });

    test('gives the bridge URL of a file, opening the share first', () async {
      final container = await withSources();

      final url = await container.read(networkConnectionsProvider).mediaUrl(smbSource.id, '/a.jpg');

      expect(url, Uri.parse('http://127.0.0.1:1234/token/smb-1/a.jpg'));
      expect(bridge.registered.keys, [smbSource.id]);
    });

    test('fails for an unknown share', () async {
      final container = await withSources();

      await expectLater(
        container.read(networkConnectionsProvider).fileSystem('unknown'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
      expect(opened, isEmpty);
    });

    test('passes on an opening failure and tries again on the next use', () async {
      final container = await withSources();
      final connections = container.read(networkConnectionsProvider);
      openError = const NetworkFileSystemException('Wrong password', isAuthentication: true);

      await expectLater(connections.fileSystem(smbSource.id), throwsA(isA<NetworkFileSystemException>()));
      expect(bridge.registered, isEmpty);

      openError = null;
      final fileSystem = await connections.fileSystem(smbSource.id);
      expect(fileSystem, same(opened.single));
      expect(bridge.registered.keys, [smbSource.id]);
    });

    test('closes the connection of a removed share and takes it off the bridge', () async {
      final container = await withSources();
      final connections = container.read(networkConnectionsProvider);
      await connections.fileSystem(smbSource.id);
      await connections.fileSystem(webDavSource.id);
      final smb = opened.first;

      await container.read(networkSourcesProvider.notifier).remove(smbSource.id);
      await pumpEventQueue();

      expect(smb.closed, isTrue);
      expect(connections.opened(smbSource.id), isNull);
      expect(bridge.unregistered, [smbSource.id]);
      expect(bridge.registered.keys, [webDavSource.id]);
      expect(opened.last.closed, isFalse, reason: 'the other share stays open');
    });

    test('opens a changed share again with its new password', () async {
      final container = await withSources();
      final connections = container.read(networkConnectionsProvider);
      final first = await connections.fileSystem(smbSource.id);

      await container.read(networkSourcesProvider.notifier).update(smbSource, password: 'new-password');
      await pumpEventQueue();

      expect((first as FakeFileSystem).closed, isTrue);
      final second = await connections.fileSystem(smbSource.id);
      expect(second, isNot(same(first)));
      expect((second as FakeFileSystem).password, 'new-password');
      expect(bridge.registered[smbSource.id], same(second));
    });

    test('drops a connection closed while it was opening', () async {
      final container = await withSources();
      final connections = container.read(networkConnectionsProvider);
      openGate = Completer();

      final opening = connections.fileSystem(smbSource.id);
      await pumpEventQueue();
      await connections.close(smbSource.id);
      openGate!.complete();

      await expectLater(opening, throwsA(isA<NetworkFileSystemException>()));
      expect(opened.single.closed, isTrue);
      expect(bridge.registered, isEmpty);
      expect(connections.opened(smbSource.id), isNull);

      openGate = null;
      expect(await connections.fileSystem(smbSource.id), same(opened.last));
      expect(opened, hasLength(2));
    });

    test('closes every connection when the provider goes away', () async {
      final container = await withSources();
      final connections = container.read(networkConnectionsProvider);
      await connections.fileSystem(smbSource.id);
      await connections.fileSystem(webDavSource.id);

      container.dispose();
      await pumpEventQueue();

      expect(opened.every((fileSystem) => fileSystem.closed), isTrue);
      expect(bridge.registered, isEmpty);
    });

    group('testConnection', () {
      test('counts the entries of the start folder with the given password, apart from the kept ones', () async {
        final container = createContainer();
        final connections = container.read(networkConnectionsProvider);

        expect(await connections.testConnection(smbSource, 'typed'), 3);
        expect(opened.single.password, 'typed');
        expect(opened.single.listed, ['/']);
        expect(opened.single.closed, isTrue);
        expect(bridge.registered, isEmpty);
        expect(connections.opened(smbSource.id), isNull);

        expect(await connections.testConnection(webDavSource, ''), 1);
        expect(opened.last.password, isNull, reason: 'an empty password is no password');
        expect(opened.last.listed, ['/Photos']);
      });

      test('throws when the share cannot be opened', () async {
        final connections = createContainer().read(networkConnectionsProvider);
        openError = const NetworkFileSystemException('Host unreachable');

        await expectLater(
          connections.testConnection(smbSource, null),
          throwsA(isA<NetworkFileSystemException>().having((e) => e.message, 'message', 'Host unreachable')),
        );
      });

      test('throws when the start folder cannot be read, and still closes the connection', () async {
        final connections = createContainer().read(networkConnectionsProvider);

        await expectLater(
          connections.testConnection(smbSource.copyWith(rootPath: '/missing'), null),
          throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
        );
        expect(opened.single.closed, isTrue);
      });
    });
  });
}
