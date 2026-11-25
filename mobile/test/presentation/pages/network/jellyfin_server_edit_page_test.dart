// The page that adds a Jellyfin or Emby server: the servers found, the address and Connect, the sign in by password
// (with the user tiles Emby shows) and by Quick Connect (the code, the poll, the expiry, turned off, none on Emby),
// the order on a TV, the failures and their diagnostics line, the http note, then the edit: rename, Remove.

import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/jellyfin_server_info.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_client.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/jellyfin_server_edit.page.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/jellyfin_connector.provider.dart';
import 'package:immich_mobile/providers/network/network_discovery.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';

import '../../../providers/network/fakes.dart';
import 'network_test_app.dart';

const _serverId = '0d6eac044f7a4e448bba5921022e44a7';
const _token = 'JF-TOKEN-0000';

const _found = DiscoveredServer(
  host: '192.168.1.50',
  displayName: 'Home',
  type: NetworkSourceType.jellyfin,
  port: 8096,
  origin: DiscoveryOrigin.jellyfin,
  discoveryId: _serverId,
  version: '12.4.0',
  product: 'jellyfin',
);

const _nas = DiscoveredServer(
  host: '192.168.1.30',
  displayName: 'Some NAS',
  type: NetworkSourceType.smb,
  port: 445,
  origin: DiscoveryOrigin.scan,
);

class _FakeDiscovery implements NetworkDiscoveryService {
  List<DiscoveredServer> servers = const [];

  @override
  Stream<List<DiscoveredServer>> discover({
    Duration timeout = NetworkDiscoveryService.defaultTimeout,
    List<String>? hosts,
  }) => Stream.value(servers);
}

/// The server as the page sees it: what it answers, and what it was asked
class _FakeConnector implements JellyfinConnector {
  JellyfinProduct product = JellyfinProduct.jellyfin;
  JellyfinFailure? infoFailure;
  bool quickConnectOn = true;
  List<JellyfinPublicUser> users = const [];
  final List<String> asked = [];
  final List<String> signedOut = [];
  int codes = 0;
  bool approved = false;
  bool expired = false;

  JellyfinPublicInfo get info => JellyfinPublicInfo(
    id: _serverId,
    product: product,
    serverName: 'Home',
    version: product == JellyfinProduct.emby ? '4.10.2.0' : '12.4.0',
  );

  @override
  Future<String> deviceIdOf(String sourceId) async => 'install-$sourceId';

  @override
  Future<JellyfinPublicInfo> publicInfo(Uri base, String sourceId) async {
    asked.add('info $base');
    final failure = infoFailure;
    if (failure != null) {
      throw JellyfinException.of(failure, status: failure == JellyfinFailure.notJellyfin ? 404 : null);
    }
    return info;
  }

  @override
  Future<List<JellyfinPublicUser>> publicUsers(JellyfinTarget target, String sourceId) async => users;

  @override
  Future<JellyfinSignIn> signIn(JellyfinTarget target, String sourceId, String user, String password) async {
    asked.add('password $user');
    if (password != 'right') {
      throw JellyfinException.of(JellyfinFailure.passwordRefused, status: 401);
    }
    return JellyfinSignIn(accessToken: _token, userId: 'user-1', userName: user, serverId: _serverId);
  }

  @override
  Future<bool> quickConnectEnabled(JellyfinTarget target, String sourceId) async =>
      product == JellyfinProduct.jellyfin && quickConnectOn;

  @override
  Future<JellyfinQuickConnect> quickConnectStart(JellyfinTarget target, String sourceId) async {
    codes++;
    expired = false;
    return JellyfinQuickConnect(secret: 'secret-$codes', code: '12345$codes');
  }

  @override
  Future<bool> quickConnectApproved(JellyfinTarget target, String sourceId, String secret) async {
    asked.add('poll $secret');
    if (expired) {
      throw JellyfinException.of(JellyfinFailure.quickConnectExpired, status: 404);
    }
    return approved;
  }

