import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_pairing.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_tv_auth.dart';

const _hash = '0123456789abcdef0123456789abcdef';
const _otherHash = 'fedcba9876543210fedcba9876543210';
const _machine = 'abcdef0123456789abcdef0123456789abcdef01';
const _clientId = '00112233445566778899aabbccddeeff';
const _accountToken = 'ACCOUNT-TOKEN-0000000';
const _serverToken = 'SERVER-TOKEN-00000000';

/// The answers of a fake plex.tv, one handler per request, and what it was asked
class _FakePlexTv {
  final List<http.Request> requests = [];
  final List<Future<http.Response> Function(http.Request request)> answers = [];

  http.Client client() => MockClient((request) async {
    requests.add(request);
    if (answers.isEmpty) {
      throw StateError('No answer left for ${request.method} ${request.url}');
    }
    return answers.removeAt(0)(request);
  });

  void answer(int status, Object? json) =>
      answers.add((_) async => http.Response(jsonEncode(json), status, headers: {'content-type': 'application/json'}));

  void fail(Exception error) => answers.add((_) async => throw error);
}

Map<String, Object?> _pin({int id = 7, String code = 'AB12', int expiresIn = 900, String? token}) => {
  'id': id,
  'code': code,
  'product': 'Immuch360',
  'trusted': false,
  'expiresIn': expiresIn,
  'authToken': token,
};

