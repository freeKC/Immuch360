// "Sign in with your phone", protocol version 1: what the big screen (a TV, the Quest window, a computer) and the phone
// that signs it in agree on, without any network or platform code, so that both sides and the tests share it.
//
// The big screen shows a QR code, http://<its private IPv4>:<port>/p#1.<id>.<S>, and a short code C of 10 symbols.
// The fragment never leaves the phone in an HTTP request, and C is only on the screen. Each side makes a temporary
// P-256 key pair; the keys are derived with HKDF-SHA256 from the ECDH secret and S (or C), salted with a hash of
// everything both sides sent (the transcript), and every message after the hello goes under AES-256-GCM. The screen
// proves it knows the secret first (confirm), so that a device that only pretends to be the screen gets nothing.
//
// Wire formats (base64url without padding everywhere):
//   transcript = SHA-256(lp("immuch360 pairing 1") lp(id) lp(mode) lp(client) lp(phone key) lp(screen key)), where
//                lp() is a two byte big endian length then the bytes, and the keys are compressed points (33 bytes)
//   PRK        = HMAC-SHA256(key: transcript, Z || secret), Z the x coordinate of the ECDH point (32 bytes), secret
//                the 16 bytes of S, or the UTF-8 of the normalised code
//   K_confirm, K_up, K_down = HMAC-SHA256(PRK, "confirm" | "up" | "down" || 0x01) (HKDF-Expand to 32 bytes)
//   confirm    = HMAC-SHA256(K_confirm, "screen" || transcript || the device bytes the screen sent)
//   AEAD       = AES-256-GCM, 12 byte random nonce, associated data transcript || 0x01 (phone to screen, K_up) or
//                transcript || 0x02 (screen to phone, K_down)
//   check      = the first four bytes of HMAC-SHA256(K_confirm, "check" || transcript), big endian, modulo 10^6: the six
//                digits both sides show, never sent
// test/fixtures/pairing/vectors.json holds known answers, made apart from this code (make_vectors.py).

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// The version of the protocol, first in the fragment of the QR code and in every message
const pairingProtocolVersion = 1;

/// The port the big screen tries first; 8360 is the phone share
const pairingDefaultPort = 8361;

/// The DNS-SD type the big screen announces while it shows a code
const pairingServiceType = '_immuch360-pair._tcp';

/// The symbols of the short code, those of the LG webOS app: no 0, O, 1, I nor L, which read alike
const pairingCodeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const pairingCodeLength = 10;

/// Bytes of the pairing id (not secret) and of the secret of the QR code
const pairingIdBytes = 8;
const pairingSecretBytes = 16;

/// The ports of the LG webOS app's own pairing (webos/service/lib/pairing.js), whose codes the phone recognises
const webOsPairingPorts = [8788, 8789, 8790, 8791, 8792];

const _transcriptLabel = 'immuch360 pairing 1';

/// How the phone learnt the secret
enum PairingMode {
  /// Scanned the QR code: the secret is S
  qr('qr'),

  /// Typed the short code: the secret is the code
  code('code');

  const PairingMode(this.wire);
  final String wire;

  static PairingMode? fromWire(Object? value) => switch (value) {
    'qr' => PairingMode.qr,
    'code' => PairingMode.code,
    _ => null,
  };
}

/// Who signs the screen in: Immuch360 on a phone (a session of the phone's account), or the browser page the screen
/// serves (an email and a password)
enum PairingClient {
  app('app'),
  web('web');

  const PairingClient(this.wire);
  final String wire;

  static PairingClient? fromWire(Object? value) => switch (value) {
    'app' => PairingClient.app,
    'web' => PairingClient.web,
    _ => null,
  };
}

/// What kind of big screen shows the code: the texts and the icons follow it
enum PairingScreenKind {
  tv('tv'),
  headset('headset'),
  computer('computer');

  const PairingScreenKind(this.wire);
  final String wire;

  static PairingScreenKind fromWire(Object? value) => switch (value) {
    'headset' => PairingScreenKind.headset,
    'computer' => PairingScreenKind.computer,
    _ => PairingScreenKind.tv,
  };
}

/// The direction of an encrypted message, the last byte of its associated data
enum PairingDirection {
  /// Phone (or browser page) to screen, under K_up
  up(1),

