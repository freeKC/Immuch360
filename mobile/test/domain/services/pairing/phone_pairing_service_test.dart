import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/pairing/big_screen_headers.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/pairing/phone_pairing.service.dart';
import 'package:immich_mobile/domain/services/pairing/screen_pairing_session.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_client.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_server.dart';
import 'package:logging/logging.dart';

const _device = {'app': '3.3.0', 'kind': 'tv', 'label': 'Living room TV', 'os': 'Android'};

/// The Immich server of the phone: the sessions it made and deleted
class _FakeImmich implements PairingSessions {
  final created = <({String id, String token, String deviceType, String deviceOS})>[];
  final deleted = <String>[];
  PairingSessionsException? failure;

  @override
  Future<({String id, String token})> create({required String deviceType, required String deviceOS}) async {
    final error = failure;
    if (error != null) {
      throw error;
    }
    final session = (id: 'session-${created.length + 1}', token: 'token-${created.length + 1}-secret');
    created.add((id: session.id, token: session.token, deviceType: deviceType, deviceOS: deviceOS));
    return session;
  }

  @override
  Future<void> delete(String id) async => deleted.add(id);

  @override
  Future<List<({String id, DateTime? updatedAt})>> list() async => [
    for (final session in created)
      if (!deleted.contains(session.id)) (id: session.id, updatedAt: null),
  ];
}

/// The screen's sign in: what arrived, and what it answers
class _ScreenSignIn implements PairingSignIn {
  final payloads = <Map<String, Object?>>[];
  Map<String, Object?> answer = {'status': 'signedIn'};
  Completer<void>? hold;

  @override
  Future<PairingSignInResult> withSession(Map<String, Object?> payload) async {
    payloads.add(payload);
    await hold?.future;
    return PairingSignInResult(answer: answer, signedIn: answer['status'] == 'signedIn');
  }

  @override
  Future<PairingSignInResult> withPassword(Map<String, Object?> credentials) => throw UnimplementedError();
}

const _account = PhonePairingAccount(
  server: 'https://photos.example.com',
  endpoints: ['https://photos.example.com/api', 'http://192.168.1.10:2283/api'],
  headers: {'CF-Access-Client-Secret': 'header-value-secret'},
  userName: 'Fred',
  userEmail: 'fred@example.com',
  phoneName: "Fred's Pixel",
);

