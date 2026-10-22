import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/pairing/screen_pairing_session.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_server.dart';
import 'package:logging/logging.dart';

const _device = {'app': '3.3.0', 'kind': 'tv', 'label': 'Living room TV', 'os': 'Android'};
const _token = 'session-token-1234567890';

class _FakeSignIn implements PairingSignIn {
  final sessions = <Map<String, Object?>>[];
  final logins = <Map<String, Object?>>[];
  PairingSignInResult sessionResult = const PairingSignInResult(
    answer: {'status': 'signedIn', 'label': 'Living room TV'},
    signedIn: true,
  );

  @override
  Future<PairingSignInResult> withSession(Map<String, Object?> payload) async {
    sessions.add(payload);
    return sessionResult;
  }

  @override
  Future<PairingSignInResult> withPassword(Map<String, Object?> credentials) async {
    logins.add(credentials);
    final right = credentials['password'] == 'right';
    return PairingSignInResult(
      answer: {'status': right ? 'signedIn' : 'badCredentials'},
      signedIn: right,
      retry: !right,
    );
  }
}

class _Answer {
  _Answer(this.status, this.headers, this.body);
  final int status;
  final HttpHeaders headers;
  final Uint8List body;
  Map<String, Object?> get json => jsonDecode(utf8.decode(body)) as Map<String, Object?>;
}

