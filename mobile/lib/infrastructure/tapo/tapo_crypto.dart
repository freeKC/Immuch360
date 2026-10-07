// The cryptography of the Tapo cameras: the hashes their logins are built on, HKDF and PBKDF2, the SHA-256 crypt that
// some firmware asks for, AES-CCM for the V4 control channel, AES-CBC for the V3 control channel, the media port and
// the discovery answer, the SPAKE2+ exchange of the V4 login on P-256, the CRC32 of the discovery datagram, and the
// G.711 tables of the camera's sound. pointycastle does the block ciphers, PBKDF2 and the curve; package:crypto the
// hashes. Nothing here logs or keeps a value: the callers pass secrets in and get derived bytes back.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// Lower case hex MD5 of the UTF-8 bytes of [text]
String md5Hex(String text) => crypto.md5.convert(utf8.encode(text)).toString();

/// Upper case hex MD5 of the UTF-8 bytes of [text]
String md5HexUpper(String text) => md5Hex(text).toUpperCase();

/// Lower case hex SHA-256 of the UTF-8 bytes of [text]
String sha256Hex(String text) => crypto.sha256.convert(utf8.encode(text)).toString();

/// Upper case hex SHA-256 of the UTF-8 bytes of [text]
String sha256HexUpper(String text) => sha256Hex(text).toUpperCase();

Uint8List md5Bytes(List<int> data) => Uint8List.fromList(crypto.md5.convert(data).bytes);

Uint8List sha256Bytes(List<int> data) => Uint8List.fromList(crypto.sha256.convert(data).bytes);

Uint8List hmacSha256(List<int> key, List<int> data) =>
    Uint8List.fromList(crypto.Hmac(crypto.sha256, key).convert(data).bytes);

