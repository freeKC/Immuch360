import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_share_edit.page.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_discovery.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';

import '../../../providers/network/fakes.dart';
import 'network_test_app.dart';

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
        '/': [fakeEntry(source.id, '/a.jpg'), fakeEntry(source.id, '/b.mp4'), fakeEntry(source.id, '/sub')],
      },
    );
    opened.add(fileSystem);
    return fileSystem;
  }

  List<NetworkSource> storedSources() => NetworkSource.decodeList(store.tryGet(StoreKey.networkSources));

  /// Opens the form over a stub page, so that leaving it can be seen
  Future<void> pumpEditPage(WidgetTester tester, {NetworkSource? source, bool settle = true}) async {
    // Tall enough for the whole form
    tester.view.physicalSize = const Size(2400, 4800);
    addTearDown(tester.view.resetPhysicalSize);

    final router = await pumpNetworkTestApp(
      tester,
      home: const Scaffold(body: Text('shares list')),
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        secureStorageServiceProvider.overrideWithValue(secureStorage),
        mediaBridgeProvider.overrideWithValue(bridge),
        networkFileSystemOpenersProvider.overrideWithValue({
          NetworkSourceType.smb: fakeOpen,
          NetworkSourceType.webdav: fakeOpen,
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
      expect(find.text('Looking for SMB and WebDAV servers on your network'), findsOneWidget);
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