void main() {
  late ScreenPairingSession session;
  late _FakeSignIn signIn;
  late PairingServer server;
  late int port;
  late bool allowed;
  late List<LogRecord> logs;
  late StreamSubscription<LogRecord> logListener;
  final page = PairingPage(
    html: Uint8List.fromList(utf8.encode('<!doctype html><title>pair</title>')),
    script: Uint8List.fromList(utf8.encode('console.log(1)')),
    style: Uint8List.fromList(utf8.encode('body{}')),
    texts: const {'pairing_web_intro': 'Sign in your TV'},
  );

  setUp(() async {
    session = ScreenPairingSession(device: _device, random: Random(5))..start();
    signIn = _FakeSignIn();
    allowed = true;
    server = PairingServer(
      session: session,
      signIn: signIn,
      page: page,
      device: _device,
      isAllowedClient: (_) => allowed,
      preferredPort: 0,
      requestTimeout: const Duration(seconds: 1),
    );
    port = await server.start();
    logs = [];
    Logger.root.level = Level.ALL;
    logListener = Logger.root.onRecord.listen(logs.add);
  });

  tearDown(() async {
    await logListener.cancel();
    await server.stop();
    await session.dispose();
  });

  Future<_Answer> send(
    String method,
    String path, {
    Object? json,
    List<int>? raw,
    ContentType? contentType,
    String? host,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.open(method, '127.0.0.1', port, path);
      if (host != null) {
        request.headers.host = host;
      }
      final bytes = raw ?? (json == null ? null : utf8.encode(jsonEncode(json)));
      if (bytes != null) {
        request.headers.contentType = contentType ?? ContentType.json;
        request.add(bytes);
      }
      final response = await request.close();
      final body = await response.fold<BytesBuilder>(BytesBuilder(), (builder, chunk) => builder..add(chunk));
      return _Answer(response.statusCode, response.headers, body.takeBytes());
    } finally {
      client.close(force: true);
    }
  }

  /// A hello of a phone as pairing_client.dart sends it, and the channel its answer gives
  Future<PairingChannel> hello({PairingClient client = PairingClient.app}) async {
    final code = session.currentCode!;
    final phone = PairingKeyPair.generate(Random(9));
    final answer = await send(
      'POST',
      '/p/${code.id}/hello',
      json: {'v': 1, 'mode': 'qr', 'client': client.wire, 'pk': pairingBase64(phone.publicKey)},
    );
    expect(answer.status, HttpStatus.ok);
    final screenKey = pairingDecodeBase64(answer.json['pk'])!;
    final transcript = pairingTranscript(
      id: code.id,
      mode: PairingMode.qr,
      client: client,
      phoneKey: phone.publicKey,
      screenKey: screenKey,
    );
    final keys = derivePairingKeys(shared: phone.agree(screenKey)!, secret: code.secret, transcript: transcript);
    final confirm = pairingConfirm(
      confirmKey: keys.confirm,
      transcript: transcript,
      device: pairingDecodeBase64(answer.json['d'])!,
    );
    expect(pairingSameBytes(confirm, pairingDecodeBase64(answer.json['confirm'])!), isTrue);
    return PairingChannel(transcript: transcript, keys: keys, sends: PairingDirection.up);
  }

  group('the page', () {
    test('is served with a strict policy, never cached nor referred', () async {
      final answer = await send('GET', '/p');
      expect(answer.status, HttpStatus.ok);
      expect(utf8.decode(answer.body), contains('<title>pair</title>'));
      expect(answer.headers.contentType?.mimeType, 'text/html');
      expect(answer.headers.value('content-security-policy'), PairingServer.contentSecurityPolicy);
      expect(answer.headers.value('content-security-policy'), contains("script-src 'self'"));
      expect(answer.headers.value('cache-control'), 'no-store');
      expect(answer.headers.value('referrer-policy'), 'no-referrer');
      expect(answer.headers.value('x-content-type-options'), 'nosniff');

      expect((await send('GET', '/p/app.js')).headers.contentType?.mimeType, 'text/javascript');
      expect((await send('GET', '/p/app.css')).headers.contentType?.mimeType, 'text/css');
    });

    test('info tells the id of the code and the device, never its secrets', () async {
      final code = session.currentCode!;
      final answer = await send('GET', '/p/info');
      expect(answer.status, HttpStatus.ok);
      expect(answer.json['id'], code.id);
      expect(answer.json['device'], _device);
      expect(answer.json['texts'], {'pairing_web_intro': 'Sign in your TV'});
      final text = utf8.decode(answer.body);
      expect(text, isNot(contains(code.code)));
      expect(text, isNot(contains(pairingBase64(code.secret))));
    });
  });

  group('refuses', () {
    test('clients outside the local network', () async {
      allowed = false;
      expect((await send('GET', '/p')).status, HttpStatus.forbidden);
    });

    test('a host name, against DNS rebinding', () async {
      expect((await send('GET', '/p/info', host: 'evil.example.com')).status, HttpStatus.forbidden);
      expect((await send('GET', '/p/info', host: '192.168.1.23')).status, HttpStatus.ok);
    });

    test('other paths and methods', () async {
      expect((await send('GET', '/')).status, HttpStatus.notFound);
      expect((await send('GET', '/p/x/y/z')).status, HttpStatus.notFound);
      expect((await send('POST', '/p')).status, HttpStatus.methodNotAllowed);
      final id = session.currentCode!.id;
      expect((await send('GET', '/p/$id/hello')).status, HttpStatus.methodNotAllowed);
      expect((await send('DELETE', '/p/$id/session')).status, HttpStatus.methodNotAllowed);
    });

    test('a body that is not JSON, or too large', () async {
      final id = session.currentCode!.id;
      expect(
        (await send('POST', '/p/$id/hello', raw: utf8.encode('{"v":1}'), contentType: ContentType.text)).status,
        HttpStatus.unsupportedMediaType,
      );
      expect((await send('POST', '/p/$id/hello', raw: utf8.encode('{nope'))).status, HttpStatus.badRequest);
      expect((await send('POST', '/p/$id/hello', json: {'v': 2})).status, HttpStatus.badRequest);
      final big = List.filled(PairingServer.maxBody + 1, 0x20);
      expect((await send('POST', '/p/$id/hello', raw: big)).status, HttpStatus.requestEntityTooLarge);
    });

    test('an address after ten failures in a minute', () async {
      for (var i = 0; i < PairingServer.maxFailures; i++) {
        expect((await send('GET', '/nothing')).status, HttpStatus.notFound);
      }
      final blocked = await send('GET', '/p');
      expect(blocked.status, HttpStatus.tooManyRequests);
      expect(blocked.headers.value(HttpHeaders.retryAfterHeader), '60');
    });

    test('an expired or unknown code, a fourth hello', () async {
      final key = pairingBase64(PairingKeyPair.generate(Random(1)).publicKey);
      final hello = {'v': 1, 'mode': 'qr', 'client': 'app', 'pk': key};
      final gone = await send('POST', '/p/AAAAAAAAAAA/hello', json: hello);
      expect(gone.status, HttpStatus.gone);
      expect(gone.json['error'], 'expired');
      final id = session.currentCode!.id;
      for (var i = 0; i < ScreenPairingSession.maxHellos; i++) {
        expect((await send('POST', '/p/$id/hello', json: hello)).status, HttpStatus.ok);
      }
      expect((await send('POST', '/p/$id/hello', json: hello)).status, HttpStatus.tooManyRequests);
    });
  });

  group('a pairing', () {
    test('opens the session of the phone once, answers sealed, and the code is used', () async {
      final code = session.currentCode!;
      final channel = await hello();
      final answer = await send('POST', '/p/${code.id}/session', json: channel.seal({'v': 1, 'token': _token}));
      expect(answer.status, HttpStatus.ok);
      expect(signIn.sessions.single['token'], _token);
      expect(channel.open(answer.json), {'v': 1, 'status': 'signedIn', 'label': 'Living room TV'});
      expect(session.state.phase, ScreenPairingPhase.signedIn);

      final again = await send('POST', '/p/${code.id}/session', json: channel.seal({'v': 1, 'token': _token}));
      expect(again.status, HttpStatus.gone);
      expect(again.json['error'], 'used');
      expect(signIn.sessions, hasLength(1));
    });

    test('a message that does not decrypt is rejected and burns the code', () async {
      final code = session.currentCode!;
      final channel = await hello();
      final sealed = channel.seal({'v': 1, 'token': _token});
      final tampered = {...sealed, 'c': pairingBase64(Uint8List(40))};
      final answer = await send('POST', '/p/${code.id}/session', json: tampered);
      expect(answer.status, HttpStatus.badRequest);
      expect(answer.json['error'], 'rejected');
      expect(signIn.sessions, isEmpty);
      expect(session.currentCode!.id, isNot(code.id));
      expect((await send('POST', '/p/${code.id}/session', json: sealed)).status, HttpStatus.gone);
    });

    test('a message that names no hello is refused without burning the code', () async {
      final code = session.currentCode!;
      // Only the id, which GET /p/info gives: no hello, no key
      final answer = await send(
        'POST',
        '/p/${code.id}/session',
        json: {'v': 1, 'h': 'AAAAAAAAAAA', 'n': 'AAAAAAAAAAAAAAAA', 'c': pairingBase64(Uint8List(40))},
      );
      expect(answer.status, HttpStatus.badRequest);
      expect(answer.json['error'], 'invalid');
      expect(session.currentCode, same(code));
      // The phone that says hello next still signs the screen in
      final channel = await hello();
      final signedIn = await send('POST', '/p/${code.id}/session', json: channel.seal({'v': 1, 'token': _token}));
      expect(channel.open(signedIn.json)!['status'], 'signedIn');
    });

    test('a phone that cancels frees the screen, sealed', () async {
      final code = session.currentCode!;
      final channel = await hello();
      expect(session.state.checks, hasLength(1));
      final answer = await send('POST', '/p/${code.id}/session', json: channel.seal({'v': 1, 'cancel': true}));
      expect(answer.status, HttpStatus.ok);
      expect(channel.open(answer.json), {'v': 1, 'status': 'cancelled'});
      expect(session.state.phase, ScreenPairingPhase.waiting);
      expect(session.state.checks, isEmpty);
      expect(signIn.sessions, isEmpty);
      expect(session.currentCode, same(code));
    });

    test('the browser page gets three tries at the password', () async {
      final code = session.currentCode!;
      final channel = await hello(client: PairingClient.web);
      for (final left in [2, 1]) {
        final answer = await send(
          'POST',
          '/p/${code.id}/login',
          json: channel.seal({'v': 1, 'server': 'http://192.168.1.10:2283', 'email': 'a@b.c', 'password': 'wrong'}),
        );
        expect(channel.open(answer.json), {'v': 1, 'status': 'badCredentials', 'triesLeft': left});
      }
      final last = await send(
        'POST',
        '/p/${code.id}/login',
        json: channel.seal({'v': 1, 'server': 'http://192.168.1.10:2283', 'email': 'a@b.c', 'password': 'wrong'}),
      );
      expect(channel.open(last.json)!['triesLeft'], 0);
      expect(session.currentCode!.id, isNot(code.id));
    });

    test('a session posted to the login of the page, or the other way round, is refused', () async {
      final code = session.currentCode!;
      final channel = await hello();
      final answer = await send('POST', '/p/${code.id}/login', json: channel.seal({'v': 1, 'password': 'right'}));
      expect(answer.status, HttpStatus.badRequest);
      expect(signIn.logins, isEmpty);
      expect(session.currentCode, same(code));
    });
  });

  test('nothing secret reaches the log', () async {
    final code = session.currentCode!;
    final channel = await hello();
    await send('POST', '/p/${code.id}/session', json: channel.seal({'v': 1, 'token': _token, 'password': 'hunter2'}));
    await send('GET', '/p/info');
    await send('GET', '/elsewhere');
    final text = logs.map((record) => '${record.message} ${record.error ?? ''}').join('\n');
    expect(text, contains('Pairing'));
    for (final secret in [code.code, pairingBase64(code.secret), _token, 'hunter2', code.id]) {
      expect(text, isNot(contains(secret)), reason: 'the log holds a secret');
    }
  });
}
