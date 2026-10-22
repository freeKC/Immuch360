import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';

/// The known answers of make_vectors.py, made with the Python cryptography package
List<Map<String, dynamic>> _vectors() {
  final file = File('test/fixtures/pairing/vectors.json');
  final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return (decoded['vectors'] as List).cast<Map<String, dynamic>>();
}

Uint8List _b64(Object? text) => pairingDecodeBase64(text)!;

void main() {
  group('known answers', () {
    for (final vector in _vectors()) {
      test(vector['name'], () {
        final phone = PairingKeyPair.fromPrivate(BigInt.parse(vector['phonePrivate'], radix: 16));
        final screen = PairingKeyPair.fromPrivate(BigInt.parse(vector['screenPrivate'], radix: 16));
        expect(pairingBase64(phone.publicKey), vector['phonePublic']);
        expect(pairingBase64(screen.publicKey), vector['screenPublic']);

        final shared = phone.agree(screen.publicKey)!;
        expect(pairingBase64(shared), vector['shared']);
        expect(screen.agree(phone.publicKey), shared);

        final transcript = pairingTranscript(
          id: vector['id'],
          mode: PairingMode.fromWire(vector['mode'])!,
          client: PairingClient.fromWire(vector['client'])!,
          phoneKey: phone.publicKey,
          screenKey: screen.publicKey,
        );
        expect(pairingBase64(transcript), vector['transcript']);

        final keys = derivePairingKeys(shared: shared, secret: _b64(vector['secret']), transcript: transcript);
        expect(pairingBase64(keys.confirm), vector['kConfirm']);
        expect(pairingBase64(keys.up), vector['kUp']);
        expect(pairingBase64(keys.down), vector['kDown']);

        final confirm = pairingConfirm(
          confirmKey: keys.confirm,
          transcript: transcript,
          device: _b64(vector['device']),
        );
        expect(pairingBase64(confirm), vector['confirm']);
        expect(pairingCheckNumber(confirmKey: keys.confirm, transcript: transcript), vector['check']);

        final sealedUp = pairingSeal(
          keys: keys,
          transcript: transcript,
          direction: PairingDirection.up,
          nonce: _b64(vector['nonceUp']),
          plain: _b64(vector['plainUp']),
        );
        expect(pairingBase64(sealedUp), vector['sealedUp']);
        final sealedDown = pairingSeal(
          keys: keys,
          transcript: transcript,
          direction: PairingDirection.down,
          nonce: _b64(vector['nonceDown']),
          plain: _b64(vector['plainDown']),
        );
        expect(pairingBase64(sealedDown), vector['sealedDown']);

        final opened = pairingOpen(
          keys: keys,
          transcript: transcript,
          direction: PairingDirection.up,
          nonce: _b64(vector['nonceUp']),
          sealed: _b64(vector['sealedUp']),
        );
        expect(opened, _b64(vector['plainUp']));
      });
    }

    test('the device bytes of the screen are its JSON with the keys sorted', () {
      final first = _vectors().first;
      expect(
        pairingDeviceBytes({'os': 'Android', 'label': 'Living room TV', 'kind': 'tv', 'app': '3.3.0'}),
        _b64(first['device']),
      );
    });
  });

  group('the encryption refuses', () {
    final vector = _vectors().first;
    final phone = PairingKeyPair.fromPrivate(BigInt.parse(vector['phonePrivate'], radix: 16));
    final screen = PairingKeyPair.fromPrivate(BigInt.parse(vector['screenPrivate'], radix: 16));
    final transcript = _b64(vector['transcript']);
    final keys = derivePairingKeys(
      shared: phone.agree(screen.publicKey)!,
      secret: _b64(vector['secret']),
      transcript: transcript,
    );
    final nonce = _b64(vector['nonceUp']);
    final sealed = _b64(vector['sealedUp']);

    Uint8List? open({
      PairingKeys? withKeys,
      List<int>? withTranscript,
      PairingDirection direction = PairingDirection.up,
      Uint8List? withNonce,
      Uint8List? withSealed,
    }) => pairingOpen(
      keys: withKeys ?? keys,
      transcript: withTranscript ?? transcript,
      direction: direction,
      nonce: withNonce ?? nonce,
      sealed: withSealed ?? sealed,
    );

    test('a changed byte', () {
      final changed = Uint8List.fromList(sealed)..[3] ^= 1;
      expect(open(withSealed: changed), isNull);
      final changedTag = Uint8List.fromList(sealed)..[sealed.length - 1] ^= 0x80;
      expect(open(withSealed: changedTag), isNull);
    });

    test('the other direction', () {
      expect(open(direction: PairingDirection.down), isNull);
    });

    test('another transcript', () {
      final other = Uint8List.fromList(transcript)..[0] ^= 1;
      expect(open(withTranscript: other), isNull);
    });

    test('keys made with another secret', () {
      final wrong = derivePairingKeys(
        shared: phone.agree(screen.publicKey)!,
        secret: Uint8List(16),
        transcript: transcript,
      );
      expect(open(withKeys: wrong), isNull);
    });

    test('a short or missing tag, a nonce of another size', () {
      expect(open(withSealed: Uint8List(15)), isNull);
      expect(open(withNonce: Uint8List(8)), isNull);
    });
  });

  group('the transcript', () {
    final phone = PairingKeyPair.fromPrivate(BigInt.from(12345));
    final screen = PairingKeyPair.fromPrivate(BigInt.from(67890));
    Uint8List of({
      String id = 'AAECAwQFBgc',
      PairingMode mode = PairingMode.qr,
      PairingClient client = PairingClient.app,
      Uint8List? phoneKey,
      Uint8List? screenKey,
    }) => pairingTranscript(
      id: id,
      mode: mode,
      client: client,
      phoneKey: phoneKey ?? phone.publicKey,
      screenKey: screenKey ?? screen.publicKey,
    );

    test('changes with every field', () {
      final base = of();
      expect(of(id: 'AAECAwQFBgg'), isNot(base));
      expect(of(mode: PairingMode.code), isNot(base));
      expect(of(client: PairingClient.web), isNot(base));
      expect(of(phoneKey: screen.publicKey, screenKey: phone.publicKey), isNot(base));
      expect(of(), base);
    });
  });

  group('the keys', () {
    test('two new pairs agree, and the public keys are compressed points', () {
      final random = Random(7);
      final a = PairingKeyPair.generate(random);
      final b = PairingKeyPair.generate(random);
      expect(a.publicKey.length, 33);
      expect(a.publicKey.first, anyOf(2, 3));
      expect(a.agree(b.publicKey), b.agree(a.publicKey));
      expect(a.agree(b.publicKey)!.length, 32);
    });

    test('a key that is not a compressed point of the curve is refused', () {
      final a = PairingKeyPair.generate(Random(1));
      expect(a.agree(Uint8List(33)), isNull);
      expect(a.agree(Uint8List.fromList([4, ...List.filled(64, 1)])), isNull);
      expect(a.agree(Uint8List.fromList([2, ...List.filled(31, 0xff)])), isNull);
      // x = 1 has no point on P-256, x = 5 has one
      expect(a.agree(Uint8List.fromList([2, ...List.filled(31, 0), 1])), isNull);
      expect(a.agree(Uint8List.fromList([2, ...List.filled(31, 0), 5])), isNotNull);
    });

    test('bytes are compared in full', () {
      expect(pairingSameBytes([1, 2, 3], [1, 2, 3]), isTrue);
      expect(pairingSameBytes([1, 2, 3], [1, 2, 4]), isFalse);
      expect(pairingSameBytes([1, 2, 3], [1, 2]), isFalse);
    });
  });

  group('a channel', () {
    test('seals for the other side only, bound to the hello', () {
      final vector = _vectors().first;
      final transcript = _b64(vector['transcript']);
      final keys = PairingKeys(confirm: _b64(vector['kConfirm']), up: _b64(vector['kUp']), down: _b64(vector['kDown']));
      final phone = PairingChannel(transcript: transcript, keys: keys, sends: PairingDirection.up);
      final screen = PairingChannel(transcript: transcript, keys: keys, sends: PairingDirection.down);

      final envelope = phone.seal({'v': 1, 'token': 'abc'});
      expect(envelope['h'], phone.handle);
      expect(phone.handle, pairingBase64(transcript.sublist(0, 8)));
      expect(screen.open(envelope), {'v': 1, 'token': 'abc'});
      // Its own message does not open as one from the other side
      expect(phone.open(envelope), isNull);
      expect(screen.open({...envelope, 'c': 'AAAA'}), isNull);
      expect(screen.open({...envelope, 'n': 'not base64!'}), isNull);
      // Every message has its own nonce
      expect(phone.seal({'v': 1})['n'], isNot(phone.seal({'v': 1})['n']));
    });
  });

  group('the QR code text', () {
    final secret = Uint8List.fromList(List.generate(16, (i) => i + 1));
    final text = buildPairingQrText(host: '192.168.1.23', port: 8361, id: 'AAECAwQFBgc', secret: secret);

    test('is read back', () {
      expect(text, 'http://192.168.1.23:8361/p#1.AAECAwQFBgc.AQIDBAUGBwgJCgsMDQ4PEA');
      final scan = parsePairingText(text);
      expect(scan, isA<PairingTarget>());
      final target = scan as PairingTarget;
      expect(target.host, '192.168.1.23');
      expect(target.port, 8361);
      expect(target.id, 'AAECAwQFBgc');
      expect(target.secret, secret);
      expect(target.mode, PairingMode.qr);
      expect(target.toString(), isNot(contains('AQIDBAUGBwgJCgsMDQ4PEA')));
    });

    test('is read wrapped in the deep link of the app, once', () {
      final link = Uri(scheme: 'immuch360', host: 'pair', queryParameters: {'u': text}).toString();
      expect(parsePairingText(link), isA<PairingTarget>());
      final twice = Uri(scheme: 'immuch360', host: 'pair', queryParameters: {'u': link}).toString();
      expect(parsePairingText(twice), isA<NotAPairingCode>());
    });

    test('accepts every private range and nothing else', () {
      for (final host in ['10.0.2.2', '172.16.0.1', '172.31.255.254', '192.168.0.1', '169.254.10.20']) {
        expect(parsePairingText(text.replaceFirst('192.168.1.23', host)), isA<PairingTarget>(), reason: host);
      }
      for (final host in [
        '8.8.8.8',
        '172.32.0.1',
        '172.15.0.1',
        '127.0.0.1',
        '0.0.0.0',
        '192.169.1.1',
        '192.168.01.1',
        '192.168.1',
        '192.168.1.256',
        'tv.local',
        '[fd00::1]',
        '0xc0.168.1.1',
      ]) {
        expect(parsePairingText(text.replaceFirst('192.168.1.23', host)), isA<NotAPairingCode>(), reason: host);
      }
    });

    test('refuses anything but the exact form', () {
      for (final other in [
        text.replaceFirst('http://', 'https://'),
        text.replaceFirst(':8361', ''),
        text.replaceFirst('/p#', '/q#'),
        text.replaceFirst('/p#', '/p?x=1#'),
        text.replaceFirst('#1.', '#2.'),
        text.replaceFirst('AAECAwQFBgc', 'AAECAwQFBg'),
        '${text}A',
        text.replaceFirst('http://', 'http://user@'),
        text.split('#').first,
        'immuch360://pair',
        'hello',
        '',
        'http://192.168.1.23:8361/p#1.AAECAwQFBgc.${'A' * 600}',
      ]) {
        expect(parsePairingText(other), isA<NotAPairingCode>(), reason: other);
      }
    });

    test('recognises a code of the LG webOS app', () {
      final scan = parsePairingText('http://192.168.1.40:8788/?c=K7M2Q9XR&u=https%3A%2F%2Fphotos.example.com');
      expect(scan, isA<WebOsPairingLink>());
      expect(parsePairingText('http://192.168.1.40:8788/?u=x'), isA<NotAPairingCode>());
      expect(parsePairingText('http://8.8.8.8:8788/?c=K7M2Q9XR'), isA<NotAPairingCode>());
    });
  });

  group('the short code', () {
    test('is made of the alphabet', () {
      final code = newPairingCode(Random(3));
      expect(code.length, pairingCodeLength);
      expect(code.split('').every(pairingCodeAlphabet.contains), isTrue);
      expect(pairingCodeAlphabet.length, 31);
    });

    test('is read without case, spaces or dashes', () {
      expect(normalizePairingCode('k7m2q 9xrth'), 'K7M2Q9XRTH');
      expect(normalizePairingCode(' K7M2Q-9XRTH '), 'K7M2Q9XRTH');
      expect(formatPairingCode('K7M2Q9XRTH'), 'K7M2Q 9XRTH');
    });

    test('symbols that read alike are not guessed', () {
      expect(normalizePairingCode('K7M2Q9XRT0'), isNull);
      expect(normalizePairingCode('K7M2Q9XRTI'), isNull);
      expect(normalizePairingCode('K7M2Q9XRT'), isNull);
      expect(normalizePairingCode('K7M2Q9XRTHH'), isNull);
    });

    test('a target with a code mixes the code into the keys', () {
      const target = PairingTarget(host: '10.0.0.2', port: 8361, id: 'AAECAwQFBgc', code: 'K7M2Q9XRTH');
      expect(target.mode, PairingMode.code);
      expect(target.secretBytes, utf8.encode('K7M2Q9XRTH'));
      expect(target.toString(), isNot(contains('K7M2Q')));
    });
  });

  group('a typed address', () {
    test('is read with or without its port and path', () {
      expect(parsePairingAddress('192.168.1.23:8362'), (host: '192.168.1.23', port: 8362));
      expect(parsePairingAddress('http://192.168.1.23:8361/p'), (host: '192.168.1.23', port: 8361));
      expect(parsePairingAddress(' 10.0.0.4 '), (host: '10.0.0.4', port: 8361));
    });

    test('only on a private address', () {
      expect(parsePairingAddress('8.8.8.8:8361'), isNull);
      expect(parsePairingAddress('https://192.168.1.23:8361/p'), isNull);
      expect(parsePairingAddress('192.168.1.23:8361/other'), isNull);
      expect(parsePairingAddress(''), isNull);
    });
  });

  group('a link of a screen', () {
    test('gives its address only, never a secret', () {
      const page = 'http://192.168.1.23:8361/p';
      expect(parsePairingLink('immuch360://pair?u=${Uri.encodeComponent(page)}'), (host: '192.168.1.23', port: 8361));
      // An old link, or a forged one, with the secret of a code: the address alone is kept
      const withSecret = '$page#1.AAECAwQFBgc.AQIDBAUGBwgJCgsMDQ4PEA';
      expect(parsePairingLink('immuch360://pair?u=${Uri.encodeComponent(withSecret)}'), (
        host: '192.168.1.23',
        port: 8361,
      ));
    });

    test('refuses anything else', () {
      expect(parsePairingLink('immuch360://pair'), isNull);
      expect(parsePairingLink('immuch360://other?u=192.168.1.23:8361'), isNull);
      expect(parsePairingLink('immich://pair?u=192.168.1.23:8361'), isNull);
      expect(parsePairingLink('immuch360://pair?u=${Uri.encodeComponent('http://8.8.8.8:8361/p')}'), isNull);
      expect(parsePairingLink('immuch360://pair?u=${Uri.encodeComponent('http://evil.example/p')}'), isNull);
    });
  });

  group('the check number', () {
    test('six digits, the same on both sides, another for another hello', () {
      final transcript = Uint8List.fromList(List.generate(32, (i) => i));
      final key = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      final check = pairingCheckNumber(confirmKey: key, transcript: transcript);
      expect(check, matches(RegExp(r'^[0-9]{6}$')));
      expect(pairingCheckNumber(confirmKey: key, transcript: transcript), check);
      expect(pairingCheckNumber(confirmKey: key, transcript: Uint8List(32)), isNot(check));
      expect(formatPairingCheckNumber('048213'), '048 213');
    });
  });

  group('names', () {
    test('lose controls, bidi overrides and zero width characters', () {
      expect(cleanPairingText('Living\u202Eroom TV'), 'Livingroom TV');
      expect(cleanPairingText('\u2067Lounge\u2069 \u200BTV\uFEFF'), 'Lounge TV');
      expect(cleanPairingText('Line\none\u2028two\ttab\u0085'), 'Line one two tab');
      expect(cleanPairingText('  Fred’s PC été  '), 'Fred’s PC été');
    });
  });

  group('base64url', () {
    test('without padding only', () {
      expect(pairingDecodeBase64('AQID'), [1, 2, 3]);
      expect(pairingDecodeBase64('AQI'), [1, 2]);
      expect(pairingDecodeBase64('AQI='), isNull);
      expect(pairingDecodeBase64('A+I/'), isNull);
      expect(pairingDecodeBase64('A'), isNull);
      expect(pairingDecodeBase64(12), isNull);
    });
  });
}
