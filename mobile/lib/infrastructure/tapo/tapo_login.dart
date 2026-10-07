// The logins of the Tapo cameras and their control channels (Tapo design 2.4): V2 (a hashed password, plain JSON), V3
// ("secure passthrough", AES-CBC) and V4 (TPAP: SPAKE2+ on P-256, then AES-128-CCM on /stok=<stok>/ds). The generation
// is the stored one (or the one the camera announced in the discovery, so that a camera announcing V4 is never sent the
// unsalted hash of V2), else the answer to a probe that carries no password: -40211 means V4, -40413 with a nonce V3,
// anything else V2.
//
// Every refused password counts towards a lockout of the camera, so nothing here loops: a first V4 login tries the two
// passcode forms of the official app once each, a later one only the form that worked (once more after 2 s, for the
// cameras that refuse a new login while their previous session lives), and a lockout or a refusal ends the login at
// once. An empty password is never sent.

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_https.dart';
import 'package:logging/logging.dart';

final _log = Logger('TapoLogin');

/// The user name of every login: the camera's administrator, whose password is the one of the TP-Link account
const tapoAdminUser = 'admin';

/// The camera refused a request of a session in plain JSON, or its answer could not be read: the session is dead on
/// the camera's side. [isSessionLost] tells the refusals that one new login may cure (-40401 a wrong sequence or an
/// expired session, -40421 a stok refused).
class TapoSessionRefused implements Exception {
  const TapoSessionRefused(this.code);

  final int? code;

  bool get isSessionLost => code == -40401 || code == -40421;

  @override
  String toString() => 'TapoSessionRefused($code)';
}

/// Runs one request after the other: the V4 and V3 channels number their requests, which must reach the camera in
/// order
class TapoSerial {
  Future<void> _last = Future.value();

