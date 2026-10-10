import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_share_edit.page.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_text_entry.widget.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_discovery.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../../providers/network/fakes.dart';
import 'network_test_app.dart';

class _MockTvApi extends Mock implements TvApi {}

/// Each discovery is a stream the test drives; it ends at once unless [keepOpen]
class _FakeDiscovery implements NetworkDiscoveryService {
  bool keepOpen = false;
  final List<StreamController<List<DiscoveredServer>>> scans = [];

  /// The index in [scans] of each discovery whose listener went away: cancelled, or told that the discovery ended
  final List<int> cancelled = [];

  @override
  Stream<List<DiscoveredServer>> discover({
    Duration timeout = NetworkDiscoveryService.defaultTimeout,
    List<String>? hosts,
  }) {
    final index = scans.length;
    final scan = StreamController<List<DiscoveredServer>>(onCancel: () => cancelled.add(index));
    scans.add(scan);
    if (!keepOpen) {
      unawaited(scan.close());
    }
    return scan.stream;
  }
}

const _nas = DiscoveredServer(
  host: '192.168.1.20',
  displayName: 'Living room NAS',
  type: NetworkSourceType.smb,
  port: 445,
  origin: DiscoveryOrigin.mdns,
);

const _office = DiscoveredServer(
  host: '192.168.1.40',
  displayName: 'Office NAS',
  type: NetworkSourceType.smb,
  port: 445,
  origin: DiscoveryOrigin.scan,
);

const _media = DiscoveredServer(
  host: '192.168.1.50',
  displayName: 'Media box',
  type: NetworkSourceType.dlna,
  port: 8200,
  path: '/rootDesc.xml',
  origin: DiscoveryOrigin.ssdp,
  address: '192.168.1.50',
  discoveryId: 'uuid:4d696e69-444c-164e-9d41-000000000001',
);

const _phone = DiscoveredServer(
  host: '192.168.1.42',
  displayName: 'Immuch360 on Pixel',
  type: NetworkSourceType.webdav,
  port: 8360,
  origin: DiscoveryOrigin.mdns,
  discoveryId: 'a1b2c3d4e5f60718',
  username: 'phone1234',
  isPhoneShare: true,
);

const _plex = DiscoveredServer(
  host: '192.0.2.20',
  displayName: 'Test Plex',
  type: NetworkSourceType.plex,
  port: 32400,
  useTls: true,
  origin: DiscoveryOrigin.gdm,
  discoveryId: '0000000000000000000000000000000000000001',
  plexHash: '0123456789abcdef0123456789abcdef',
);

const _tapo = DiscoveredServer(
  host: '192.0.2.30',
  displayName: 'Tapo C200',
  type: NetworkSourceType.tapo,
  port: 443,
  useTls: true,
  origin: DiscoveryOrigin.tdp,
  discoveryId: '02-00-00-00-00-01',
);

const _cloud = DiscoveredServer(
  host: '192.168.1.30',
  displayName: 'Cloud',
  type: NetworkSourceType.webdav,
  port: 5006,
  useTls: true,
  path: '/dav/photos',
  origin: DiscoveryOrigin.scan,
);

