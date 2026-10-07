// A fake Tapo camera behind the TapoTransport of the protocol layer, in memory: the device side of the V4 login
// (SPAKE2+ with the verifier of pytapo's test_tpap.py, the SHA-256 crypt shadow of a C200, the user name forms), of the
// V3 login (-40413, device_confirm, digest_passwd, Tapo_tag) and of the V2 one, and of their control channels, with
// lockouts, dead sessions and a small set of read methods answering synthetic data. Synthetic values only: MAC
// 02-00-00-00-00-01, addresses in 192.0.2.0/24.

import 'dart:convert';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_https.dart';
import 'package:pointycastle/export.dart';

const fakeCameraHost = '192.0.2.30';
const fakeCameraMac = '02-00-00-00-00-01';
const fakeCameraCertificate = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

/// The answer of a read method, from its params; null for a method the camera does not know (-40106)
typedef FakeMethod = Object? Function(Map<String, Object?> params);

/// The device side of SPAKE2+: w0 and w1 of the credential, the share Y = y*G + w0*N, and the confirmations and keys
/// once the client's share is known (RFC 9383, as the fake camera of pytapo's test_tpap.py)
class Spake2pVerifier {
  Spake2pVerifier({required String credential, required this.salt, required this.iterations}) {
    final dk = pbkdf2HmacSha256(utf8.encode(credential), salt, iterations, 80);
    _w0 = bigIntOf(dk.sublist(0, 40)) % p256Order;
    _w1 = bigIntOf(dk.sublist(40, 80)) % p256Order;
    devShare = ((p256.G * _y)! + (spake2pN * _w0))!.getEncoded(false);
  }

  final Uint8List salt;
  final int iterations;
  final BigInt _y = randomP256Scalar();
  late final BigInt _w0;
  late final BigInt _w1;
  late final Uint8List devShare;