  Future<T> run<T>(Future<T> Function() task) {
    final result = _last.then((_) => task());
    _last = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

/// The control channel of a logged in camera
abstract class TapoSession {
  TapoLoginProtocol get protocol;

  /// When the camera forgets the session; a new login is needed after it
  DateTime get expiresAt;

  bool get isExpired => !DateTime.now().isBefore(expiresAt);

  /// Sends [requests] as one multipleRequest and gives back the answer object
  /// (`{"result":{"responses":[...]},"error_code":0}`). Throws [TapoSessionRefused] when the camera refused it,
  /// [TapoNetworkException] when it could not be reached.
  Future<Map<String, Object?>> multiple(List<Map<String, Object?>> requests);
}

/// What a login gives: the session, and what it learned about the camera
class TapoLoginResult {
  const TapoLoginResult({required this.session, required this.protocol, this.passcode, this.userName});

  final TapoSession session;
  final TapoLoginProtocol protocol;
  final TapoPasscodeHash? passcode;
  final TapoUserNameForm? userName;
}

/// The client side of SPAKE2+, injectable so that the tests need not start isolates
typedef Spake2pCompute = Future<Spake2pOutput> Function(Spake2pInput input);

/// PBKDF2 and the products on P-256 off the UI isolate
Future<Spake2pOutput> spake2pInIsolate(Spake2pInput input) => Isolate.run(() => spake2pClient(input));

/// Logs in to the camera behind [transport]
class TapoLogin {
  TapoLogin(
    this.transport, {
    this.spake2p = spake2pInIsolate,
    this.spake2pTimeout = const Duration(minutes: 1),
    this.reloginDelay = const Duration(seconds: 2),
    this.sessionLifetime = const Duration(hours: 1),
  });

  final TapoTransport transport;
  final Spake2pCompute spake2p;

  /// The longest the SPAKE2+ exchange may take: the requests of the camera wait behind the login
  final Duration spake2pTimeout;

  /// The PBKDF2 iterations a camera may ask for in pake_register (5000 on the C510W): the count comes from whoever
  /// answers at the address, and a huge one would keep the phone busy for hours
  static const maxIterations = 100000;

  /// The pause before the passcode that worked is tried again (see the header)
  final Duration reloginDelay;

  /// How long a V2 or V3 session is used: those logins tell no expiry, and a camera that forgot one earlier answers
  /// -40401, which costs one new login
  final Duration sessionLifetime;

  /// Logs in with [password], the password of the TP-Link account. [known] is what an earlier login learned: its
  /// generation, and the passcode and user name forms that worked, which are then the only ones tried. Throws a
  /// [TapoCameraException] (wrongPassword, locked, notOwner, unsupported, certificateChanged) or a
  /// [TapoNetworkException].
  Future<TapoLoginResult> login(String password, {TapoCameraInfo? known}) async {
    if (password.isEmpty) {
      // Never sent: every refusal counts towards the lockout of the camera
      throw const TapoCameraException(TapoErrorKind.wrongPassword);
    }
    final protocol = known?.protocol;
    if (protocol == TapoLoginProtocol.v4) {
      return _loginV4(password, known);
    }
    // The V3 probe carries no password: it cannot count as a failed attempt, and a V3 camera answers it with the
    // nonce the login goes on with
    final cnonce = hexOf(randomBytes(8)).toUpperCase();
    final probe = await _postLogin({'cnonce': cnonce, 'encrypt_type': '3', 'username': tapoAdminUser});
    _throwIfLocked(probe);
    final code = _int(probe['error_code']);
    if (code == -40211) {
      return _loginV4(password, known);
    }
    final data = _map(_map(probe['result'])?['data']);
    final encryptTypes = data?['encrypt_type'];
    final offersV3 = encryptTypes is List ? encryptTypes.map((type) => '$type').contains('3') : '$encryptTypes' == '3';
    if (code == -40413 && data != null && data['nonce'] is String && offersV3) {
      return _loginV3(password, cnonce, data);
    }
    if (protocol == TapoLoginProtocol.v3) {
      throw TapoCameraException(TapoErrorKind.unsupported, code: code, detail: 'V3 probe');
    }
    return _loginV2(password);
  }

  // V4 (TPAP)

  Future<TapoLoginResult> _loginV4(String password, TapoCameraInfo? known) async {
    final knownPasscode = known?.passcode;
    // A first login tries the passcodes in the official app's order, a later one the one that worked, twice
    final attempts = knownPasscode == null
        ? const [TapoPasscodeHash.md5, TapoPasscodeHash.sha256]
        : [knownPasscode, knownPasscode];
    var userName = known?.userName;
    TapoCameraException? refused;
    for (var index = 0; index < attempts.length; index++) {
      final passcode = attempts[index];
      if (index > 0 && passcode == attempts[index - 1]) {
        await Future<void>.delayed(reloginDelay);
      }
      final register = await _register(userName);
      userName = register.userName;
      final passcodeText = switch (passcode) {
        TapoPasscodeHash.md5 => md5Hex(password),
        TapoPasscodeHash.sha256 => sha256HexUpper(password),
      };
      try {
        final session = await _share(register, passcodeText);
        return TapoLoginResult(
          session: session,
          protocol: TapoLoginProtocol.v4,
          passcode: passcode,
          userName: userName,
        );
      } on TapoCameraException catch (error) {
        if (error.kind != TapoErrorKind.wrongPassword) {
          rethrow;
        }
        refused = error;
        _log.fine('The camera refused passcode form ${passcode.name}');
      }
    }
    throw refused ?? const TapoCameraException(TapoErrorKind.wrongPassword);
  }

  /// pake_register with the forms of the official app in turn: md5 hex of "admin", then the literal (the C510W takes
  /// it), then the SHA-256 (user_hash_type 1); [known] first, the one that worked or the one the camera announced. An
  /// unknown user name is refused with -40209 before any password is involved, so trying the others costs nothing.
  Future<_Register> _register(TapoUserNameForm? known) async {
    const order = [TapoUserNameForm.md5, TapoUserNameForm.plain, TapoUserNameForm.sha256];
    final forms = [?known, ...order.where((form) => form != known)];
    int? lastCode;
    for (final form in forms) {
      final userRandom = randomBytes(32);
      final reply = await _postLogin({
        'sub_method': 'pake_register',
        'username': switch (form) {
          TapoUserNameForm.md5 => md5Hex(tapoAdminUser),
          TapoUserNameForm.plain => tapoAdminUser,
          TapoUserNameForm.sha256 => sha256HexUpper(tapoAdminUser),
        },
        'user_random': base64.encode(userRandom),
        'cipher_suites': [1],
        'encryption': ['aes_128_ccm'],
        'passcode_type': 'userpw',
      });
      _throwIfLocked(reply);
      final result = _map(reply['result']);
      final code = _int(reply['error_code']);
      if (result != null && (code == null || code == 0)) {
        final iterations = _int(result['iterations']) ?? 10000;
        if (iterations < 1 || iterations > maxIterations) {
          throw const TapoCameraException(TapoErrorKind.unsupported, detail: 'pake_register');
        }
        try {
          return _Register(
            userName: form,
            userRandom: userRandom,
            devRandom: base64.decode('${result['dev_random']}'),
            salt: base64.decode('${result['dev_salt']}'),
            devShare: base64.decode('${result['dev_share']}'),
            iterations: iterations,
            extraCrypt: result['extra_crypt'],
          );
        } on FormatException {
          throw const TapoCameraException(TapoErrorKind.unsupported, detail: 'pake_register');
        }
      }
      lastCode = code;
      if (code != -40209) {
        break;
      }
    }
    throw TapoCameraException(TapoErrorKind.unsupported, code: lastCode, detail: 'pake_register');
  }

  Future<TapoSession> _share(_Register register, String passcode) async {
    final String credential;
    try {
      credential = applyExtraCrypt(passcode, register.extraCrypt);
    } on TapoCredentialFormException catch (error) {
      throw TapoCameraException(TapoErrorKind.unsupported, detail: error.detail);
    }
    final Spake2pOutput exchange;
    try {
      exchange = await spake2p(
        Spake2pInput(
          credential: credential,
          salt: register.salt,
          iterations: register.iterations,
          userRandom: register.userRandom,
          devRandom: register.devRandom,
          devShare: register.devShare,
          x: randomP256Scalar(),
        ),
      ).timeout(spake2pTimeout);
    } on FormatException {
      throw const TapoCameraException(TapoErrorKind.unsupported, detail: 'dev_share');
    } on TimeoutException {
      throw const TapoCameraException(TapoErrorKind.unsupported, detail: 'pake_register');
    }
    final reply = await _postLogin({
      'sub_method': 'pake_share',
      'user_share': base64.encode(exchange.userShare),
      'user_confirm': base64.encode(exchange.userConfirm),
    });
    _throwIfLocked(reply);
    final result = _map(reply['result']);
    final code = _int(reply['error_code']);
    if (result == null || (code != null && code != 0)) {
      if (code == -40401) {
        throw TapoCameraException(TapoErrorKind.wrongPassword, code: code, attemptsLeft: _attemptsLeft(reply));
      }
      throw TapoCameraException(TapoErrorKind.unsupported, code: code, detail: 'pake_share');
    }
    final Uint8List devConfirm;
    try {
      devConfirm = base64.decode('${result['dev_confirm']}');
    } on FormatException {
      throw const TapoCameraException(TapoErrorKind.unsupported, detail: 'dev_confirm');
    }
    // The camera proves it holds the same keys: without that the session is never used
    if (!sameBytes(devConfirm, exchange.expectedDevConfirm)) {
      throw const TapoCameraException(TapoErrorKind.unsupported, detail: 'dev_confirm');
    }
    final stok = result['stok'];
    final startSeq = _int(result['start_seq']);
    if (stok is! String || stok.isEmpty || startSeq == null) {
      throw const TapoCameraException(TapoErrorKind.unsupported, detail: 'pake_share');
    }
    final lifetime = _int(result['expired']) ?? 3600;
    return TapoV4Session(
      transport: transport,
      stok: stok,
      startSeq: startSeq,
      key: exchange.key,
      nonce0: exchange.nonce0,
      expiresAt: DateTime.now().add(Duration(seconds: lifetime > 0 ? lifetime : 3600)),
    );
  }

  // V3 (secure passthrough)

  Future<TapoLoginResult> _loginV3(String password, String cnonce, Map<String, Object?> data) async {
    final nonce = '${data['nonce']}';
    final deviceConfirm = '${data['device_confirm'] ?? ''}';
    // The camera tells which hash of the password it holds, without any try of the password
    TapoPasscodeHash? passcode;
    String? hashed;
    for (final (form, candidate) in [
      (TapoPasscodeHash.sha256, sha256HexUpper(password)),
      (TapoPasscodeHash.md5, md5HexUpper(password)),
    ]) {
      if (deviceConfirm == '${sha256HexUpper(cnonce + candidate + nonce)}$nonce$cnonce') {
        passcode = form;
        hashed = candidate;
        break;
      }
    }
    if (hashed == null || passcode == null) {
      throw const TapoCameraException(TapoErrorKind.wrongPassword);
    }
    final digest = sha256HexUpper(hashed + cnonce + nonce);
    final reply = await _postLogin({
      'cnonce': cnonce,
      'encrypt_type': '3',
      'digest_passwd': '$digest$cnonce$nonce',
      'username': tapoAdminUser,
    });
    _throwIfLocked(reply);
    final result = _map(reply['result']);
    final code = _int(reply['error_code']);
    final stok = result?['stok'];
    final startSeq = _int(result?['start_seq']);
    if (result == null || stok is! String || startSeq == null || (code != null && code != 0)) {
      if (code == -40401 || code == -40411) {
        throw TapoCameraException(TapoErrorKind.wrongPassword, code: code, attemptsLeft: _attemptsLeft(reply));
      }
      throw TapoCameraException(TapoErrorKind.unsupported, code: code, detail: 'V3 login');
    }
    // An account the camera was shared with cannot use the encrypted channel (Home Assistant Tapo issue 456)
    final group = result['user_group'];
    if (group != null && group != 'root') {
      throw const TapoCameraException(TapoErrorKind.notOwner);
    }
    final key = sha256HexUpper(cnonce + hashed + nonce);
    Uint8List token(String type) => sha256Bytes(utf8.encode('$type$cnonce$nonce$key')).sublist(0, 16);
    return TapoLoginResult(
      session: TapoV3Session(
        transport: transport,
        stok: stok,
        startSeq: startSeq,
        lsk: token('lsk'),
        ivb: token('ivb'),
        tagSeed: sha256HexUpper(hashed + cnonce),
        expiresAt: DateTime.now().add(sessionLifetime),
      ),
      protocol: TapoLoginProtocol.v3,
      passcode: passcode,
    );
  }

  // V2 (older firmware)

  Future<TapoLoginResult> _loginV2(String password) async {
    final reply = await _postLogin({'hashed': true, 'password': md5HexUpper(password), 'username': tapoAdminUser});
    _throwIfLocked(reply);
    final code = _int(reply['error_code']);
    final stok = _map(reply['result'])?['stok'];
    if (stok is! String || stok.isEmpty || (code != null && code != 0)) {
      if (code == -40401 || code == -40411) {
        throw TapoCameraException(TapoErrorKind.wrongPassword, code: code, attemptsLeft: _attemptsLeft(reply));
      }
      throw TapoCameraException(TapoErrorKind.unsupported, code: code, detail: 'V2 login');
    }
    return TapoLoginResult(
      session: TapoV2Session(transport: transport, stok: stok, expiresAt: DateTime.now().add(sessionLifetime)),
      protocol: TapoLoginProtocol.v2,
      passcode: TapoPasscodeHash.md5,
    );
  }

  Future<Map<String, Object?>> _postLogin(Map<String, Object?> params) async {
    final reply = await transport.post(
      '/',
      utf8.encode(jsonEncode({'method': 'login', 'params': params})),
      contentType: 'application/json',
    );
    final decoded = _jsonObject(reply.body);
    if (decoded == null) {
      // A device that does not speak the control API of the cameras (a KLAP plug, a web server)
      throw TapoCameraException(TapoErrorKind.unsupported, detail: 'HTTP ${reply.status}');
    }
    return decoded;
  }
}

class _Register {
  const _Register({
    required this.userName,
    required this.userRandom,
    required this.devRandom,
    required this.salt,
    required this.devShare,
    required this.iterations,
    required this.extraCrypt,
  });

  final TapoUserNameForm userName;
  final Uint8List userRandom;
  final Uint8List devRandom;
  final Uint8List salt;
  final Uint8List devShare;
  final int iterations;
  final Object? extraCrypt;
}

/// The V4 channel: `uint32_be(seq) || AES-128-CCM(key, nonce0[0:8] || uint32_be(seq), inner)`, the first seq the
/// start_seq of the login, one more per request, refused ones included (Tapo design 2.4 step 6)
class TapoV4Session extends TapoSession {
  TapoV4Session({
    required this.transport,
    required this.stok,
    required int startSeq,
    required this._key,
    required this._nonce0,
    required this.expiresAt,
  }) : _seq = startSeq;

  final TapoTransport transport;
  final String stok;
  final Uint8List _key;
  final Uint8List _nonce0;
  int _seq;
  final _serial = TapoSerial();

  @override
  final DateTime expiresAt;

  @override
  TapoLoginProtocol get protocol => TapoLoginProtocol.v4;

  Uint8List _nonce(int seq) => Uint8List(12)
    ..setRange(0, 8, _nonce0)
    ..buffer.asByteData().setUint32(8, seq & 0xffffffff);

  @override
  Future<Map<String, Object?>> multiple(List<Map<String, Object?>> requests) => _serial.run(() async {
    final inner = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'method': 'multipleRequest',
          'params': {'requests': requests},
        }),
      ),
    );
    final seq = _seq;
    // start_seq is a signed 32 bit number in the official app: on the wire its two's complement
    _seq = (_seq + 1) & 0xffffffff;
    final body = BytesBuilder(copy: false)
      ..add((ByteData(4)..setUint32(0, seq & 0xffffffff)).buffer.asUint8List())
      ..add(aesCcmEncrypt(_key, _nonce(seq), inner));
    final reply = await transport.post(tapoStokPath(stok), body.takeBytes(), contentType: 'application/octet-stream');
    // A refusal is a JSON object in plain text. Checked on the whole body: a sequence number of 0x7Bxxxxxx would also
    // start an encrypted answer with "{"
    final refusal = _jsonObject(reply.body);
    if (refusal != null && refusal.containsKey('error_code')) {
      throw TapoSessionRefused(_int(refusal['error_code']));
    }
    if (reply.body.length < 20) {
      throw const TapoSessionRefused(null);
    }
    final replySeq = ByteData.sublistView(reply.body, 0, 4).getUint32(0);
    final Uint8List plain;
    try {
      plain = aesCcmDecrypt(_key, _nonce(replySeq), Uint8List.sublistView(reply.body, 4));
    } on FormatException {
      throw const TapoSessionRefused(null);
    }
    final answer = _jsonObject(plain);
    if (answer == null) {
      throw const TapoSessionRefused(null);
    }
    return answer;
  });
}

