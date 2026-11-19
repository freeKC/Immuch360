// The client of jellyfin_client.dart against the loopback fake of the bench answers: the header of each product, the
// sign in both ways, the failures and what reaches the logs.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_client.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_routes.dart';
import 'package:logging/logging.dart';

import 'fake_jellyfin_server.dart';

JellyfinClient clientOf(FakeJellyfinServer server, {String? token, String? version}) => JellyfinClient(
  IOClient(HttpClient()),
  routes: JellyfinRoutes(
    server.base,
    server.product,
    version ?? (server.product == JellyfinProduct.emby ? '4.10.2.0' : '12.4.0'),
  ),
  deviceId: '0123456789abcdef0123456789abcdef-src12345',
  token: token,
  appVersion: '3.4.3',
  deviceName: 'Immuch360 Android',
);

Matcher failsWith(JellyfinFailure failure) =>
    throwsA(isA<JellyfinException>().having((e) => e.failure, 'failure', failure));

void main() {
  test('the authorization header of each product', () {
    final value = jellyfinAuthorization(
      deviceId: 'd-1',
      deviceName: 'Immuch360 Android',
      appVersion: '3.4.3',
      token: 'tok',
    );
    expect(
      value,
      'MediaBrowser Client="Immuch360", Device="Immuch360 Android", DeviceId="d-1", Version="3.4.3", Token="tok"',
    );
    expect(jellyfinAuthorization(deviceId: 'd', deviceName: 'n'), isNot(contains('Token')));
    final jellyfin = JellyfinClient(
      IOClient(),
      routes: JellyfinRoutes(Uri.parse('http://x'), JellyfinProduct.jellyfin, '12.4.0'),
      deviceId: 'd',
      token: 'tok',
    );
    expect(jellyfin.headers().keys, containsAll(['authorization', 'accept']));
    expect(jellyfin.headers(withToken: false)['authorization'], isNot(contains('tok')));
    final emby = JellyfinClient(
      IOClient(),
      routes: JellyfinRoutes(Uri.parse('http://x'), JellyfinProduct.emby, '4.10.2.0'),
      deviceId: 'd',
      token: 'tok',
    );
    expect(emby.headers()['x-emby-token'], 'tok');
    expect(emby.headers()['x-emby-authorization'], startsWith('MediaBrowser Client="Immuch360"'));
    expect(emby.headers().containsKey('authorization'), isFalse);
  });

  test('the DeviceId is the install id then the start of the source id', () {
    expect(
      jellyfinDeviceIdOf('0123456789abcdef0123456789abcdef', 'Ab-cd_ef0123456789'),
      '0123456789abcdef0123456789abcdef-Abcdef01',
    );
    expect(jellyfinDeviceIdOf('i', 'x'), 'i-x');
  });

  for (final folder in ['jellyfin', 'jellyfin-10.10', 'emby']) {
    group(folder, () {
      late FakeJellyfinServer server;
      setUp(() async => server = await FakeJellyfinServer.start(folder: folder));
      tearDown(() => server.close());

      test('public information without a token, then a sign in with the password', () async {
        final client = clientOf(server);
        final info = await client.publicInfo();
        expect(info.id, server.serverId);
        expect(server.requestsWithToken, isEmpty);
        await expectLater(client.signIn('viewer', 'wrong'), failsWith(JellyfinFailure.passwordRefused));
        final signedIn = await client.signIn('viewer', jellyfinTestPassword);
        expect(signedIn.accessToken, jellyfinTestToken);
        expect(client.token, jellyfinTestToken);
        final me = await client.me(signedIn.userId);
        expect(me.name, 'viewer');
        final views = await client.views(signedIn.userId);
        expect(views.map((v) => v.name), ['Films', 'Home', 'Photos', 'Shows']);
      });

      test('a token the server no longer takes is tokenRefused, an authentication failure', () async {
        final client = clientOf(server, token: 'ended');
        try {
          await client.me(server.userId);
          fail('no failure');
        } on JellyfinException catch (error) {
          expect(error.failure, JellyfinFailure.tokenRefused);
          expect(error.isAuthentication, isTrue);
        }
      });

      test('Quick Connect: on Jellyfin, a code to approve; none on Emby', () async {
        final client = clientOf(server);
        if (server.product == JellyfinProduct.emby) {
          expect(await client.quickConnectEnabled(), isFalse);
          await expectLater(client.quickConnectInitiate(), failsWith(JellyfinFailure.quickConnectOff));
          return;
        }
        expect(await client.quickConnectEnabled(), isTrue);
        final started = await client.quickConnectInitiate();
        expect(await client.quickConnectApproved(started.secret), isFalse);
        expect(server.approve(started.code), isTrue);
        expect(await client.quickConnectApproved(started.secret), isTrue);
        final signedIn = await client.quickConnectSignIn(started.secret);
        expect(signedIn.accessToken, jellyfinTestToken);
        await expectLater(client.quickConnectApproved(started.secret), failsWith(JellyfinFailure.quickConnectExpired));
        server.quickConnectEnabled = false;
        expect(await client.quickConnectEnabled(), isFalse);
        await expectLater(client.quickConnectInitiate(), failsWith(JellyfinFailure.quickConnectOff));
      });

      test('a server error is serverError, a 403 downloadForbidden', () async {
        final client = clientOf(server, token: jellyfinTestToken);
        server.failWith = 500;
        await expectLater(client.me(server.userId), failsWith(JellyfinFailure.serverError));
        server.failWith = 403;
        try {
          await client.me(server.userId);
          fail('no failure');
        } on JellyfinException catch (error) {
          expect(error.isDownloadForbidden, isTrue);
        }
      });

      test('the playback reports carry ticks, the source and the session', () async {
        final client = clientOf(server, token: jellyfinTestToken);
        final film = server.itemId(folder == 'emby' ? 'Pattern' : 'Pattern (2024)');
        await client.report(JellyfinReport.start, itemId: film, mediaSourceId: 'm', positionMs: 0, playSessionId: 'p1');
        await client.report(
          JellyfinReport.progress,
          itemId: film,
          mediaSourceId: 'm',
          positionMs: 12000,
          playSessionId: 'p1',
          paused: true,
        );
        await client.report(
          JellyfinReport.stopped,
          itemId: film,
          mediaSourceId: 'm',
          positionMs: 12500,
          playSessionId: 'p1',
        );
        expect(server.reports.map((r) => r.kind), ['start', 'progress', 'stopped']);
        expect(server.reports[1].body['PositionTicks'], 120000000);
        expect(server.reports[1].body['IsPaused'], isTrue);
        expect(server.reports[2].body['PlayMethod'], 'DirectPlay');
        expect(server.reports[2].body['PlaySessionId'], 'p1');
        await client.logout();
        await expectLater(client.me(server.userId), failsWith(JellyfinFailure.tokenRefused));
      });
    });
  }

  test('a server of another kind is notJellyfin, a closed port unreachable', () async {
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    other.listen((request) async {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<html>router</html>');
      await request.response.close();
    });
    addTearDown(() => other.close(force: true));
    final client = JellyfinClient(
      IOClient(HttpClient()),
      routes: JellyfinRoutes(Uri.parse('http://127.0.0.1:${other.port}'), JellyfinProduct.jellyfin, null),
      deviceId: 'd',
    );
    await expectLater(client.publicInfo(), failsWith(JellyfinFailure.notJellyfin));
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final nobody = JellyfinClient(
      IOClient(HttpClient()),
      routes: JellyfinRoutes(Uri.parse('http://127.0.0.1:$port'), JellyfinProduct.jellyfin, null),
      deviceId: 'd',
    );
    try {
      await nobody.publicInfo();
      fail('no failure');
    } catch (error) {
      expect(
        jellyfinErrorOf(error),
        isA<JellyfinException>().having((e) => e.failure, 'failure', JellyfinFailure.unreachable),
      );
    }
  });

  test('the token, the Quick Connect secret, the address and the password stay out of the logs', () async {
    final records = <LogRecord>[];
    final previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await subscription.cancel();
      Logger.root.level = previous;
    });
    final server = await FakeJellyfinServer.start();
    addTearDown(server.close);
    final client = clientOf(server);
    await client.publicInfo();
    await client.signIn('viewer', jellyfinTestPassword);
    final started = await client.quickConnectInitiate();
    await client.quickConnectApproved(started.secret);
    await client.views(server.userId);
    await client.items(server.userId, parentId: server.viewId('Films'));
    await client.logout();
    await client.logout();
    expect(records, isNotEmpty);
    for (final record in records) {
      final text = '${record.message} ${record.error ?? ''}';
      expect(text, isNot(contains(jellyfinTestToken)));
      expect(text, isNot(contains(started.secret)));
      expect(text, isNot(contains(jellyfinTestPassword)));
      expect(text, isNot(contains('127.0.0.1')));
      expect(text, isNot(contains('${server.port}')));
      expect(text, isNot(contains('Pattern')));
      expect(text, isNot(contains(server.viewId('Films'))));
    }
  });
}
