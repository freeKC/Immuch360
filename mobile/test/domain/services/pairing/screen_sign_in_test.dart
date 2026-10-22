import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/pairing/screen_pairing_session.dart';
import 'package:immich_mobile/domain/services/pairing/screen_sign_in.dart';

/// The app as the sign in sees it: which servers answer, which token and password it takes
class _FakeApp implements ScreenSignInActions {
  Map<String, String> headers = {'Existing': 'one'};
  String? label = 'Living room TV';
  String? token;
  String? server = 'https://old.example.com/api';
  String? signedInBy;
  final reachable = <String>{};
  final hanging = <String>{};
  final tried = <String>[];
  String goodToken = 'good-token-1234';
  bool passwordLogin = true;
  String password = 'right';
  bool restored = false;

  @override
  Future<ScreenSignInSnapshot> snapshot() async =>
      ScreenSignInSnapshot(headers: Map.of(headers), label: label, serverUrl: server, serverEndpoint: server);

  @override
  Future<void> restore(ScreenSignInSnapshot snapshot) async {
    headers = snapshot.headers;
    label = snapshot.label;
    server = snapshot.serverEndpoint;
    token = null;
    restored = true;
  }

  @override
  Future<void> setCustomHeaders(Map<String, String> value) async => headers = value;

  @override
  Future<void> setLabel(String value) async => label = value;

  @override
  Future<String?> tryServer(String endpoint, Duration timeout) async {
    tried.add(endpoint);
    if (hanging.contains(endpoint)) {
      await Completer<void>().future;
    }
    // Only a ping: the server changes with useServer
    return reachable.contains(endpoint) ? endpoint : null;
  }

  @override
  Future<void> useServer(String apiUrl) async => server = apiUrl;

  @override
  Future<bool> useToken(String value) async {
    token = value;
    return value == goodToken;
  }

  @override
  Future<({bool passwordLogin, String? oauthProvider})> loginOptions() async =>
      (passwordLogin: passwordLogin, oauthProvider: passwordLogin ? null : 'Authentik');

  @override
  Future<PasswordSignInOutcome> login(String email, String value) async =>
      value == password ? PasswordSignInOutcome.signedIn : PasswordSignInOutcome.wrongCredentials;

  @override
  Future<void> setSignedInBy(String? phone) async => signedInBy = phone;

  @override
  String? userName() => 'Fred';
}