void main() {
  late _FakePlexTv plexTv;
  late DateTime now;
  late PlexTvAuth auth;

  setUp(() {
    plexTv = _FakePlexTv();
    now = DateTime.utc(2026, 11, 11, 22);
    auth = PlexTvAuth(
      client: plexTv.client,
      clientIdentifier: () async => _clientId,
      appVersion: () async => '3.4.1',
      now: () => now,
    );
  });

  group('the PIN request', () {
    test('a short PIN for plex.tv/link: POST /pins with the headers that name the app, and no token', () async {
      plexTv.answer(201, _pin());
      final pin = await auth.requestPin(strong: false);

      final request = plexTv.requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://plex.tv/api/v2/pins');
      expect(request.headers, {
        'accept': 'application/json',
        'x-plex-client-identifier': _clientId,
        'x-plex-product': 'Immuch360',
        'x-plex-version': '3.4.1',
        'x-plex-platform': isA<String>(),
        'x-plex-device-name': 'Immuch360',
      });
      expect(request.followRedirects, isFalse);
      expect((pin.id, pin.code, pin.strong), (7, 'AB12', false));
      expect(pin.expiresAt, now.add(const Duration(seconds: 900)), reason: 'on the clock of the device');
    });

    test('a strong PIN for the auth page asks strong=true', () async {
      plexTv.answer(201, _pin(code: 'a' * 25, expiresIn: 1800));
      final pin = await auth.requestPin(strong: true);
      expect(plexTv.requests.single.url.toString(), 'https://plex.tv/api/v2/pins?strong=true');
      expect((pin.strong, pin.code.length), (true, 25));
      expect(pin.expiresAt, now.add(const Duration(minutes: 30)));
      expect(pin.toString(), isNot(contains(pin.code)));
    });

    test('a failure of plex.tv or of the network is a PlexTvException', () async {
      plexTv.answer(500, {'error': 'down'});
      await expectLater(
        auth.requestPin(strong: true),
        throwsA(
          isA<PlexTvException>().having((e) => (e.failure, e.status, e.isTransient), 'kind', (
            PlexTvFailure.failed,
            500,
            true,
          )),
        ),
      );
      plexTv.fail(const SocketException('No route'));
      await expectLater(
        auth.requestPin(strong: true),
        throwsA(isA<PlexTvException>().having((e) => e.failure, 'failure', PlexTvFailure.unreachable)),
      );
      plexTv.answers.add((_) async => http.Response('<html>not json</html>', 201));
      await expectLater(
        auth.requestPin(strong: true),
        throwsA(isA<PlexTvException>().having((e) => e.failure, 'failure', PlexTvFailure.failed)),
      );
    });
  });

  group('the check of a PIN', () {
    final pin = PlexTvPin(id: 42, code: 'AB12', expiresAt: DateTime.utc(2100), strong: false);

    test('null while the user has not allowed the app, then the token', () async {
      plexTv.answer(200, _pin(id: 42));
      plexTv.answer(200, _pin(id: 42, token: _accountToken));
      expect(await auth.checkPin(pin), isNull);
      expect(await auth.checkPin(pin), _accountToken);
      expect(plexTv.requests.map((r) => '${r.method} ${r.url}'), [
        'GET https://plex.tv/api/v2/pins/42',
        'GET https://plex.tv/api/v2/pins/42',
      ]);
      expect(plexTv.requests.first.headers.containsKey('x-plex-token'), isFalse);
    });

    test('a PIN plex.tv forgot answers 404', () async {
      plexTv.answer(404, {'errors': []});
      await expectLater(auth.checkPin(pin), throwsA(isA<PlexTvException>().having((e) => e.status, 'status', 404)));
    });
  });

  group('the sign in, step by step', () {
    final waits = <Duration>[];
    Future<void> tick(Duration duration) async {
      waits.add(duration);
      now = now.add(duration);
    }

    setUp(waits.clear);

    Future<List<String>> run({bool strong = false, int maxTransientErrors = 3}) async {
      final states = await auth.signIn(strong: strong, wait: tick, maxTransientErrors: maxTransientErrors).toList();
      final labels = [
        for (final state in states)
          switch (state) {
            PlexTvRequesting() => 'requesting',
            PlexTvWaiting() => 'waiting',
            PlexTvAuthorised(:final token) => 'authorised $token',
            PlexTvExpired() => 'expired',
            PlexTvFailed(:final error) => 'failed ${error.failure.name}',
          },
      ];
      // The waiting state comes again after each pending question: one label per stretch
      return [
        for (var i = 0; i < labels.length; i++)
          if (i == 0 || labels[i] != labels[i - 1]) labels[i],
      ];
    }

    test('pending, pending, then authorised: the token, and no question after it', () async {
      plexTv.answer(201, _pin());
      plexTv.answer(200, _pin());
      plexTv.answer(200, _pin());
      plexTv.answer(200, _pin(token: _accountToken));

      expect(await run(), ['requesting', 'waiting', 'authorised $_accountToken']);
      expect(plexTv.requests, hasLength(4));
      expect(waits, everyElement(const Duration(seconds: 2)));
      expect(plexTv.answers, isEmpty);
    });

    test('the waiting state holds the PIN, strong or not as asked', () async {
      plexTv.answer(201, _pin(code: 'b' * 25, expiresIn: 1800));
      plexTv.answer(200, _pin(token: _accountToken));
      final states = await auth.signIn(strong: true, wait: tick).toList();
      final waiting = states.whereType<PlexTvWaiting>().single;
      expect((waiting.pin.strong, waiting.pin.code), (true, 'b' * 25));
      expect(states.last.toString(), isNot(contains(_accountToken)));
    });

    test('expired when the time of the PIN ran out, without asking again', () async {
      plexTv.answer(201, _pin(expiresIn: 5));
      plexTv.answer(200, _pin());
      plexTv.answer(200, _pin());

      expect(await run(), ['requesting', 'waiting', 'expired']);
      expect(plexTv.requests, hasLength(3), reason: 'asked at 2 s and 4 s, not at 6 s');
    });

    test('expired when plex.tv forgot the PIN (404)', () async {
      plexTv.answer(201, _pin());
      plexTv.answer(404, {'errors': []});
      expect(await run(), ['requesting', 'waiting', 'expired']);
    });

    test('a network error passes when the next question gets an answer', () async {
      plexTv.answer(201, _pin());
      plexTv.fail(const SocketException('Network is unreachable'));
      plexTv.answer(503, {});
      plexTv.answer(200, _pin());
      plexTv.fail(const SocketException('Network is unreachable'));
      plexTv.answer(200, _pin(token: _accountToken));
      expect(await run(), ['requesting', 'waiting', 'authorised $_accountToken']);
    });

    test('network errors in a row end the sign in', () async {
      plexTv.answer(201, _pin());
      plexTv.fail(const SocketException('Network is unreachable'));
      plexTv.fail(http.ClientException('Connection closed'));
      plexTv.fail(const SocketException('Network is unreachable'));
      expect(await run(), ['requesting', 'waiting', 'failed unreachable']);
      expect(plexTv.answers, isEmpty);
    });

    test('an answer that will not pass ends the sign in at once', () async {
      plexTv.answer(201, _pin());
      plexTv.answer(400, {});
      expect(await run(), ['requesting', 'waiting', 'failed failed']);
    });

    test('no PIN, no wait', () async {
      plexTv.fail(const SocketException('Network is unreachable'));
      expect(await run(), ['requesting', 'failed unreachable']);
      expect(waits, isEmpty);
    });

    test('the waiting state comes after each pending question, and cancelling there stops the questions', () async {
      plexTv.answer(201, _pin());
      for (var i = 0; i < 10; i++) {
        plexTv.answer(200, _pin());
      }
      final seen = <PlexTvSignInState>[];
      late final StreamSubscription<PlexTvSignInState> subscription;
      subscription = auth.signIn(strong: false, wait: tick).listen((state) {
        seen.add(state);
        if (seen.whereType<PlexTvWaiting>().length == 3) {
          unawaited(subscription.cancel());
        }
      });
      await pumpEventQueue();
      expect(seen.map((state) => state.runtimeType), [PlexTvRequesting, PlexTvWaiting, PlexTvWaiting, PlexTvWaiting]);
      expect(plexTv.requests, hasLength(3), reason: 'the PIN, then two pending questions; none after the cancel');
      expect(plexTv.answers, hasLength(8));
    });
  });

  group('the servers of the account', () {
    Map<String, Object?> connection(String uri, {bool local = false, bool relay = false, bool ipv6 = false}) => {
      'protocol': 'https',
      'uri': uri,
      'local': local,
      'relay': relay,
      'IPv6': ipv6,
    };

    final resources = [
      {
        'name': 'Phone of the user',
        'product': 'Plex for Android (Mobile)',
        'provides': 'client,player',
        'clientIdentifier': 'phone-id',
        'owned': true,
        'accessToken': 'PHONE-TOKEN-000000000',
        'connections': <Object>[],
      },
      {
        'name': 'Friend server',
        'product': 'Plex Media Server',
        'provides': 'server',
        'clientIdentifier': 'FRIEND',
        'owned': false,
        'accessToken': 'FRIEND-TOKEN-0000000',
        'connections': [connection('https://198-51-100-9.$_otherHash.plex.direct:32400')],
      },
      {
        'name': 'Living room',
        'product': 'Plex Media Server',
        'provides': 'server,provider',
        'clientIdentifier': _machine.toUpperCase(),
        'owned': true,
        'accessToken': _serverToken,
        'connections': [
          connection('https://203-0-113-7.$_hash.plex.direct:32400', relay: true),
          connection('https://203-0-113-7.$_hash.plex.direct:32401'),
          connection('https://[2001-db8--1].$_hash.plex.direct:32400', local: true, ipv6: true),
          connection('https://192-168-1-20.$_hash.plex.direct:32400', local: true),
          connection('https://172-17-0-2.$_hash.plex.direct:32400', local: true),
        ],
      },
    ];

    test('GET /resources with the account token in its header, never in the URL', () async {
      plexTv.answer(200, resources);
      final servers = await auth.servers(_accountToken);

      final request = plexTv.requests.single;
      expect(request.url.toString(), 'https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=0');
      expect(request.url.toString(), isNot(contains(_accountToken)));
      expect(request.headers['x-plex-token'], _accountToken);
      expect(servers.map((server) => server.name), ['Living room', 'Friend server'], reason: 'owned first, no player');
    });

    test('parses the servers: their machine identifier, their token, their connections in order', () {
      final servers = parsePlexTvResources(resources);
      final living = servers.first;
      expect((living.clientIdentifier, living.owned, living.accessToken), (_machine, true, _serverToken));
      expect(living.connections.map((c) => c.uri), [
        'https://192-168-1-20.$_hash.plex.direct:32400',
        'https://172-17-0-2.$_hash.plex.direct:32400',
        'https://203-0-113-7.$_hash.plex.direct:32401',
        'https://203-0-113-7.$_hash.plex.direct:32400',
      ], reason: 'local first in the order of plex.tv, then remote, the relay last, IPv6 left out');
      expect(living.toString(), isNot(contains(_serverToken)));
      expect(servers.last.owned, isFalse);
    });

    test('reads what plex.tv may leave out, and refuses what is no list', () {
      final servers = parsePlexTvResources([
        {'provides': 'server', 'clientIdentifier': 'abc', 'connections': 'none'},
        {'provides': 'server'},
        'junk',
      ]);
      expect(servers.single.name, 'abc');
      expect(servers.single.accessToken, isNull);
      expect(servers.single.connections, isEmpty);
      expect(() => parsePlexTvResources({'MediaContainer': {}}), throwsFormatException);
    });

    test('orders connections stably within each kind', () {
      final ordered = orderPlexTvConnections([
        for (var i = 0; i < 20; i++) PlexTvConnection(uri: '$i', local: i.isEven, relay: i % 5 == 0 && i.isOdd),
      ]);
      expect(ordered.map((c) => c.uri), [
        for (var i = 0; i < 20; i += 2) '$i',
        for (var i = 1; i < 20; i += 2)
          if (i % 5 != 0) '$i',
        '5',
        '15',
      ]);
    });

    test('a token plex.tv refuses is refused', () async {
      plexTv.answer(401, {});
      await expectLater(
        auth.servers(_accountToken),
        throwsA(
          isA<PlexTvException>().having((e) => (e.failure, e.isTransient), 'kind', (PlexTvFailure.refused, false)),
        ),
      );
    });
  });

  test('the auth page of a strong PIN names the app and its code, in its fragment', () {
    final url = plexTvAuthUrl(PlexTvPin(id: 1, code: 'c' * 25, expiresAt: DateTime.utc(2026), strong: true), _clientId);
    expect(url.scheme, 'https');
    expect(url.host, 'app.plex.tv');
    expect(url.path, '/auth');
    expect(url.query, isEmpty, reason: 'the fragment never reaches a server');
    expect(url.fragment, '?clientID=$_clientId&code=${'c' * 25}&context%5Bdevice%5D%5Bproduct%5D=Immuch360');
  });

  group('reaching a server of the account', () {
    PlexTvServer server({String? token = _serverToken, List<String>? uris}) => PlexTvServer(
      name: 'Living room',
      clientIdentifier: _machine,
      owned: true,
      accessToken: token,
      connections: [
        for (final uri
            in uris ??
                [
                  'https://192-168-1-20.$_hash.plex.direct:32400',
                  'https://203-0-113-7.$_hash.plex.direct:32401',
                  'https://203-0-113-8.$_hash.plex.direct:8443',
                ])
          PlexTvConnection(uri: uri),
      ],
    );

    PlexServerFound found(PlexAddress address, {String machine = _machine}) => PlexServerFound(
      address: InternetAddress(address.host),
      port: address.port ?? 32400,
      hash: address.hash!,
      machineIdentifier: machine,
      version: '1.42.1',
    );

    test('the first connection that answers wins, with the hash of its plex.direct name', () async {
      final tried = <String>[];
      final connected = await connectPlexTvServer(server(), _accountToken, (address) async {
        tried.add(address.text);
        return found(address);
      });
      expect(tried, ['192.168.1.20:32400']);
      expect(connected.address.hash, _hash);
      expect(connected.token, _serverToken, reason: 'the token of the server, not the one of the account');
      expect(
        (connected.server.name, connected.server.machineIdentifier, connected.server.isLocal),
        ('Living room', _machine, true),
      );
      expect(connected.toString(), isNot(contains(_serverToken)));
    });

    test('an address that does not answer, then another server, then the right one', () async {
      final tried = <String>[];
      final connected = await connectPlexTvServer(server(), _accountToken, (address) async {
        tried.add(address.text);
        return switch (address.host) {
          '192.168.1.20' => throw const PlexFileSystemException('No answer', PlexFailure.unreachable),
          '203.0.113.7' => found(address, machine: 'another'),
          _ => found(address),
        };
      });
      expect(tried, ['192.168.1.20:32400', '203.0.113.7:32401', '203.0.113.8:8443']);
      expect(connected.address.text, '203.0.113.8:8443');
      expect(connected.server.isLocal, isFalse);
    });

    test('the failure of the last connection when none answers', () async {
      await expectLater(
        connectPlexTvServer(
          server(),
          _accountToken,
          (address) async => throw PlexFileSystemException(
            'x',
            address.host == '203.0.113.8' ? PlexFailure.wrongCertificate : PlexFailure.unreachable,
          ),
        ),
        throwsA(isA<PlexFileSystemException>().having((e) => e.failure, 'failure', PlexFailure.wrongCertificate)),
      );
    });

    test(
      'a server without any usable connection is unreachable, and one without a token gets the account one',
      () async {
        await expectLater(
          connectPlexTvServer(server(uris: ['https://[2001:db8::1]:32400', 'not an address']), _accountToken, (a) {
            fail('nothing to try');
          }),
          throwsA(isA<PlexFileSystemException>().having((e) => e.failure, 'failure', PlexFailure.unreachable)),
        );
        final connected = await connectPlexTvServer(
          server(token: null),
          _accountToken,
          (address) async => found(address),
        );
        expect(connected.token, _accountToken);
      },
    );
  });
}
