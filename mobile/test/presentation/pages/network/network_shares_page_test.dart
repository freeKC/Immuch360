import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_shares.page.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';

import '../../../providers/network/fakes.dart';
import 'network_test_app.dart';

void main() {
  late Drift db;
  late StoreService store;
  late FakeSecureStorage secureStorage;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    secureStorage = FakeSecureStorage();
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  Future<void> pumpSharesPage(WidgetTester tester, {List<NetworkSource> sources = const []}) async {
    if (sources.isNotEmpty) {
      await store.put(StoreKey.networkSources, NetworkSource.encodeList(sources));
    }
    await pumpNetworkTestApp(
      tester,
      home: const NetworkSharesPage(),
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        secureStorageServiceProvider.overrideWithValue(secureStorage),
      ],
    );
  }

  group('networkSourceAddress', () {
    test('writes an SMB share as smb://host/share', () {
      expect(networkSourceAddress(smbSource), 'smb://nas.local/media');
      expect(networkSourceAddress(smbSource.copyWith(port: 1445)), 'smb://nas.local:1445/media');
    });

    test('writes a WebDAV share as its URL', () {
      expect(networkSourceAddress(webDavSource), 'https://cloud.example.com/remote.php/dav/files/alice');
      expect(
        networkSourceAddress(webDavSource.copyWith(useTls: false, port: 1880, share: '')),
        'http://cloud.example.com:1880',
      );
    });

    test('writes a DLNA media server as the URL of its description, with its icon', () {
      const dlna = NetworkSource(
        id: 'dlna-1',
        type: NetworkSourceType.dlna,
        name: 'Media box',
        host: '192.168.1.10',
        port: 8200,
        share: '/dlna/abc/description.xml?client=1',
      );
      expect(networkSourceAddress(dlna), 'http://192.168.1.10:8200/dlna/abc/description.xml?client=1');
      expect(networkSourceIcon(NetworkSourceType.dlna), Icons.perm_media_outlined);
    });
  });

  group('NetworkSharesPage', () {
    testWidgets('without any share, explains what shares are for and offers to add one', (tester) async {
      await pumpSharesPage(tester);

      expect(find.text('Network shares'), findsOneWidget);
      expect(
        find.text('No share yet. Add a NAS or a computer of your network to play its photos and videos from here.'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Add a share'));
      await tester.pumpAndSettle();

      expect(find.text('edit new'), findsOneWidget);
    });

    testWidgets('lists the shares with their address', (tester) async {
      await pumpSharesPage(tester, sources: const [smbSource, webDavSource]);

      expect(
        find.text(
          'Browse a NAS or a computer of your network and play its photos and videos straight from it. Nothing is '
          'copied to this device.',
        ),
        findsOneWidget,
      );
      expect(find.text('NAS'), findsOneWidget);
      expect(find.text('smb://nas.local/media'), findsOneWidget);
      expect(find.text('Cloud'), findsOneWidget);
      expect(find.text('https://cloud.example.com/remote.php/dav/files/alice'), findsOneWidget);
      expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
      expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
      expect(tester.getTopLeft(find.text('NAS')).dy, lessThan(tester.getTopLeft(find.text('Cloud')).dy));
    });

    testWidgets('opens a share at its start folder when tapped', (tester) async {
      await pumpSharesPage(tester, sources: const [smbSource, webDavSource]);

      await tester.tap(find.text('Cloud'));
      await tester.pumpAndSettle();

      expect(find.text('browse dav-1 /Photos'), findsOneWidget);
    });

    testWidgets('opens the form of a share from its edit button', (tester) async {
      await pumpSharesPage(tester, sources: const [smbSource, webDavSource]);

      await tester.tap(
        find.descendant(of: find.widgetWithText(ListTile, 'NAS'), matching: find.byIcon(Icons.edit_outlined)),
      );
      await tester.pumpAndSettle();

      expect(find.text('edit NAS'), findsOneWidget);
    });

    testWidgets('opens an empty form from the add button of the app bar', (tester) async {
      await pumpSharesPage(tester, sources: const [smbSource]);

      await tester.tap(find.byTooltip('Add a share'));
      await tester.pumpAndSettle();

      expect(find.text('edit new'), findsOneWidget);
    });

    testWidgets('follows the changes of the list', (tester) async {
      await pumpSharesPage(tester, sources: const [smbSource, webDavSource]);
      final container = ProviderScope.containerOf(tester.element(find.byType(NetworkSharesPage)));

      await container.read(networkSourcesProvider.notifier).remove(smbSource.id);
      await tester.pumpAndSettle();

      expect(find.text('NAS'), findsNothing);
      expect(find.text('Cloud'), findsOneWidget);
    });
  });
}