/// The V3 channel: the request encrypted with AES-CBC inside a securePassthrough, signed with the Tapo_tag header and
/// numbered with the Seq header (Tapo design 2.4, V3 step 5)
class TapoV3Session extends TapoSession {
  TapoV3Session({
    required this.transport,
    required this.stok,
    required int startSeq,
    required this._lsk,
    required this._ivb,
    required this._tagSeed,
    required this.expiresAt,
  }) : _seq = startSeq;

  final TapoTransport transport;
  final String stok;
  final Uint8List _lsk;
  final Uint8List _ivb;

  /// SHA256_UPPER(hashed password + cnonce), the start of every tag
  final String _tagSeed;
  int _seq;
  final _serial = TapoSerial();

  @override
  final DateTime expiresAt;

  @override
  TapoLoginProtocol get protocol => TapoLoginProtocol.v3;

  @override
  Future<Map<String, Object?>> multiple(List<Map<String, Object?>> requests) => _serial.run(() async {
    final inner = jsonEncode({
      'method': 'multipleRequest',
      'params': {'requests': requests},
    });
    final full = jsonEncode({
      'method': 'securePassthrough',
      'params': {'request': base64.encode(aesCbcEncrypt(_lsk, _ivb, utf8.encode(inner)))},
    });
    final seq = _seq;
    _seq++;
    final reply = await transport.post(
      tapoStokPath(stok),
      utf8.encode(full),
      contentType: 'application/json; charset=UTF-8',
      headers: {'Seq': '$seq', 'Tapo_tag': sha256HexUpper('$_tagSeed$full$seq')},
    );
    final answer = _jsonObject(reply.body);
    if (answer == null) {
      throw const TapoSessionRefused(null);
    }
    final encrypted = _map(answer['result'])?['response'];
    if (encrypted is! String) {
      final code = _int(answer['error_code']);
      throw TapoSessionRefused(code ?? -40401);
    }
    try {
      final plain = _jsonObject(aesCbcDecrypt(_lsk, _ivb, base64.decode(encrypted)));
      if (plain == null) {
        throw const FormatException('Not a JSON object');
      }
      return plain;
    } on FormatException {
      // What pytapo sees when the camera ended the session: a padding that does not decrypt
      throw const TapoSessionRefused(-40401);
    }
  });
}

