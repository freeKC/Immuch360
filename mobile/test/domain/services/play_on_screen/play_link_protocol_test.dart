import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';

/// The known answers of make_vectors.py, made with the Python cryptography package
List<Map<String, dynamic>> _vectors() {
  final file = File('test/fixtures/play_link/vectors.json');
  final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return (decoded['vectors'] as List).cast<Map<String, dynamic>>();
}

Uint8List _b64(Object? text) => pairingDecodeBase64(text)!;

/// Both sides of one session over [key]
({PlayLinkChannel phone, PlayLinkChannel screen}) _pair({List<int>? key, int seed = 1}) {
  final random = Random(seed);
  final transcript = playLinkTranscript(
    screenId: '0123456789abcdef',
    phoneId: 'fedcba9876543210',
    screenNonce: pairingRandomBytes(playLinkNonceBytes, random),
    phoneNonce: pairingRandomBytes(playLinkNonceBytes, random),
  );
  final keys = derivePlayLinkKeys(key: key ?? List.filled(32, 7), transcript: transcript);
  return (
    phone: PlayLinkChannel(transcript: transcript, keys: keys, sends: PairingDirection.up),
    screen: PlayLinkChannel(transcript: transcript, keys: keys, sends: PairingDirection.down),
  );
}

void main() {
  group('known answers', () {
    for (final vector in _vectors()) {
      test(vector['name'], () {
        final key = _b64(vector['key']);
        final transcript = playLinkTranscript(
          screenId: vector['screenId'],
          phoneId: vector['phoneId'],
          screenNonce: _b64(vector['nonceScreen']),
          phoneNonce: _b64(vector['noncePhone']),
        );
        expect(pairingBase64(transcript), vector['transcript']);
        expect(playLinkHandle(transcript), vector['handle']);
        expect(
          pairingBase64(playLinkProof(key: key, role: PlayLinkRole.phone, transcript: transcript)),
          vector['proofPhone'],
        );
        expect(
          pairingBase64(playLinkProof(key: key, role: PlayLinkRole.screen, transcript: transcript)),
          vector['proofScreen'],
        );

        final keys = derivePlayLinkKeys(key: key, transcript: transcript);
        expect(pairingBase64(keys.up), vector['kUp']);
        expect(pairingBase64(keys.down), vector['kDown']);
        expect(pairingBase64(keys.handover), vector['kHandover']);

        final sealedUp = playLinkSeal(
          keys: keys,
          transcript: transcript,
          direction: PairingDirection.up,
          counter: vector['counterUp'],
          plain: _b64(vector['plainUp']),
        );
        expect(pairingBase64(sealedUp), vector['sealedUp']);
        final sealedDown = playLinkSeal(
          keys: keys,
          transcript: transcript,
          direction: PairingDirection.down,
          counter: vector['counterDown'],
          plain: _b64(vector['plainDown']),
        );
        expect(pairingBase64(sealedDown), vector['sealedDown']);

        // The channels open the envelopes of the other side as Python sealed them
        final screen = PlayLinkChannel(transcript: transcript, keys: keys, sends: PairingDirection.down);
        final opened = screen.open({'v': 1, 's': vector['handle'], 'k': vector['counterUp'], 'c': vector['sealedUp']});
        expect(opened, jsonDecode(utf8.decode(_b64(vector['plainUp']))));
        final phone = PlayLinkChannel(transcript: transcript, keys: keys, sends: PairingDirection.up);
        expect(
          phone.open({'v': 1, 's': vector['handle'], 'k': vector['counterDown'], 'c': vector['sealedDown']}),
          jsonDecode(utf8.decode(_b64(vector['plainDown']))),
        );

        // The token handover
        final handover = vector['handover'] as Map<String, dynamic>;
        final phoneKeys = PairingKeyPair.fromPrivate(BigInt.parse(handover['phonePrivate'], radix: 16));
        final screenKeys = PairingKeyPair.fromPrivate(BigInt.parse(handover['screenPrivate'], radix: 16));
        expect(pairingBase64(phoneKeys.publicKey), handover['phonePublic']);
        expect(pairingBase64(screenKeys.publicKey), handover['screenPublic']);
        final onPhone = PlayHandover.of(own: phoneKeys, peerKey: screenKeys.publicKey, isPhone: true, session: phone)!;
        final onScreen = PlayHandover.of(
          own: screenKeys,
          peerKey: phoneKeys.publicKey,
          isPhone: false,
          session: screen,
        )!;
        expect(pairingBase64(onPhone.transcript), handover['transcript']);
        expect(pairingBase64(onScreen.transcript), handover['transcript']);
        expect(pairingBase64(onPhone.keys.confirm), handover['kConfirm']);
        expect(pairingBase64(onPhone.keys.up), handover['kUp']);
        expect(pairingBase64(onPhone.keys.down), handover['kDown']);
        expect(onPhone.check, handover['check']);
        expect(onScreen.check, handover['check']);
        final token = onScreen.channel(isPhone: false).open({
          'v': 1,
          'h': pairingBase64(onScreen.transcript.sublist(0, 8)),
          'n': handover['tokenNonce'],
          'c': handover['tokenSealed'],
        });
        expect(token, jsonDecode(utf8.decode(_b64(handover['tokenPlain']))));
      });
    }
  });

  group('channel', () {
    test('a message goes each way, with the version inside', () {
      final (:phone, :screen) = _pair();
      expect(screen.open(phone.seal({'type': 'play', 'item': '1'})), {'v': 1, 'type': 'play', 'item': '1'});
      expect(phone.open(screen.seal({'status': 'ok'})), {'v': 1, 'status': 'ok'});
      expect(phone.handle, screen.handle);
    });

    test('a replayed envelope does not open twice', () {
      final (:phone, :screen) = _pair();
      final envelope = phone.seal({'type': 'pause'});
      expect(screen.open(envelope), isNotNull);
      expect(screen.open(envelope), isNull);
    });

    test('envelopes that cross on the wire open once each, within the window', () {
      final (:phone, :screen) = _pair();
      final envelopes = [
        for (var i = 0; i < 10; i++) phone.seal({'n': i}),
      ];
      for (final index in [3, 0, 9, 1, 2, 8, 4, 7, 5, 6]) {
        expect(screen.open(envelopes[index]), {'v': 1, 'n': index}, reason: 'envelope $index');
      }
      for (final envelope in envelopes) {
        expect(screen.open(envelope), isNull);
      }
    });

    test('a counter 64 below the highest one seen is refused even unseen', () {
      final (:phone, :screen) = _pair();
      final old = phone.seal({'n': 'old'});
      final kept = [
        for (var i = 0; i < 63; i++) phone.seal({'n': i}),
      ];
      final last = phone.seal({'n': 'last'});
      expect(last['k'], 65);
      expect(screen.open(last), isNotNull);
      // Counter 1 is 64 below 65: out of the window. Counter 2 is 63 below: still opens.
      expect(screen.open(old), isNull);
      expect(screen.open(kept.first), isNotNull);
    });

    test('a changed byte, another counter, the wrong direction or another session do not open', () {
      final (:phone, :screen) = _pair();
      final envelope = phone.seal({'type': 'stop'});
      final sealed = _b64(envelope['c']);
      final changed = Uint8List.fromList(sealed)..[3] ^= 1;
      expect(screen.open({...envelope, 'c': pairingBase64(changed)}), isNull);
      expect(screen.open({...envelope, 'k': (envelope['k']! as int) + 1}), isNull);
      expect(screen.open({...envelope, 'k': 0}), isNull);
      expect(screen.open({...envelope, 's': 'AAAAAAAAAAA'}), isNull);
      // The phone's own envelope does not open on the phone: it is of the other direction
      expect(phone.open(envelope), isNull);
      // A session with another key, or with other nonces, does not open it
      final other = _pair(key: List.filled(32, 8));
      expect(other.screen.open({...envelope, 's': other.screen.handle}), isNull);
      final otherNonces = _pair(seed: 2);
      expect(otherNonces.screen.open({...envelope, 's': otherNonces.screen.handle}), isNull);
      // Still opens once it is the one sent
      expect(screen.open(envelope), isNotNull);
    });

    test('an envelope of another version or no object does not open', () {
      final (:phone, :screen) = _pair();
      const counter = 1;
      final sealed = playLinkSeal(
        keys: phone.keys,
        transcript: phone.transcript,
        direction: PairingDirection.up,
        counter: counter,
        plain: utf8.encode(jsonEncode({'v': 2, 'type': 'play'})),
      );
      expect(screen.open({'v': 1, 's': screen.handle, 'k': counter, 'c': pairingBase64(sealed)}), isNull);
      final list = playLinkSeal(
        keys: phone.keys,
        transcript: phone.transcript,
        direction: PairingDirection.up,
        counter: 2,
        plain: utf8.encode('[1]'),
      );
      expect(screen.open({'v': 1, 's': screen.handle, 'k': 2, 'c': pairingBase64(list)}), isNull);
      expect(screen.open({'v': 1, 's': screen.handle, 'k': '3', 'c': 'abc'}), isNull);
    });
  });

  group('replay window', () {
    test('each counter once, none below the window, counters above it move it', () {
      final window = PlayLinkReplayWindow();
      expect(window.accepts(0), isFalse);
      expect(window.accepts(5), isTrue);
      window.mark(5);
      expect(window.accepts(5), isFalse);
      expect(window.accepts(4), isTrue);
      window.mark(200);
      expect(window.accepts(4), isFalse);
      expect(window.accepts(137), isTrue);
      expect(window.accepts(136), isFalse);
      window.mark(137);
      expect(window.accepts(137), isFalse);
      window.mark(201);
      expect(window.accepts(137), isFalse);
      expect(window.accepts(200), isFalse);
      expect(window.accepts(199), isTrue);
    });
  });

  group('handover', () {
    test('both sides show the same check, and the token opens on the screen only', () {
      final (:phone, :screen) = _pair();
      final phoneKeys = PairingKeyPair.generate(Random(3));
      final screenKeys = PairingKeyPair.generate(Random(4));
      final onPhone = PlayHandover.of(own: phoneKeys, peerKey: screenKeys.publicKey, isPhone: true, session: phone)!;
      final onScreen = PlayHandover.of(own: screenKeys, peerKey: phoneKeys.publicKey, isPhone: false, session: screen)!;
      expect(onPhone.check, onScreen.check);
      expect(onPhone.check, matches(RegExp(r'^[0-9]{6}$')));
      final envelope = onPhone.channel(isPhone: true).seal({'token': 'secret-token'});
      expect(onScreen.channel(isPhone: false).open(envelope), {'token': 'secret-token'});
      // Not on the phone's side, which sends in the other direction
      expect(onPhone.channel(isPhone: true).open(envelope), isNull);
    });

    test('another session gives another check and keys', () {
      final first = _pair();
      final second = _pair(seed: 9);
      final phoneKeys = PairingKeyPair.generate(Random(3));
      final screenKeys = PairingKeyPair.generate(Random(4));
      final a = PlayHandover.of(own: phoneKeys, peerKey: screenKeys.publicKey, isPhone: true, session: first.phone)!;
      final b = PlayHandover.of(own: screenKeys, peerKey: phoneKeys.publicKey, isPhone: false, session: second.screen)!;
      expect(a.transcript, isNot(b.transcript));
      final envelope = a.channel(isPhone: true).seal({'token': 'secret-token'});
      expect(b.channel(isPhone: false).open(envelope), isNull);
    });

    test('a key that is no point of the curve gives no handover', () {
      final (:phone, screen: _) = _pair();
      final bad = Uint8List(33)..[0] = 2;
      bad.fillRange(1, 33, 0xff);
      expect(
        PlayHandover.of(own: PairingKeyPair.generate(Random(1)), peerKey: bad, isPhone: true, session: phone),
        isNull,
      );
    });
  });

  test('the TXT record names the kind player and the id', () {
    expect(playLinkAttributes(screenId: '0123456789abcdef', kind: PairingScreenKind.headset), {
      'v': '1',
      'kind': 'player',
      'sk': 'headset',
      'id': '0123456789abcdef',
      'pv': '1',
    });
    expect(isPlayLinkId('0123456789abcdef'), isTrue);
    expect(isPlayLinkId('0123456789ABCDEF'), isFalse);
    expect(isPlayLinkId('0123456789abcde'), isFalse);
    expect(isPlayLinkId(null), isFalse);
  });
}