  /// Screen to phone, under K_down
  down(2);

  const PairingDirection(this.byte);
  final int byte;
}

String pairingBase64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Decodes base64url without padding; null for anything else (padding, other symbols, a wrong length)
Uint8List? pairingDecodeBase64(Object? text) {
  if (text is! String || !RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(text) || text.length % 4 == 1) {
    return null;
  }
  try {
    return base64Url.decode(text.padRight((text.length + 3) ~/ 4 * 4, '='));
  } on FormatException {
    return null;
  }
}

Uint8List pairingRandomBytes(int length, [Random? random]) {
  final source = random ?? Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => source.nextInt(256)));
}

/// A new short code: [pairingCodeLength] symbols of [pairingCodeAlphabet], about 49.5 bits
String newPairingCode([Random? random]) {
  final source = random ?? Random.secure();
  return String.fromCharCodes(
    List.generate(pairingCodeLength, (_) => pairingCodeAlphabet.codeUnitAt(source.nextInt(pairingCodeAlphabet.length))),
  );
}

/// The code as typed, in capitals and without its spaces and dashes; null when it cannot be a code. "o", "0", "i",
/// "1" and "l" are refused rather than guessed: the alphabet has none of them.
String? normalizePairingCode(String typed) {
  final code = typed.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
  if (code.length != pairingCodeLength || code.split('').any((symbol) => !pairingCodeAlphabet.contains(symbol))) {
    return null;
  }
  return code;
}

// Format characters (bidi overrides and isolates, zero width ones), surrogates and private use: dropped
final _invisibleCharacters = RegExp(r'[\p{Cf}\p{Cs}\p{Co}]', unicode: true);
// Controls and line or paragraph separators: a space
final _breakingCharacters = RegExp(r'[\p{Cc}\p{Zl}\p{Zp}]', unicode: true);

/// A name a device gives itself or the user types, on one line and as it reads: no control, no format character (a
/// right to left override could make "VT moor gniviL" read as another name), spaces collapsed
String cleanPairingText(String text) => text
    .replaceAll(_invisibleCharacters, '')
    .replaceAll(_breakingCharacters, ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// The code as the screen shows it, in two groups of five: "K7M2Q 9XRTH"
String formatPairingCode(String code) =>
    code.length == pairingCodeLength ? '${code.substring(0, 5)} ${code.substring(5)}' : code;

/// Whether [host] is an IPv4 literal, written the plain way (four decimal numbers without leading zeros), of a
/// private range: 10/8, 172.16/12, 192.168/16 or link-local 169.254/16. Nothing else may receive a session.
bool isPrivatePairingIPv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) {
    return false;
  }
  final bytes = <int>[];
  for (final part in parts) {
    if (!RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part)) {
      return false;
    }
    final value = int.parse(part);
    if (value > 255) {
      return false;
    }
    bytes.add(value);
  }
  return bytes[0] == 10 ||
      (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] < 32) ||
      (bytes[0] == 192 && bytes[1] == 168) ||
      (bytes[0] == 169 && bytes[1] == 254);
}

/// The text of the QR code
String buildPairingQrText({required String host, required int port, required String id, required List<int> secret}) =>
    'http://$host:$port/p#$pairingProtocolVersion.$id.${pairingBase64(secret)}';

/// The address the screen shows under its code, for a browser typed by hand
String buildPairingTypedUrl({required String host, required int port}) => 'http://$host:$port/p';

/// The address of a screen as the user typed it from the screen ("192.168.1.23:8361", "http://192.168.1.23:8361/p"):
/// its host and port when the host is a private IPv4 literal, else null. The port is 8361 when none is written.
({String host, int port})? parsePairingAddress(String typed) {
  var text = typed.trim();
  if (text.isEmpty || text.length > 64) {
    return null;
  }
  if (!text.contains('://')) {
    text = 'http://$text';
  }
  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException {
    return null;
  }
  if (uri.scheme != 'http' || uri.userInfo.isNotEmpty || !isPrivatePairingIPv4(uri.host)) {
    return null;
  }
  if (uri.path.isNotEmpty && uri.path != '/' && uri.path != '/p') {
    return null;
  }
  final hasPort = RegExp(r'^http://[0-9.]+:[0-9]{1,5}(/|$)').hasMatch(text);
  final port = hasPort ? uri.port : pairingDefaultPort;
  return port < 1 || port > 65535 ? null : (host: uri.host, port: port);
}