/// The V2 channel: plain JSON to `/stok=<stok>/ds`
class TapoV2Session extends TapoSession {
  TapoV2Session({required this.transport, required this.stok, required this.expiresAt});

  final TapoTransport transport;
  final String stok;
  final _serial = TapoSerial();

  @override
  final DateTime expiresAt;

  @override
  TapoLoginProtocol get protocol => TapoLoginProtocol.v2;

  @override
  Future<Map<String, Object?>> multiple(List<Map<String, Object?>> requests) => _serial.run(() async {
    final reply = await transport.post(
      tapoStokPath(stok),
      utf8.encode(
        jsonEncode({
          'method': 'multipleRequest',
          'params': {'requests': requests},
        }),
      ),
      contentType: 'application/json; charset=UTF-8',
    );
    final answer = _jsonObject(reply.body);
    if (answer == null) {
      throw const TapoSessionRefused(null);
    }
    final code = _int(answer['error_code']);
    if (code == -40401) {
      throw TapoSessionRefused(code);
    }
    return answer;
  });
}

/// Throws the lockout a camera tells, wherever it puts it (Tapo design 2.4 step 8): -40404 the device blocked, -40408
/// the system blocked, a sec_left in error_info, data or result.data, a lockedMinute with no attempt left
void _throwIfLocked(Map<String, Object?> reply) {
  final lockout = tapoLockoutOf(reply);
  if (lockout != null) {
    throw lockout;
  }
}