void main() {
  late _FakeApp app;
  late ScreenSignIn signIn;

  setUp(() {
    app = _FakeApp();
    signIn = ScreenSignIn(app, perServer: const Duration(milliseconds: 200), budget: const Duration(seconds: 1));
  });

  Map<String, Object?> payload({Object? token = 'good-token-1234', Object? endpoints, Object? headers}) => {
    'v': 1,
    'server': 'https://photos.example.com',
    'endpoints': endpoints ?? ['https://photos.example.com/api', 'http://192.168.1.10:2283/api'],
    'headers': ?headers,
    'token': token,
    'sessionId': 'session-1',
    'label': 'Lounge',
    'user': {'name': 'Fred', 'email': 'fred@example.com'},
    'phone': "Fred's Pixel",
  };

  group('with the session of a phone', () {
    test('the first address that answers, the token checked, the name and the phone kept', () async {
      app.reachable.add('http://192.168.1.10:2283/api');
      final result = await signIn.withSession(payload(headers: {'CF-Access-Client-Id': 'id'}));
      expect(result.signedIn, isTrue);
      expect(result.answer, {'status': 'signedIn', 'label': 'Lounge'});
      expect(app.tried, ['https://photos.example.com/api', 'http://192.168.1.10:2283/api']);
      expect(app.server, 'http://192.168.1.10:2283/api');
      expect(app.headers, {'CF-Access-Client-Id': 'id'});
      expect(app.label, 'Lounge');
      expect(app.token, 'good-token-1234');
      expect(app.signedInBy, "Fred's Pixel");
      expect(signIn.signedIn?.user, 'Fred');
      expect(signIn.signedIn?.phone, "Fred's Pixel");
    });

    test('no address answers: the screen is left as it was', () async {
      final result = await signIn.withSession(payload(headers: {'X-Other': 'two'}));
      expect(result.signedIn, isFalse);
      expect(result.answer, {'status': 'serverUnreachable', 'tried': 2});
      expect(result.notice, ScreenPairingNotice.serverUnreachable);
      expect(result.detail, 'photos.example.com');
      expect(app.restored, isTrue);
      expect(app.headers, {'Existing': 'one'});
      expect(app.label, 'Living room TV');
      expect(app.server, 'https://old.example.com/api');
    });

    test('an address that hangs does not take the time of the others', () async {
      app.hanging.add('https://photos.example.com/api');
      app.reachable.add('http://192.168.1.10:2283/api');
      final result = await signIn.withSession(payload());
      expect(result.signedIn, isTrue);
    });

    test('the server refuses the token: no token kept', () async {
      app.reachable.add('https://photos.example.com/api');
      final result = await signIn.withSession(payload(token: 'revoked-token-123'));
      expect(result.answer, {'status': 'tokenRejected'});
      expect(app.token, isNull);
      expect(app.restored, isTrue);
      // The server the payload named does not stay: the login form would offer it at the next start
      expect(app.server, 'https://old.example.com/api');
    });

    test('a payload without a token or an address is refused before anything changes', () async {
      expect((await signIn.withSession(payload(token: null))).answer['status'], 'invalid');
      expect(
        (await signIn.withSession({
          ...payload(endpoints: ['ftp://x', 42]),
          'server': 'nope',
        })).answer['status'],
        'invalid',
      );
      expect(app.tried, isEmpty);
    });

    test('custom headers that an HTTP stack would refuse are left out', () async {
      app.reachable.add('https://photos.example.com/api');
      await signIn.withSession(
        payload(headers: {'Good-Name': 'ok', 'Bad Name': 'x', 'Split': 'a\r\nInjected: b', 'Number': 5}),
      );
      expect(app.headers, {'Good-Name': 'ok'});
    });
  });

  group('with the password of the browser page', () {
    Map<String, Object?> credentials({String password = 'right', Object? server = 'http://192.168.1.10:2283'}) => {
      'v': 1,
      'server': server,
      'email': 'fred@example.com',
      'password': password,
    };

    test('signs in', () async {
      app.reachable.add('http://192.168.1.10:2283');
      final result = await signIn.withPassword(credentials());
      expect(result.signedIn, isTrue);
      expect(app.signedInBy, isNull);
      expect(signIn.signedIn?.user, 'Fred');
    });

    test('a wrong password keeps the code for another try, and the screen its server', () async {
      app.reachable.add('http://192.168.1.10:2283');
      final result = await signIn.withPassword(credentials(password: 'wrong'));
      expect(result.answer, {'status': 'badCredentials'});
      expect(result.retry, isTrue);
      expect(app.server, 'https://old.example.com/api');
    });

    test('a server that signs in with OAuth only says so, and the page may try another', () async {
      app.reachable.add('http://192.168.1.10:2283');
      app.passwordLogin = false;
      final result = await signIn.withPassword(credentials());
      expect(result.answer, {'status': 'oauthOnly', 'provider': 'Authentik'});
      expect(result.signedIn, isFalse);
      expect(result.retry, isTrue);
      expect(app.server, 'https://old.example.com/api');
    });

    test('an unreachable or invalid server: a typo keeps the code', () async {
      final unreachable = await signIn.withPassword(credentials());
      expect(unreachable.answer['status'], 'serverUnreachable');
      expect(unreachable.retry, isTrue);
      expect((await signIn.withPassword(credentials(server: 'javascript:alert(1)'))).answer['status'], 'invalid');
    });
  });
}
