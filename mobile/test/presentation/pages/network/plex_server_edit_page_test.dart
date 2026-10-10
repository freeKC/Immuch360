import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_pairing.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/plex_server_edit.page.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_discovery.provider.dart';
import 'package:immich_mobile/providers/network/plex_learned_addresses.provider.dart';
import 'package:immich_mobile/providers/network/plex_pairing.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';

import '../../../providers/network/fakes.dart';
import 'network_test_app.dart';

const _hash = '0123456789abcdef0123456789abcdef';
const _machine = '0000000000000000000000000000000000000001';
const _token = 'TEST-TOKEN-0000000000';
const _version = '1.42.1.10060-4e8b05daf';

const _plex = DiscoveredServer(
  host: '192.168.1.20',
  displayName: 'Test Plex',
  type: NetworkSourceType.plex,
  port: 32400,
  useTls: true,
  origin: DiscoveryOrigin.gdm,
  discoveryId: _machine,
  plexHash: _hash,
  version: _version,
);

const _nas = DiscoveredServer(
  host: '192.168.1.30',
  displayName: 'Some NAS',
  type: NetworkSourceType.smb,
  port: 445,
  origin: DiscoveryOrigin.scan,
);

/// The discovery of the page, which answers [servers] once
class _FakeDiscovery implements NetworkDiscoveryService {
  List<DiscoveredServer> servers = const [];
  int scans = 0;

  @override
  Stream<List<DiscoveredServer>> discover({
    Duration timeout = NetworkDiscoveryService.defaultTimeout,
    List<String>? hosts,
  }) {
    scans++;
    return Stream.value(servers);
  }
}

/// The pairing of the page: what it was asked, and what it answers
class _FakePairing implements PlexPairing {
  final List<(PlexAddress, String?)> lookedUp = [];
  final List<(PlexServerFound, String)> tested = [];
  PlexFileSystemException? lookUpError;

  /// Errors for some hosts only, as an address at home that does not answer away from home
  final Map<String, PlexFileSystemException> lookUpErrors = {};
  PlexFileSystemException? testError;
  PlexTokenCheck check = PlexTokenCheck(
    sections: const [
      PlexSection(key: '1', title: 'Movies', type: 'movie'),
      PlexSection(key: '2', title: 'Photos', type: 'photo'),
      PlexSection(key: '3', title: 'Series', type: 'show'),
    ],
    serverName: 'Living room Plex',
    version: _version,
    learned: PlexLearnedAddress(host: '203.0.113.7', port: 32401, mapping: 'mapped', at: DateTime.utc(2026, 10, 7)),
  );

  @override
  Future<PlexServerFound> lookUp(PlexAddress typed, {String? knownHash}) async {
    lookedUp.add((typed, knownHash));
    final error = lookUpErrors[typed.host] ?? lookUpError;
    if (error != null) {
      throw error;
    }
    return PlexServerFound(
      address: InternetAddress(typed.isName ? '203.0.113.7' : typed.host),
      port: typed.port ?? 32400,
      hash: typed.hash ?? knownHash ?? _hash,
      machineIdentifier: _machine,
      version: _version,
      typedName: typed.isName ? typed.host : null,
    );
  }

  @override
  Future<PlexTokenCheck> testToken(PlexServerFound server, String token) async {
    tested.add((server, token));
    final error = testError;
    if (error != null) {
      throw error;
    }
    return check;
  }
}

String _jwt(DateTime expires) {
  String part(Object json) => base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'EdDSA'})}.${part({'exp': expires.millisecondsSinceEpoch ~/ 1000})}.c2ln';
}

