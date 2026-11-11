// Linking a phone and a big screen for "Play on the TV", over a hello of "Sign in with your phone": after the check
// number, the phone adds to its sealed message {link: {phone: {id, name}, key}}, a key of 32 random bytes it made,
// and the screen answers {link: {status: linked, screen: {id, name, kind}}} under the keys of the same hello. Both
// keep the key (play_links.provider.dart); it never crosses the network again.
//
// Two ways: at the end of a sign in (one switch on the phone's sheet, on by default), the link rides the same message
// as the session; or alone, from "Play from a phone" on the screen, whose pairing panel then says purpose=link in the
// device bytes of its hello (which its proof covers): the phone sends the link only, no session.

import 'dart:math';
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_server.dart';
import 'package:logging/logging.dart';

final _log = Logger('PlayLinkPairing');

/// The value of "purpose" in the device bytes of a screen whose panel links a phone without signing in
const pairingPurposeLink = 'link';

/// What the phone adds to its sealed message to link the screen
class PlayLinkOffer {
  PlayLinkOffer({required this.phoneId, required this.phoneName, Random? random})
    : key = pairingRandomBytes(playLinkKeyBytes, random);

  final String phoneId;
  final String phoneName;

  /// Secret, never logged
  final Uint8List key;

  Map<String, Object?> toJson() => {
    'phone': {'id': phoneId, 'name': phoneName},
    'key': pairingBase64(key),
  };

  /// The screen [answer] (the "link" of the screen's sealed answer) names, null when it did not link
  LinkedPeer? accepted(Object? answer, {required DateTime now}) {
    if (answer is! Map || answer['status'] != 'linked') {
      return null;
    }
    final screen = answer['screen'];
    if (screen is! Map || !isPlayLinkId(screen['id'])) {
      return null;
    }
    final name = screen['name'];
    final cleaned = name is String ? cleanPairingText(name) : '';
    return LinkedPeer(
      id: screen['id'] as String,
      name: cleaned.isEmpty ? 'TV' : (cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned),
      key: key,
      linkedAt: now,
      kind: PairingScreenKind.fromWire(screen['kind']),
    );
  }

  @override
  String toString() => 'PlayLinkOffer';
}

/// This screen, as the link answer names it
typedef PlayLinkScreen = ({String id, String name, PairingScreenKind kind});

/// The screen's side: a sign in that also takes a link, or a link alone ([linkOnly])
class LinkingPairingSignIn implements PairingSignIn {
  LinkingPairingSignIn({
    required this.screen,
    required this.keep,
    this.inner,
    this.linkOnly = false,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The sign in of the screen; null with [linkOnly]
  final PairingSignIn? inner;
  final bool linkOnly;
  final Future<PlayLinkScreen> Function() screen;

  /// Keeps the phone in the list of the screen
  final Future<void> Function(LinkedPeer phone) keep;
  final DateTime Function() _clock;

  /// The name of the phone linked last, for the panel's toast
  String? linkedPhone;

  static const _invalid = PairingSignInResult(answer: {'status': 'invalid'}, signedIn: false);

  @override
  Future<PairingSignInResult> withSession(Map<String, Object?> payload) async {
    final link = payload['link'];
    if (linkOnly) {
      final answer = await _link(link);
      if (answer == null) {
        return _invalid;
      }
      return PairingSignInResult(answer: {'status': 'linked', 'link': answer}, signedIn: true);
    }
    final signIn = inner;
    if (signIn == null) {
      return _invalid;
    }
    final result = await signIn.withSession(payload);
    if (!result.signedIn || link == null) {
      return result;
    }
    final answer = await _link(link);
    return PairingSignInResult(
      answer: {...result.answer, 'link': ?answer},
      signedIn: result.signedIn,
      retry: result.retry,
      notice: result.notice,
      detail: result.detail,
    );
  }

  @override
  Future<PairingSignInResult> withPassword(Map<String, Object?> credentials) {
    final signIn = inner;
    // The browser page signs a screen in; it links nothing
    if (linkOnly || signIn == null) {
      return Future.value(_invalid);
    }
    return signIn.withPassword(credentials);
  }

  /// Keeps the phone [link] names; the answer for it, null when the link is not one
  Future<Map<String, Object?>?> _link(Object? link) async {
    if (link is! Map) {
      return null;
    }
    final phone = link['phone'];
    final key = pairingDecodeBase64(link['key']);
    if (phone is! Map || !isPlayLinkId(phone['id']) || key == null || key.length != playLinkKeyBytes) {
      return null;
    }
    final rawName = phone['name'];
    final cleaned = rawName is String ? cleanPairingText(rawName) : '';
    final name = cleaned.isEmpty ? 'Phone' : (cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned);
    try {
      await keep(LinkedPeer(id: phone['id'] as String, name: name, key: key, linkedAt: _clock()));
      final self = await screen();
      linkedPhone = name;
      _log.info('Play on the TV: a phone is linked');
      return {
        'status': 'linked',
        'screen': {'id': self.id, 'name': self.name, 'kind': self.kind.wire},
      };
    } catch (error) {
      _log.warning('Play on the TV: the link was not kept: ${error.runtimeType}');
      return null;
    }
  }
}