/// The address of the screen an `immuch360://pair?u=<address>` link names (the "Open it" link of the browser page a
/// screen serves), null for anything else. A secret in the link is never used: a link may come from anywhere, so the
/// phone scans the code on the screen, or asks for the code it shows, before it says anything to that address.
({String host, int port})? parsePairingLink(String link) {
  final Uri uri;
  try {
    uri = Uri.parse(link.trim());
  } on FormatException {
    return null;
  }
  final inner = uri.scheme == 'immuch360' && uri.host == 'pair' ? uri.queryParameters['u'] : null;
  if (inner == null) {
    return null;
  }
  final fragment = inner.indexOf('#');
  return parsePairingAddress(fragment < 0 ? inner : inner.substring(0, fragment));
}

/// What a scanned text turned out to be
sealed class PairingScan {
  const PairingScan();
}

/// A code of an Immuch360 big screen
class PairingTarget extends PairingScan {
  const PairingTarget({required this.host, required this.port, required this.id, this.secret, this.code});

  /// A private IPv4 literal
  final String host;
  final int port;
  final String id;

  /// S, from a QR code
  final Uint8List? secret;

  /// The normalised short code, when typed
  final String? code;

  PairingMode get mode => secret != null ? PairingMode.qr : PairingMode.code;

  /// The bytes mixed into the keys
  Uint8List get secretBytes => secret ?? Uint8List.fromList(utf8.encode(code!));

  PairingTarget withCode(String normalizedCode) => PairingTarget(host: host, port: port, id: id, code: normalizedCode);

  // Never the secret nor the code: this ends up in logs
  @override
  String toString() => 'PairingTarget($mode)';
}

/// The pairing code of the LG webOS app (`http://<tv>:8788/?c=...`): it signs in through a browser
class WebOsPairingLink extends PairingScan {
  const WebOsPairingLink(this.uri);
  final Uri uri;

  @override
  String toString() => 'WebOsPairingLink';
}

/// Anything else
class NotAPairingCode extends PairingScan {
  const NotAPairingCode();
}

final _fragment = RegExp(r'^1\.([A-Za-z0-9_-]{11})\.([A-Za-z0-9_-]{22})$');

/// Reads a scanned (or deep linked) text. Only the exact form of [buildPairingQrText] on a private IPv4 address is a
/// [PairingTarget], also wrapped as `immuch360://pair?u=<that text>`.
PairingScan parsePairingText(String text, {bool unwrapped = false}) {
  final trimmed = text.trim();
  if (trimmed.length > 512) {
    return const NotAPairingCode();
  }
  final Uri uri;
  try {
    uri = Uri.parse(trimmed);
  } on FormatException {
    return const NotAPairingCode();
  }
  if (!unwrapped && uri.scheme == 'immuch360' && uri.host == 'pair') {
    final inner = uri.queryParameters['u'];
    return inner == null ? const NotAPairingCode() : parsePairingText(inner, unwrapped: true);
  }
  if (uri.scheme != 'http' || uri.userInfo.isNotEmpty || !isPrivatePairingIPv4(uri.host)) {
    return const NotAPairingCode();
  }
  // Uri gives 80 for a missing port: the screen always writes its port
  if (!RegExp(r'^http://[0-9.]+:[0-9]{1,5}/').hasMatch(trimmed)) {
    return const NotAPairingCode();
  }
  if (webOsPairingPorts.contains(uri.port) &&
      (uri.path.isEmpty || uri.path == '/') &&
      (uri.queryParameters['c'] ?? '').isNotEmpty) {
    return WebOsPairingLink(uri);
  }
  if (uri.port < 1 || uri.port > 65535 || uri.path != '/p' || uri.hasQuery || !uri.hasFragment) {
    return const NotAPairingCode();
  }
  final match = _fragment.firstMatch(uri.fragment);
  final secret = match == null ? null : pairingDecodeBase64(match.group(2));
  if (match == null || secret == null || secret.length != pairingSecretBytes) {
    return const NotAPairingCode();
  }
  return PairingTarget(host: uri.host, port: uri.port, id: match.group(1)!, secret: secret);
}