void main() {
  late Drift db;
  late StoreService store;
  late FakeSecureStorage secureStorage;
  late _FakeDiscovery discovery;
  late _FakePairing pairing;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    secureStorage = FakeSecureStorage();
    discovery = _FakeDiscovery();
    pairing = _FakePairing();
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
    bool focusToken = false,
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
        plexPairingProvider.overrideWithValue(pairing),
        if (tv) tvModeProvider.overrideWith((ref) => true),
      ],
      pages: {
        PlexServerEditRoute.name: (data) {
          final args = data.argsAs<PlexServerEditRouteArgs>(orElse: () => const PlexServerEditRouteArgs());
          return PlexServerEditPage(source: args.source, server: args.server, focusToken: args.focusToken);
        },
      },
    );
    unawaited(router.push(PlexServerEditRoute(source: source, server: server, focusToken: focusToken)));
    await tester.pumpAndSettle();
  }

  Finder field(String key) => find.byKey(Key(key));
  String textOf(WidgetTester tester, String key) => tester.widget<TextField>(field(key)).controller!.text;

  Future<void> enter(WidgetTester tester, String key, String text) async {
    await tester.ensureVisible(field(key));
    await tester.enterText(field(key), text);
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  bool isEnabled(WidgetTester tester, String key) => tester.widget<ButtonStyleButton>(field(key)).onPressed != null;

  group('a new Plex server', () {
    testWidgets('lists the Plex servers found, and fills the page with the one tapped', (tester) async {
      discovery.servers = const [_plex, _nas];
      await pumpPage(tester);

      expect(find.text('Add a Plex server'), findsOneWidget);
      expect(find.byKey(const Key('network_share_found_plex_192.168.1.20_32400')), findsOneWidget);
      expect(find.byKey(const Key('network_share_found_smb_192.168.1.30_445')), findsNothing);
      expect(find.byKey(const Key('plex_remove')), findsNothing);
      expect(isEnabled(tester, 'plex_save'), isFalse);

      await tap(tester, find.byKey(const Key('network_share_found_plex_192.168.1.20_32400')));
      expect(textOf(tester, 'plex_server_address'), '192.168.1.20:32400');
      expect(textOf(tester, 'plex_name'), 'Test Plex');
      expect(find.text('Test Plex, Plex $_version, id 00000000'), findsOneWidget);
      expect(pairing.lookedUp, isEmpty, reason: 'what GDM told needs no request; the test checks it');
    });

    testWidgets('tests the token, shows the address outside home, and saves', (tester) async {
      discovery.servers = const [_plex];
      await pumpPage(tester);
      await tap(tester, find.byKey(const Key('network_share_found_plex_192.168.1.20_32400')));
      expect(isEnabled(tester, 'plex_test'), isFalse, reason: 'no token yet');
      await enter(tester, 'plex_token', _token);
      expect(find.byKey(const Key('plex_token_format')), findsNothing, reason: 'a token of the usual form');
      expect(isEnabled(tester, 'plex_save'), isFalse, reason: 'saved after a successful test only');

      await tap(tester, field('plex_test'));
      expect(pairing.tested.single.$2, _token);
      expect(pairing.tested.single.$1.hash, _hash);
      expect(find.text('Connected: 3 libraries'), findsOneWidget);
      expect(find.text('The server says it is reachable at 203.0.113.7:32401.'), findsOneWidget);
      expect(textOf(tester, 'plex_name'), 'Living room Plex', reason: 'the name the server gives replaces the GDM one');
      expect(isEnabled(tester, 'plex_save'), isTrue);

      await tap(tester, field('plex_root_path'));
      await tap(tester, find.text('/Photos').last);
      await enter(tester, 'plex_remote_address', 'plex.example.com');
      await enter(tester, 'plex_remote_port', '32401');
      await tap(tester, field('plex_save'));

      expect(find.text('shares list'), findsOneWidget);
      final saved = storedSources().single;
      expect(saved.type, NetworkSourceType.plex);
      expect(saved.name, 'Living room Plex');
      expect((saved.host, saved.port, saved.share, saved.username), ('192.168.1.20', null, '', ''));
      expect(saved.rootPath, '/Photos');
      expect(saved.useTls, isTrue);
      expect(saved.discoveryId, _machine);
      expect(
        saved.plex,
        const PlexServerInfo(hash: _hash, publicHost: 'plex.example.com', publicPort: 32401, version: _version),
      );
      expect(secureStorage.values, {saved.secretKey: _token});
      expect(secureStorage.writtenDeviceOnly, {saved.secretKey});
      expect(store.tryGet(StoreKey.networkSourcesExtra), isNot(contains(_token)));
      expect(PlexLearnedAddressStore(store).read(saved.id)?.host, '203.0.113.7');
    });

    testWidgets('a whole "View XML" address pasted in the token field fills both fields', (tester) async {
      await pumpPage(tester);
      await enter(
        tester,
        'plex_token',
        'https://192-168-1-21.$_hash.plex.direct:32401/library/metadata/1?checkFiles=1&X-Plex-Token=$_token',
      );
      expect(textOf(tester, 'plex_token'), _token);
      expect(textOf(tester, 'plex_server_address'), '192-168-1-21.$_hash.plex.direct:32401');
      final (typed, _) = pairing.lookedUp.single;
      expect((typed.host, typed.port, typed.hash), ('192.168.1.21', 32401, _hash));
      expect(find.byKey(const Key('plex_server_card')), findsOneWidget);
    });

    testWidgets('the paste button takes the token and the server from the clipboard', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          return {'text': 'https://192-168-1-22.$_hash.plex.direct:32400/x?X-Plex-Token=$_token\n'};
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pumpPage(tester);
      await tap(tester, field('plex_token_paste'));
      expect(textOf(tester, 'plex_token'), _token);
      expect(textOf(tester, 'plex_server_address'), '192-168-1-22.$_hash.plex.direct:32400');
    });

    testWidgets('a View XML address typed in the address field moves its token', (tester) async {
      await pumpPage(tester);
      await enter(
        tester,
        'plex_server_address',
        'https://192-168-1-21.$_hash.plex.direct:32400/x?X-Plex-Token=$_token',
      );
      expect(textOf(tester, 'plex_server_address'), '192.168.1.21:32400');
      expect(textOf(tester, 'plex_token'), _token);
    });

    testWidgets('looks a typed address up and tells what went wrong', (tester) async {
      await pumpPage(tester);
      await enter(tester, 'plex_server_address', '[2001:db8::1]:32400');
      await tap(tester, field('plex_server_look_up'));
      expect(find.text('IPv6 addresses are not supported yet. Type the IPv4 address of the server.'), findsOneWidget);
      expect(pairing.lookedUp, isEmpty);

      await enter(tester, 'plex_server_address', '192.168.1.20:abc');
      await tap(tester, field('plex_server_look_up'));
      expect(find.text('This is not an address the app can read.'), findsOneWidget, reason: 'nothing was asked');
      expect(find.text('The Plex server does not answer at this address.'), findsNothing);
      expect(pairing.lookedUp, isEmpty);

      pairing.lookUpError = const PlexFileSystemException('x', PlexFailure.notPlex);
      await enter(tester, 'plex_server_address', '192.168.1.40');
      await tap(tester, field('plex_server_look_up'));
      expect(find.textContaining('This address answers without a Plex certificate.'), findsOneWidget);

      pairing.lookUpError = const PlexFileSystemException('x', PlexFailure.unreachable);
      await tap(tester, field('plex_server_look_up'));
      expect(find.text('The Plex server does not answer at this address.'), findsOneWidget);

      pairing.lookUpError = null;
      await tap(tester, field('plex_server_look_up'));
      expect(find.byKey(const Key('plex_server_card')), findsOneWidget);
      expect(pairing.lookedUp.last.$1.host, '192.168.1.40');
    });

    testWidgets('tells a token refused, one that cannot read, and one expired', (tester) async {
      discovery.servers = const [_plex];
      await pumpPage(tester);
      await tap(tester, find.byKey(const Key('network_share_found_plex_192.168.1.20_32400')));
      await enter(tester, 'plex_token', _token);

      pairing.testError = const PlexFileSystemException('x', PlexFailure.tokenRefused, isAuthentication: true);
      await tap(tester, field('plex_test'));
      expect(find.text('The Plex server refused this token.'), findsOneWidget);
      expect(isEnabled(tester, 'plex_save'), isFalse);
      expect(find.byKey(const Key('plex_remote_title')), findsNothing);

      pairing.testError = const PlexFileSystemException('x', PlexFailure.tokenForbidden, isAuthentication: true);
      await tap(tester, field('plex_test'));
      expect(find.text('This token cannot read the libraries of the server.'), findsOneWidget);

      final tests = pairing.tested.length;
      await enter(tester, 'plex_token', _jwt(DateTime.now().subtract(const Duration(days: 1))));
      expect(find.byKey(const Key('plex_token_format')), findsOneWidget);
      await tap(tester, field('plex_test'));
      expect(find.text('This token has expired. Paste a new one.'), findsWidgets);
      expect(pairing.tested.length, tests, reason: 'an expired token is not sent');

      await enter(tester, 'plex_token', _jwt(DateTime.now().add(const Duration(days: 7))));
      expect(find.textContaining('and the app cannot renew it'), findsOneWidget);

      await enter(tester, 'plex_token', 'not a token!');
      expect(find.text('This does not look like a Plex token.'), findsOneWidget);
    });
  });

  testWidgets('a start folder no longer listed after a new test goes back to the root', (tester) async {
    discovery.servers = const [_plex];
    await pumpPage(tester);
    await tap(tester, find.byKey(const Key('network_share_found_plex_192.168.1.20_32400')));
    await enter(tester, 'plex_token', _token);
    await tap(tester, field('plex_test'));
    await tap(tester, field('plex_root_path'));
    await tap(tester, find.text('/Series').last);

    pairing.check = const PlexTokenCheck(
      sections: [PlexSection(key: '1', title: 'Movies', type: 'movie')],
    );
    await enter(tester, 'plex_token', 'TEST-TOKEN-0000000001');
    await tap(tester, field('plex_test'));
    expect(find.text('Connected: 1 library'), findsOneWidget);
    await tap(tester, field('plex_save'));
    expect(storedSources().single.rootPath, '/');
  });

  testWidgets('a server announced without its hash is looked up once the page shows', (tester) async {
    const withoutHash = DiscoveredServer(
      host: '192.168.1.20',
      displayName: 'Test Plex',
      type: NetworkSourceType.plex,
      port: 32400,
      useTls: true,
      origin: DiscoveryOrigin.gdm,
      discoveryId: _machine,
    );
    await pumpPage(tester, server: withoutHash);
    expect(pairing.lookedUp.single.$1.host, '192.168.1.20');
    expect(find.byKey(const Key('plex_server_card')), findsOneWidget);
  });

  group('a Plex server already added', () {
    const source = NetworkSource(
      id: '0123456789abcdef',
      type: NetworkSourceType.plex,
      name: 'Test Plex',
      host: '192.168.1.20',
      rootPath: '/Movies',
      useTls: true,
      discoveryId: _machine,
      plex: PlexServerInfo(hash: _hash, publicHost: 'plex.example.com', publicPort: 32401, version: _version),
    );

    Future<void> addSource() async {
      await store.put(StoreKey.networkSourcesExtra, NetworkSource.encodeStored([source], const []));
      secureStorage.values[source.secretKey] = _token;
      await PlexLearnedAddressStore(
        store,
      ).write(source.id, PlexLearnedAddress(host: '203.0.113.7', port: 32401, at: DateTime.utc(2026, 10, 7)));
    }

    testWidgets('shows what is stored and saves a new name without a new test, keeping the token', (tester) async {
      await addSource();
      await pumpPage(tester, source: source);

      expect(find.text('Edit the Plex server'), findsOneWidget);
      expect(textOf(tester, 'plex_server_address'), '192.168.1.20:32400');
      expect(textOf(tester, 'plex_token'), _token);
      expect(tester.widget<TextField>(field('plex_token')).obscureText, isTrue);
      expect(textOf(tester, 'plex_remote_address'), 'plex.example.com');
      expect(textOf(tester, 'plex_remote_port'), '32401');
      expect(find.text('The server says it is reachable at 203.0.113.7:32401.'), findsOneWidget);
      expect(find.text('Test Plex, Plex $_version, id 00000000'), findsOneWidget);
      expect(isEnabled(tester, 'plex_save'), isTrue);

      await enter(tester, 'plex_name', 'Renamed');
      await tap(tester, field('plex_save'));

      final saved = storedSources().single;
      expect(saved.name, 'Renamed');
      expect(saved.rootPath, '/Movies');
      expect(saved.plex, source.plex);
      expect(secureStorage.writtenDeviceOnly, isEmpty, reason: 'the token was kept, not written again');
      expect(secureStorage.values[source.secretKey], _token);
    });

    testWidgets('"Paste a new token" starts on an empty token field, which has the focus', (tester) async {
      await addSource();
      await pumpPage(tester, source: source, focusToken: true);

      expect(textOf(tester, 'plex_token'), isEmpty);
      expect(tester.widget<TextField>(field('plex_token')).focusNode!.hasFocus, isTrue);
      expect(isEnabled(tester, 'plex_save'), isFalse);

      await enter(tester, 'plex_token', 'TEST-TOKEN-0000000001');
      await tap(tester, field('plex_test'));
      expect(pairing.lookedUp.single.$2, _hash, reason: 'the stored hash is the one the address must hold');
      await tap(tester, field('plex_save'));
      expect(secureStorage.values[source.secretKey], 'TEST-TOKEN-0000000001');
      expect(secureStorage.writtenDeviceOnly, {source.secretKey});
    });

    testWidgets('reads the address outside home typed, and keeps a port typed alone', (tester) async {
      await addSource();
      await pumpPage(tester, source: source);

      await enter(tester, 'plex_remote_address', 'my nas');
      expect(find.text('This is not an address the app can read.'), findsOneWidget);
      expect(isEnabled(tester, 'plex_save'), isFalse);

      // A whole address: its host stays in the field and its port goes to the port field once the field is left
      await enter(tester, 'plex_remote_address', 'https://Home.Example.org:40000/web');
      expect(find.text('This is not an address the app can read.'), findsNothing);
      await tap(tester, field('plex_name'));
      expect(textOf(tester, 'plex_remote_address'), 'home.example.org');
      expect(textOf(tester, 'plex_remote_port'), '40000');

      // Without a port, the hint tells the one the server told, which the connection uses
      await enter(tester, 'plex_remote_port', '');
      expect(find.text('32401'), findsOneWidget);
      await tap(tester, field('plex_save'));
      expect(
        storedSources().single.plex,
        const PlexServerInfo(hash: _hash, publicHost: 'home.example.org', version: _version),
      );
    });

    testWidgets('a port typed without an address outside home is kept', (tester) async {
      await addSource();
      await pumpPage(tester, source: source);
      await enter(tester, 'plex_remote_address', '');
      await enter(tester, 'plex_remote_port', '40000');
      await tap(tester, field('plex_save'));
      expect(storedSources().single.plex, const PlexServerInfo(hash: _hash, publicPort: 40000, version: _version));
    });

    testWidgets('away from home, a new token is tested through the address outside home', (tester) async {
      await addSource();
      pairing.lookUpErrors['192.168.1.20'] = const PlexFileSystemException('x', PlexFailure.unreachable);
      await pumpPage(tester, source: source, focusToken: true);

      await enter(tester, 'plex_token', 'TEST-TOKEN-0000000001');
      await tap(tester, field('plex_test'));
      expect(
        [for (final (typed, hash) in pairing.lookedUp) (typed.host, typed.port, hash)],
        [('192.168.1.20', 32400, _hash), ('plex.example.com', 32401, _hash)],
      );
      expect(find.text('Connected: 3 libraries'), findsOneWidget);
      await tap(tester, field('plex_save'));

      final saved = storedSources().single;
      expect((saved.host, saved.port), ('192.168.1.20', null), reason: 'the address at home stays');
      expect(saved.plex, source.plex);
      expect(secureStorage.values[source.secretKey], 'TEST-TOKEN-0000000001');
    });

    testWidgets('away from home, the address the server told is tried and not written as typed', (tester) async {
      final told = source.copyWith(
        plex: const PlexServerInfo(hash: _hash, version: _version),
      );
      await store.put(StoreKey.networkSourcesExtra, NetworkSource.encodeStored([told], const []));
      secureStorage.values[told.secretKey] = _token;
      await PlexLearnedAddressStore(
        store,
      ).write(told.id, PlexLearnedAddress(host: '203.0.113.7', port: 32401, at: DateTime.utc(2026, 10, 7)));
      pairing.lookUpErrors['192.168.1.20'] = const PlexFileSystemException('x', PlexFailure.unreachable);
      await pumpPage(tester, source: told, focusToken: true);

      await enter(tester, 'plex_token', 'TEST-TOKEN-0000000001');
      await tap(tester, field('plex_test'));
      expect(pairing.lookedUp.last.$1.host, '203.0.113.7');
      await tap(tester, field('plex_save'));

      final saved = storedSources().single;
      expect(saved.host, '192.168.1.20');
      expect(saved.plex, told.plex, reason: 'what the server tells goes on being learned');
    });

    testWidgets('the address outside home typed in the address field does not replace the one at home', (tester) async {
      final athome = source.copyWith(
        plex: const PlexServerInfo(hash: _hash, version: _version),
      );
      await store.put(StoreKey.networkSourcesExtra, NetworkSource.encodeStored([athome], const []));
      secureStorage.values[athome.secretKey] = _token;
      await pumpPage(tester, source: athome, focusToken: true);

      await enter(tester, 'plex_server_address', 'plex.example.com:32401');
      await enter(tester, 'plex_token', 'TEST-TOKEN-0000000001');
      await tap(tester, field('plex_test'));
      await tap(tester, field('plex_save'));

      final saved = storedSources().single;
      expect(saved.host, '192.168.1.20');
      expect(
        saved.plex,
        const PlexServerInfo(hash: _hash, publicHost: 'plex.example.com', publicPort: 32401, version: _version),
      );
    });

    testWidgets('a server paired from outside home keeps its address when the field outside home is emptied', (
      tester,
    ) async {
      final outside = source.copyWith(host: '');
      await store.put(StoreKey.networkSourcesExtra, NetworkSource.encodeStored([outside], const []));
      secureStorage.values[outside.secretKey] = _token;
      await pumpPage(tester, source: outside);
      expect(textOf(tester, 'plex_server_address'), 'plex.example.com:32401');

      await enter(tester, 'plex_remote_address', '');
      await enter(tester, 'plex_remote_port', '');
      await tap(tester, field('plex_save'));

      final saved = storedSources().single;
      expect(saved.host, isEmpty);
      expect(saved.plex?.publicHost, 'plex.example.com');
      expect(saved.plex?.publicPort, 32401);
    });

    testWidgets('removes the server after a confirmation telling the token stays valid', (tester) async {
      await addSource();
      await pumpPage(tester, source: source);

      await tap(tester, field('plex_remove'));
      expect(
        find.textContaining(
          'Remove Test Plex? Its token is forgotten on this device. Nothing is deleted on the server.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('The token stays valid on the server'), findsOneWidget);
      await tap(tester, find.text('Remove').last);

      expect(find.text('shares list'), findsOneWidget);
      expect(storedSources(), isEmpty);
      expect(secureStorage.values, isEmpty);
      expect(secureStorage.deletedDeviceOnly, {source.secretKey});
      expect(PlexLearnedAddressStore(store).read(source.id), isNull);
    });
  });

  testWidgets('in TV mode the address entry has the focus, and every field is typed through the TV', (tester) async {
    await pumpPage(tester, tv: true);
    expect(find.text('Press OK to type'), findsWidgets);
    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull);
    final remote = find.ancestor(of: field('plex_server_address'), matching: find.byType(RemoteFocusable));
    expect(remote, findsOneWidget);
    expect(
      find.descendant(of: find.byWidget(focused!.context!.widget), matching: field('plex_server_address')),
      findsOneWidget,
    );
  });

  group('leaving with unsaved changes', () {
    final discardTitle = find.text('Discard the changes?');

    Future<void> close(WidgetTester tester) async {
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
    }

    testWidgets('asks before a typed token is lost, and leaves once the user agrees', (tester) async {
      await pumpPage(tester);
      await enter(tester, 'plex_token', _token);

      await close(tester);
      expect(discardTitle, findsOneWidget);
      await tester.tap(find.byKey(const Key('form_discard_changes_discard')));
      await tester.pumpAndSettle();

      expect(find.text('shares list'), findsOneWidget);
      expect(storedSources(), isEmpty);
    });

    testWidgets('a server tapped in the share form, left as it came, leaves at once', (tester) async {
      await pumpPage(tester, server: _plex);
      expect(textOf(tester, 'plex_server_address'), isNotEmpty);

      await close(tester);

      expect(discardTitle, findsNothing);
      expect(find.text('shares list'), findsOneWidget);
    });

    testWidgets('a server already added, its token read and left as it was, leaves at once', (tester) async {
      const source = NetworkSource(
        id: 'plex1',
        type: NetworkSourceType.plex,
        name: 'Test Plex',
        host: '192.168.1.20',
        port: 32400,
        useTls: true,
        discoveryId: _machine,
        plex: PlexServerInfo(hash: _hash),
      );
      await store.put(StoreKey.networkSourcesExtra, NetworkSource.encodeStored([source], const []));
      secureStorage.values[source.secretKey] = _token;
      await pumpPage(tester, source: source);
      expect(textOf(tester, 'plex_token'), _token);

      await close(tester);

      expect(discardTitle, findsNothing);
      expect(find.text('shares list'), findsOneWidget);
    });
  });
}
