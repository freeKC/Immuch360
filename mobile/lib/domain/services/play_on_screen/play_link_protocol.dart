// "Play on the TV", protocol version 1: what a phone and a big screen (a TV, the Quest window, a computer) that were
// linked once agree on, without any network or platform code, so that both sides and the tests share it.
//
// Linking happens once, over "Sign in with your phone" (pairing_protocol.dart): after the check number, the phone
// sends a link key K of 32 random bytes, sealed under the keys of that hello, and both keep it in their secure
// storage with the id and the name of the other side. K never crosses the network again.
//
// Each connection of the phone to the screen's listener then proves both sides with fresh nonces:
//   GET  /v1/hello  gives {v, id: screenId, n: nonce_s} (16 random bytes, used once, alive 30 s)
//   POST /v1/open   {v, phone: phoneId, ns: nonce_s, np: nonce_p, proof: proof_p}, answered {v, s, proof: proof_s}
//   transcript  = SHA-256(lp("immuch360 player 1") lp(screenId) lp(phoneId) lp(nonce_s) lp(nonce_p)), lp() a two
//                 byte big endian length then the bytes
//   proof_p     = HMAC-SHA256(K, "phone" || transcript), proof_s = HMAC-SHA256(K, "screen" || transcript)
//   PRK         = HMAC-SHA256(key: transcript, K); K_up, K_down, K_handover = HMAC-SHA256(PRK, "up" | "down" |
//                 "handover" || 0x01)
//   s           = the first 8 bytes of the transcript, base64url: which session a command belongs to
// Every command after that (POST /v1/cmd) and every answer is sealed with a counter:
//   envelope    = {v, s, k: counter, c: AES-256-GCM(K_up or K_down, nonce, JSON)}
//   nonce       = direction byte (1 phone to screen, 2 screen to phone), three zero bytes, counter as 8 bytes
//   AD          = transcript || direction byte || counter as 8 bytes
// A counter is used once per direction: a replayed or a much older command does not open (a window of 64 lets the
// long poll of the status and a command cross on the wire). K has 256 bits: a recorded session gives nothing offline.
//
// "Add (server) to (screen)" moves a Plex token, and only with a fresh P-256 hello inside such a session, whose check
// number both sides show and both users accept (see PlayHandover): a link key alone never moves a token.
//
// test/fixtures/play_link/vectors.json holds known answers, made apart from this code (make_vectors.py).

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:pointycastle/export.dart';

/// The version of the protocol, in the TXT record and in every message
const playLinkProtocolVersion = 1;

/// The port the screen tries first: 8360 is the phone share, 8361 the pairing, 8362 the DJI relay
const playLinkDefaultPort = 8363;

/// The kind of the TXT record of the screen's listener, under the pairing type (no third service type)
const playLinkKind = 'player';

/// Bytes of a link key, of a nonce
const playLinkKeyBytes = 32;
const playLinkNonceBytes = 16;

/// How many counters below the highest one seen still open, once each
const playLinkReplayWindow = 64;

const _transcriptLabel = 'immuch360 player 1';
const _handoverLabel = 'immuch360 player handover 1';

/// The install id of a phone or a screen: 16 lower case hex digits
bool isPlayLinkId(Object? value) => value is String && RegExp(r'^[0-9a-f]{16}$').hasMatch(value);

/// The TXT record the screen's listener is announced with
Map<String, String> playLinkAttributes({required String screenId, required PairingScreenKind kind}) => {
  'v': '$pairingProtocolVersion',
  'kind': playLinkKind,
  'sk': kind.wire,
  'id': screenId,
  'pv': '$playLinkProtocolVersion',
};

Uint8List _lengthPrefixed(List<List<int>> fields) {
  final builder = BytesBuilder(copy: false);
  for (final bytes in fields) {
    builder
      ..addByte(bytes.length >> 8)
      ..addByte(bytes.length & 0xff)
      ..add(bytes);
  }
  return builder.takeBytes();
}

Uint8List _hmac(List<int> key, List<int> message) => Uint8List.fromList(Hmac(sha256, key).convert(message).bytes);