  @override
  Future<JellyfinSignIn> quickConnectSignIn(JellyfinTarget target, String sourceId, String secret) async =>
      const JellyfinSignIn(accessToken: _token, userId: 'user-2', userName: 'kid', serverId: _serverId);

  @override
  Future<void> signOut(JellyfinTarget target, String sourceId, String token) async => signedOut.add(token);

  @override
  Uri quickConnectPage(JellyfinTarget target) => target.base.replace(path: '/web/', fragment: '/quickconnect');
}

void main() {
  late Drift db;
  late StoreService store;
  late FakeSecureStorage secureStorage;
  late _FakeDiscovery discovery;
  late _FakeConnector connector;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    secureStorage = FakeSecureStorage();
    discovery = _FakeDiscovery();
    connector = _FakeConnector();
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  List<NetworkSource> storedSources() => NetworkSource.decodeList(store.tryGet(StoreKey.networkSourcesExtra));

  Future<void> pumpPage(
    WidgetTester tester, {
    NetworkSource? source,
    DiscoveredServer? server,
    bool focusCredentials = false,
    bool tv = false,
  }) async {
    tester.view.physicalSize = const Size(2400, 6000);
    addTearDown(tester.view.resetPhysicalSize);
    final router = await pumpNetworkTestApp(
      tester,
      home: const Scaffold(body: Text('shares list')),
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        secureStorageServiceProvider.overrideWithValue(secureStorage),
        mediaBridgeProvider.overrideWithValue(FakeMediaBridge()),
        networkDiscoveryServiceProvider.overrideWithValue(discovery),
        jellyfinConnectorProvider.overrideWithValue(connector),
        if (tv) tvModeProvider.overrideWith((ref) => true),
      ],
      pages: {
        JellyfinServerEditRoute.name: (data) {
          final args = data.argsAs<JellyfinServerEditRouteArgs>(orElse: () => const JellyfinServerEditRouteArgs());
          return JellyfinServerEditPage(
            source: args.source,
            server: args.server,
            focusCredentials: args.focusCredentials,
          );
        },
      },
    );
    unawaited(router.push(JellyfinServerEditRoute(source: source, server: server, focusCredentials: focusCredentials)));
    // Quick Connect shows an endless progress bar: frames, not a settle
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Finder key(String name) => find.byKey(Key(name));

  Future<void> enter(WidgetTester tester, String name, String text) async {
    await tester.ensureVisible(key(name));
    await tester.enterText(key(name), text);
    await settle(tester);
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await settle(tester);
    await tester.tap(target);
    await settle(tester);
  }

  testWidgets('a server found: filled in and connected; the password way saves its server, user and token', (
    tester,
  ) async {
    discovery.servers = const [_found, _nas];
    await pumpPage(tester);
    expect(key('jellyfin_experimental'), findsNothing);
    expect(find.textContaining(RegExp('xperimental')), findsNothing);
    expect(find.text('Some NAS'), findsNothing, reason: 'the found list shows Jellyfin and Emby servers only');
    await tap(tester, find.text('Home').first);
    expect(connector.asked.first, 'info http://192.168.1.50:8096');
    expect(find.text('Jellyfin 12.4.0, named Home'), findsOneWidget);
    expect(key('jellyfin_quick_connect_code'), findsOneWidget);
    expect(tester.widget<ElevatedButton>(key('jellyfin_save')).onPressed, isNull);
    await enter(tester, 'jellyfin_user', 'alice');
    await enter(tester, 'jellyfin_password', 'wrong');
    await tap(tester, key('jellyfin_sign_in'));
    expect(find.text('The user or the password is wrong.'), findsOneWidget);
    expect(key('jellyfin_diagnostics'), findsNothing, reason: 'a wrong password needs no report');
    await enter(tester, 'jellyfin_password', 'right');
    await tap(tester, key('jellyfin_sign_in'));
    expect(find.text('Signed in as alice'), findsOneWidget);
    expect(key('jellyfin_password'), findsNothing);
    await tap(tester, key('jellyfin_save'));
    final saved = storedSources().single;
    expect(saved.type, NetworkSourceType.jellyfin);
    expect((saved.host, saved.port, saved.share, saved.useTls), ('192.168.1.50', null, '', false));
    expect(saved.discoveryId, _serverId);
    expect(saved.jellyfin, const JellyfinServerInfo(serverId: _serverId, userId: 'user-1', version: '12.4.0'));
    expect(saved.username, 'alice');
    expect(saved.name, 'Home');
    expect(secureStorage.values[saved.secretKey], _token);
    expect(secureStorage.writtenDeviceOnly, contains(saved.secretKey));
    expect(secureStorage.values.values, isNot(contains('right')), reason: 'the password is kept nowhere');
    expect(find.text('shares list'), findsOneWidget);
  });

  testWidgets('Quick Connect: the code and its QR code, polled every 5 s, then signed in', (tester) async {
    await pumpPage(tester);
    await enter(tester, 'jellyfin_address', '192.168.1.50');
    await tap(tester, key('jellyfin_connect'));
    expect(find.text('123451'), findsOneWidget);
    expect(key('jellyfin_quick_connect_qr'), findsOneWidget);
    expect(find.text('Waiting for the code to be approved'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await settle(tester);
    expect(connector.asked.where((a) => a.startsWith('poll')), hasLength(1));
    connector.approved = true;
    await tester.pump(const Duration(seconds: 5));
    await settle(tester);
    expect(find.text('Signed in as kid'), findsOneWidget);
    await tap(tester, key('jellyfin_save'));
    expect(storedSources().single.jellyfin!.userId, 'user-2');
  });

  testWidgets('Quick Connect: an expired code offers a new one; turned off says so', (tester) async {
    await pumpPage(tester);
    await enter(tester, 'jellyfin_address', '192.168.1.50:8096');
    await tap(tester, key('jellyfin_connect'));
    connector.expired = true;
    await tester.pump(const Duration(seconds: 5));
    await settle(tester);
    expect(find.text('This code expired.'), findsOneWidget);
    await tap(tester, key('jellyfin_quick_connect_new'));
    expect(find.text('123452'), findsOneWidget);

    connector.quickConnectOn = false;
    await tap(tester, key('jellyfin_connect'));
    expect(key('jellyfin_quick_connect_off'), findsOneWidget);
    expect(key('jellyfin_quick_connect_code'), findsNothing);
  });

  testWidgets('Emby: its users as tiles, no Quick Connect', (tester) async {
    connector
      ..product = JellyfinProduct.emby
      ..users = const [JellyfinPublicUser(id: 'u1', name: 'admin'), JellyfinPublicUser(id: 'u2', name: 'viewer')];
    await pumpPage(tester);
    await enter(tester, 'jellyfin_address', 'http://192.168.1.51:8096');
    await tap(tester, key('jellyfin_connect'));
    expect(find.text('Emby 4.10.2.0, named Home'), findsOneWidget);
    expect(key('jellyfin_emby_password_only'), findsOneWidget);
    await tap(tester, key('jellyfin_user_u2'));
    expect(tester.widget<TextField>(key('jellyfin_user')).controller!.text, 'viewer');
    await enter(tester, 'jellyfin_password', 'right');
    await tap(tester, key('jellyfin_sign_in'));
    await tap(tester, key('jellyfin_save'));
    expect(storedSources().single.jellyfin!.product, 'emby');
  });

  testWidgets('on a TV the code comes before the password', (tester) async {
    await pumpPage(tester, server: _found, tv: true);
    final code = tester.getTopLeft(key('jellyfin_quick_connect_panel')).dy;
    final password = tester.getTopLeft(key('jellyfin_password_panel')).dy;
    expect(code, lessThan(password));
  });

  testWidgets('on a phone the password comes first', (tester) async {
    await pumpPage(tester, server: _found);
    final code = tester.getTopLeft(key('jellyfin_quick_connect_panel')).dy;
    final password = tester.getTopLeft(key('jellyfin_password_panel')).dy;
    expect(password, lessThan(code));
  });

  testWidgets('a failure to connect is told, with its diagnostics line', (tester) async {
    connector.infoFailure = JellyfinFailure.notJellyfin;
    await pumpPage(tester);
    await enter(tester, 'jellyfin_address', '192.168.1.60');
    await tap(tester, key('jellyfin_connect'));
    expect(find.text('The server at this address is not a Jellyfin or Emby server.'), findsOneWidget);
    final line = tester.widget<SelectableText>(key('jellyfin_diagnostics')).data!;
    expect(line, 'Diagnostics: jellyfin ?, step connect, status 404, route items-v1, ranges ?, tls no');
    expect(line, isNot(contains('192.168')));
    connector.infoFailure = JellyfinFailure.setupNotDone;
    await tap(tester, key('jellyfin_connect'));
    expect(find.text('This server is not set up yet. Finish its setup in its web page first.'), findsOneWidget);
  });

  testWidgets('an http address outside home shows a note; one at home does not; a bad address is told', (tester) async {
    await pumpPage(tester);
    await enter(tester, 'jellyfin_address', 'http://203.0.113.9:8096');
    expect(key('jellyfin_http_outside'), findsOneWidget);
    await enter(tester, 'jellyfin_address', 'https://media.example.org/jellyfin');
    expect(key('jellyfin_http_outside'), findsNothing);
    await enter(tester, 'jellyfin_address', 'http://192.168.1.50:8096');
    expect(key('jellyfin_http_outside'), findsNothing);
    await enter(tester, 'jellyfin_address', 'ftp://x');
    expect(find.textContaining('This is not a server address.'), findsOneWidget);
  });

  group('an existing server', () {
    const source = NetworkSource(
      id: 'jf00112233445566',
      type: NetworkSourceType.jellyfin,
      name: 'Home',
      host: '192.168.1.50',
      username: 'alice',
      discoveryId: _serverId,
      jellyfin: JellyfinServerInfo(serverId: _serverId, userId: 'user-1', version: '12.4.0'),
    );

    Future<void> withSource() async {
      await store.put(StoreKey.networkSourcesExtra, NetworkSource.encodeList([source]));
      secureStorage.values[source.secretKey] = _token;
    }

    testWidgets('renamed: the session is kept', (tester) async {
      await withSource();
      await pumpPage(tester, source: source);
      expect(find.text('Jellyfin server'), findsOneWidget);
      expect(key('jellyfin_password_panel'), findsNothing);
      await enter(tester, 'jellyfin_name', 'Living room');
      await tap(tester, key('jellyfin_save'));
      expect(storedSources().single.name, 'Living room');
      expect(secureStorage.values[source.secretKey], _token);
    });

    testWidgets('Sign in again from a refused session: the sign in shows at once', (tester) async {
      await withSource();
      await pumpPage(tester, source: source, focusCredentials: true);
      expect(key('jellyfin_password_panel'), findsOneWidget);
      expect(key('jellyfin_sign_in_again'), findsNothing);
      await enter(tester, 'jellyfin_user', 'alice');
      await enter(tester, 'jellyfin_password', 'right');
      await tap(tester, key('jellyfin_sign_in'));
      await tap(tester, key('jellyfin_save'));
      expect(storedSources().single.id, source.id);
      expect(secureStorage.values[source.secretKey], _token);
    });

    testWidgets('removed: the server is told of the sign out, the token forgotten', (tester) async {
      await withSource();
      await pumpPage(tester, source: source);
      await tap(tester, key('jellyfin_remove'));
      await tap(tester, find.text('Remove').last);
      expect(connector.signedOut, [_token]);
      expect(storedSources(), isEmpty);
      expect(secureStorage.values.containsKey(source.secretKey), isFalse);
    });
  });
}