/// The lockout [reply] tells, null when it tells none
TapoCameraException? tapoLockoutOf(Map<String, Object?> reply) {
  final code = _int(reply['error_code']);
  int? secondsLeft;
  int? lockedMinutes;
  int? dataCode;
  final attemptsLeft = _attemptsLeft(reply);
  for (final holder in [reply['error_info'], reply['data'], _map(reply['result'])?['data']]) {
    final map = _map(holder);
    if (map == null) {
      continue;
    }
    final seconds = _int(map['sec_left']);
    if (seconds != null && seconds > 0) {
      secondsLeft ??= seconds;
    }
    final minutes = _int(map['lockedMinute']);
    if (minutes != null && minutes > 0) {
      lockedMinutes ??= minutes;
    }
    dataCode ??= _int(map['code']);
  }
  final blocked = code == -40404 || code == -40408 || dataCode == -40404 || dataCode == -40408;
  // error_info {failedAttempts, lockedMinute, remainAttempts} goes with every refusal (P§4.1): its lockedMinute may be
  // the length a lock would have, which locks nothing while attempts are left
  final minutes = blocked || attemptsLeft == 0 ? lockedMinutes : null;
  if (!blocked && secondsLeft == null && minutes == null) {
    return null;
  }
  return TapoCameraException(
    TapoErrorKind.locked,
    code: blocked ? (code == -40404 || code == -40408 ? code : dataCode) : code,
    lockedMinutes: minutes ?? (secondsLeft == null ? null : (secondsLeft + 59) ~/ 60),
  );
}

int? _attemptsLeft(Map<String, Object?> reply) {
  for (final holder in [reply['error_info'], reply['data'], _map(reply['result'])?['data']]) {
    final left = _int(_map(holder)?['remainAttempts']);
    if (left != null && left >= 0) {
      return left;
    }
  }
  return null;
}

Map<String, Object?>? _map(Object? value) =>
    value is Map ? value.map((key, entry) => MapEntry('$key', entry as Object?)) : null;

int? _int(Object? value) => value is int ? value : (value is String ? int.tryParse(value.trim()) : null);

/// [bytes] as a JSON object, null when they are not one
Map<String, Object?>? _jsonObject(List<int> bytes) {
  if (bytes.isEmpty || bytes.first != 0x7b) {
    return null;
  }
  try {
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    return _map(decoded);
  } on FormatException {
    return null;
  }
}