void main() {
  late Drift db;
  late StoreService store;
  late FakeSecureStorage secureStorage;
  late FakeMediaBridge bridge;
  late _FakeDiscovery discovery;

  /// What the share lister was asked, and what it answers
  late List<(NetworkSource, String?)> listed;
  late Future<List<String>> Function() listAnswer;

  /// What the connection tests opened, with the password they got
  late List<FakeFileSystem> opened;
  Exception? openError;

  /// How many of the three entries of the start folder the share holds
  late int startFolderEntries;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    secureStorage = FakeSecureStorage();
    bridge = FakeMediaBridge();
    discovery = _FakeDiscovery();
    listed = [];
    listAnswer = () async => const ['media', 'photos'];
    opened = [];
    openError = null;
    startFolderEntries = 3;
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  Future<NetworkFileSystem> fakeOpen(NetworkSource source, String? password) async {
    final error = openError;
    if (error != null) {
      throw error;
    }
    final fileSystem = FakeFileSystem(
      source,
      password: password,
      entries: {
        '/': [
          fakeEntry(source.id, '/a.jpg'),
          fakeEntry(source.id, '/b.mp4'),
          fakeEntry(source.id, '/sub'),
        ].take(startFolderEntries).toList(),
      },
    );
    opened.add(fileSystem);
    return fileSystem;
  }

  List<NetworkSource> storedSources() => NetworkSource.decodeList(store.tryGet(StoreKey.networkSources));

  /// Opens the form over a stub page, so that leaving it can be seen; in the remote control layout of a TV with
  /// [tvMode], on the screen of a 1080p TV with [tvScreen]
  Future<void> pumpEditPage(
    WidgetTester tester, {
    NetworkSource? source,
    bool settle = true,
    bool tvMode = false,
    bool tvScreen = false,
    TvApi? tvApi,
  }) async {
    if (tvScreen) {
      // A Google TV at 1920 x 1080 and 320 dpi: 960 x 540 logical pixels
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 2;
      addTearDown(tester.view.reset);
    } else {
      // Tall enough for the whole form
      tester.view.physicalSize = const Size(2400, 4800);
      addTearDown(tester.view.resetPhysicalSize);
    }

    final router = await pumpNetworkTestApp(
      tester,
      home: const Scaffold(body: Text('shares list')),
      builder: tvMode ? (context, child) => TvShell(child: child!) : null,
      overrides: [
        if (tvMode) ...[tvModeProvider.overrideWithValue(true), tvApiProvider.overrideWithValue(tvApi ?? _MockTvApi())],
        storeServiceProvider.overrideWithValue(store),
        secureStorageServiceProvider.overrideWithValue(secureStorage),
        mediaBridgeProvider.overrideWithValue(bridge),
        networkFileSystemOpenersProvider.overrideWithValue({
          NetworkSourceType.smb: fakeOpen,
          NetworkSourceType.webdav: fakeOpen,
          NetworkSourceType.dlna: fakeOpen,
        }),
        networkDiscoveryServiceProvider.overrideWithValue(discovery),
        networkShareListerProvider.overrideWithValue((source, password) {
          listed.add((source, password));
          return listAnswer();
        }),
      ],
      pages: {
        NetworkShareEditRoute.name: (data) {
          final args = data.argsAs<NetworkShareEditRouteArgs>(orElse: () => const NetworkShareEditRouteArgs());
          return NetworkShareEditPage(source: args.source);
        },
      },
    );
    // The push completes when the form is left
    unawaited(router.push(NetworkShareEditRoute(source: source)));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // The progress indicator of a scan never settles
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }
  }

  Finder field(String key) => find.byKey(Key('network_share_$key'));

  String textOf(WidgetTester tester, String key) => tester.widget<TextField>(field(key)).controller!.text;

  Future<void> enter(WidgetTester tester, String key, String text) async {
    await tester.ensureVisible(field(key));
    await tester.enterText(field(key), text);
    await tester.pump();
  }

  Future<void> tapButton(WidgetTester tester, Finder button) async {
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  // The buttons with an icon are subclasses of the button types
  Finder button(String label) =>
      find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));
  final saveButton = button('Save');
  final testButton = button('Test the connection');
  final removeButton = button('Remove this share');

  bool isEnabled(WidgetTester tester, Finder button) => tester.widget<ButtonStyleButton>(button).onPressed != null;

  group('NetworkShareEditPage, a new share', () {
    testWidgets('saves an SMB share, its password in the secure storage only, and goes back', (tester) async {
      await pumpEditPage(tester);

      expect(find.text('Add a share'), findsOneWidget);
      expect(removeButton, findsNothing);
      expect(find.text('Secure connection (HTTPS)'), findsNothing, reason: 'HTTPS is for WebDAV');
      expect(isEnabled(tester, saveButton), isFalse);

      await enter(tester, 'name', 'My NAS');
      await enter(tester, 'host', 'nas.local');
      expect(isEnabled(tester, saveButton), isFalse, reason: 'an SMB share needs its share name');
      await enter(tester, 'share', '/media/');
      await enter(tester, 'port', '1445');
      await enter(tester, 'root_path', r'photos\2026\');
      await enter(tester, 'username', 'tester');
      await enter(tester, 'password', 'testpass');
      expect(isEnabled(tester, saveButton), isTrue);

      await tapButton(tester, saveButton);

      expect(find.text('shares list'), findsOneWidget);
      final saved = storedSources().single;
      expect(saved.type, NetworkSourceType.smb);
      expect(saved.name, 'My NAS');
      expect(saved.host, 'nas.local');
      expect(saved.port, 1445);
      expect(saved.share, 'media');
      expect(saved.rootPath, '/photos/2026');
      expect(saved.username, 'tester');
      expect(saved.useTls, isFalse);
      expect(saved.id, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(secureStorage.values, {saved.secretKey: 'testpass'});
      expect(store.tryGet(StoreKey.networkSources), isNot(contains('testpass')));
    });

    testWidgets('names a share after its server when no name is given', (tester) async {
      await pumpEditPage(tester);

      await enter(tester, 'host', '192.168.1.20');
      await enter(tester, 'share', 'media');
      await tapButton(tester, saveButton);

      final saved = storedSources().single;
      expect(saved.name, '192.168.1.20');
      expect(saved.port, isNull);
      expect(saved.rootPath, '/');
      expect(secureStorage.values, isEmpty);
    });

    testWidgets('saves a WebDAV share over HTTPS', (tester) async {
      await pumpEditPage(tester);

      await tapButton(tester, find.byKey(const Key('network_share_type_webdav')));
      expect(find.text('Path of the WebDAV address'), findsOneWidget);
      expect(isEnabled(tester, saveButton), isFalse);

      await enter(tester, 'host', 'cloud.example.com');
      expect(isEnabled(tester, saveButton), isTrue, reason: 'the path of a WebDAV address is optional');
      await enter(tester, 'share', 'remote.php/dav/files/alice/');
      await tapButton(tester, find.text('Secure connection (HTTPS)'));
      await tapButton(tester, saveButton);

      final saved = storedSources().single;
      expect(saved.type, NetworkSourceType.webdav);
      expect(saved.host, 'cloud.example.com');
      expect(saved.share, '/remote.php/dav/files/alice');
      expect(saved.useTls, isTrue);
    });

    testWidgets('refuses a port out of range', (tester) async {
      await pumpEditPage(tester);

      await enter(tester, 'host', 'nas.local');
      await enter(tester, 'share', 'media');
      await enter(tester, 'port', '70000');

      expect(find.text('1-65535'), findsOneWidget);
      expect(isEnabled(tester, saveButton), isFalse);
      expect(isEnabled(tester, testButton), isFalse);
    });

    testWidgets('spreads a pasted address over the fields', (tester) async {
      await pumpEditPage(tester);

      await enter(tester, 'host', 'https://cloud.example.com:8443/remote.php/dav/files/alice');
      await tester.tap(field('name'));
      await tester.pumpAndSettle();

      expect(textOf(tester, 'host'), 'cloud.example.com');
      expect(textOf(tester, 'port'), '8443');
      expect(textOf(tester, 'share'), '/remote.php/dav/files/alice');
      expect(find.text('Path of the WebDAV address'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('network_share_use_tls'))).value, isTrue);
    });

    testWidgets('saves a typed SMB address at once, without leaving the field', (tester) async {
      await pumpEditPage(tester);

      await enter(tester, 'host', 'smb://nas.local:1445/media/photos');
      expect(isEnabled(tester, saveButton), isTrue);
      await tapButton(tester, saveButton);

      final saved = storedSources().single;
      expect(saved.type, NetworkSourceType.smb);
      expect(saved.host, 'nas.local');
      expect(saved.port, 1445);
      expect(saved.share, 'media');
      expect(saved.rootPath, '/photos');
      expect(saved.name, 'nas.local');
    });

    testWidgets('tests the connection with the typed password and tells how many entries it found', (tester) async {
      await pumpEditPage(tester);
      await enter(tester, 'host', 'nas.local');
      await enter(tester, 'share', 'media');
      await enter(tester, 'password', 'typed');

      await tapButton(tester, testButton);

      expect(find.text('Connected, 3 entries in the start folder'), findsOneWidget);
      expect(opened.single.password, 'typed');
      expect(opened.single.closed, isTrue);
      expect(bridge.registered, isEmpty);
      expect(storedSources(), isEmpty, reason: 'a test saves nothing');

      // A change of the fields clears the outcome
      await enter(tester, 'share', 'other');
      expect(find.text('Connected, 3 entries in the start folder'), findsNothing);
    });

    testWidgets('tells one entry in the singular', (tester) async {
      startFolderEntries = 1;
      await pumpEditPage(tester);
      await enter(tester, 'host', 'nas.local');
      await enter(tester, 'share', 'media');

      await tapButton(tester, testButton);

      expect(find.text('Connected, 1 entry in the start folder'), findsOneWidget);
      expect(find.textContaining('1 entries'), findsNothing);
    });

    testWidgets('tells why the connection failed', (tester) async {
      openError = const NetworkFileSystemException('Wrong user name or password', isAuthentication: true);
      await pumpEditPage(tester);
      await enter(tester, 'host', 'nas.local');
      await enter(tester, 'share', 'media');

      await tapButton(tester, testButton);

      expect(find.text('Connection failed: Wrong user name or password'), findsOneWidget);
    });
  });

  group('NetworkShareEditPage, servers found on the network', () {
    Finder found(DiscoveredServer server) =>
        find.byKey(Key('network_share_found_${server.type.name}_${server.host}_${server.port}'));
    final progress = find.byKey(const Key('network_share_scan_progress'));
    final scanAgain = find.byKey(const Key('network_share_scan_again'));

    testWidgets('shows the servers found while the scan runs', (tester) async {
      discovery.keepOpen = true;
      await pumpEditPage(tester, settle: false);

      expect(discovery.scans, hasLength(1), reason: 'the scan starts with the page');
      expect(find.text('Found on the network'), findsOneWidget);
      expect(progress, findsOneWidget);
      expect(scanAgain, findsNothing);
      expect(find.text('Looking for shares, media servers and cameras on your network'), findsOneWidget);
      expect(
        find.text('Not in the list? Enter the details by hand below, the form works for any server.'),
        findsOneWidget,
      );

      discovery.scans.single.add(const [_cloud, _nas]);
      await tester.pump();

      expect(find.text('Tap a server to fill in the form'), findsOneWidget);
      expect(find.descendant(of: found(_nas), matching: find.text('Living room NAS')), findsOneWidget);
      expect(find.descendant(of: found(_nas), matching: find.text('192.168.1.20:445')), findsOneWidget);
      expect(find.descendant(of: found(_nas), matching: find.text('SMB')), findsOneWidget);
      expect(find.descendant(of: found(_nas), matching: find.byIcon(Icons.dns_outlined)), findsOneWidget);
      expect(find.descendant(of: found(_cloud), matching: find.text('WebDAV')), findsOneWidget);
      expect(find.descendant(of: found(_cloud), matching: find.byIcon(Icons.cloud_outlined)), findsOneWidget);

      await discovery.scans.single.close();
      await tester.pumpAndSettle();

      expect(progress, findsNothing);
      expect(scanAgain, findsOneWidget);
      expect(found(_nas), findsOneWidget, reason: 'the list stays once the scan ended');
    });

    testWidgets('fills the form with the server tapped and asks for the user name', (tester) async {
      discovery.keepOpen = true;
      await pumpEditPage(tester, settle: false);
      discovery.scans.single.add(const [_cloud, _nas]);
      await discovery.scans.single.close();
      await tester.pumpAndSettle();

      await tapButton(tester, found(_cloud));

      expect(find.text('Path of the WebDAV address'), findsOneWidget);
      expect(textOf(tester, 'host'), '192.168.1.30');
      expect(textOf(tester, 'port'), '5006');
      expect(textOf(tester, 'share'), '/dav/photos');
      expect(textOf(tester, 'name'), 'Cloud');
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('network_share_use_tls'))).value, isTrue);
      expect(tester.widget<TextField>(field('username')).focusNode!.hasFocus, isTrue);

      await tapButton(tester, found(_nas));

      expect(find.text('Path of the WebDAV address'), findsNothing);
      expect(textOf(tester, 'host'), '192.168.1.20');
      expect(textOf(tester, 'port'), '445');
      expect(textOf(tester, 'share'), '', reason: 'a WebDAV path is no share name');
      expect(textOf(tester, 'name'), 'Living room NAS', reason: 'the name filled in for the other server is replaced');

      await enter(tester, 'share', 'media');
      await enter(tester, 'username', 'tester');
      await tapButton(tester, saveButton);

      final saved = storedSources().single;
      expect(saved.type, NetworkSourceType.smb);
      expect(saved.name, 'Living room NAS');
      expect(saved.host, '192.168.1.20');
      expect(saved.port, 445);
      expect(saved.share, 'media');
    });

    testWidgets('a second tap replaces what the first one filled in, and keeps what the user typed', (tester) async {
      discovery.keepOpen = true;
      await pumpEditPage(tester, settle: false);
      discovery.scans.single.add(const [_cloud, _nas, _office]);
      await discovery.scans.single.close();
      await tester.pumpAndSettle();

      await tapButton(tester, found(_nas));
      expect(textOf(tester, 'name'), 'Living room NAS');
      // A share picked in the list of this server
      await enter(tester, 'username', 'tester');
      await tapButton(tester, find.byKey(const Key('network_share_choose_share')));
      await tester.tap(find.byKey(const Key('network_share_pick_photos')));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'share'), 'photos');

      await tapButton(tester, found(_office));

      expect(textOf(tester, 'host'), '192.168.1.40');
      expect(textOf(tester, 'name'), 'Office NAS', reason: 'the name filled in for the other server is replaced');
      expect(textOf(tester, 'share'), '', reason: 'so is the share picked on the other server');

      await enter(tester, 'name', 'My NAS');
      await enter(tester, 'share', 'media');
      await tapButton(tester, found(_nas));

      expect(textOf(tester, 'host'), '192.168.1.20');
      expect(textOf(tester, 'name'), 'My NAS', reason: 'a name typed by the user stays');
      expect(textOf(tester, 'share'), 'media', reason: 'so does a share typed by the user');

      await tapButton(tester, saveButton);

      final saved = storedSources().single;
      expect(saved.name, 'My NAS');
      expect(saved.host, '192.168.1.20');
      expect(saved.share, 'media');
    });

    testWidgets('stops the scan under way when the page is left', (tester) async {
      discovery.keepOpen = true;
      await pumpEditPage(tester, settle: false);
      expect(discovery.scans.single.hasListener, isTrue);
      expect(discovery.cancelled, isEmpty);

      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();

      expect(find.text('shares list'), findsOneWidget);
      expect(discovery.cancelled, [0], reason: 'the page cancels the discovery as it goes');
      expect(discovery.scans.single.isClosed, isFalse, reason: 'the discovery itself had not ended');
    });

    testWidgets('a new scan lets go of the previous one, and stops when the page is left', (tester) async {
      await pumpEditPage(tester);
      expect(discovery.cancelled, [0], reason: 'the first scan ended');

      discovery.keepOpen = true;
      await tester.tap(scanAgain);
      await tester.pump();

      expect(discovery.scans, hasLength(2));
      expect(discovery.scans.first.hasListener, isFalse);
      expect(discovery.scans.last.hasListener, isTrue);
      expect(discovery.cancelled, [0], reason: 'the new scan runs');

      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();

      expect(discovery.cancelled, [0, 1]);
      expect(discovery.scans.last.isClosed, isFalse, reason: 'cancelled by the page');
    });

    testWidgets('tells when nothing was found, and scans again', (tester) async {
      await pumpEditPage(tester);

      expect(find.text('No server found on this network.'), findsOneWidget);
      expect(progress, findsNothing);

      discovery.keepOpen = true;
      await tester.tap(scanAgain);
      await tester.pump();

      expect(discovery.scans, hasLength(2));
      expect(progress, findsOneWidget);
      expect(find.text('No server found on this network.'), findsNothing);

      discovery.scans.last.add(const [_nas]);
      await discovery.scans.last.close();
      await tester.pumpAndSettle();
      expect(found(_nas), findsOneWidget);
    });

    testWidgets('does not scan for an existing share', (tester) async {
      await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [smbSource]));
      await pumpEditPage(tester, source: smbSource);

      expect(discovery.scans, isEmpty);
      expect(find.text('Found on the network'), findsNothing);
    });
  });

  group('NetworkShareEditPage, the shares of an SMB server', () {
    final chooseButton = find.byKey(const Key('network_share_choose_share'));

    testWidgets('lists the shares once the server and the user name are there, and fills the one chosen', (
      tester,
    ) async {
      await pumpEditPage(tester);

      expect(chooseButton, findsOneWidget);
      expect(isEnabled(tester, chooseButton), isFalse);
      await enter(tester, 'host', 'nas.local');
      expect(isEnabled(tester, chooseButton), isFalse, reason: 'needs a user name');
      await enter(tester, 'port', '1445');
      await enter(tester, 'username', 'tester');
      await enter(tester, 'password', 'testpass');
      expect(isEnabled(tester, chooseButton), isTrue);

      await tapButton(tester, chooseButton);

      expect(find.text('Shares on nas.local'), findsOneWidget);
      final (source, password) = listed.single;
      expect(source.type, NetworkSourceType.smb);
      expect(source.host, 'nas.local');
      expect(source.port, 1445);
      expect(source.username, 'tester');
      expect(password, 'testpass');

      await tester.tap(find.byKey(const Key('network_share_pick_photos')));
      await tester.pumpAndSettle();

      expect(find.text('Shares on nas.local'), findsNothing);
      expect(textOf(tester, 'share'), 'photos');
    });

    testWidgets('tells when the server lists no share', (tester) async {
      listAnswer = () async => const [];
      await pumpEditPage(tester);
      await enter(tester, 'host', 'nas.local');
      await enter(tester, 'username', 'tester');

      await tapButton(tester, chooseButton);

      expect(
        find.text('This server lists no share for this user. Type the name of the share instead.'),
        findsOneWidget,
      );
    });

    testWidgets('tells why the shares could not be listed', (tester) async {
      listAnswer = () async =>
          throw const NetworkFileSystemException('nas.local refused the user name or password', isAuthentication: true);
      await pumpEditPage(tester);
      await enter(tester, 'host', 'nas.local');
      await enter(tester, 'username', 'tester');

      await tapButton(tester, chooseButton);

      expect(find.text('Could not list the shares: nas.local refused the user name or password'), findsOneWidget);
      expect(textOf(tester, 'share'), '');
    });

    testWidgets('is for SMB only', (tester) async {
      await pumpEditPage(tester);
      await tapButton(tester, find.byKey(const Key('network_share_type_webdav')));

      expect(chooseButton, findsNothing);
    });
  });

  group('NetworkShareEditPage, an existing share', () {
    Future<void> addExisting() async {
      await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [smbSource, webDavSource]));
      secureStorage.values[smbSource.secretKey] = 'stored';
    }

    testWidgets('shows the share and its stored password, and keeps the password on save', (tester) async {
      await addExisting();
      await pumpEditPage(tester, source: smbSource);

      expect(find.text('Edit the share'), findsOneWidget);
      expect(textOf(tester, 'name'), 'NAS');
      expect(textOf(tester, 'host'), 'nas.local');
      expect(textOf(tester, 'share'), 'media');
      expect(textOf(tester, 'root_path'), '', reason: 'the root is the default start folder');
      expect(textOf(tester, 'username'), 'tester');
      expect(textOf(tester, 'password'), 'stored');
      expect(tester.widget<TextField>(field('password')).obscureText, isTrue);

      await enter(tester, 'name', 'Living room NAS');
      await tapButton(tester, saveButton);

      expect(find.text('shares list'), findsOneWidget);
      expect(storedSources().map((s) => s.name), ['Living room NAS', 'Cloud']);
      expect(storedSources().first.id, smbSource.id);
      expect(secureStorage.values, {smbSource.secretKey: 'stored'});
    });

    testWidgets('keeps on save what a later build stored with the share', (tester) async {
      // A field this build does not know, as a later build may add one
      final stored = {...smbSource.toJson(), 'laterSetting': 'kept'};
      await store.put(StoreKey.networkSources, jsonEncode([stored, webDavSource.toJson()]));
      secureStorage.values[smbSource.secretKey] = 'stored';
      final source = NetworkSource.decodeList(store.tryGet(StoreKey.networkSources)).first;
      await pumpEditPage(tester, source: source);

      await enter(tester, 'name', 'Living room NAS');
      await tapButton(tester, saveButton);

      final saved = (jsonDecode(store.tryGet(StoreKey.networkSources)!) as List).first as Map;
      expect(saved['name'], 'Living room NAS');
      expect(saved['laterSetting'], 'kept');
    });

    testWidgets('forgets the password when the field is emptied', (tester) async {
      await addExisting();
      await pumpEditPage(tester, source: smbSource);

      await enter(tester, 'password', '');
      await tapButton(tester, saveButton);

      expect(secureStorage.values, isEmpty);
    });

    testWidgets('removes the share after a confirmation', (tester) async {
      await addExisting();
      await pumpEditPage(tester, source: smbSource);

      await tapButton(tester, removeButton);
      expect(find.text('Remove NAS? Its password is forgotten too. Nothing is deleted on the server.'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(find.text('shares list'), findsOneWidget);
      expect(storedSources().map((s) => s.id), [webDavSource.id]);
      expect(secureStorage.values, isEmpty);
    });

    testWidgets('keeps the share when the removal is cancelled', (tester) async {
      await addExisting();
      await pumpEditPage(tester, source: smbSource);

      await tapButton(tester, removeButton);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Edit the share'), findsOneWidget);
      expect(storedSources(), hasLength(2));
      expect(secureStorage.values, {smbSource.secretKey: 'stored'});
    });
  });

  group('NetworkShareEditPage, DLNA media servers and phone shares', () {
    Finder found(DiscoveredServer server) =>
        find.byKey(Key('network_share_found_${server.type.name}_${server.host}_${server.port}'));
    final dlnaRadio = find.byKey(const Key('network_share_type_dlna'));

    Future<void> pumpWithServers(WidgetTester tester, List<DiscoveredServer> servers) async {
      discovery.keepOpen = true;
      await pumpEditPage(tester, settle: false);
      discovery.scans.single.add(servers);
      await discovery.scans.single.close();
      await tester.pumpAndSettle();
    }

    testWidgets('saves a DLNA media server: a description path and no credentials', (tester) async {
      await pumpEditPage(tester);

      await tapButton(tester, dlnaRadio);

      expect(find.text('DLNA media server (Jellyfin, NAS, TV box)'), findsOneWidget);
      expect(find.text('Description path'), findsOneWidget);
      expect(find.byKey(const Key('network_share_dlna_hint')), findsOneWidget);
      expect(find.textContaining('minidlna on Linux are not found'), findsOneWidget);
      expect(
        find.descendant(of: field('host'), matching: find.text('http://192.168.1.10:8200/rootDesc.xml')),
        findsOneWidget,
        reason: 'the whole address of minidlna, which iOS does not find, as the example of the server field',
      );
      expect(field('username'), findsNothing);
      expect(field('password'), findsNothing);
      expect(find.byKey(const Key('network_share_use_tls')), findsNothing);
      expect(find.byKey(const Key('network_share_choose_share')), findsNothing);
      expect(field('root_path'), findsOneWidget);

      await enter(tester, 'host', '192.168.1.10');
      expect(isEnabled(tester, saveButton), isFalse, reason: 'a DLNA share needs its description path');
      await enter(tester, 'port', '8200');
      await enter(tester, 'share', 'rootDesc.xml');
      await enter(tester, 'name', 'Media box');
      await tapButton(tester, testButton);
      expect(opened.single.source.type, NetworkSourceType.dlna);
      await tapButton(tester, saveButton);

      final saved = storedSources().single;
      expect(saved.type, NetworkSourceType.dlna);
      expect(saved.name, 'Media box');
      expect(saved.host, '192.168.1.10');
      expect(saved.port, 8200);
      expect(saved.share, '/rootDesc.xml');
      expect(saved.username, '');
      expect(saved.useTls, isFalse);
      expect(saved.discoveryId, isNull);
      expect(secureStorage.values, isEmpty);
    });

    testWidgets('spreads a pasted description address over the fields, its query kept', (tester) async {
      await pumpEditPage(tester);
      await tapButton(tester, dlnaRadio);

      await enter(tester, 'host', 'http://nas:8200/rootDesc.xml');
      await tester.tap(field('name'));
      await tester.pumpAndSettle();

      expect(textOf(tester, 'host'), 'nas');
      expect(textOf(tester, 'port'), '8200');
      expect(textOf(tester, 'share'), '/rootDesc.xml');

      await enter(tester, 'host', 'https://192.168.1.13:8920/dlna/abc/description?client=1');
      await tapButton(tester, saveButton);

      final saved = storedSources().single;
      expect(saved.type, NetworkSourceType.dlna);
      expect(saved.host, '192.168.1.13');
      expect(saved.port, 8920);
      expect(saved.share, '/dlna/abc/description?client=1');
      expect(saved.useTls, isTrue);
    });

    testWidgets('takes a pasted address of an XML file for a DLNA description, even on the WebDAV form', (
      tester,
    ) async {
      await pumpEditPage(tester);
      await tapButton(tester, find.byKey(const Key('network_share_type_webdav')));

      await enter(tester, 'host', 'http://192.168.1.10:8200/rootDesc.xml');
      await tester.tap(field('name'));
      await tester.pumpAndSettle();

      expect(find.text('Description path'), findsOneWidget);
      expect(textOf(tester, 'share'), '/rootDesc.xml');
    });

    testWidgets('lists two DLNA servers found at one address and port', (tester) async {
      const second = DiscoveredServer(
        host: '192.168.1.50',
        displayName: 'Second box',
        type: NetworkSourceType.dlna,
        port: 8200,
        path: '/second.xml',
        origin: DiscoveryOrigin.ssdp,
        address: '192.168.1.50',
        discoveryId: 'uuid:4d696e69-444c-164e-9d41-000000000002',
      );
      await pumpWithServers(tester, const [_media, second]);

      expect(tester.takeException(), isNull);
      expect(find.text('Media box'), findsOneWidget);
      expect(find.text('Second box'), findsOneWidget);

      await tester.tap(find.text('Second box'));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'share'), '/second.xml');
    });

    testWidgets('a DLNA server found on the network fills the form and is saved with its id', (tester) async {
      await pumpWithServers(tester, const [_media, _nas]);

      expect(find.descendant(of: found(_media), matching: find.text('DLNA')), findsOneWidget);
      expect(find.descendant(of: found(_media), matching: find.byIcon(Icons.perm_media_outlined)), findsOneWidget);

      await tapButton(tester, found(_media));

      expect(find.text('Description path'), findsOneWidget);
      expect(textOf(tester, 'host'), '192.168.1.50');
      expect(textOf(tester, 'port'), '8200');
      expect(textOf(tester, 'share'), '/rootDesc.xml');
      expect(textOf(tester, 'name'), 'Media box');

      await tapButton(tester, saveButton);

      final saved = storedSources().single;
      expect(saved.type, NetworkSourceType.dlna);
      expect(saved.share, '/rootDesc.xml');
      expect(saved.discoveryId, 'uuid:4d696e69-444c-164e-9d41-000000000001');
    });

    testWidgets('drops the id of the server tapped once the server field is edited', (tester) async {
      await pumpWithServers(tester, const [_media]);
      await tapButton(tester, found(_media));

      await enter(tester, 'host', '192.168.1.51');
      await tapButton(tester, saveButton);

      final saved = storedSources().single;
      expect(saved.host, '192.168.1.51');
      expect(saved.discoveryId, isNull);
    });

    testWidgets('a phone share fills the WebDAV form with its user name and asks for the password', (tester) async {
      await pumpWithServers(tester, const [_phone, _media]);

      expect(find.descendant(of: found(_phone), matching: find.text('Phone')), findsOneWidget);
      expect(find.descendant(of: found(_phone), matching: find.byIcon(Icons.smartphone)), findsOneWidget);

      await tapButton(tester, found(_media));
      await tapButton(tester, found(_phone));

      expect(find.text('Path of the WebDAV address'), findsOneWidget);
      expect(textOf(tester, 'host'), '192.168.1.42');
      expect(textOf(tester, 'port'), '8360');
      expect(textOf(tester, 'share'), '/');
      expect(textOf(tester, 'username'), 'phone1234');
      expect(textOf(tester, 'name'), 'Immuch360 on Pixel');
      expect(tester.widget<TextField>(field('password')).focusNode!.hasFocus, isTrue);

      await enter(tester, 'password', 'k7m3x9p2');
      await tapButton(tester, saveButton);

      final saved = storedSources().single;
      expect(saved.type, NetworkSourceType.webdav);
      expect(saved.username, 'phone1234');
      expect(saved.share, '');
      expect(saved.port, 8360);
      expect(saved.discoveryId, 'a1b2c3d4e5f60718');
      expect(secureStorage.values, {saved.secretKey: 'k7m3x9p2'});
    });

    testWidgets('keeps the id of an existing DLNA share, and forgets a password left from another type', (
      tester,
    ) async {
      const source = NetworkSource(
        id: 'dlna-1',
        type: NetworkSourceType.dlna,
        name: 'Media box',
        host: '192.168.1.50',
        port: 8200,
        share: '/rootDesc.xml',
        discoveryId: 'uuid:media',
      );
      await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [source]));
      secureStorage.values[source.secretKey] = 'old';
      await pumpEditPage(tester, source: source);

      expect(find.text('Description path'), findsOneWidget);
      await enter(tester, 'name', 'Living room box');
      await tapButton(tester, saveButton);

      final saved = storedSources().single;
      expect(saved.name, 'Living room box');
      expect(saved.discoveryId, 'uuid:media');
      expect(secureStorage.values, isEmpty);
    });
  });

  group('NetworkShareEditPage, Plex servers and cameras', () {
    Finder found(DiscoveredServer server) =>
        find.byKey(Key('network_share_found_${server.type.name}_${server.host}_${server.port}'));
    final plexRadio = find.byKey(const Key('network_share_type_plex'));

    Future<void> pumpWithServers(WidgetTester tester, List<DiscoveredServer> servers) async {
      discovery.keepOpen = true;
      await pumpEditPage(tester, settle: false);
      discovery.scans.single.add(servers);
      await discovery.scans.single.close();
      await tester.pumpAndSettle();
    }

    testWidgets('lists the Plex servers and the cameras found, with their tags', (tester) async {
      await pumpWithServers(tester, const [_nas, _plex, _tapo]);

      expect(find.descendant(of: found(_plex), matching: find.text('Plex')), findsOneWidget);
      expect(find.descendant(of: found(_plex), matching: find.text('Test Plex')), findsOneWidget);
      expect(find.descendant(of: found(_plex), matching: find.byIcon(Icons.video_library_outlined)), findsOneWidget);
      expect(find.descendant(of: found(_tapo), matching: find.text('Tapo')), findsOneWidget);
      expect(find.descendant(of: found(_tapo), matching: find.text('192.0.2.30:443')), findsOneWidget);
      expect(find.descendant(of: found(_tapo), matching: find.byIcon(Icons.videocam_outlined)), findsOneWidget);
    });

    testWidgets('a Plex server found on the network opens its own page in place of this one, filled in', (
      tester,
    ) async {
      await pumpWithServers(tester, const [_plex]);

      await tapButton(tester, found(_plex));

      expect(find.text('plex edit Test Plex'), findsOneWidget);
      expect(find.text('Add a share'), findsNothing, reason: 'replaced, not pushed over the form');
      expect(storedSources(), isEmpty);
    });

    testWidgets('a camera found on the network opens its own page in place of this one, filled in', (tester) async {
      await pumpWithServers(tester, const [_tapo]);

      await tapButton(tester, found(_tapo));

      expect(find.text('camera edit 192.0.2.30'), findsOneWidget);
      expect(find.text('Add a share'), findsNothing);
    });

    testWidgets('the Plex radio of a new share opens the Plex page in place of the form', (tester) async {
      await pumpEditPage(tester);

      expect(find.text('Plex Media Server'), findsOneWidget);
      await tapButton(tester, plexRadio);

      expect(find.text('plex edit new'), findsOneWidget);
      expect(find.text('Add a share'), findsNothing);
    });

    testWidgets('an existing share is not offered the Plex radio', (tester) async {
      await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [smbSource]));
      await pumpEditPage(tester, source: smbSource);

      expect(plexRadio, findsNothing);
      expect(find.byKey(const Key('network_share_type_dlna')), findsOneWidget);
    });
  });

  group('NetworkShareEditPage, leaving with unsaved changes', () {
    final discardTitle = find.text('Discard the changes?');
    final keepEditing = find.byKey(const Key('form_discard_changes_keep'));
    final discard = find.byKey(const Key('form_discard_changes_discard'));

    Future<void> close(WidgetTester tester) async {
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
    }

    testWidgets('asks before a filled form is closed, and keeps it when the user keeps editing', (tester) async {
      await pumpEditPage(tester);
      await enter(tester, 'name', 'My NAS');

      await close(tester);
      expect(discardTitle, findsOneWidget);
      expect(find.text('Add a share'), findsOneWidget);

      await tester.tap(keepEditing);
      await tester.pumpAndSettle();
      expect(discardTitle, findsNothing);
      expect(textOf(tester, 'name'), 'My NAS');

      await close(tester);
      await tester.tap(discard);
      await tester.pumpAndSettle();
      expect(find.text('shares list'), findsOneWidget);
      expect(storedSources(), isEmpty);
    });

    testWidgets('asks on the Back of the system too', (tester) async {
      await pumpEditPage(tester);
      await enter(tester, 'host', 'nas.local');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(discardTitle, findsOneWidget);
    });

    testWidgets('leaves at once when nothing was changed, or when the change was undone', (tester) async {
      await pumpEditPage(tester);
      await enter(tester, 'name', 'My NAS');
      await enter(tester, 'name', '');

      await close(tester);

      expect(discardTitle, findsNothing);
      expect(find.text('shares list'), findsOneWidget);
    });

    testWidgets('an existing share left as it was, its stored password read, leaves at once', (tester) async {
      await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [smbSource]));
      secureStorage.values[smbSource.secretKey] = 'stored';
      await pumpEditPage(tester, source: smbSource);
      expect(textOf(tester, 'password'), 'stored');

      await close(tester);

      expect(discardTitle, findsNothing);
      expect(find.text('shares list'), findsOneWidget);
    });

    testWidgets('an existing share whose type changed asks', (tester) async {
      await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [smbSource]));
      await pumpEditPage(tester, source: smbSource);

      await tapButton(tester, find.byKey(const Key('network_share_type_webdav')));
      await close(tester);

      expect(discardTitle, findsOneWidget);
    });

    testWidgets('a saved form leaves without asking', (tester) async {
      await pumpEditPage(tester);
      await enter(tester, 'host', 'nas.local');
      await enter(tester, 'share', 'media');

      await tapButton(tester, saveButton);

      expect(discardTitle, findsNothing);
      expect(find.text('shares list'), findsOneWidget);
      expect(storedSources(), hasLength(1));
    });

    testWidgets('Plex asks before the typed form gives way to the Plex page', (tester) async {
      await pumpEditPage(tester);
      await enter(tester, 'name', 'My NAS');

      await tapButton(tester, find.byKey(const Key('network_share_type_plex')));
      expect(discardTitle, findsOneWidget);
      await tester.tap(keepEditing);
      await tester.pumpAndSettle();
      expect(find.text('Add a share'), findsOneWidget);
      expect(find.text('plex edit new'), findsNothing);

      await tapButton(tester, find.byKey(const Key('network_share_type_plex')));
      await tester.tap(discard);
      await tester.pumpAndSettle();
      expect(find.text('plex edit new'), findsOneWidget);
    });

    testWidgets('a camera found asks too before it replaces a typed form', (tester) async {
      discovery.keepOpen = true;
      await pumpEditPage(tester, settle: false);
      discovery.scans.single.add(const [_tapo]);
      await discovery.scans.single.close();
      await tester.pumpAndSettle();
      await enter(tester, 'name', 'My NAS');

      await tapButton(tester, find.byKey(const Key('network_share_found_tapo_192.0.2.30_443')));

      expect(discardTitle, findsOneWidget);
      expect(find.text('camera edit 192.0.2.30'), findsNothing);
    });
  });

  group('NetworkShareEditPage on a TV', () {
    Finder type(String name) => find.byKey(Key('network_share_type_$name'));

    NetworkSourceType? chosenType(WidgetTester tester) =>
        tester.widget<RadioGroup<NetworkSourceType>>(find.byType(RadioGroup<NetworkSourceType>)).groupValue;

    bool focusedIn(Finder finder) {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused == null) {
        return false;
      }
      final targets = finder.evaluate().toSet();
      var found = targets.contains(focused);
      focused.visitAncestorElements((element) {
        found = found || targets.contains(element);
        return !found;
      });
      return found;
    }

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    testWidgets('the arrows move the focus through the types and on to the name, OK picks a type', (tester) async {
      await pumpEditPage(tester, tvMode: true);
      Focus.of(tester.element(find.descendant(of: type('smb'), matching: find.byType(Text)).first)).requestFocus();
      await tester.pumpAndSettle();
      expect(focusedIn(type('smb')), isTrue);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedIn(type('webdav')), isTrue);
      expect(chosenType(tester), NetworkSourceType.smb, reason: 'moving is not choosing');

      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedIn(type('plex')), isTrue);
      expect(find.text('Add a share'), findsOneWidget, reason: 'passing over Plex does not open its page');
      expect(find.text('plex edit new'), findsNothing);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(
        focusedIn(find.ancestor(of: field('name'), matching: find.byType(TvTextEntry))),
        isTrue,
        reason: 'the focus goes on to the next field',
      );
      expect(chosenType(tester), NetworkSourceType.smb);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedIn(type('plex')), isTrue, reason: 'Up goes back into the group');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedIn(type('dlna')), isTrue, reason: 'and through it');
      await press(tester, LogicalKeyboardKey.select);
      expect(chosenType(tester), NetworkSourceType.dlna, reason: 'OK picks the type that has the focus');
      expect(find.byKey(const Key('network_share_dlna_hint')), findsOneWidget);

      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedIn(type('smb')), isTrue);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(
        focusedIn(find.byKey(const Key('network_share_scan_again'))),
        isTrue,
        reason: 'the focus leaves the group upwards too',
      );
      expect(chosenType(tester), NetworkSourceType.dlna);
    });

    testWidgets('on a 1080p TV the outcome of a first connection test comes into view', (tester) async {
      final tvApi = _MockTvApi();
      registerFallbackValue(TvTextRequest(title: '', text: '', kind: TvTextKind.text, okLabel: '', cancelLabel: ''));
      when(() => tvApi.editText(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.single as TvTextRequest;
        return switch (request.title) {
          'Server name or address' => 'nas.local',
          'Share' => 'media',
          _ => null,
        };
      });
      await pumpEditPage(tester, tvMode: true, tvScreen: true, tvApi: tvApi);
      Finder entry(String key) => find.ancestor(of: field(key), matching: find.byType(TvTextEntry));
      // Down until [target] has the focus, as a remote goes: each press scrolls the next item just into view
      Future<void> downTo(Finder target) async {
        for (var i = 0; i < 30 && !focusedIn(target); i++) {
          await press(tester, LogicalKeyboardKey.arrowDown);
        }
        expect(focusedIn(target), isTrue);
      }

      for (final key in ['host', 'share']) {
        await downTo(entry(key));
        await press(tester, LogicalKeyboardKey.select);
      }
      expect(textOf(tester, 'share'), 'media');
      await downTo(testButton);

      await press(tester, LogicalKeyboardKey.select);

      final outcome = find.text('Connected, 3 entries in the start folder', skipOffstage: false);
      expect(outcome, findsOneWidget);
      final view = tester.getRect(find.byType(ListView));
      expect(tester.getRect(outcome).bottom, lessThanOrEqualTo(view.bottom), reason: 'shown without a press of Down');
      expect(focusedIn(testButton), isTrue, reason: 'the focus stays on the button, in view too');
      expect(tester.getRect(testButton).top, greaterThanOrEqualTo(view.top));
    });

    testWidgets('on a 1080p TV the focus ring of the first type leaves the Type label above it whole', (tester) async {
      await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [smbSource]));
      await pumpEditPage(tester, source: smbSource, tvMode: true, tvScreen: true);
      expect(focusedIn(type('smb')), isTrue, reason: 'the first item of the form of a share');

      final focused = tester.state<TvFocusRingState>(find.byType(TvFocusRing)).ringRect!;
      // How far the ring reaches out of the focused row, its dark outline included
      const reach = TvFocusRing.gap + TvFocusRing.strokeWidth + 1;
      expect(focused.top - reach, greaterThanOrEqualTo(tester.getRect(find.text('Type')).bottom));
    });

    testWidgets('OK on Plex opens the Plex page in place of the form', (tester) async {
      await pumpEditPage(tester, tvMode: true);
      Focus.of(tester.element(find.descendant(of: type('plex'), matching: find.byType(Text)).first)).requestFocus();
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.select);

      expect(find.text('plex edit new'), findsOneWidget);
      expect(find.text('Add a share'), findsNothing);
    });

    testWidgets('Back on a filled form asks, Keep editing has the focus, the arrows reach Discard', (tester) async {
      final tvApi = _MockTvApi();
      registerFallbackValue(TvTextRequest(title: '', text: '', kind: TvTextKind.text, okLabel: '', cancelLabel: ''));
      when(() => tvApi.editText(any())).thenAnswer((_) async => 'My NAS');
      await pumpEditPage(tester, tvMode: true, tvApi: tvApi);
      final nameEntry = find.ancestor(of: field('name'), matching: find.byType(TvTextEntry));
      await tester.tap(nameEntry);
      await tester.pumpAndSettle();
      expect(textOf(tester, 'name'), 'My NAS');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Discard the changes?'), findsOneWidget);
      expect(focusedIn(find.byKey(const Key('form_discard_changes_keep'))), isTrue, reason: 'the safe answer first');

      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('Discard the changes?'), findsNothing);
      expect(textOf(tester, 'name'), 'My NAS');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedIn(find.byKey(const Key('form_discard_changes_discard'))), isTrue);
      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('shares list'), findsOneWidget);
    });
  });

  group('parseNetworkAddress', () {
    test('leaves a plain server name or address alone', () {
      expect(parseNetworkAddress('nas.local'), isNull);
      expect(parseNetworkAddress(' 192.168.1.20 '), isNull);
      expect(parseNetworkAddress('ftp://nas.local/media'), isNull);
    });

    test('reads an SMB address, a Windows path included', () {
      for (final input in ['smb://nas.local/media/photos/2026', r'\\nas.local\media\photos\2026']) {
        final address = parseNetworkAddress(input)!;
        expect(address.type, NetworkSourceType.smb, reason: input);
        expect(address.host, 'nas.local', reason: input);
        expect(address.port, isNull, reason: input);
        expect(address.share, 'media', reason: input);
        expect(address.rootPath, '/photos/2026', reason: input);
      }

      final short = parseNetworkAddress('smb://nas:1445/media')!;
      expect(short.port, 1445);
      expect(short.rootPath, isNull);
    });

    test('reads a WebDAV address', () {
      final secure = parseNetworkAddress('https://cloud.example.com/remote.php/dav/files/alice/')!;
      expect(secure.type, NetworkSourceType.webdav);
      expect(secure.host, 'cloud.example.com');
      expect(secure.share, '/remote.php/dav/files/alice');
      expect(secure.useTls, isTrue);

      final plain = parseNetworkAddress('http://localhost:1880/')!;
      expect(plain.host, 'localhost');
      expect(plain.port, 1880);
      expect(plain.share, '');
      expect(plain.useTls, isFalse);
    });
  });

  group('parseNetworkAddress, DLNA', () {
    test('reads a device description address', () {
      final xml = parseNetworkAddress('http://nas:8200/rootDesc.xml')!;
      expect(xml.type, NetworkSourceType.dlna, reason: 'an XML file');
      expect(xml.host, 'nas');
      expect(xml.port, 8200);
      expect(xml.share, '/rootDesc.xml');
      expect(xml.useTls, isFalse);

      final current = parseNetworkAddress(
        'https://192.168.1.13:8920/dlna/abc/description?client=1',
        current: NetworkSourceType.dlna,
      )!;
      expect(current.type, NetworkSourceType.dlna, reason: 'the form is for a DLNA server');
      expect(current.share, '/dlna/abc/description?client=1');
      expect(current.useTls, isTrue);

      for (final scheme in ['upnp', 'dlna']) {
        final upnp = parseNetworkAddress('$scheme://192.168.1.10:8200/rootDesc.xml', current: NetworkSourceType.smb)!;
        expect(upnp.type, NetworkSourceType.dlna, reason: scheme);
        expect(upnp.useTls, isFalse, reason: scheme);
      }

      expect(
        parseNetworkAddress('http://nas:5005/photos', current: NetworkSourceType.webdav)!.type,
        NetworkSourceType.webdav,
      );
      expect(parseNetworkAddress('http://nas:5005/photos')!.type, NetworkSourceType.webdav);
    });

    test('normalizeDescriptionPath starts with a slash and keeps the rest', () {
      expect(normalizeDescriptionPath(''), '');
      expect(normalizeDescriptionPath(' rootDesc.xml '), '/rootDesc.xml');
      expect(normalizeDescriptionPath('/dlna/a/description.xml?x=1'), '/dlna/a/description.xml?x=1');
    });
  });

  group('normalizeNetworkPath', () {
    test('starts with a slash, ends without one, and gives the root for nothing', () {
      expect(normalizeNetworkPath(''), '/');
      expect(normalizeNetworkPath(' / '), '/');
      expect(normalizeNetworkPath('photos'), '/photos');
      expect(normalizeNetworkPath('//photos//2026/'), '/photos/2026');
      expect(normalizeNetworkPath(r'\photos\2026'), '/photos/2026');
      expect(normalizeNetworkPath('/', empty: ''), '');
    });
  });
}
