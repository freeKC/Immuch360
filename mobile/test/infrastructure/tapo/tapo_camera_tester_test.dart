// "Test the camera" with the fake camera and a fake live probe: both sides side by side, each only with its secrets,
// a refusal of one not stopping the other, the login left for the connection after the save, a remembered refusal
// asked again at the press; and the certificate of a camera read without sending anything, with the pin of the HTTPS
// client checked before any request (the first certificate kept for the later connections, a host typed with capitals,
// a request never answered not holding the next ones). The certificates are made with openssl at test time in a
// temporary folder (the TLS tests are skipped without it).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_camera_tester.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_control_client.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_https.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_login.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_session_cache.dart';
import 'package:timezone/data/latest.dart';

import 'fake_tapo_camera.dart';

const _sourceId = '0123456789abcdef';

void main() {
  setUpAll(initializeTimeZones);

  group('test of a camera', () {
    late TapoSessionCache cache;
    late FakeTapoCamera camera;
    final liveCalls = <String>[];

    setUp(() {
      cache = TapoSessionCache();
      camera = FakeTapoCamera();
      liveCalls.clear();
    });

    TapoControlClient client(TapoTestRequest request, String password) => TapoControlClient(
      sourceId: request.sourceId,
      host: request.host,
      password: password,
      known: request.known ?? const TapoCameraInfo(),
      transport: (host, pin) => camera,
      login: (transport) =>
          TapoLogin(transport, spake2p: (input) async => spake2pClient(input), reloginDelay: Duration.zero),
      cache: cache,
      trustFirstCertificate: true,
    );

    Future<TapoLiveProbe> live(String host, {required int port, required String user, required String password}) async {
      liveCalls.add('$host:$port $user');
      if (password != 'camera-account-pw') {
        throw const TapoCameraException(TapoErrorKind.wrongPassword, code: 401);
      }
      return const TapoLiveProbe(video: 'H264', audio: 'PCMA');
    }

    TapoTestRequest request({String? cloud = 'synthetic-cloud-password', String? user = 'viewer', String? pw}) =>
        TapoTestRequest(
          sourceId: _sourceId,
          host: fakeCameraHost,
          cloudPassword: cloud,
          cameraUser: user,
          cameraPassword: pw ?? 'camera-account-pw',
        );

    test('checks the recordings and the live view side by side', () async {
      final result = await runTapoCameraTest(request(), client: client, rtsp: live);
      expect(result.recordingsError, isNull);
      expect(result.details?.model, 'C200');
      expect(result.details?.alias, 'Garden');
      expect(result.card?.state, TapoCardState.normal);
      expect(result.info?.protocol, TapoLoginProtocol.v4);
      expect(result.info?.passcode, TapoPasscodeHash.md5);
      expect(result.info?.certificateSha256, fakeCameraCertificate);
      expect(result.info?.zoneId, 'Europe/Brussels');
      expect(result.live?.video, 'H264');
      expect(liveCalls, ['$fakeCameraHost:554 viewer']);
      // One request for the four read methods
      expect(camera.calls, ['getDeviceInfo', 'getTimezone', 'getSdCardStatus', 'getAppComponentList']);
      // The login stays for the connection after the save
      expect(cache.get(_sourceId, fakeCameraHost, 'synthetic-cloud-password'), isNotNull);
    });

    test('runs each side only with its secrets', () async {
      final recordingsOnly = await runTapoCameraTest(
        request(user: ''),
        client: client,
        rtsp: live,
      );
      expect(recordingsOnly.live, isNull);
      expect(recordingsOnly.liveError, isNull);
      expect(liveCalls, isEmpty);
      final liveOnly = await runTapoCameraTest(request(cloud: null), client: client, rtsp: live);
      expect(liveOnly.details, isNull);
      expect(liveOnly.recordingsError, isNull);
      expect(liveOnly.live, isNotNull);
    });

    test('tells each refusal on its own side', () async {
      camera = FakeTapoCamera(cloudPassword: 'another');
      final result = await runTapoCameraTest(
        request(pw: 'wrong'),
        client: client,
        rtsp: live,
      );
      expect(result.recordingsError?.kind, TapoErrorKind.wrongPassword);
      expect(result.recordingsError?.attemptsLeft, 3);
      expect(result.liveError?.kind, TapoErrorKind.wrongPassword);
      expect(result.details, isNull);
      expect(cache.get(_sourceId, fakeCameraHost, 'synthetic-cloud-password'), isNull);
    });

    test('asks the camera again at each press, and leaves the refusal for the camera page', () async {
      camera = FakeTapoCamera(cloudPassword: 'another');
      cache.refuse(
        _sourceId,
        fakeCameraHost,
        'synthetic-cloud-password',
        const TapoCameraException(TapoErrorKind.wrongPassword),
      );
      final refused = await runTapoCameraTest(
        request(user: ''),
        client: client,
        rtsp: live,
      );
      expect(refused.recordingsError?.kind, TapoErrorKind.wrongPassword);
      expect(camera.shares, 2);
      // The camera page, after a save anyway, does not try it again
      expect(cache.refusal(_sourceId, fakeCameraHost, 'synthetic-cloud-password'), isNotNull);

      camera.cloudPassword = 'synthetic-cloud-password';
      final tested = await runTapoCameraTest(
        request(user: ''),
        client: client,
        rtsp: live,
      );
      expect(tested.recordingsError, isNull);
      expect(camera.shares, 3);
    });

    test('keeps the passwords out of the description of a request', () {
      expect(request().toString(), isNot(contains('synthetic-cloud-password')));
      expect(request().toString(), isNot(contains('camera-account-pw')));
    });
  });

  group('certificate', () {
    late Directory folder;
    String? certificateSha256;
    SecurityContext? context;
    SecurityContext? otherContext;

    /// A self-signed certificate of a camera and its SHA-256, null without openssl
    Future<(SecurityContext, String)?> make(String name) async {
      final key = '${folder.path}/$name.key';
      final pem = '${folder.path}/$name.pem';
      try {
        final made = await Process.run('openssl', [
          'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key, '-out', pem, '-days', '2', //
          '-subj', '/CN=TPRI-DEVICE',
        ]);
        if (made.exitCode != 0) {
          return null;
        }
      } on ProcessException {
        return null;
      }
      final body = File(pem).readAsLinesSync().where((line) => !line.startsWith('-----')).join();
      return (
        SecurityContext()
          ..useCertificateChain(pem)
          ..usePrivateKey(key),
        hexOf(sha256Bytes(base64.decode(body))),
      );
    }

    setUpAll(() async {
      folder = await Directory.systemTemp.createTemp('immuch360-tapo-https');
      final camera = await make('camera');
      context = camera?.$1;
      certificateSha256 = camera?.$2;
      otherContext = (await make('other'))?.$1;
    });

    tearDownAll(() => folder.delete(recursive: true));

    test('reads the certificate of a camera and sends nothing', () async {
      final tls = context;
      if (tls == null) {
        markTestSkipped('openssl is not there');
        return;
      }
      var applicationBytes = 0;
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) async {
        try {
          final secure = await SecureSocket.secureServer(socket, tls);
          secure.listen((data) => applicationBytes += data.length, onError: (Object _) {}, onDone: secure.destroy);
        } catch (_) {
          // The client refused the certificate: the expected end
        }
      });
      expect(await readTapoCertificate('127.0.0.1', port: server.port), certificateSha256);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(applicationBytes, 0);
    });

    test('the HTTPS client accepts the pinned certificate only, before any request', () async {
      final tls = context;
      if (tls == null) {
        markTestSkipped('openssl is not there');
        return;
      }
      final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.write('{"error_code":0}');
        await request.response.close();
      });

      final firstUse = TapoHttpsTransport('127.0.0.1', port: server.port);
      final reply = await firstUse.post('/', utf8.encode('{}'), contentType: 'application/json');
      expect(reply.status, 200);
      expect(firstUse.certificateSha256, certificateSha256);
      firstUse.close();

      final pinned = TapoHttpsTransport('127.0.0.1', port: server.port, pinnedSha256: certificateSha256!.toUpperCase());
      expect((await pinned.post('/', utf8.encode('{}'), contentType: 'application/json')).status, 200);
      pinned.close();
      expect(requests, 2);

      final other = TapoHttpsTransport('127.0.0.1', port: server.port, pinnedSha256: 'ab' * 32);
      await expectLater(
        other.post('/', utf8.encode('{}'), contentType: 'application/json'),
        throwsA(
          isA<TapoCameraException>()
              .having((e) => e.kind, 'kind', TapoErrorKind.certificateChanged)
              .having((e) => e.certificateSha256, 'certificate', certificateSha256),
        ),
      );
      other.close();
      expect(requests, 2);
    });

    test('the HTTPS client keeps the first certificate it trusted for its later connections', () async {
      final tls = context;
      final other = otherContext;
      if (tls == null || other == null) {
        markTestSkipped('openssl is not there');
        return;
      }
      final first = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls);
      final port = first.port;
      var requests = 0;
      first.listen((request) async {
        requests++;
        request.response.write('{"error_code":0}');
        await request.response.close();
      });
      final transport = TapoHttpsTransport('127.0.0.1', port: port);
      addTearDown(transport.close);
      expect((await transport.post('/', utf8.encode('{}'), contentType: 'application/json')).status, 200);
      await first.close(force: true);

      // Another device answers at the address while the session of the test is kept
      final second = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, port, other);
      addTearDown(() => second.close(force: true));
      second.listen((request) async {
        requests++;
        await request.response.close();
      });
      // The connection kept alive is gone with the first server: one network failure, as the control client retries
      Object? failure;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          await transport.post('/', utf8.encode('{}'), contentType: 'application/json');
          failure = null;
          break;
        } catch (error) {
          failure = error;
          if (error is! TapoNetworkException) {
            break;
          }
        }
      }
      expect(failure, isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.certificateChanged));
      expect(requests, 1);
    });

    test('the HTTPS client takes a camera address typed with capitals', () async {
      final tls = context;
      if (tls == null) {
        markTestSkipped('openssl is not there');
        return;
      }
      final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write('{"error_code":0}');
        await request.response.close();
      });
      final transport = TapoHttpsTransport('LocalHost', port: server.port, pinnedSha256: certificateSha256);
      addTearDown(transport.close);
      expect((await transport.post('/', utf8.encode('{}'), contentType: 'application/json')).status, 200);
    });

    test('the HTTPS client is not held by a request the camera never answered', () async {
      final tls = context;
      if (tls == null) {
        markTestSkipped('openssl is not there');
        return;
      }
      final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests++;
        if (requests == 1) {
          // Read, then never answered: a camera that rebooted after the request
          return;
        }
        request.response.write('{"error_code":0}');
        await request.response.close();
      });
      final transport = TapoHttpsTransport(
        '127.0.0.1',
        port: server.port,
        pinnedSha256: certificateSha256,
        timeout: const Duration(milliseconds: 500),
      );
      addTearDown(transport.close);
      await expectLater(
        transport.post('/', utf8.encode('{}'), contentType: 'application/json'),
        throwsA(isA<TapoNetworkException>()),
      );
      expect((await transport.post('/', utf8.encode('{}'), contentType: 'application/json')).status, 200);
      expect(requests, 2);
    });

    test('the HTTPS client tells a camera that does not answer', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      final transport = TapoHttpsTransport('127.0.0.1', port: port, timeout: const Duration(seconds: 2));
      await expectLater(
        transport.post('/', const [], contentType: 'application/json'),
        throwsA(isA<TapoNetworkException>()),
      );
      transport.close();
    });

    test('keeps the stok raw in the path, escaping only what would change its meaning', () {
      expect(tapoStokPath(r"ab!*()~'=+,;:@&$cd"), r"/stok=ab!*()~'=+,;:@&$cd/ds");
      expect(tapoStokPath('a/b?c#d%e'), '/stok=a%2Fb%3Fc%23d%25e/ds');
    });
  });
}
