import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/pairing/phone_pairing.service.dart';
import 'package:immich_mobile/domain/services/pairing/screen_pairing_session.dart';
import 'package:immich_mobile/domain/services/pairing/screen_sign_in.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_client.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_server.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/pairing/screen_pairing.provider.dart';

import '../../test_utils.dart';

/// The app as a sign in sees it: every server answers, every token is good
class _App implements ScreenSignInActions {
  final tokens = <String>[];

  @override
  Future<ScreenSignInSnapshot> snapshot() async => const ScreenSignInSnapshot(headers: {}, label: null);
  @override
  Future<void> restore(ScreenSignInSnapshot snapshot) async {}
  @override
  Future<void> setCustomHeaders(Map<String, String> headers) async {}
  @override
  Future<void> setLabel(String label) => Store.put(StoreKey.pairingScreenLabel, label);
  @override
  Future<bool> tryServer(String endpoint, Duration timeout) async => true;
  @override
  Future<bool> useToken(String token) async {
    tokens.add(token);
    return true;
  }

  @override
  Future<({bool passwordLogin, String? oauthProvider})> loginOptions() async =>
      (passwordLogin: true, oauthProvider: null);
  @override
  Future<PasswordSignInOutcome> login(String email, String password) async => PasswordSignInOutcome.signedIn;
  @override
  Future<void> setSignedInBy(String? phone) async {}
  @override
  String? userName() => 'Fred';
}

class _Immich implements PairingSessions {
  @override
  Future<({String id, String token})> create({required String deviceType, required String deviceOS}) async =>
      (id: 'session-1', token: 'token-for-the-screen');
  @override
  Future<void> delete(String id) async {}
  @override
  Future<List<({String id, DateTime? updatedAt})>> list() async => const [];
}

void main() {
  late StreamController<AppLifecycleState> lifecycle;
  late StreamController<void> network;
  late List<String> addresses;
  late bool publicOnly;
  late List<(String, int, Map<String, String>)> announced;
  late int announcementsStopped;
  late ProviderContainer container;

  late Drift db;

  setUpAll(() async {
    TestUtils.init();
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db));
  });

  tearDownAll(() => db.close());

  setUp(() async {
    await Store.delete(StoreKey.pairingScreenLabel);
    lifecycle = StreamController<AppLifecycleState>.broadcast();
    network = StreamController<void>.broadcast();
    addresses = ['127.0.0.1'];
    publicOnly = false;
    announced = [];
    announcementsStopped = 0;
    container = ProviderContainer(
      overrides: [
        screenPairingEnvironmentProvider.overrideWithValue(
          ScreenPairingEnvironment(
            localAddresses: () async => addresses,
            publicNetworkOnly: () async => publicOnly,
            advertise: (name, port, attributes) async {
              announced.add((name, port, attributes));
              return () async => announcementsStopped++;
            },
            networkChanges: () => network.stream,
            lifecycle: () => lifecycle.stream,
            deviceName: () async => 'Living room TV',
            kind: () async => PairingScreenKind.tv,
            os: 'Android',
            appVersion: () async => '3.3.0',
            page: () async => PairingPage(html: Uint8List(0), script: Uint8List(0), style: Uint8List(0)),
            // The code shows a private address; the test reaches the listener on the loopback
            advertisedAddress: '10.0.0.5:8361',
            preferredPort: 0,
          ),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await lifecycle.close();
    await network.close();
  });

  ScreenPairingController controller() => container.read(screenPairingProvider.notifier);
  ScreenPairingView view() => container.read(screenPairingProvider);

  Future<bool> listening(int port) async {
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 1));
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

  test('the panel shows: a code, the listener and its announcement under the name of the device', () async {
    await controller().show(_App());
    await settle();
    final shown = view();
    expect(shown.phase, ScreenPairingPhase.waiting);
    expect(shown.qrText, startsWith('http://10.0.0.5:8361/p#1.'));
    expect(shown.typedUrl, 'http://10.0.0.5:8361/p');
    expect(shown.code, matches(RegExp(r'^[A-Z2-9]{5} [A-Z2-9]{5}$')));
    expect(await listening(shown.port!), isTrue);
    expect(announced.single.$1, 'Immuch360 on Living room TV');
    expect(announced.single.$3, {'v': '1', 'kind': 'tv'});
    expect(Store.tryGet(StoreKey.pairingScreenLabel), 'Living room TV');
    expect(shown.toString(), isNot(contains(shown.code)));

    await controller().hide();
    await settle();
    expect(await listening(shown.port!), isFalse);
    expect(announcementsStopped, 1);
    expect(view().phase, ScreenPairingPhase.stopped);
  });

  test('the app in the background stops it, back in front a new code', () async {
    await controller().show(_App());
    await settle();
    final first = view();
    lifecycle.add(AppLifecycleState.paused);
    await settle();
    expect(await listening(first.port!), isFalse);
    expect(view().qrText, isNull);

    lifecycle.add(AppLifecycleState.resumed);
    await settle();
    expect(view().phase, ScreenPairingPhase.waiting);
    expect(view().code, isNot(first.code));
    await controller().hide();
  });

  test('no local network, or only public ones on Windows: no listening, and why', () async {
    addresses = [];
    await controller().show(_App());
    await settle();
    expect(view().problem, ScreenPairingProblem.noNetwork);
    expect(announced, isEmpty);
    await controller().hide();

    publicOnly = true;
    await controller().show(_App());
    await settle();
    expect(view().problem, ScreenPairingProblem.publicNetwork);

    // A network comes up: the code shows
    addresses = ['127.0.0.1'];
    network.add(null);
    await settle();
    await settle();
    expect(view().problem, ScreenPairingProblem.none);
    expect(view().qrText, isNotNull);
    await controller().hide();
  });

  test('a phone signs the screen in: the listener and the announcement stop', () async {
    final app = _App();
    await controller().show(app);
    await settle();
    final shown = view();
    final scan = parsePairingText(shown.qrText!) as PairingTarget;
    final phone = PhonePairingService(
      client: PairingHttpClient(
        addressOf: (_, _) => Uri(scheme: 'http', host: '127.0.0.1', port: shown.port),
      ),
      sessions: _Immich(),
    );
    final hello = await phone.hello(scan);
    await settle();
    expect(view().phase, ScreenPairingPhase.confirmOnPhone);

    final result = await phone.signIn(
      hello,
      label: 'Lounge',
      account: const PhonePairingAccount(
        server: 'https://photos.example.com',
        endpoints: ['https://photos.example.com/api'],
        headers: {},
        userName: 'Fred',
        userEmail: 'fred@example.com',
        phoneName: "Fred's Pixel",
      ),
    );
    await settle();
    expect(result.signedIn, isTrue);
    expect(app.tokens, ['token-for-the-screen']);
    expect(view().phase, ScreenPairingPhase.signedIn);
    expect(view().signedIn?.user, 'Fred');
    expect(view().signedIn?.phone, "Fred's Pixel");
    expect(Store.tryGet(StoreKey.pairingScreenLabel), 'Lounge');
    expect(await listening(shown.port!), isFalse);
    expect(announcementsStopped, 1);
  });
}
