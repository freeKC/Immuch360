// The cryptography of the Tapo logins and media port against what the reference client of tapo-v4-protocol computed
// (test/fixtures/tapo/spake2p_v4_vector.json, a synthetic password) and against published test vectors.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';

void main() {
  final vector = jsonDecode(File('test/fixtures/tapo/spake2p_v4_vector.json').readAsStringSync()) as Map;
  Uint8List hex(String key) => bytesOfHex(vector[key] as String);

  group('SPAKE2+', () {
    late Spake2pOutput output;

    setUpAll(() {
      output = spake2pClient(
        Spake2pInput(
          credential: md5Hex(vector['cloud_password'] as String),
          salt: hex('dev_salt'),
          iterations: vector['iterations'] as int,
          userRandom: hex('user_random'),
          devRandom: hex('dev_random'),
          devShare: hex('dev_share'),
          x: BigInt.parse(vector['x'] as String, radix: 16),
        ),
      );
    });

    test('gives the share and the confirmations of the reference client', () {
      expect(hexOf(output.userShare), vector['user_share']);
      expect(hexOf(output.userConfirm), vector['user_confirm']);
      expect(hexOf(output.expectedDevConfirm), vector['dev_confirm']);
    });

    test('gives the session key and nonce of the reference client', () {
      expect(hexOf(output.key), vector['key']);
      expect(hexOf(output.nonce0), vector['nonce0']);
    });

    test('encrypts a /ds body as the reference client does, and decrypts it back', () {
      final seq = vector['seq'] as int;
      final nonce = Uint8List(12)
        ..setRange(0, 8, output.nonce0)
        ..buffer.asByteData().setUint32(8, seq);
      final inner = Uint8List.fromList(utf8.encode(vector['inner'] as String));
      final body = BytesBuilder()
        ..add((ByteData(4)..setUint32(0, seq)).buffer.asUint8List())
        ..add(aesCcmEncrypt(output.key, nonce, inner));
      final bytes = body.takeBytes();
      expect(hexOf(bytes), vector['ds_body']);
      expect(utf8.decode(aesCcmDecrypt(output.key, nonce, Uint8List.sublistView(bytes, 4))), vector['inner']);
    });

    test('refuses a /ds body whose tag was changed', () {
      final bytes = hex('ds_body');
      bytes[bytes.length - 1] ^= 1;
      final nonce = Uint8List(12)
        ..setRange(0, 8, output.nonce0)
        ..buffer.asByteData().setUint32(8, vector['seq'] as int);
      expect(() => aesCcmDecrypt(output.key, nonce, Uint8List.sublistView(bytes, 4)), throwsFormatException);
    });

    test('refuses a share that is not a point of the curve', () {
      expect(
        () => spake2pClient(
          Spake2pInput(
            credential: 'x',
            salt: Uint8List(16),
            iterations: 1,
            userRandom: Uint8List(32),
            devRandom: Uint8List(32),
            devShare: Uint8List.fromList([4, ...List.filled(64, 1)]),
            x: BigInt.two,
          ),
        ),
        throwsFormatException,
      );
    });
  });

  group('media port', () {
    final password = vector['cloud_password'] as String;
    final hashed = sha256HexUpper(password);

    test('hashes the password as the Digest of the media port wants it', () {
      expect(hashed, vector['media_hashed_pwd']);
      final ha1 = md5Hex('admin:TP-Link IP-Camera:$hashed');
      final ha2 = md5Hex('POST:/stream');
      final response = md5Hex('$ha1:09939140a84cc97b2a27579bb823b2e1:00000001:0123456789abcdef01234567:auth:$ha2');
      expect(response, vector['media_digest_response']);
    });

    test('decrypts a part with the key and IV of the key exchange', () {
      final nonce = vector['media_kx_nonce'] as String;
      final key = md5Bytes(utf8.encode('$nonce:$hashed'));
      final iv = md5Bytes(utf8.encode('admin:$nonce'));
      final decryptor = AesCbcDecryptor(key, iv);
      expect(hexOf(decryptor.decrypt(hex('media_part_cipher'))), vector['media_part_plain']);
      // The cipher starts again from the IV for every part
      expect(hexOf(decryptor.decrypt(hex('media_part_cipher'))), vector['media_part_plain']);
      expect(hexOf(aesCbcEncrypt(key, iv, hex('media_part_plain'))), vector['media_part_cipher']);
    });

    test('refuses a part decrypted with another key', () {
      final decryptor = AesCbcDecryptor(Uint8List(16), Uint8List(16));
      expect(() => decryptor.decrypt(hex('media_part_cipher')), throwsFormatException);
    });
  });

  group('SHA-256 crypt', () {
    // Drepper's published vectors, also in tapo-v4-protocol/tests/test_tapo_v4_ds.py
    test('matches the glibc test vectors', () {
      expect(
        sha256Crypt('Hello world!', r'$5$saltstring'),
        r'$5$saltstring$5B8vYYiY.CVt1RlTTf8KbXBH3hsxY/GNooZaBBGWEc5',
      );
      expect(
        sha256Crypt('Hello world!', r'$5$rounds=10000$saltstringsaltstring'),
        r'$5$rounds=10000$saltstringsaltst$3xv.VbSHBb41AL9AvLeujZkZRBAwqFMz2.opqey6IcA',
      );
      expect(
        sha256Crypt('This is just a test', r'$5$rounds=5000$toolongsaltstring'),
        r'$5$rounds=5000$toolongsaltstrin$Un/5jzAHMgOGZ5.mWJpuVolil07guHPvOW8mGRcvxa5',
      );
      expect(
        sha256Crypt(
          'a very much longer text to encrypt.  This one even stretches over morethan one line.',
          r'$5$rounds=1400$anotherlongsaltstring',
        ),
        r'$5$rounds=1400$anotherlongsalts$Rx.j8H.h8HjEDGomFU8bDkXm3XIUnzyxf12oP84Bnq1',
      );
    });

    test('takes the prefix of a camera, with its trailing dollar', () {
      final crypt = sha256Crypt('x', r'$5$x1hYMevsEYq2APg+$');
      expect(crypt, startsWith(r'$5$x1hYMevsEYq2APg+$'));
      expect(crypt.split(r'$').last, hasLength(43));
    });

    test('is what extra_crypt password_shadow 5 asks for, and nothing is done without extra_crypt', () {
      expect(applyExtraCrypt('abc', null), 'abc');
      expect(
        applyExtraCrypt('Hello world!', {
          'type': 'password_shadow',
          'params': {'passwd_id': 5, 'passwd_prefix': r'$5$saltstring$'},
        }),
        sha256Crypt('Hello world!', r'$5$saltstring'),
      );
      expect(
        applyExtraCrypt('abc', {
          'type': 'password_shadow',
          'params': {'passwd_id': 2},
        }),
        'a9993e364706816aba3e25717850c26c9cd0d89d',
      );
      expect(
        () => applyExtraCrypt('abc', {
          'type': 'password_shadow',
          'params': {'passwd_id': 9},
        }),
        throwsA(isA<TapoCredentialFormException>()),
      );
      expect(() => applyExtraCrypt('abc', {'type': 'password_authkey'}), throwsA(isA<TapoCredentialFormException>()));
    });
  });

  group('hashes and KDFs', () {
    test('hashes as the camera logins do', () {
      expect(md5Hex('admin'), '21232f297a57a5a743894a0e4a801fc3');
      expect(sha256HexUpper('admin'), '8C6976E5B5410415BDE908BD4DEE15DFB167A9C873FC4BB8A81F6F2AB448A918');
      expect(md5HexUpper('admin'), '21232F297A57A5A743894A0E4A801FC3');
    });

    test('derives HKDF-SHA256 as RFC 5869 test case 1', () {
      final okm = hkdfSha256(
        bytesOfHex('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'),
        bytesOfHex('000102030405060708090a0b0c'),
        bytesOfHex('f0f1f2f3f4f5f6f7f8f9'),
        42,
      );
      expect(hexOf(okm), '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865');
    });

    test('derives PBKDF2-HMAC-SHA256 as RFC 7914 does', () {
      expect(
        hexOf(pbkdf2HmacSha256(utf8.encode('passwd'), utf8.encode('salt'), 1, 64)),
        '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc'
        '49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783',
      );
    });

    test('computes the CRC32 of zlib', () {
      expect(crc32(ascii.encode('123456789')), 0xcbf43926);
      expect(crc32(const []), 0);
    });
  });

  group('G.711', () {
    test('decodes A-law as ffmpeg does', () {
      const expected = {0x00: -5504, 0x55: -8, 0xd5: 8, 0x2a: -32256, 0xaa: 32256, 0x80: 5504, 0x7f: -848, 0xff: 848};
      for (final MapEntry(:key, :value) in expected.entries) {
        expect(alawToPcm16[key], value, reason: 'A-law 0x${key.toRadixString(16)}');
      }
    });

    test('decodes µ-law as ffmpeg does', () {
      const expected = {0x00: -32124, 0x7f: 0, 0xff: 0, 0x80: 32124};
      for (final MapEntry(:key, :value) in expected.entries) {
        expect(ulawToPcm16[key], value, reason: 'µ-law 0x${key.toRadixString(16)}');
      }
    });

    test('encodes A-law back to the same code for every code', () {
      for (var code = 0; code < 256; code++) {
        expect(pcm16ToAlaw(alawToPcm16[code]), code, reason: 'A-law 0x${code.toRadixString(16)}');
      }
    });
  });
}
