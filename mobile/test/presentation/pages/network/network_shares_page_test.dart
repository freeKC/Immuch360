import 'package:auto_route/auto_route.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_shares.page.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';

import '../../../providers/network/fakes.dart';
import 'network_test_app.dart';

const _plexServer = NetworkSource(
  id: 'plex-1',
  type: NetworkSourceType.plex,
  name: 'Test Plex',
  host: '192.0.2.20',
  rootPath: '/Photos',
  useTls: true,
  discoveryId: '0000000000000000000000000000000000000001',
  plex: PlexServerInfo(hash: '0123456789abcdef0123456789abcdef'),
);

const _camera = NetworkSource(
  id: 'cam-1',
  type: NetworkSourceType.tapo,
  name: 'Garden',
  host: '192.0.2.30',
  useTls: true,
  camera: TapoCameraInfo(model: 'C200'),
);

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

  Future<RootStackRouter> pumpSharesPage(WidgetTester tester, {List<NetworkSource> sources = const []}) async {
    final legacy = sources.where((source) => source.type.inLegacyList).toList();
    final extra = sources.where((source) => !source.type.inLegacyList).toList();
    if (legacy.isNotEmpty) {
      await store.put(StoreKey.networkSources, NetworkSource.encodeList(legacy));
    }
    if (extra.isNotEmpty) {
      await store.put(StoreKey.networkSourcesExtra, NetworkSource.encodeList(extra));
    }
    return pumpNetworkTestApp(
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

    test('writes a Plex server as plex://host:port, its address outside home when it has no local one', () {
      expect(networkSourceAddress(_plexServer), 'plex://192.0.2.20:32400');
      expect(networkSourceAddress(_plexServer.copyWith(port: 32500)), 'plex://192.0.2.20:32500');
      final outside = _plexServer.copyWith(
        host: '',
        plex: const PlexServerInfo(hash: '0123456789abcdef0123456789abcdef', publicHost: '203.0.113.7'),
      );
      expect(networkSourceAddress(outside), 'plex://203.0.113.7:32400');
      expect(
        networkSourceAddress(outside.copyWith(plex: outside.plex!.copyWith(publicPort: 32401))),
        'plex://203.0.113.7:32401',
      );
      expect(networkSourceIcon(NetworkSourceType.plex), Icons.video_library_outlined);
    });

    test('writes a camera as tapo://host', () {
      expect(networkSourceAddress(_camera), 'tapo://192.0.2.30');
      expect(networkSourceIcon(NetworkSourceType.tapo), Icons.videocam_outlined);
    });
  });

  group('the routes of a source', () {
    test('a camera opens its own page, the shares the browser at their start folder', () {
      final camera = networkSourceOpenRoute(_camera);
      expect(camera.routeName, CameraRoute.name);
      expect((camera.args! as CameraRouteArgs).sourceId, 'cam-1');
      for (final source in [smbSource, webDavSource, _plexServer]) {
        final route = networkSourceOpenRoute(source);
        expect(route.routeName, NetworkBrowserRoute.name);
        expect((route.args! as NetworkBrowserRouteArgs).path, source.rootPath);
      }
    });

    test('each type is edited on its own page, a Plex server on its token after a refusal', () {
      expect(networkSourceEditRoute(smbSource).routeName, NetworkShareEditRoute.name);
      expect(networkSourceEditRoute(webDavSource, focusCredentials: true).routeName, NetworkShareEditRoute.name);
      final plex = networkSourceEditRoute(_plexServer, focusCredentials: true);
      expect(plex.routeName, PlexServerEditRoute.name);
      expect((plex.args! as PlexServerEditRouteArgs).focusToken, isTrue);
      expect((networkSourceEditRoute(_plexServer).args! as PlexServerEditRouteArgs).focusToken, isFalse);
      expect(networkSourceEditRoute(_camera).routeName, CameraEditRoute.name);
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
      await tester.tap(find.byKey(const Key('network_add_choose_share')));
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

    testWidgets('the add button asks what to add: a share, a Plex server or a camera, each on its own page', (
      tester,
    ) async {
      final router = await pumpSharesPage(tester, sources: const [smbSource]);
      final pages = {
        'network_add_choose_share': 'edit new',
        'network_add_choose_plex': 'plex edit new',
        'network_add_choose_camera': 'camera edit new',
      };

      for (final MapEntry(key: choice, value: page) in pages.entries) {
        await tester.tap(find.byTooltip('Add a share'));
        await tester.pumpAndSettle();
        expect(find.text('A network share (NAS, computer, media server)'), findsOneWidget);
        expect(find.text('A Plex Media Server'), findsOneWidget);
        expect(find.text('A Tapo camera'), findsOneWidget);

        await tester.tap(find.byKey(Key(choice)));
        await tester.pumpAndSettle();
        expect(find.text(page), findsOneWidget, reason: choice);

        await router.maybePop();
        await tester.pumpAndSettle();
      }

      // Closing the sheet opens nothing
      await tester.tap(find.byTooltip('Add a share'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('NAS'), findsOneWidget);
    });

    testWidgets('lists the Plex servers with the shares and the cameras under their own header', (tester) async {
      await pumpSharesPage(tester, sources: const [_camera, _plexServer, smbSource]);

      expect(find.text('Test Plex'), findsOneWidget);
      expect(find.text('plex://192.0.2.20:32400'), findsOneWidget);
      expect(find.byKey(const Key('network_shares_cameras_header')), findsOneWidget);
      expect(find.text('Cameras'), findsOneWidget);
      expect(find.text('C200, tapo://192.0.2.30'), findsOneWidget);
      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(top('NAS'), lessThan(top('Test Plex')));
      expect(top('Test Plex'), lessThan(top('Cameras')));
      expect(top('Cameras'), lessThan(top('Garden')));
    });

    testWidgets('no camera header without a camera, and the address alone for a camera of unknown model', (
      tester,
    ) async {
      await pumpSharesPage(tester, sources: const [smbSource]);
      expect(find.byKey(const Key('network_shares_cameras_header')), findsNothing);

      final container = ProviderScope.containerOf(tester.element(find.byType(NetworkSharesPage)));
      await container
          .read(networkSourcesProvider.notifier)
          .add(const NetworkSource(id: 'cam-2', type: NetworkSourceType.tapo, name: 'Door', host: '192.0.2.31'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('network_shares_cameras_header')), findsOneWidget);
      expect(find.text('tapo://192.0.2.31'), findsOneWidget);
    });

    testWidgets('opens a Plex server in the browser and a camera on its page, and edits each on its page', (
      tester,
    ) async {
      final router = await pumpSharesPage(tester, sources: const [_plexServer, _camera]);

      await tester.tap(find.text('Test Plex'));
      await tester.pumpAndSettle();
      expect(find.text('browse plex-1 /Photos'), findsOneWidget);
      await router.maybePop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Garden'));
      await tester.pumpAndSettle();
      expect(find.text('camera cam-1'), findsOneWidget);
      await router.maybePop();
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(of: find.widgetWithText(ListTile, 'Test Plex'), matching: find.byIcon(Icons.edit_outlined)),
      );
      await tester.pumpAndSettle();
      expect(find.text('plex edit Test Plex'), findsOneWidget);
      await router.maybePop();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Edit the camera'));
      await tester.pumpAndSettle();
      expect(find.text('camera edit Garden'), findsOneWidget);
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
