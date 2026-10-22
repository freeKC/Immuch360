import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/pairing/screen_pairing_session.dart';

const _device = {'app': '3.3.0', 'kind': 'tv', 'label': 'Living room TV', 'os': 'Android'};

/// The phone's side of one hello, as pairing_client.dart plays it
class _Phone {
  _Phone(this.mode, {this.client = PairingClient.app}) : keyPair = PairingKeyPair.generate(Random(_seed++));

  static var _seed = 1;

  final PairingMode mode;
  final PairingClient client;
  final PairingKeyPair keyPair;
  PairingChannel? channel;

  String get publicKey => pairingBase64(keyPair.publicKey);

  /// Checks the screen's answer with [secret], as the phone does before it shows anything; keeps the channel
  bool accept(String id, Map<String, Object> response, List<int> secret) {
    final screenKey = pairingDecodeBase64(response['pk'])!;
    final transcript = pairingTranscript(
      id: id,
      mode: mode,
      client: client,
      phoneKey: keyPair.publicKey,
      screenKey: screenKey,
    );
    final keys = derivePairingKeys(shared: keyPair.agree(screenKey)!, secret: secret, transcript: transcript);
    final expected = pairingConfirm(
      confirmKey: keys.confirm,
      transcript: transcript,
      device: pairingDecodeBase64(response['d'])!,
    );
    if (!pairingSameBytes(expected, pairingDecodeBase64(response['confirm'])!)) {
      return false;
    }
    channel = PairingChannel(transcript: transcript, keys: keys, sends: PairingDirection.up);
    return true;
  }
}