/// Lower case hex of [bytes]
String hexOf(List<int> bytes) {
  final out = StringBuffer();
  for (final byte in bytes) {
    out.write((byte & 0xff).toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

/// The bytes of the hex string [hex]; throws a [FormatException] for an odd length or a character that is not hex
Uint8List bytesOfHex(String hex) {
  if (hex.length.isOdd) {
    throw const FormatException('Odd length of a hex string');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

/// [length] random bytes from the secure generator of the system
Uint8List randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

/// HKDF with SHA-256 (RFC 5869); a null [salt] is 32 zero bytes, as in Bouncy Castle which the official app uses
Uint8List hkdfSha256(List<int> ikm, List<int>? salt, List<int> info, int length) {
  final prk = hmacSha256(salt ?? Uint8List(32), ikm);
  final out = BytesBuilder(copy: false);
  var previous = Uint8List(0);
  for (var counter = 1; out.length < length; counter++) {
    previous = hmacSha256(prk, [...previous, ...info, counter]);
    out.add(previous);
  }
  return Uint8List.sublistView(out.takeBytes(), 0, length);
}

/// PBKDF2 with HMAC-SHA-256. 5000 iterations take a few hundred milliseconds on a phone: callers run it off the UI
/// isolate (see [spake2pClient]).
Uint8List pbkdf2HmacSha256(List<int> password, List<int> salt, int iterations, int length) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(Uint8List.fromList(salt), iterations, length));
  return derivator.process(Uint8List.fromList(password));
}

/// AES-128-CCM with a 16 byte tag and no associated data: the ciphertext then the tag
Uint8List aesCcmEncrypt(Uint8List key, Uint8List nonce, Uint8List plain) {
  final cipher = CCMBlockCipher(AESEngine())..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
  return cipher.process(plain);
}

/// The plaintext of [cipherAndTag] (see [aesCcmEncrypt]); throws a [FormatException] when the tag does not match
Uint8List aesCcmDecrypt(Uint8List key, Uint8List nonce, Uint8List cipherAndTag) {
  if (cipherAndTag.length < 16) {
    throw const FormatException('An AES-CCM message shorter than its tag');
  }
  final cipher = CCMBlockCipher(AESEngine())..init(false, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
  try {
    return cipher.process(cipherAndTag);
  } on StateError {
    throw const FormatException('The AES-CCM tag does not match');
  } on InvalidCipherTextException {
    throw const FormatException('The AES-CCM tag does not match');
  }
}

/// AES-CBC with PKCS#7 padding
Uint8List aesCbcEncrypt(Uint8List key, Uint8List iv, List<int> plain) {
  final padding = 16 - plain.length % 16;
  final padded = Uint8List(plain.length + padding)
    ..setRange(0, plain.length, plain)
    ..fillRange(plain.length, plain.length + padding, padding);
  final cipher = CBCBlockCipher(AESEngine())..init(true, ParametersWithIV(KeyParameter(key), iv));
  final out = Uint8List(padded.length);
  for (var offset = 0; offset < padded.length; offset += 16) {
    cipher.processBlock(padded, offset, out, offset);
  }
  return out;
}

/// The plaintext of an AES-CBC message with PKCS#7 padding; throws a [FormatException] when its length or its padding
/// is wrong (the usual sign of a wrong key, that is of a wrong password)
Uint8List aesCbcDecrypt(Uint8List key, Uint8List iv, Uint8List cipherText) =>
    AesCbcDecryptor(key, iv).decrypt(cipherText);

/// AES-CBC decryption with one key and one IV for many messages, the cipher started again from the IV for each: the
/// parts of the media port (the cipher is set up once, which counts at several hundred parts a second)
class AesCbcDecryptor {
  AesCbcDecryptor(Uint8List key, this._iv) : _engine = AESEngine()..init(false, KeyParameter(key));

  final AESEngine _engine;
  final Uint8List _iv;

  Uint8List decrypt(Uint8List cipherText) {
    if (cipherText.isEmpty || cipherText.length % 16 != 0) {
      throw const FormatException('An AES-CBC message whose length is not a multiple of 16');
    }
    final out = Uint8List(cipherText.length);
    var previous = _iv;
    for (var offset = 0; offset < cipherText.length; offset += 16) {
      _engine.processBlock(cipherText, offset, out, offset);
      for (var i = 0; i < 16; i++) {
        out[offset + i] ^= previous[i];
      }
      previous = Uint8List.sublistView(cipherText, offset, offset + 16);
    }
    final padding = out.last;
    if (padding < 1 || padding > 16) {
      throw const FormatException('Wrong PKCS#7 padding');
    }
    for (var i = out.length - padding; i < out.length; i++) {
      if (out[i] != padding) {
        throw const FormatException('Wrong PKCS#7 padding');
      }
    }
    return Uint8List.sublistView(out, 0, out.length - padding);
  }
}

/// The CRC32 of zlib (the one of the TP-Link discovery datagram)
int crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c;
  }
  return table;
}();

// G.711 (ITU-T), as in the reference g711.c of Sun: the cameras send their sound in A-law (some in µ-law), which the
// clips keep as 16 bit PCM that every player reads

/// The 16 bit sample of each A-law byte
final Int16List alawToPcm16 = Int16List.fromList(List.generate(256, _alawSample));

/// The 16 bit sample of each µ-law byte
final Int16List ulawToPcm16 = Int16List.fromList(List.generate(256, _ulawSample));

int _alawSample(int code) {
  final value = code ^ 0x55;
  var sample = (value & 0x0f) << 4;
  final segment = (value & 0x70) >> 4;
  switch (segment) {
    case 0:
      sample += 8;
    case 1:
      sample += 0x108;
    default:
      sample = (sample + 0x108) << (segment - 1);
  }
  return (value & 0x80) != 0 ? sample : -sample;
}

int _ulawSample(int code) {
  final value = ~code & 0xff;
  var sample = ((value & 0x0f) << 3) + 0x84;
  sample <<= (value & 0x70) >> 4;
  return (value & 0x80) != 0 ? 0x84 - sample : sample - 0x84;
}

/// The A-law byte of a 16 bit [sample]: the tests make the camera's sound with it
int pcm16ToAlaw(int sample) {
  const segmentEnds = [0xff, 0x1ff, 0x3ff, 0x7ff, 0xfff, 0x1fff, 0x3fff, 0x7fff];
  var value = sample >> 3;
  int mask;
  if (value >= 0) {
    mask = 0xd5;
  } else {
    mask = 0x55;
    value = -value - 1;
  }
  var segment = 0;
  while (segment < 8 && value > segmentEnds[segment] >> 3) {
    segment++;
  }
  if (segment >= 8) {
    return 0x7f ^ mask;
  }
  var code = segment << 4;
  code |= segment < 2 ? (value >> 1) & 0x0f : (value >> segment) & 0x0f;
  return code ^ mask;
}

/// The SHA-256 crypt of Unix ("$5$", Drepper 2007) of [key] with the salt and the rounds of [prefix], what a camera
/// asks for with extra_crypt password_shadow 5 (`$5$<salt>$`, the salt cut to 16 characters, "rounds=N$" honoured).
/// Returns the whole `$5$[rounds=N$]salt$hash`.
String sha256Crypt(String key, String prefix) {
  var rest = prefix.startsWith(r'$5$') ? prefix.substring(3) : prefix;
  var rounds = 5000;
  var explicitRounds = false;
  if (rest.startsWith('rounds=')) {
    final end = rest.indexOf(r'$');
    if (end > 0 && end < rest.length - 1) {
      rounds = (int.tryParse(rest.substring(7, end)) ?? 5000).clamp(1000, 999999999);
      explicitRounds = true;
      rest = rest.substring(end + 1);
    }
  }
  final saltEnd = rest.indexOf(r'$');
  final salt = rest.substring(0, min(saltEnd > 0 ? saltEnd : rest.length, 16));
  final k = utf8.encode(key);
  final s = utf8.encode(salt);

  List<int> repeat(List<int> digest, int length) => [for (var i = 0; i < length; i++) digest[i % digest.length]];

  final b = sha256Bytes([...k, ...s, ...k]);
  final aInput = <int>[...k, ...s, ...repeat(b, k.length)];
  for (var n = k.length; n > 0; n >>= 1) {
    aInput.addAll((n & 1) != 0 ? b : k);
  }
  final a = sha256Bytes(aInput);
  final p = repeat(sha256Bytes([for (var i = 0; i < k.length; i++) ...k]), k.length);
  final sb = repeat(sha256Bytes([for (var i = 0; i < 16 + a[0]; i++) ...s]), s.length);
  var c = a;
  for (var i = 0; i < rounds; i++) {
    final input = <int>[...(i & 1) != 0 ? p : c];
    if (i % 3 != 0) {
      input.addAll(sb);
    }
    if (i % 7 != 0) {
      input.addAll(p);
    }
    input.addAll((i & 1) != 0 ? c : p);
    c = sha256Bytes(input);
  }
  const alphabet = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  final encoded = StringBuffer();
  void to64(int value, int count) {
    var rest = value;
    for (var i = 0; i < count; i++) {
      encoded.write(alphabet[rest & 0x3f]);
      rest >>= 6;
    }
  }

  const order = [
    [0, 10, 20],
    [21, 1, 11],
    [12, 22, 2],
    [3, 13, 23],
    [24, 4, 14],
    [15, 25, 5],
    [6, 16, 26],
    [27, 7, 17],
    [18, 28, 8],
    [9, 19, 29],
  ];
  for (final [x, y, z] in order) {
    to64((c[x] << 16) | (c[y] << 8) | c[z], 4);
  }
  to64((c[31] << 8) | c[30], 3);
  return '\$5\$${explicitRounds ? 'rounds=$rounds\$' : ''}$salt\$$encoded';
}

/// Thrown when the camera asks for a credential form this app does not know (an extra_crypt of a later firmware)
class TapoCredentialFormException implements Exception {
  const TapoCredentialFormException(this.detail);

  /// The form the camera named, never a secret
  final String detail;

  @override
  String toString() => 'TapoCredentialFormException($detail)';
}

/// The SPAKE2+ credential of [passcode] after the extra_crypt of the pake_register answer, when the camera sends one
/// (a C200 on firmware 1.4.6 asks for the SHA-256 crypt of the passcode, password_shadow 5)
String applyExtraCrypt(String passcode, Object? extraCrypt) {
  if (extraCrypt is! Map) {
    return passcode;
  }
  final type = '${extraCrypt['type'] ?? ''}'.toLowerCase();
  if (type.isEmpty) {
    return passcode;
  }
  final params = extraCrypt['params'] is Map ? extraCrypt['params'] as Map : const {};
  if (type == 'password_shadow') {
    final id = int.tryParse('${params['passwd_id'] ?? ''}');
    if (id == 5) {
      return sha256Crypt(passcode, '${params['passwd_prefix'] ?? ''}');
    }
    if (id == 2) {
      return crypto.sha1.convert(utf8.encode(passcode)).toString();
    }
    throw TapoCredentialFormException('password_shadow $id');
  }
  throw TapoCredentialFormException(type);
}

// SPAKE2+ (RFC 9383 points M and N, P-256) as the V4 login of the cameras runs it, see the Tapo design 2.4

final ECDomainParameters _p256 = ECCurve_secp256r1();

/// P-256 and the points M and N of RFC 9383, for the device side of the exchange in the tests
ECDomainParameters get p256 => _p256;
ECPoint get spake2pM => _m;
ECPoint get spake2pN => _n;
final ECPoint _m = _p256.curve.decodePoint(
  bytesOfHex('02886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f'),
)!;
final ECPoint _n = _p256.curve.decodePoint(
  bytesOfHex('03d8bbd6c639c62937b04d997f38c3770719c629d7014d49a24b4f98baa1292b49'),
)!;

/// The order of P-256
BigInt get p256Order => _p256.n;

/// A random scalar of P-256 in [1, n - 1]
BigInt randomP256Scalar() => bigIntOf(randomBytes(32)) % (p256Order - BigInt.one) + BigInt.one;

BigInt bigIntOf(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

/// [value] as [length] big endian bytes
Uint8List bytesOfBigInt(BigInt value, int length) {
  final out = Uint8List(length);
  var rest = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (rest & BigInt.from(0xff)).toInt();
    rest >>= 8;
  }
  return out;
}

final BigInt _p256Prime = BigInt.parse('ffffffff00000001000000000000000000000000ffffffffffffffffffffffff', radix: 16);
final BigInt _p256B = BigInt.parse('5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b', radix: 16);

/// Whether [point] lies on P-256. pointycastle decodes any coordinates without checking them, and a share off the
/// curve would make the products below leak what they are made of.
bool isOnP256(ECPoint point) {
  final x = point.x?.toBigInteger();
  final y = point.y?.toBigInteger();
  if (x == null || y == null || x >= _p256Prime || y >= _p256Prime) {
    return false;
  }
  final left = y * y % _p256Prime;
  final right = (x * x * x - BigInt.from(3) * x + _p256B) % _p256Prime;
  return left == right;
}

/// What the client side of one SPAKE2+ exchange needs: the pake_register answer, and the credential. [x] is the
/// random scalar of the client (given by the tests, [randomP256Scalar] otherwise).
class Spake2pInput {
  const Spake2pInput({
    required this.credential,
    required this.salt,
    required this.iterations,
    required this.userRandom,
    required this.devRandom,
    required this.devShare,
    required this.x,
  });

  final String credential;
  final Uint8List salt;
  final int iterations;
  final Uint8List userRandom;
  final Uint8List devRandom;

  /// The camera's share Y, an uncompressed (or compressed) P-256 point
  final Uint8List devShare;
  final BigInt x;
}

/// What the client sends in pake_share, what it expects back, and the keys of the session once the camera confirmed
class Spake2pOutput {
  const Spake2pOutput({
    required this.userShare,
    required this.userConfirm,
    required this.expectedDevConfirm,
    required this.key,
    required this.nonce0,
  });

  final Uint8List userShare;
  final Uint8List userConfirm;
  final Uint8List expectedDevConfirm;

  /// AES-128 key of the /ds channel
  final Uint8List key;

  /// The 12 byte base nonce of the /ds channel; its last 4 bytes are replaced by the sequence number
  final Uint8List nonce0;

  @override
  String toString() => 'Spake2pOutput';
}

/// The client side of SPAKE2+ (Tapo design 2.4 step 3): PBKDF2 of the credential into w0 and w1, X = x*G + w0*M,
/// Z = x*(Y - w0*N), V = w1*(Y - w0*N), the transcript with 8 byte little endian lengths and the hashed context, then
/// the confirmations and the session keys through HKDF. Throws a [FormatException] for a share that is not a point of
/// the curve. Heavy: run it in an isolate.
Spake2pOutput spake2pClient(Spake2pInput input) {
  final dk = pbkdf2HmacSha256(utf8.encode(input.credential), input.salt, input.iterations, 80);
  final w0 = bigIntOf(dk.sublist(0, 40)) % p256Order;
  final w1 = bigIntOf(dk.sublist(40, 80)) % p256Order;
  final ECPoint y;
  try {
    final decoded = _p256.curve.decodePoint(input.devShare);
    if (decoded == null || decoded.isInfinity || !isOnP256(decoded)) {
      throw const FormatException('The share of the camera is not a point');
    }
    y = decoded;
  } on ArgumentError {
    throw const FormatException('The share of the camera is not a point');
  }
  ECPoint required(ECPoint? point) {
    if (point == null || point.isInfinity) {
      throw const FormatException('A point at infinity in the exchange');
    }
    return point;
  }

  final x = required(required(_p256.G * input.x) + required(_m * w0));
  final h = required(y - required(_n * w0));
  final z = required(h * input.x);
  final v = required(h * w1);

  Uint8List encode(ECPoint point) => point.getEncoded(false);
  final xBytes = encode(x);
  final yBytes = encode(y);
  final context = sha256Bytes([...utf8.encode('PAKE V1'), ...input.userRandom, ...input.devRandom]);
  final transcript = BytesBuilder(copy: false);
  for (final element in [
    context,
    Uint8List(0),
    Uint8List(0),
    encode(_m),
    encode(_n),
    xBytes,
    yBytes,
    encode(z),
    encode(v),
    bytesOfBigInt(w0, 32),
  ]) {
    final length = ByteData(8)..setUint64(0, element.length, Endian.little);
    transcript
      ..add(length.buffer.asUint8List())
      ..add(element);
  }
  final ke = sha256Bytes(transcript.takeBytes());
  final confirmation = hkdfSha256(ke, null, utf8.encode('ConfirmationKeys'), 64);
  final shared = hkdfSha256(ke, null, utf8.encode('SharedKey'), 32);
  return Spake2pOutput(
    userShare: xBytes,
    userConfirm: hmacSha256(confirmation.sublist(0, 32), yBytes),
    expectedDevConfirm: hmacSha256(confirmation.sublist(32), xBytes),
    key: hkdfSha256(
      shared,
      utf8.encode('tp-kdf-salt-aes128-key'),
      utf8.encode('tp-kdf-info-aes128-key'),
      32,
    ).sublist(0, 16),
    nonce0: hkdfSha256(
      shared,
      utf8.encode('tp-kdf-salt-aes128-iv'),
      utf8.encode('tp-kdf-info-aes128-iv'),
      32,
    ).sublist(0, 12),
  );
}

/// Constant time equality of two byte strings, for the confirmations
bool sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}