// Keys

final ECDomainParameters _curve = ECCurve_prime256v1();

/// A temporary P-256 key pair, thrown away with its pairing
class PairingKeyPair {
  PairingKeyPair._(this._private, this.publicKey);

  final BigInt _private;

  /// The compressed point, 33 bytes
  final Uint8List publicKey;

  /// A new key pair from [random] (a secure one by default)
  factory PairingKeyPair.generate([Random? random]) {
    final source = random ?? Random.secure();
    final n = _curve.n;
    while (true) {
      final scalar = _bigIntOf(pairingRandomBytes(32, source));
      if (scalar > BigInt.zero && scalar < n) {
        return PairingKeyPair.fromPrivate(scalar);
      }
    }
  }

  factory PairingKeyPair.fromPrivate(BigInt scalar) {
    final point = (_curve.G * scalar)!;
    return PairingKeyPair._(scalar, point.getEncoded(true));
  }

  /// The x coordinate of the ECDH point with [peerPublicKey], 32 bytes; null when that is not a compressed point of
  /// the curve
  Uint8List? agree(Uint8List peerPublicKey) {
    final peer = decodePairingPublicKey(peerPublicKey);
    if (peer == null) {
      return null;
    }
    final shared = (peer * _private)!;
    if (shared.isInfinity) {
      return null;
    }
    return _bytesOf(shared.x!.toBigInteger()!, 32);
  }
}

/// The point of a compressed public key (33 bytes, 02 or 03 first), null for anything else
ECPoint? decodePairingPublicKey(Uint8List bytes) {
  if (bytes.length != 33 || (bytes[0] != 2 && bytes[0] != 3)) {
    return null;
  }
  try {
    final point = _curve.curve.decodePoint(bytes);
    return point == null || point.isInfinity ? null : point;
  } catch (_) {
    // Not on the curve
    return null;
  }
}

BigInt _bigIntOf(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

Uint8List _bytesOf(BigInt value, int length) {
  final bytes = Uint8List(length);
  var rest = value;
  for (var i = length - 1; i >= 0; i--) {
    bytes[i] = (rest & BigInt.from(0xff)).toInt();
    rest = rest >> 8;
  }
  return bytes;
}

/// The hash of everything both sides sent in the hello, which every key and message is bound to
Uint8List pairingTranscript({
  required String id,
  required PairingMode mode,
  required PairingClient client,
  required List<int> phoneKey,
  required List<int> screenKey,
}) {
  final builder = BytesBuilder(copy: false);
  void field(List<int> bytes) {
    builder
      ..addByte(bytes.length >> 8)
      ..addByte(bytes.length & 0xff)
      ..add(bytes);
  }

  field(utf8.encode(_transcriptLabel));
  field(utf8.encode(id));
  field(utf8.encode(mode.wire));
  field(utf8.encode(client.wire));
  field(phoneKey);
  field(screenKey);
  return Uint8List.fromList(sha256.convert(builder.takeBytes()).bytes);
}

/// The three keys of one hello
class PairingKeys {
  const PairingKeys({required this.confirm, required this.up, required this.down});

  final Uint8List confirm;
  final Uint8List up;
  final Uint8List down;

  Uint8List keyFor(PairingDirection direction) => direction == PairingDirection.up ? up : down;
}

Uint8List _hmac(List<int> key, List<int> message) => Uint8List.fromList(Hmac(sha256, key).convert(message).bytes);

/// HKDF-SHA256 with the transcript as salt over the ECDH secret and the pairing secret
PairingKeys derivePairingKeys({required List<int> shared, required List<int> secret, required List<int> transcript}) {
  final prk = _hmac(transcript, [...shared, ...secret]);
  Uint8List expand(String info) => _hmac(prk, [...utf8.encode(info), 1]);
  return PairingKeys(confirm: expand('confirm'), up: expand('up'), down: expand('down'));
}

/// What the screen sends to prove it knows the secret, over the device bytes it sent
Uint8List pairingConfirm({required List<int> confirmKey, required List<int> transcript, required List<int> device}) =>
    _hmac(confirmKey, [...utf8.encode('screen'), ...transcript, ...device]);

/// The six digits the phone and the screen both show once a hello is done, so that the user sees that the phone talks
/// to the screen in front of them: HMAC-SHA256(K_confirm, "check" || transcript), its first four bytes as a big
/// endian number, modulo a million. Only a device that knows the secret and took this very hello can show it.
String pairingCheckNumber({required List<int> confirmKey, required List<int> transcript}) {
  final mac = _hmac(confirmKey, [...utf8.encode('check'), ...transcript]);
  final value = ((mac[0] << 24) | (mac[1] << 16) | (mac[2] << 8) | mac[3]) % 1000000;
  return value.toString().padLeft(6, '0');
}

/// The check number as both sides show it: "482 913"
String formatPairingCheckNumber(String digits) =>
    digits.length == 6 ? '${digits.substring(0, 3)} ${digits.substring(3)}' : digits;

/// Compares in a time that does not depend on where [a] and [b] differ
bool pairingSameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

Uint8List _associatedData(List<int> transcript, PairingDirection direction) =>
    Uint8List.fromList([...transcript, direction.byte]);

/// AES-256-GCM of [plain] under the key of [direction]; the tag ends the result
Uint8List pairingSeal({
  required PairingKeys keys,
  required List<int> transcript,
  required PairingDirection direction,
  required Uint8List nonce,
  required List<int> plain,
}) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(KeyParameter(keys.keyFor(direction)), 128, nonce, _associatedData(transcript, direction)),
    );
  return cipher.process(Uint8List.fromList(plain));
}