void main() {
  late DateTime start;
  late ScreenPairingSession session;

  ScreenPairingSession make(FakeAsync async) =>
      ScreenPairingSession(device: _device, clock: () => start.add(async.elapsed), random: Random(42));

  setUp(() => start = DateTime.utc(2026, 10, 22, 20));

  /// A hello of [phone] for the current code, run to its end
  HelloOutcome hello(FakeAsync async, _Phone phone, {String? id}) {
    HelloOutcome? outcome;
    unawaited(
      session
          .hello(
            id: id ?? session.currentCode!.id,
            mode: phone.mode.wire,
            client: phone.client.wire,
            phoneKey: phone.publicKey,
          )
          .then((value) => outcome = value),
    );
    async.flushMicrotasks();
    return outcome!;
  }

  test('a code lives two minutes, then the next one replaces it and the old one is dead', () {
    fakeAsync((async) {
      session = make(async)..start();
      final first = session.currentCode!;
      expect(session.state.phase, ScreenPairingPhase.waiting);
      expect(first.code, hasLength(pairingCodeLength));
      expect(first.secret, hasLength(pairingSecretBytes));
      expect(pairingDecodeBase64(first.id), hasLength(pairingIdBytes));

      async.elapse(const Duration(seconds: 119));
      expect(session.currentCode, same(first));
      async.elapse(const Duration(seconds: 1));
      final second = session.currentCode!;
      expect(second, isNot(same(first)));
      expect(second.id, isNot(first.id));
      expect(second.code, isNot(first.code));

      expect(hello(async, _Phone(PairingMode.qr), id: first.id), isA<HelloGone>());
      expect(hello(async, _Phone(PairingMode.qr), id: 'unknownidxx'), isA<HelloGone>());
      expect(hello(async, _Phone(PairingMode.qr)), isA<HelloAccepted>());
    });
  });

  test('a hello proves the screen knows S, and a phone with another secret sees it', () {
    fakeAsync((async) {
      session = make(async)..start();
      final code = session.currentCode!;
      final phone = _Phone(PairingMode.qr);
      final outcome = hello(async, phone) as HelloAccepted;
      expect(phone.accept(code.id, outcome.response, code.secret), isTrue);
      expect(utf8.decode(pairingDecodeBase64(outcome.response['d'])!), jsonEncode(_device));
      expect(session.state.phase, ScreenPairingPhase.confirmOnPhone);

      final fooled = _Phone(PairingMode.qr);
      final other = hello(async, fooled) as HelloAccepted;
      expect(fooled.accept(code.id, other.response, Uint8List(16)), isFalse);
    });
  });

  test('in code mode the code is the secret', () {
    fakeAsync((async) {
      session = make(async)..start();
      final code = session.currentCode!;
      final phone = _Phone(PairingMode.code);
      final outcome = hello(async, phone) as HelloAccepted;
      expect(phone.accept(code.id, outcome.response, utf8.encode(code.code)), isTrue);
      final wrongCode = _Phone(PairingMode.code);
      final other = hello(async, wrongCode) as HelloAccepted;
      expect(wrongCode.accept(code.id, other.response, utf8.encode('AAAAAAAAAA')), isFalse);
      // The QR secret does not open a code mode hello either
      final mixed = _Phone(PairingMode.code);
      final third = hello(async, mixed) as HelloAccepted;
      expect(mixed.accept(code.id, third.response, code.secret), isFalse);
    });
  });

  test('three hellos per code, the fourth is throttled', () {
    fakeAsync((async) {
      session = make(async)..start();
      for (var i = 0; i < ScreenPairingSession.maxHellos; i++) {
        expect(hello(async, _Phone(PairingMode.qr)), isA<HelloAccepted>());
      }
      expect(hello(async, _Phone(PairingMode.qr)), isA<HelloThrottled>());
    });
  });

  test('a hello that is not one is refused', () {
    fakeAsync((async) {
      session = make(async)..start();
      final id = session.currentCode!.id;
      Future<HelloOutcome> send(Object? mode, Object? client, Object? key) =>
          session.hello(id: id, mode: mode, client: client, phoneKey: key);
      final key = _Phone(PairingMode.qr).publicKey;
      final outcomes = <HelloOutcome>[];
      unawaited(send('other', 'app', key).then(outcomes.add));
      unawaited(send('qr', 'other', key).then(outcomes.add));
      unawaited(send('qr', 'app', 'AAAA').then(outcomes.add));
      unawaited(send('qr', 'app', pairingBase64(Uint8List(33))).then(outcomes.add));
      async.flushMicrotasks();
      expect(outcomes, everyElement(isA<HelloInvalid>()));
    });
  });

  test('a hello holds the code for a minute more, then it rotates', () {
    fakeAsync((async) {
      session = make(async)..start();
      final code = session.currentCode!;
      async.elapse(const Duration(seconds: 100));
      expect(hello(async, _Phone(PairingMode.qr)), isA<HelloAccepted>());
      async.elapse(const Duration(seconds: 59));
      expect(session.currentCode, same(code));
      async.elapse(const Duration(seconds: 1));
      expect(session.currentCode, isNot(same(code)));
      expect(session.state.phase, ScreenPairingPhase.waiting);
    });
  });

  test('the message that decrypts uses the code up: a second pairing is refused', () {
    fakeAsync((async) {
      session = make(async)..start();
      final code = session.currentCode!;
      final phone = _Phone(PairingMode.qr);
      final second = _Phone(PairingMode.qr);
      expect(phone.accept(code.id, (hello(async, phone) as HelloAccepted).response, code.secret), isTrue);
      expect(second.accept(code.id, (hello(async, second) as HelloAccepted).response, code.secret), isTrue);

      final opened = session.open(
        id: code.id,
        envelope: phone.channel!.seal({'v': 1, 'token': 't'}),
        client: PairingClient.app,
      );
      expect(opened, isA<SealedOpened>());
      expect((opened as SealedOpened).message['token'], 't');
      expect(session.state.phase, ScreenPairingPhase.signingIn);
      // While the screen signs in, nothing else gets through
      expect(
        session.open(id: code.id, envelope: second.channel!.seal({'v': 1}), client: PairingClient.app),
        isA<SealedBusy>(),
      );
      expect(hello(async, _Phone(PairingMode.qr)), isA<HelloThrottled>());

      session.finish(id: code.id, signedIn: true);
      expect(session.state.phase, ScreenPairingPhase.signedIn);
      expect(code.isUsed, isTrue);
      expect(
        session.open(id: code.id, envelope: second.channel!.seal({'v': 1}), client: PairingClient.app),
        isA<SealedGone>().having((gone) => gone.used, 'used', isTrue),
      );
      expect(hello(async, _Phone(PairingMode.qr), id: code.id), isA<HelloGone>());
      // Signed in: no more codes
      async.elapse(const Duration(minutes: 5));
      expect(session.state.phase, ScreenPairingPhase.signedIn);
    });
  });

  test('a message that does not decrypt burns the code and shows a new one', () {
    fakeAsync((async) {
      session = make(async)..start();
      final code = session.currentCode!;
      final phone = _Phone(PairingMode.code);
      final response = (hello(async, phone) as HelloAccepted).response;
      // A wrong code typed: the phone does not see the mismatch here because it skips the check, as an attacker would
      expect(phone.accept(code.id, response, utf8.encode('AAAAAAAAAA')), isFalse);
      final transcriptOnly = PairingChannel(
        transcript: pairingTranscript(
          id: code.id,
          mode: PairingMode.code,
          client: PairingClient.app,
          phoneKey: phone.keyPair.publicKey,
          screenKey: pairingDecodeBase64(response['pk'])!,
        ),
        keys: derivePairingKeys(
          shared: phone.keyPair.agree(pairingDecodeBase64(response['pk'])!)!,
          secret: utf8.encode('AAAAAAAAAA'),
          transcript: pairingTranscript(
            id: code.id,
            mode: PairingMode.code,
            client: PairingClient.app,
            phoneKey: phone.keyPair.publicKey,
            screenKey: pairingDecodeBase64(response['pk'])!,
          ),
        ),
        sends: PairingDirection.up,
      );
      final outcome = session.open(id: code.id, envelope: transcriptOnly.seal({'v': 1}), client: PairingClient.app);
      expect(outcome, isA<SealedRejected>());
      expect(code.isUsed, isTrue);
      expect(session.currentCode, isNot(same(code)));
      expect(session.state.notice, ScreenPairingNotice.tooManyAttempts);
    });
  });

  test('an envelope of an unknown hello, or of the other client, burns the code too', () {
    fakeAsync((async) {
      session = make(async)..start();
      var code = session.currentCode!;
      final phone = _Phone(PairingMode.qr);
      phone.accept(code.id, (hello(async, phone) as HelloAccepted).response, code.secret);
      expect(
        session.open(
          id: code.id,
          envelope: {
            ...phone.channel!.seal({'v': 1}),
            'h': 'AAAAAAAAAAA',
          },
          client: PairingClient.app,
        ),
        isA<SealedRejected>(),
      );

      code = session.currentCode!;
      final app = _Phone(PairingMode.qr);
      app.accept(code.id, (hello(async, app) as HelloAccepted).response, code.secret);
      expect(
        session.open(id: code.id, envelope: app.channel!.seal({'v': 1}), client: PairingClient.web),
        isA<SealedRejected>(),
      );
    });
  });

  test('the browser page has three tries at the password', () {
    fakeAsync((async) {
      session = make(async)..start();
      final code = session.currentCode!;
      final page = _Phone(PairingMode.qr, client: PairingClient.web);
      page.accept(code.id, (hello(async, page) as HelloAccepted).response, code.secret);
      for (var left = 2; left >= 1; left--) {
        expect(
          session.open(id: code.id, envelope: page.channel!.seal({'v': 1}), client: PairingClient.web),
          isA<SealedOpened>(),
        );
        expect(session.finish(id: code.id, signedIn: false, wrongPassword: true), left);
        expect(session.currentCode, same(code));
      }
      expect(
        session.open(id: code.id, envelope: page.channel!.seal({'v': 1}), client: PairingClient.web),
        isA<SealedOpened>(),
      );
      expect(session.finish(id: code.id, signedIn: false, wrongPassword: true), 0);
      expect(code.isUsed, isTrue);
      expect(session.currentCode, isNot(same(code)));
    });
  });

  test('a sign in that fails uses the code up and shows why under the next one', () {
    fakeAsync((async) {
      session = make(async)..start();
      final code = session.currentCode!;
      final phone = _Phone(PairingMode.qr);
      phone.accept(code.id, (hello(async, phone) as HelloAccepted).response, code.secret);
      session.open(id: code.id, envelope: phone.channel!.seal({'v': 1}), client: PairingClient.app);
      session.finish(
        id: code.id,
        signedIn: false,
        notice: ScreenPairingNotice.serverUnreachable,
        detail: 'photos.example.com',
      );
      expect(code.isUsed, isTrue);
      expect(session.currentCode, isNot(same(code)));
      expect(session.state.notice, ScreenPairingNotice.serverUnreachable);
      expect(session.state.noticeDetail, 'photos.example.com');
    });
  });

  test('a code being signed in with does not rotate under it', () {
    fakeAsync((async) {
      session = make(async)..start();
      final code = session.currentCode!;
      async.elapse(const Duration(seconds: 110));
      final phone = _Phone(PairingMode.qr);
      phone.accept(code.id, (hello(async, phone) as HelloAccepted).response, code.secret);
      async.elapse(const Duration(seconds: 55));
      session.open(id: code.id, envelope: phone.channel!.seal({'v': 1}), client: PairingClient.app);
      async.elapse(const Duration(seconds: 20));
      expect(session.currentCode, same(code));
      session.finish(id: code.id, signedIn: true);
      expect(session.state.phase, ScreenPairingPhase.signedIn);
    });
  });

  test('five codes without a hello pause the session until it starts again', () {
    fakeAsync((async) {
      session = make(async)..start();
      async.elapse(ScreenPairingSession.codeLifetime * 4);
      expect(session.state.phase, ScreenPairingPhase.waiting);
      async.elapse(ScreenPairingSession.codeLifetime);
      expect(session.state.phase, ScreenPairingPhase.paused);
      expect(session.currentCode, isNull);
      session.start();
      expect(session.state.phase, ScreenPairingPhase.waiting);
      expect(session.currentCode, isNotNull);
    });
  });

  test('a hello counts as use: the idle count starts again', () {
    fakeAsync((async) {
      session = make(async)..start();
      async.elapse(ScreenPairingSession.codeLifetime * 4);
      expect(hello(async, _Phone(PairingMode.qr)), isA<HelloAccepted>());
      async.elapse(ScreenPairingSession.codeLifetime * 4);
      expect(session.state.phase, ScreenPairingPhase.waiting);
    });
  });

  test('stopped, it answers gone', () {
    fakeAsync((async) {
      session = make(async)..start();
      final id = session.currentCode!.id;
      session.stop();
      expect(session.state.phase, ScreenPairingPhase.stopped);
      expect(hello(async, _Phone(PairingMode.qr), id: id), isA<HelloGone>());
      expect(session.open(id: id, envelope: const {}, client: PairingClient.app), isA<SealedGone>());
    });
  });

  test('nothing secret in what the state prints', () {
    fakeAsync((async) {
      session = make(async)..start();
      final code = session.currentCode!;
      final printed = '${session.state} $code';
      expect(printed, isNot(contains(code.code)));
      expect(printed, isNot(contains(pairingBase64(code.secret))));
    });
  });
}
