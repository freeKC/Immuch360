// Linking a phone and a screen for "Play on the TV" over a hello of "Sign in with your phone": the screen's side
// (LinkingPairingSignIn, with or without a sign in) and what the phone keeps of the answer (PlayLinkOffer)

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_pairing.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_server.dart';

const _screenId = '0123456789abcdef';
const _phoneId = 'fedcba9876543210';

/// The sign in of the screen, answering [result]
class _FakeSignIn implements PairingSignIn {
  _FakeSignIn(this.result);

  final PairingSignInResult result;
  final sessions = <Map<String, Object?>>[];
  var passwords = 0;

  @override
  Future<PairingSignInResult> withSession(Map<String, Object?> payload) async {
    sessions.add(payload);
    return result;
  }

  @override
  Future<PairingSignInResult> withPassword(Map<String, Object?> credentials) async {
    passwords++;
    return result;
  }
}

Map<String, Object?> _link({Object? id = _phoneId, int keyLength = playLinkKeyBytes, Object? name = 'Galaxy S24+'}) => {
  'phone': {'id': id, 'name': name},
  'key': pairingBase64(Uint8List.fromList(List.filled(keyLength, 9))),
};

void main() {
  final at = DateTime.utc(2026, 11, 10, 23, 30);
  late List<LinkedPeer> kept;

  LinkingPairingSignIn linking({PairingSignIn? inner, bool linkOnly = false}) => LinkingPairingSignIn(
    inner: inner,
    linkOnly: linkOnly,
    screen: () async => (id: _screenId, name: 'Living room TV', kind: PairingScreenKind.tv),
    keep: (phone) async => kept.add(phone),
    clock: () => at,
  );

  setUp(() => kept = []);

  group('a link alone (Play from a phone)', () {
    test('keeps the phone and answers with the screen', () async {
      final signIn = linking(linkOnly: true);
      final result = await signIn.withSession({'link': _link()});
      expect(result.signedIn, isTrue);
      expect(result.answer['status'], 'linked');
      expect(result.answer['link'], {
        'status': 'linked',
        'screen': {'id': _screenId, 'name': 'Living room TV', 'kind': 'tv'},
      });
      expect(kept, hasLength(1));
      expect(kept.single.id, _phoneId);
      expect(kept.single.name, 'Galaxy S24+');
      expect(kept.single.key, List.filled(playLinkKeyBytes, 9));
      expect(kept.single.linkedAt, at);
      expect(signIn.linkedPhone, 'Galaxy S24+');
    });

    test('a name with format characters is cleaned, a missing one named Phone', () async {
      final signIn = linking(linkOnly: true);
      await signIn.withSession({'link': _link(name: 'Gal\u202Eaxy\n')});
      await signIn.withSession({'link': _link(name: 7)});
      expect(kept.map((phone) => phone.name), ['Galaxy', 'Phone']);
    });

    for (final (what, link) in [
      ('a bad id', _link(id: 'FEDCBA9876543210')),
      ('a short id', _link(id: 'fedcba98')),
      ('a short key', _link(keyLength: 16)),
      ('no phone', {'key': pairingBase64(Uint8List(32))}),
      ('no link', null),
    ]) {
      test('refuses $what and keeps nothing', () async {
        final signIn = linking(linkOnly: true);
        final result = await signIn.withSession({'link': ?link, 'token': 'never used here'});
        expect(result.signedIn, isFalse);
        expect(result.answer, {'status': 'invalid'});
        expect(kept, isEmpty);
        expect(signIn.linkedPhone, isNull);
      });
    }

    test('the browser page signs nothing in', () async {
      final inner = _FakeSignIn(const PairingSignInResult(answer: {'status': 'signedIn'}, signedIn: true));
      final result = await linking(inner: inner, linkOnly: true).withPassword({'email': 'a@b.c', 'password': 'x'});
      expect(result.signedIn, isFalse);
      expect(inner.passwords, 0);
    });

    test('a link that cannot be kept answers invalid', () async {
      final signIn = LinkingPairingSignIn(
        linkOnly: true,
        screen: () async => (id: _screenId, name: 'TV', kind: PairingScreenKind.tv),
        keep: (_) async => throw StateError('no storage'),
      );
      final result = await signIn.withSession({'link': _link()});
      expect(result.signedIn, isFalse);
      expect(signIn.linkedPhone, isNull);
    });
  });

  group('a link with a sign in', () {
    test('rides the answer of a sign in that worked', () async {
      final inner = _FakeSignIn(
        const PairingSignInResult(answer: {'status': 'signedIn', 'label': 'Lounge'}, signedIn: true),
      );
      final result = await linking(inner: inner).withSession({'token': 'session-token', 'link': _link()});
      expect(inner.sessions.single['token'], 'session-token');
      expect(result.signedIn, isTrue);
      expect(result.answer['status'], 'signedIn');
      expect(result.answer['label'], 'Lounge');
      expect((result.answer['link']! as Map)['status'], 'linked');
      expect(kept.single.id, _phoneId);
    });

    test('a sign in that failed links nothing and keeps its outcome', () async {
      final inner = _FakeSignIn(const PairingSignInResult(answer: {'status': 'tokenRejected'}, signedIn: false));
      final result = await linking(inner: inner).withSession({'token': 'session-token', 'link': _link()});
      expect(result.signedIn, isFalse);
      expect(result.answer, {'status': 'tokenRejected'});
      expect(kept, isEmpty);
    });

    test('a sign in without a link is the sign in as it was', () async {
      const signedIn = PairingSignInResult(answer: {'status': 'signedIn'}, signedIn: true);
      final result = await linking(inner: _FakeSignIn(signedIn)).withSession({'token': 'session-token'});
      expect(identical(result, signedIn), isTrue);
      expect(kept, isEmpty);
    });

    test('a broken link does not undo the sign in', () async {
      final inner = _FakeSignIn(const PairingSignInResult(answer: {'status': 'signedIn'}, signedIn: true));
      final result = await linking(inner: inner).withSession({'token': 'x', 'link': _link(keyLength: 3)});
      expect(result.signedIn, isTrue);
      expect(result.answer.containsKey('link'), isFalse);
      expect(kept, isEmpty);
    });

    test('the browser page goes to the sign in', () async {
      final inner = _FakeSignIn(const PairingSignInResult(answer: {'status': 'signedIn'}, signedIn: true));
      final result = await linking(inner: inner).withPassword({'email': 'a@b.c', 'password': 'x'});
      expect(result.signedIn, isTrue);
      expect(inner.passwords, 1);
    });
  });

  group('the phone keeps what the screen answered', () {
    final offer = PlayLinkOffer(phoneId: _phoneId, phoneName: 'Galaxy S24+', random: Random(3));

    test('its offer holds a fresh key of 32 bytes, never in its text', () {
      final json = offer.toJson();
      expect(json['phone'], {'id': _phoneId, 'name': 'Galaxy S24+'});
      expect(pairingDecodeBase64(json['key']), offer.key);
      expect(offer.key, hasLength(playLinkKeyBytes));
      expect(offer.toString(), isNot(contains(pairingBase64(offer.key))));
      expect(PlayLinkOffer(phoneId: _phoneId, phoneName: 'x').key, isNot(offer.key));
    });

    test('a linked screen, with the key of the offer', () {
      final screen = offer.accepted({
        'status': 'linked',
        'screen': {'id': _screenId, 'name': 'Living room TV', 'kind': 'headset'},
      }, now: at);
      expect(screen?.id, _screenId);
      expect(screen?.name, 'Living room TV');
      expect(screen?.kind, PairingScreenKind.headset);
      expect(screen?.key, offer.key);
      expect(screen?.linkedAt, at);
    });

    test('a long name is cut, a missing one is TV', () {
      final long = offer.accepted({
        'status': 'linked',
        'screen': {'id': _screenId, 'name': 'N' * 100},
      }, now: at);
      expect(long?.name, 'N' * 64);
      expect(long?.kind, PairingScreenKind.tv);
      final unnamed = offer.accepted({
        'status': 'linked',
        'screen': {'id': _screenId},
      }, now: at);
      expect(unnamed?.name, 'TV');
    });

    for (final (what, answer) in [
      (
        'another status',
        {
          'status': 'invalid',
          'screen': {'id': _screenId},
        },
      ),
      (
        'a bad id',
        {
          'status': 'linked',
          'screen': {'id': 'not-an-id'},
        },
      ),
      ('no screen', {'status': 'linked'}),
      ('nothing', null),
    ]) {
      test('nothing for $what', () => expect(offer.accepted(answer, now: at), isNull));
    }
  });
}