/// The plain text of [sealed], null when it does not decrypt (another key, a changed byte, another direction)
Uint8List? pairingOpen({
  required PairingKeys keys,
  required List<int> transcript,
  required PairingDirection direction,
  required Uint8List nonce,
  required Uint8List sealed,
}) {
  if (nonce.length != 12 || sealed.length < 16) {
    return null;
  }
  try {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(KeyParameter(keys.keyFor(direction)), 128, nonce, _associatedData(transcript, direction)),
      );
    return cipher.process(sealed);
  } on InvalidCipherTextException {
    return null;
  } on ArgumentError {
    return null;
  }
}

/// One side of one hello once both keys are known: seals and opens the JSON messages of its pairing
class PairingChannel {
  PairingChannel({required this.transcript, required this.keys, required this.sends, Random? random})
    : _random = random ?? Random.secure();

  final Uint8List transcript;
  final PairingKeys keys;

  /// The direction this side sends in: up on the phone, down on the screen
  final PairingDirection sends;
  final Random _random;

  PairingDirection get _receives => sends == PairingDirection.up ? PairingDirection.down : PairingDirection.up;

  /// The first 8 bytes of the transcript, which tell the screen which of its hellos a message belongs to
  String get handle => pairingBase64(transcript.sublist(0, 8));

  /// {v, h, n, c} for [message]
  Map<String, Object> seal(Map<String, Object?> message) {
    final nonce = pairingRandomBytes(12, _random);
    final sealed = pairingSeal(
      keys: keys,
      transcript: transcript,
      direction: sends,
      nonce: nonce,
      plain: utf8.encode(jsonEncode(message)),
    );
    return {'v': pairingProtocolVersion, 'h': handle, 'n': pairingBase64(nonce), 'c': pairingBase64(sealed)};
  }

  /// The JSON object an envelope of the other side holds, null when it does not decrypt or is not an object
  Map<String, Object?>? open(Map<String, Object?> envelope) {
    final nonce = pairingDecodeBase64(envelope['n']);
    final sealed = pairingDecodeBase64(envelope['c']);
    if (nonce == null || sealed == null) {
      return null;
    }
    final plain = pairingOpen(keys: keys, transcript: transcript, direction: _receives, nonce: nonce, sealed: sealed);
    if (plain == null) {
      return null;
    }
    try {
      final decoded = jsonDecode(utf8.decode(plain));
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}

/// The bytes of the device description the screen sends in its hello, keys sorted, for [pairingConfirm]
Uint8List pairingDeviceBytes(Map<String, String> device) {
  final sorted = Map.fromEntries(device.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  return Uint8List.fromList(utf8.encode(jsonEncode(sorted)));
}
