import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/pairing/screen_pairing_session.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_client.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_server.dart';

const _device = {'app': '3.3.0', 'kind': 'tv', 'label': 'Living room TV', 'os': 'Android'};

class _SignIn implements PairingSignIn {
  final received = <Map<String, Object?>>[];
  Completer<void>? hold;
  PairingSignInResult result = const PairingSignInResult(answer: {'status': 'signedIn'}, signedIn: true);

  @override
  Future<PairingSignInResult> withSession(Map<String, Object?> payload) async {
    received.add(payload);
    await hold?.future;
    return result;
  }

  @override
  Future<PairingSignInResult> withPassword(Map<String, Object?> credentials) => throw UnimplementedError();
}

void main() {
  late ScreenPairingSession session;
  late _SignIn signIn;
  late PairingServer server;
  late int port;
  // The loopback stands for the screen's LAN address: the client refuses anything but a private IPv4
  final client = PairingHttpClient(
    connectTimeout: const Duration(seconds: 2),
    answerTimeout: const Duration(seconds: 2),
    addressOf: (host, port) => Uri(scheme: 'http', host: host == '10.0.0.1' ? '127.0.0.1' : host, port: port),
  );
  final page = PairingPage(html: Uint8List(0), script: Uint8List(0), style: Uint8List(0));

  setUp(() async {
    session = ScreenPairingSession(device: _device, random: Random(11))..start();
    signIn = _SignIn();
    server = PairingServer(session: session, signIn: signIn, page: page, device: _device, preferredPort: 0);
    port = await server.start();
  });

  tearDown(() async {
    await server.stop();
    await session.dispose();
  });

  PairingTarget target({Uint8List? secret, String? code, String? id}) => PairingTarget(
    host: '10.0.0.1',
    port: port,
    id: id ?? session.currentCode!.id,
    secret: code == null ? (secret ?? session.currentCode!.secret) : null,
    code: code,
  );

  test('the hello proves the screen, and the session goes sealed and comes back signed in', () async {
    final hello = await client.hello(target());
    expect(hello.device.label, 'Living room TV');
    expect(hello.device.kind, PairingScreenKind.tv);
    expect(hello.device.os, 'Android');
    final answer = await client.send(hello, {'token': 'abc', 'label': 'Lounge'});
    expect(answer['status'], 'signedIn');
    expect(signIn.received.single['token'], 'abc');
    expect(signIn.received.single['label'], 'Lounge');
  });

  test('a typed code works the same, after info gives the id', () async {
    final info = await client.info(host: '10.0.0.1', port: port);
    expect(info.id, session.currentCode!.id);
    expect(info.device.label, 'Living room TV');
    final typed = normalizePairingCode(formatPairingCode(session.currentCode!.code).toLowerCase())!;
    final hello = await client.hello(target(id: info.id, code: typed));
    expect((await client.send(hello, {'token': 'abc'}))['status'], 'signedIn');
  });

  test('a wrong code is caught before anything is sent', () async {
    await expectLater(
      client.hello(target(code: 'AAAAAAAAAA')),
      throwsA(isA<PairingException>().having((e) => e.failure, 'failure', PairingFailure.wrongCode)),
    );
    await expectLater(
      client.hello(target(secret: Uint8List(16))),
      throwsA(isA<PairingException>().having((e) => e.failure, 'failure', PairingFailure.wrongCode)),
    );
    expect(signIn.received, isEmpty);
  });

  test('an expired code, a used one', () async {
    await expectLater(
      client.hello(target(id: 'AAAAAAAAAAA')),
      throwsA(isA<PairingException>().having((e) => e.failure, 'failure', PairingFailure.expired)),
    );
    final first = target();
    final hello = await client.hello(first);
    await client.send(hello, {'token': 'abc'});
    await expectLater(
      client.hello(first),
      throwsA(isA<PairingException>().having((e) => e.failure, 'failure', PairingFailure.used)),
    );
    await expectLater(
      client.send(hello, {'token': 'again'}),
      throwsA(isA<PairingException>().having((e) => e.failure, 'failure', PairingFailure.used)),
    );
  });

  test('a screen that does not answer in time is lost', () async {
    signIn.hold = Completer<void>();
    final hello = await client.hello(target());
    await expectLater(
      client.send(hello, {'token': 'abc'}),
      throwsA(isA<PairingException>().having((e) => e.failure, 'failure', PairingFailure.lost)),
    );
    signIn.hold!.complete();
  });

  test('a screen that cannot reach the server says so, sealed', () async {
    signIn.result = const PairingSignInResult(
      answer: {'status': 'serverUnreachable', 'tried': 2},
      signedIn: false,
      notice: ScreenPairingNotice.serverUnreachable,
    );
    final hello = await client.hello(target());
    final answer = await client.send(hello, {'token': 'abc'});
    expect(answer['status'], 'serverUnreachable');
    expect(answer['tried'], 2);
  });

  test('nobody listening: unreachable', () async {
    await server.stop();
    await expectLater(
      client.hello(target()),
      throwsA(isA<PairingException>().having((e) => e.failure, 'failure', PairingFailure.unreachable)),
    );
  });

  test('only private IPv4 addresses', () async {
    await expectLater(
      client.hello(const PairingTarget(host: '8.8.8.8', port: 8361, id: 'AAAAAAAAAAA', code: 'AAAAAAAAAA')),
      throwsA(isA<PairingException>().having((e) => e.failure, 'failure', PairingFailure.invalid)),
    );
  });

  test('a bare client: no HTTP overrides of the app, no cookie, no custom header, no redirect followed', () async {
    final raw = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <HttpHeaders>[];
    raw.listen((request) async {
      seen.add(request.headers);
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(HttpHeaders.locationHeader, 'http://127.0.0.1:${raw.port}/elsewhere');
      await request.response.close();
    });
    final overrides = _CountingOverrides();
    final previous = HttpOverrides.current;
    HttpOverrides.global = overrides;
    try {
      final bare = PairingHttpClient(
        addressOf: (_, port) => Uri(scheme: 'http', host: '127.0.0.1', port: port),
      );
      await expectLater(
        bare.hello(PairingTarget(host: '10.0.0.1', port: raw.port, id: 'AAAAAAAAAAA', secret: Uint8List(16))),
        throwsA(isA<PairingException>().having((e) => e.failure, 'failure', PairingFailure.invalid)),
      );
    } finally {
      HttpOverrides.global = previous;
      await raw.close(force: true);
    }
    expect(overrides.created, 0);
    final headers = seen.single;
    expect(headers.value(HttpHeaders.cookieHeader), isNull);
    expect(headers.value(HttpHeaders.authorizationHeader), isNull);
    expect(headers.value(HttpHeaders.userAgentHeader), 'Immuch360');
    expect(headers.value(HttpHeaders.contentTypeHeader), startsWith('application/json'));
  });

  test('what goes on the wire is sealed: no token in clear', () async {
    final hello = await client.hello(target());
    final envelope = hello.channel.seal({'v': 1, 'token': 'very-secret-token'});
    expect(jsonEncode(envelope), isNot(contains('very-secret-token')));
  });
}

/// An app's own overrides (the computers have some): the pairing client must not go through them
class _CountingOverrides extends HttpOverrides {
  int created = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    created++;
    return super.createHttpClient(context);
  }
}