/// The hash of everything both sides sent to open a session, which its keys and every command are bound to
Uint8List playLinkTranscript({
  required String screenId,
  required String phoneId,
  required List<int> screenNonce,
  required List<int> phoneNonce,
}) => Uint8List.fromList(
  sha256
      .convert(
        _lengthPrefixed([
          utf8.encode(_transcriptLabel),
          utf8.encode(screenId),
          utf8.encode(phoneId),
          screenNonce,
          phoneNonce,
        ]),
      )
      .bytes,
);

/// Who proves: the phone first, then the screen
enum PlayLinkRole {
  phone('phone'),
  screen('screen');

  const PlayLinkRole(this.label);
  final String label;
}

/// What [role] sends to prove it holds the link key
Uint8List playLinkProof({required List<int> key, required PlayLinkRole role, required List<int> transcript}) =>
    _hmac(key, [...utf8.encode(role.label), ...transcript]);

/// The keys of one session
class PlayLinkKeys {
  const PlayLinkKeys({required this.up, required this.down, required this.handover});

  /// Phone to screen
  final Uint8List up;

  /// Screen to phone
  final Uint8List down;

  /// Mixed into the keys of a token handover (see PlayHandover)
  final Uint8List handover;

  Uint8List keyFor(PairingDirection direction) => direction == PairingDirection.up ? up : down;
}

/// HKDF-SHA256 with the transcript as salt over the link key
PlayLinkKeys derivePlayLinkKeys({required List<int> key, required List<int> transcript}) {
  final prk = _hmac(transcript, key);
  Uint8List expand(String info) => _hmac(prk, [...utf8.encode(info), 1]);
  return PlayLinkKeys(up: expand('up'), down: expand('down'), handover: expand('handover'));
}

Uint8List _counterBytes(int counter) {
  final bytes = ByteData(8)..setUint64(0, counter);
  return bytes.buffer.asUint8List();
}

/// The nonce of [counter] in [direction]
Uint8List playLinkNonce(PairingDirection direction, int counter) =>
    Uint8List.fromList([direction.byte, 0, 0, 0, ..._counterBytes(counter)]);

Uint8List _associatedData(List<int> transcript, PairingDirection direction, int counter) =>
    Uint8List.fromList([...transcript, direction.byte, ..._counterBytes(counter)]);

/// AES-256-GCM of [plain] with [counter] in [direction]; the tag ends the result
Uint8List playLinkSeal({
  required PlayLinkKeys keys,
  required List<int> transcript,
  required PairingDirection direction,
  required int counter,
  required List<int> plain,
}) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(
        KeyParameter(keys.keyFor(direction)),
        128,
        playLinkNonce(direction, counter),
        _associatedData(transcript, direction, counter),
      ),
    );
  return cipher.process(Uint8List.fromList(plain));
}

/// The plain text of [sealed], null when it does not decrypt (another key, another counter, a changed byte, another
/// direction)
Uint8List? playLinkOpen({
  required PlayLinkKeys keys,
  required List<int> transcript,
  required PairingDirection direction,
  required int counter,
  required Uint8List sealed,
}) {
  if (sealed.length < 16 || counter < 1) {
    return null;
  }
  try {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(keys.keyFor(direction)),
          128,
          playLinkNonce(direction, counter),
          _associatedData(transcript, direction, counter),
        ),
      );
    return cipher.process(sealed);
  } on InvalidCipherTextException {
    return null;
  } on ArgumentError {
    return null;
  }
}

/// The counters of the other side that opened already: each once, and none [playLinkReplayWindow] or more below the
/// highest one
class PlayLinkReplayWindow {
  int _highest = 0;

  /// Bit i: the counter _highest - i was seen
  BigInt _seen = BigInt.zero;

  static final _mask = (BigInt.one << playLinkReplayWindow) - BigInt.one;

  /// Whether [counter] may still open
  bool accepts(int counter) {
    if (counter < 1) {
      return false;
    }
    if (counter > _highest) {
      return true;
    }
    final age = _highest - counter;
    if (age >= playLinkReplayWindow) {
      return false;
    }
    return (_seen >> age) & BigInt.one == BigInt.zero;
  }