  ({Uint8List userConfirm, Uint8List devConfirm, Uint8List key, Uint8List nonce0}) confirm(
    Uint8List userShare,
    Uint8List userRandom,
    Uint8List devRandom,
  ) {
    final ECPoint x = p256.curve.decodePoint(userShare)!;
    final h = (x - (spake2pM * _w0)!)!;
    final z = (h * _y)!;
    final v = ((p256.G * _w1)! * _y)!;
    final context = sha256Bytes([...utf8.encode('PAKE V1'), ...userRandom, ...devRandom]);
    final transcript = BytesBuilder();
    for (final element in [
      context,
      Uint8List(0),
      Uint8List(0),
      spake2pM.getEncoded(false),
      spake2pN.getEncoded(false),
      userShare,
      devShare,
      z.getEncoded(false),
      v.getEncoded(false),
      bytesOfBigInt(_w0, 32),
    ]) {
      transcript
        ..add((ByteData(8)..setUint64(0, element.length, Endian.little)).buffer.asUint8List())
        ..add(element);
    }
    final ke = sha256Bytes(transcript.takeBytes());
    final confirmation = hkdfSha256(ke, null, utf8.encode('ConfirmationKeys'), 64);
    final shared = hkdfSha256(ke, null, utf8.encode('SharedKey'), 32);
    return (
      userConfirm: hmacSha256(confirmation.sublist(0, 32), devShare),
      devConfirm: hmacSha256(confirmation.sublist(32), userShare),
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
}

/// See the header
class FakeTapoCamera implements TapoTransport {
  FakeTapoCamera({
    this.protocol = TapoLoginProtocol.v4,
    this.cloudPassword = 'synthetic-cloud-password',
    this.passcode = TapoPasscodeHash.md5,
    this.shadow = false,
    this.userName = TapoUserNameForm.md5,
    this.startSeq = 1000,
    this.userGroup = 'root',
    this.iterations = 1000,
    this.certificate = fakeCameraCertificate,
    Map<String, FakeMethod>? methods,
  }) : methods = methods ?? defaultFakeMethods();

  final TapoLoginProtocol protocol;
  String cloudPassword;
  final TapoPasscodeHash passcode;

  /// Answers pake_register with the password_shadow 5 of a C200
  final bool shadow;
  final TapoUserNameForm userName;
  final int startSeq;
  final String userGroup;
  final int iterations;
  final String certificate;
  final Map<String, FakeMethod> methods;

  @override
  String get host => fakeCameraHost;

  @override
  String? get certificateSha256 => certificate;

  // What the tests look at
  final List<String> calls = [];
  final List<String> registeredUserNames = [];
  int shares = 0;
  int refusedShares = 0;
  int logins = 0;
  final List<Uint8List> bodies = [];
  final List<Map<String, String>> headers = [];

  /// The pake_share answers to refuse with -40401 before accepting (a C200 right after its previous session)
  int refuseNextShares = 0;

  /// The lockout to answer to the next login request
  Map<String, Object?>? lockout;

  /// The lockedMinute of the error_info of a refused pake_share, which some cameras may send with every refusal
  int refusalLockedMinute = 0;

  /// The iteration count pake_register tells instead of the one of the verifier (a device asking for a huge one)
  int? reportedIterations;

  /// The posts to fail as a network failure
  int failNextPosts = 0;

  /// Refuses every request of a session in plain text, as a camera that keeps ending its sessions
  bool refuseRequests = false;
  bool closed = false;

  // The live session
  String? _stok;
  int? _expectSeq;
  Uint8List? _key;
  Uint8List? _nonce0;
  Spake2pVerifier? _verifier;
  String? _userRandom;
  String? _devRandom;
  String? _cnonce;
  String? _v3Nonce;
  String? _v3Hashed;
  Uint8List? _lsk;
  Uint8List? _ivb;

  /// Ends the session on the camera's side: the next request gets -40401
  void killSession() => _stok = null;

  bool get hasSession => _stok != null;

  /// Every stok given, for the tests that look for them where they must not be
  final List<String> stoks = [];

  String get _passcodeText => passcode == TapoPasscodeHash.md5 ? md5Hex(cloudPassword) : sha256HexUpper(cloudPassword);

  String get _shadowPrefix => r'$5$x1hYMevsEYq2APg+$';

  String _credential() => shadow ? sha256Crypt(_passcodeText, _shadowPrefix) : _passcodeText;

  String get _expectedUserName => switch (userName) {
    TapoUserNameForm.md5 => md5Hex('admin'),
    TapoUserNameForm.plain => 'admin',
    TapoUserNameForm.sha256 => sha256HexUpper('admin'),
  };

  @override
  Future<TapoHttpReply> post(
    String path,
    List<int> body, {
    required String contentType,
    Map<String, String> headers = const {},
  }) async {
    if (closed) {
      throw const TapoNetworkException('closed');
    }
    if (failNextPosts > 0) {
      failNextPosts--;
      throw const TapoNetworkException('socket');
    }
    final bytes = Uint8List.fromList(body);
    bodies.add(bytes);
    this.headers.add(headers);
    if (path == '/') {
      return _json(_login(jsonDecode(utf8.decode(bytes)) as Map<String, Object?>));
    }
    final stok = _stok;
    if (refuseRequests || stok == null || path != tapoStokPath(stok)) {
      return _json({'error_code': -40401});
    }
    return switch (protocol) {
      TapoLoginProtocol.v4 => _dsV4(bytes),
      TapoLoginProtocol.v3 => _dsV3(bytes, headers),
      TapoLoginProtocol.v2 => _json(_answer(jsonDecode(utf8.decode(bytes)) as Map<String, Object?>)),
    };
  }

  TapoHttpReply _json(Object? value) => (status: 200, body: Uint8List.fromList(utf8.encode(jsonEncode(value))));

  Map<String, Object?> _login(Map<String, Object?> request) {
    final params = (request['params']! as Map).cast<String, Object?>();
    final locked = lockout;
    if (locked != null) {
      lockout = null;
      return locked;
    }
    if (params['sub_method'] == 'pake_register') {
      if (protocol != TapoLoginProtocol.v4) {
        return {'error_code': -40210};
      }
      registeredUserNames.add('${params['username']}');
      if (params['username'] != _expectedUserName) {
        return {'error_code': -40209};
      }
      final salt = Uint8List.fromList(List.generate(16, (i) => i));
      _verifier = Spake2pVerifier(credential: _credential(), salt: salt, iterations: iterations);
      _userRandom = '${params['user_random']}';
      _devRandom = base64.encode(randomBytes(32));
      return {
        'error_code': 0,
        'result': {
          'dev_salt': base64.encode(salt),
          'dev_share': base64.encode(_verifier!.devShare),
          'dev_random': _devRandom,
          'iterations': reportedIterations ?? iterations,
          'cipher_suites': 1,
          'encryption': 'aes_128_ccm',
          if (shadow)
            'extra_crypt': {
              'type': 'password_shadow',
              'params': {'passwd_id': 5, 'passwd_prefix': _shadowPrefix},
            },
        },
      };
    }
    if (params['sub_method'] == 'pake_share') {
      shares++;
      final verifier = _verifier!;
      final confirmed = verifier.confirm(
        base64.decode('${params['user_share']}'),
        base64.decode(_userRandom!),
        base64.decode(_devRandom!),
      );
      if (refuseNextShares > 0 || !sameBytes(base64.decode('${params['user_confirm']}'), confirmed.userConfirm)) {
        if (refuseNextShares > 0) {
          refuseNextShares--;
        }
        refusedShares++;
        return {
          'error_code': -40401,
          'error_info': {
            'failedAttempts': refusedShares,
            'remainAttempts': 5 - refusedShares,
            'lockedMinute': refusalLockedMinute,
          },
        };
      }
      logins++;
      _key = confirmed.key;
      _nonce0 = confirmed.nonce0;
      _stok = 'S!t*o(k)~${logins.toString().padLeft(4, '0')}abcdefghijklmnopq';
      stoks.add(_stok!);
      _expectSeq = startSeq + logins * 100;
      return {
        'error_code': 0,
        'result': {
          'dev_confirm': base64.encode(confirmed.devConfirm),
          'stok': _stok,
          'start_seq': _expectSeq,
          'expired': 3600,
        },
      };
    }
    // V3 and V2
    if (params['encrypt_type'] == '3' && params['digest_passwd'] == null) {
      if (protocol == TapoLoginProtocol.v4) {
        return {'error_code': -40211};
      }
      if (protocol == TapoLoginProtocol.v2) {
        return {'error_code': -40210};
      }
      _cnonce = '${params['cnonce']}';
      _v3Nonce = 'ABCDEF0123456789';
      _v3Hashed = passcode == TapoPasscodeHash.sha256 ? sha256HexUpper(cloudPassword) : md5HexUpper(cloudPassword);
      return {
        'error_code': -40413,
        'result': {
          'data': {
            'code': -40413,
            'encrypt_type': ['3'],
            'nonce': _v3Nonce,
            'device_confirm': '${sha256HexUpper(_cnonce! + _v3Hashed! + _v3Nonce!)}$_v3Nonce$_cnonce',
          },
        },
      };
    }
    if (params['digest_passwd'] != null) {
      final expected = '${sha256HexUpper(_v3Hashed! + _cnonce! + _v3Nonce!)}$_cnonce$_v3Nonce';
      if (params['digest_passwd'] != expected) {
        refusedShares++;
        return {'error_code': -40401};
      }
      logins++;
      final key = sha256HexUpper(_cnonce! + _v3Hashed! + _v3Nonce!);
      _lsk = sha256Bytes(utf8.encode('lsk$_cnonce$_v3Nonce$key')).sublist(0, 16);
      _ivb = sha256Bytes(utf8.encode('ivb$_cnonce$_v3Nonce$key')).sublist(0, 16);
      _stok = 'v3stok$logins${hexOf(randomBytes(8))}';
      stoks.add(_stok!);
      _expectSeq = startSeq + logins * 100;
      return {
        'error_code': 0,
        'result': {'stok': _stok, 'start_seq': _expectSeq, 'user_group': userGroup},
      };
    }
    if (params['hashed'] == true) {
      if (protocol != TapoLoginProtocol.v2 || params['password'] != md5HexUpper(cloudPassword)) {
        refusedShares++;
        return {'error_code': -40401};
      }
      logins++;
      _stok = 'v2stok$logins';
      return {
        'error_code': 0,
        'result': {'stok': _stok},
      };
    }
    return {'error_code': -40209};
  }

  TapoHttpReply _dsV4(Uint8List body) {
    final seq = ByteData.sublistView(body, 0, 4).getUint32(0);
    if (seq != (_expectSeq! & 0xffffffff)) {
      _stok = null;
      return _json({'error_code': -40401});
    }
    final nonce = Uint8List(12)
      ..setRange(0, 8, _nonce0!)
      ..buffer.asByteData().setUint32(8, seq);
    final Uint8List plain;
    try {
      plain = aesCcmDecrypt(_key!, nonce, Uint8List.sublistView(body, 4));
    } on FormatException {
      _stok = null;
      return _json({'error_code': -40401});
    }
    _expectSeq = _expectSeq! + 1;
    final inner = jsonDecode(utf8.decode(plain)) as Map<String, Object?>;
    if (inner['method'] != 'multipleRequest') {
      return _json({'error_code': -40209});
    }
    final answer = Uint8List.fromList(utf8.encode(jsonEncode(_answer(inner))));
    return (status: 200, body: Uint8List.fromList([...body.sublist(0, 4), ...aesCcmEncrypt(_key!, nonce, answer)]));
  }

  TapoHttpReply _dsV3(Uint8List body, Map<String, String> headers) {
    final full = utf8.decode(body);
    final seq = int.parse(headers['Seq']!);
    final tag = sha256HexUpper('${sha256HexUpper(_v3Hashed! + _cnonce!)}$full$seq');
    if (seq != _expectSeq || headers['Tapo_tag'] != tag) {
      _stok = null;
      return _json({'error_code': -40401});
    }
    _expectSeq = _expectSeq! + 1;
    final request = jsonDecode(full) as Map<String, Object?>;
    final encrypted = '${(request['params']! as Map)['request']}';
    final inner =
        jsonDecode(utf8.decode(aesCbcDecrypt(_lsk!, _ivb!, base64.decode(encrypted)))) as Map<String, Object?>;
    final answer = utf8.encode(jsonEncode(_answer(inner)));
    return _json({
      'error_code': 0,
      'result': {'response': base64.encode(aesCbcEncrypt(_lsk!, _ivb!, answer))},
    });
  }

  Map<String, Object?> _answer(Map<String, Object?> inner) {
    final requests = ((inner['params']! as Map)['requests'] as List).cast<Map>();
    return {
      'error_code': 0,
      'result': {
        'responses': [
          for (final request in requests) _method('${request['method']}', (request['params'] as Map).cast()),
        ],
      },
    };
  }

  Map<String, Object?> _method(String method, Map<String, Object?> params) {
    calls.add(method);
    final handler = methods[method];
    if (handler == null) {
      return {'method': method, 'error_code': -40106};
    }
    final result = handler(params);
    if (result is int) {
      return {'method': method, 'error_code': result};
    }
    return {'method': method, 'result': result, 'error_code': 0};
  }

  @override
  void close() {}
}

/// A C200 with a memory card, in Europe/Brussels, that recorded on 2026-09-18 (three clips) and 2026-09-17
Map<String, FakeMethod> defaultFakeMethods({Map<String, List<(int, int, String)>>? clipsByDay, int playback = 6}) {
  final clips =
      clipsByDay ??
      {
        // 2026-09-18 in Europe/Brussels: 1789682400 to 1789768799
        '2026-09-18': [(1789683060, 1789683144, '2'), (1789700000, 1789700060, '6'), (1789750000, 1789750600, '1')],
        '2026-09-17': [(1789600000, 1789600030, '9')],
      };
  return {
    'getDeviceInfo': (_) => {
      'device_info': {
        'basic_info': {
          'device_type': 'SMART.IPCAMERA',
          'device_model': 'C200',
          'sw_version': '1.4.6 Build 260709 Rel.1n',
          'hw_version': '5.0',
          'device_alias': 'Garden',
          'mac': fakeCameraMac.toUpperCase(),
        },
      },
    },
    'getTimezone': (_) => {
      'system': {
        'basic': {'timing_mode': 'ntp', 'zone_id': 'Europe/Brussels', 'timezone': 'UTC+01:00'},
      },
    },
    'getSdCardStatus': (_) => {
      'harddisk_manage': {
        'hd_info': [
          {
            'hd_info_1': {
              'status': 'normal',
              'total_space_accurate': '119453777920B',
              'free_space_accurate': '124926940B',
              'record_start_time': '1779527888',
            },
          },
        ],
      },
    },
    'getAppComponentList': (_) => {
      'app_component': {
        'app_component_list': [
          {'name': 'sdCard', 'version': 1},
          {'name': 'playback', 'version': playback},
          {'name': 'recordDownload', 'version': 2},
        ],
      },
    },
    'searchDateWithVideo': (_) => {
      'playback': {
        'search_results': [
          for (final (index, day) in clips.keys.indexed)
            {
              'search_results_${index + 1}': {'date': day.replaceAll('-', '')},
            },
        ],
      },
    },
    'searchVideoWithUTC': (params) {
      final query = ((params['playback']! as Map)['search_video_with_utc'] as Map).cast<String, Object?>();
      final start = query['start_time']! as int;
      final end = query['end_time']! as int;
      final all = [
        for (final day in clips.values)
          for (final clip in day)
            if (clip.$1 >= start && clip.$1 <= end) clip,
      ];
      final from = query['start_index']! as int;
      final to = (query['end_index']! as int) + 1;
      final page = all.sublist(from.clamp(0, all.length), to.clamp(0, all.length));
      return {
        'playback': {
          'search_video_results': [
            for (final (index, clip) in page.indexed)
              {
                'search_video_results_${from + index + 1}': {
                  'startTime': clip.$1,
                  'endTime': clip.$2,
                  'video_type': clip.$3,
                },
              },
          ],
          'to_be_continued': to < all.length ? 1 : 0,
        },
      };
    },
  };
}