void main() {
  late ScreenPairingSession screen;
  late _ScreenSignIn screenSignIn;
  late PairingServer server;
  late int port;
  late _FakeImmich immich;
  late PhonePairingService phone;
  late List<LogRecord> logs;
  late StreamSubscription<LogRecord> logListener;

  setUp(() async {
    screen = ScreenPairingSession(device: _device, random: Random(3))..start();
    screenSignIn = _ScreenSignIn();
    server = PairingServer(
      session: screen,
      signIn: screenSignIn,
      page: PairingPage(html: Uint8List(0), script: Uint8List(0), style: Uint8List(0)),
      device: _device,
      preferredPort: 0,
    );
    port = await server.start();
    immich = _FakeImmich();
    phone = PhonePairingService(
      client: PairingHttpClient(
        answerTimeout: const Duration(seconds: 2),
        addressOf: (_, port) => Uri(scheme: 'http', host: '127.0.0.1', port: port),
      ),
      sessions: immich,
      clock: () => DateTime.utc(2026, 10, 22, 20, 15),
    );
    logs = [];
    Logger.root.level = Level.ALL;
    logListener = Logger.root.onRecord.listen(logs.add);
  });

  tearDown(() async {
    await logListener.cancel();
    await server.stop();
    await screen.dispose();
  });

  PairingTarget scanned() =>
      PairingTarget(host: '192.168.1.23', port: port, id: screen.currentCode!.id, secret: screen.currentCode!.secret);

  test('the screen gets a session of its own, named after it, and the phone keeps it', () async {
    final hello = await phone.hello(scanned());
    expect(hello.device.label, 'Living room TV');
    expect(immich.created, isEmpty, reason: 'nothing is created before the user confirms');

    final result = await phone.signIn(hello, label: ' Lounge\nTV ', account: _account);
    expect(result.status, PhonePairingStatus.signedIn);
    expect(result.sessionId, 'session-1');
    expect(result.label, 'Lounge TV');
    expect(immich.created.single.deviceType, 'Immuch360 on Lounge TV');
    expect(immich.created.single.deviceOS, 'Android');
    expect(immich.deleted, isEmpty);

    final payload = screenSignIn.payloads.single;
    expect(payload['token'], 'token-1-secret');
    expect(payload['sessionId'], 'session-1');
    expect(payload['server'], 'https://photos.example.com');
    expect(payload['endpoints'], _account.endpoints);
    expect(payload['headers'], {'CF-Access-Client-Secret': 'header-value-secret'});
    expect(payload['label'], 'Lounge TV');
    expect(payload['user'], {'name': 'Fred', 'email': 'fred@example.com'});
    expect(payload['phone'], "Fred's Pixel");
    expect(payload['issuedAt'], '2026-10-22T20:15:00.000Z');
    expect(payload.keys, isNot(contains('password')));
  });

  test('the screen cannot reach the server: the session is deleted at once', () async {
    screenSignIn.answer = {'status': 'serverUnreachable', 'tried': 2};
    final result = await phone.signIn(await phone.hello(scanned()), label: 'TV', account: _account);
    expect(result.status, PhonePairingStatus.serverUnreachable);
    expect(result.triedAddresses, 2);
    expect(immich.deleted, ['session-1']);
  });

  test('the token refused, a screen that says something else: deleted', () async {
    screenSignIn.answer = {'status': 'tokenRejected'};
    expect(
      (await phone.signIn(await phone.hello(scanned()), label: 'TV', account: _account)).status,
      PhonePairingStatus.tokenRejected,
    );
    expect(immich.deleted, ['session-1']);
  });

  test('no answer in time: lost, and deleted', () async {
    screenSignIn.hold = Completer<void>();
    final result = await phone.signIn(await phone.hello(scanned()), label: 'TV', account: _account);
    expect(result.status, PhonePairingStatus.lost);
    expect(immich.deleted, ['session-1']);
    screenSignIn.hold!.complete();
  });

  test('the screen went away between the hello and Sign in: deleted', () async {
    final hello = await phone.hello(scanned());
    await server.stop();
    final result = await phone.signIn(hello, label: 'TV', account: _account);
    expect(result.status, PhonePairingStatus.lost);
    expect(immich.deleted, ['session-1']);
  });

  test('the code rotated between the hello and Sign in: deleted', () async {
    final hello = await phone.hello(scanned());
    screen.start();
    final result = await phone.signIn(hello, label: 'TV', account: _account);
    expect(result.status, PhonePairingStatus.expired);
    expect(immich.deleted, ['session-1']);
  });

  test('a wrong typed code: nothing is created', () async {
    final typed = PairingTarget(host: '192.168.1.23', port: port, id: screen.currentCode!.id, code: 'AAAAAAAAAA');
    await expectLater(
      phone.hello(typed),
      throwsA(isA<PairingException>().having((e) => e.failure, 'failure', PairingFailure.wrongCode)),
    );
    expect(immich.created, isEmpty);
  });

  test('a server without POST /sessions: nothing goes to the screen', () async {
    immich.failure = const PairingSessionsException(PairingSessionsFailure.serverTooOld);
    final result = await phone.signIn(await phone.hello(scanned()), label: 'TV', account: _account);
    expect(result.status, PhonePairingStatus.serverTooOld);
    expect(screenSignIn.payloads, isEmpty);
  });

  test('a second pairing with the same code is refused, and its session deleted', () async {
    final first = await phone.hello(scanned());
    final second = await phone.hello(scanned());
    expect((await phone.signIn(first, label: 'TV', account: _account)).signedIn, isTrue);
    final again = await phone.signIn(second, label: 'TV', account: _account);
    expect(again.status, PhonePairingStatus.expired);
    expect(immich.deleted, ['session-2']);
    expect(screenSignIn.payloads, hasLength(1));
  });

  test('the names of the sessions', () {
    expect(pairingSessionName('Living room TV'), 'Immuch360 on Living room TV');
    const computer = PairingScreenDevice(label: 'PC', kind: PairingScreenKind.computer, os: 'Windows', app: '');
    expect(pairingSessionOs(computer), 'Windows');
    const odd = PairingScreenDevice(label: 'PC', kind: PairingScreenKind.computer, os: 'Plan 9', app: '');
    expect(pairingSessionOs(odd), 'Linux');
    expect(cleanPairingLabel('   '), isNull);
    expect(cleanPairingLabel('a' * 60), hasLength(maxLabelLength));
  });

  test('nothing secret reaches the log', () async {
    await phone.signIn(await phone.hello(scanned()), label: 'TV', account: _account);
    screenSignIn.answer = {'status': 'serverUnreachable'};
    screen.start();
    await phone.signIn(await phone.hello(scanned()), label: 'TV', account: _account);
    final text = logs.map((record) => '${record.message} ${record.error ?? ''}').join('\n');
    expect(text, contains('Pairing'));
    for (final secret in ['token-1-secret', 'token-2-secret', 'header-value-secret', screen.currentCode!.code]) {
      expect(text, isNot(contains(secret)));
    }
  });
}