  /// [counter] opened: never again
  void mark(int counter) {
    if (counter > _highest) {
      final shift = counter - _highest;
      _seen = shift >= playLinkReplayWindow ? BigInt.zero : (_seen << shift) & _mask;
      _highest = counter;
      _seen |= BigInt.one;
      return;
    }
    _seen |= BigInt.one << (_highest - counter);
  }
}

/// The session handle of [transcript]
String playLinkHandle(List<int> transcript) => pairingBase64(transcript.sublist(0, 8));

/// One side of one session: seals and opens its JSON messages, each counter once
class PlayLinkChannel {
  PlayLinkChannel({required this.transcript, required this.keys, required this.sends});

  final Uint8List transcript;
  final PlayLinkKeys keys;

  /// Up on the phone, down on the screen
  final PairingDirection sends;
  int _sent = 0;
  final _received = PlayLinkReplayWindow();

  PairingDirection get _receives => sends == PairingDirection.up ? PairingDirection.down : PairingDirection.up;

  String get handle => playLinkHandle(transcript);

  /// {v, s, k, c} for [message]
  Map<String, Object> seal(Map<String, Object?> message) {
    final counter = ++_sent;
    final sealed = playLinkSeal(
      keys: keys,
      transcript: transcript,
      direction: sends,
      counter: counter,
      plain: utf8.encode(jsonEncode({'v': playLinkProtocolVersion, ...message})),
    );
    return {'v': playLinkProtocolVersion, 's': handle, 'k': counter, 'c': pairingBase64(sealed)};
  }

  /// The JSON object an envelope of the other side holds, null when it does not decrypt, was opened before, is too
  /// old, or is not an object of this version
  Map<String, Object?>? open(Map<String, Object?> envelope) {
    final counter = envelope['k'];
    final sealed = pairingDecodeBase64(envelope['c']);
    if (envelope['s'] != handle || counter is! int || sealed == null || !_received.accepts(counter)) {
      return null;
    }
    final plain = playLinkOpen(
      keys: keys,
      transcript: transcript,
      direction: _receives,
      counter: counter,
      sealed: sealed,
    );
    if (plain == null) {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(plain));
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?> || decoded['v'] != playLinkProtocolVersion) {
      return null;
    }
    _received.mark(counter);
    return decoded;
  }
}

/// The hash of a token handover inside the session of [sessionTranscript]
Uint8List playHandoverTranscript({
  required List<int> sessionTranscript,
  required List<int> phoneKey,
  required List<int> screenKey,
}) => Uint8List.fromList(
  sha256.convert(_lengthPrefixed([utf8.encode(_handoverLabel), sessionTranscript, phoneKey, screenKey])).bytes,
);

/// One side of a token handover: a fresh P-256 hello inside a session, whose check number both sides show. The keys
/// come from the ECDH secret and the handover key of the session (pairing v1's derivation, the session key in place
/// of the code); the token goes sealed under them (PairingChannel), and only once both users accepted.
class PlayHandover {
  PlayHandover._({required this.transcript, required this.keys, required this.check});

  /// The handover of the side that made [own] and got [peerKey]; null when that is no point of the curve
  static PlayHandover? of({
    required PairingKeyPair own,
    required Uint8List peerKey,
    required bool isPhone,
    required PlayLinkChannel session,
  }) {
    final shared = own.agree(peerKey);
    if (shared == null) {
      return null;
    }
    final transcript = playHandoverTranscript(
      sessionTranscript: session.transcript,
      phoneKey: isPhone ? own.publicKey : peerKey,
      screenKey: isPhone ? peerKey : own.publicKey,
    );
    final keys = derivePairingKeys(shared: shared, secret: session.keys.handover, transcript: transcript);
    return PlayHandover._(
      transcript: transcript,
      keys: keys,
      check: pairingCheckNumber(confirmKey: keys.confirm, transcript: transcript),
    );
  }

  final Uint8List transcript;
  final PairingKeys keys;

  /// The six digits both sides show
  final String check;

  PairingChannel channel({required bool isPhone}) =>
      PairingChannel(transcript: transcript, keys: keys, sends: isPhone ? PairingDirection.up : PairingDirection.down);
}
