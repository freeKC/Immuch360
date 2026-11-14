// The ONVIF client against the fake camera: the UsernameToken at the camera's time, HTTP Digest on top when asked,
// never Basic, the addresses brought back to the host of the source, a closed list of calls (nothing that writes), no
// secret in a log, and the brand presets of fake_onvif_camera.dart. Vectors computed by a script of ours (Python
// hashlib) from the rules of the specifications.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/ip_camera.dart';
import 'package:immich_mobile/infrastructure/ipcam/onvif_client.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_probe.dart';
import 'package:logging/logging.dart';

import 'fake_onvif_camera.dart';

const _readOnlyCalls = {
  'GetSystemDateAndTime',
  'GetDeviceInformation',
  'GetCapabilities',
  'GetServices',
  'GetProfiles',
  'GetStreamUri',
  'GetSnapshotUri',
};

OnvifClient _client(
  FakeOnvifCamera camera, {
  String host = '192.0.2.50',
  int port = 80,
  String? user,
  String? password,
}) => OnvifClient(
  host: host,
  port: port,
  path: camera.devicePath,
  user: user ?? camera.user,
  password: password ?? camera.password,
  post: camera.post,
  now: () => camera.now,
);

void main() {
  final logs = <String>[];
  setUp(() {
    logs.clear();
    Logger.root.level = Level.ALL;
  });
  final subscription = Logger.root.onRecord.listen((record) => logs.add('${record.message} ${record.error ?? ''}'));
  tearDownAll(subscription.cancel);

  test('the UsernameToken digest follows the profile (synthetic vector)', () {
    final header = usernameToken('onvif', 'synthetic-pw', DateTime.utc(2026, 11, 14, 12), List.generate(16, (i) => i));
    expect(
      header,
      contains(
        '<wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/'
        'oasis-200401-wss-username-token-profile-1.0#PasswordDigest">W4ISZ3VoNoIdbTkldRB3+Yqk9KA=</wsse:Password>',
      ),
    );
    expect(header, contains('>AAECAwQFBgcICQoLDA0ODw==</wsse:Nonce>'));
    expect(header, contains('<wsu:Created>2026-11-14T12:00:00Z</wsu:Created>'));
    expect(header, isNot(contains('synthetic-pw')));
    expect(header, isNot(contains('PasswordText')));
  });

  group('Digest of RTSP and HTTP', () {
    const uri = 'rtsp://192.0.2.30:554/stream1';
    test('MD5 and SHA-256 with qop', () {
      final md5 = RtspDigest.of(['Digest realm="realm-x", nonce="n0nce", qop="auth"'], cnonce: 'c0ffee')!;
      expect(
        md5.authorization('DESCRIBE', uri, 'viewer', 'secret'),
        contains('response="7abea8a733407260c65821524b5821b3"'),
      );
      final sha = RtspDigest.of([
        'Digest realm="realm-x", nonce="n0nce", algorithm=SHA-256, qop="auth"',
      ], cnonce: 'c0ffee')!;
      final header = sha.authorization('DESCRIBE', uri, 'viewer', 'secret');
      expect(header, contains('response="143f3ce75f7411b2ccc6cdd3d0543a4d8e5f78dd005195deda494b1865f7fafa"'));
      expect(header, contains('algorithm=SHA-256'));
    });

    test('MD5-sess sends its client nonce without qop', () {
      final sess = RtspDigest.of(['Digest realm="realm-x", nonce="n0nce", algorithm=MD5-sess'], cnonce: 'c0ffee')!;
      final header = sess.authorization('DESCRIBE', uri, 'viewer', 'secret');
      expect(header, contains('response="002291f4466967307e33fb4c9b693c2e"'));
      expect(header, contains('cnonce="c0ffee"'));
      expect(header, isNot(contains('qop=')));
    });

    test('an unknown algorithm is never answered, Basic neither', () {
      expect(RtspDigest.of(['Digest realm="r", nonce="n", algorithm=SHA-512-256']), isNull);
      expect(RtspDigest.of(['Basic realm="r"']), isNull);
      // The answerable one among several
      expect(
        RtspDigest.of(['Digest realm="r", nonce="n", algorithm=AKAv1-MD5', 'Digest realm="r", nonce="n"']),
        isNotNull,
      );
    });
  });

  group('reading a camera', () {
    test('device, media service on the host of the source, profiles, stream and snapshot', () async {
      final camera = FakeOnvifCamera();
      final client = _client(camera);
      final reading = await client.read();
      expect(reading.device.manufacturer, 'Example');
      expect(reading.device.label, 'Example Cam-1');
      // The camera announced 192.0.2.200: the account goes to the host of the source only
      expect(reading.services.media.toString(), 'http://192.0.2.50/onvif/media_service');
      expect(reading.profiles.map((p) => p.label), ['H.264 1920 x 1080', 'H.264 640 x 360']);
      expect(reading.profiles.first.audioEncoding, 'G711');
      final picked = pickOnvifProfiles(reading.profiles)!;
      expect(picked.main.token, 'main');
      expect(picked.sub!.token, 'sub');
      final stream = await client.streamUri(reading.services.media, 'main');
      expect(stream.url, 'rtsp://192.0.2.50:554/live/main');
      expect(await client.snapshotUri(reading.services.media, 'main'), 'http://192.0.2.50/snapshot.jpg');
      expect(camera.requests.map((r) => r.action).toSet().difference(_readOnlyCalls), isEmpty);
      for (final request in camera.requests) {
        expect(request.url.host, '192.0.2.50');
        expect(request.body, isNot(contains('synthetic-pw')));
        expect(request.headers['Content-Type'], startsWith('application/soap+xml; charset=utf-8; action="'));
      }
      // The clock is asked without an account
      expect(camera.requests.first.action, 'GetSystemDateAndTime');
      expect(camera.requests.first.body, isNot(contains('UsernameToken')));
    });

    test('a camera that needs no account gets none', () async {
      final camera = FakeOnvifCamera(requireToken: false);
      final client = _client(camera, user: '', password: '');
      await client.read();
      expect(camera.requests.any((r) => r.body.contains('UsernameToken')), isFalse);
      expect(camera.requests.any((r) => r.headers.containsKey('Authorization')), isFalse);
    });

    test('a refused account is told, and never tried twice in a call', () async {
      final camera = FakeOnvifCamera();
      final client = _client(camera, password: 'wrong');
      await expectLater(
        client.read(),
        throwsA(isA<IpCameraException>().having((e) => e.kind, 'kind', IpCameraErrorKind.wrongPassword)),
      );
      expect(camera.requests.where((r) => r.action == 'GetDeviceInformation'), hasLength(1));
    });

    test('no account for a camera that wants one: needsAccount', () async {
      final camera = FakeOnvifCamera();
      await expectLater(
        _client(camera, user: '', password: '').read(),
        throwsA(isA<IpCameraException>().having((e) => e.kind, 'kind', IpCameraErrorKind.needsAccount)),
      );
    });

    test('HTTP Digest on top of the token, MD5 and SHA-256, the password never in a header', () async {
      for (final algorithm in ['MD5', 'SHA-256']) {
        final camera = FakeOnvifCamera(requireDigest: true, digestAlgorithm: algorithm);
        final reading = await _client(camera).read();
        expect(reading.usedHttpDigest, isTrue, reason: algorithm);
        expect(reading.profiles, hasLength(2));
        for (final request in camera.requests) {
          expect(request.headers.values.join(' '), isNot(contains('synthetic-pw')));
        }
        // One challenge for the whole session: the device information once refused, then each call answered
        expect(camera.requests.where((r) => r.action == 'GetDeviceInformation'), hasLength(2));
        expect(camera.requests.where((r) => r.action == 'GetProfiles'), hasLength(1));
      }
    });

    test('a camera with Basic only is refused without sending the password', () async {
      final camera = FakeOnvifCamera(basicOnly: true, requireToken: false);
      await expectLater(
        _client(camera).read(),
        throwsA(isA<IpCameraException>().having((e) => e.kind, 'kind', IpCameraErrorKind.basicOnly)),
      );
      expect(camera.requests.any((r) => r.headers['Authorization']?.startsWith('Basic') ?? false), isFalse);
    });

    test('GetCapabilities refused: GetServices; both refused: the device service', () async {
      final viaServices = FakeOnvifCamera(capabilitiesFault: true, mediaXAddr: 'http://192.0.2.200/onvif/service');
      final reading = await _client(viaServices).read();
      expect(reading.services.media.path, '/onvif/service');
      final neither = FakeOnvifCamera(
        capabilitiesFault: true,
        servicesFault: true,
        mediaXAddr: 'http://x$onvifDevicePath',
      );
      expect((await _client(neither).read()).services.media.path, onvifDevicePath);
    });

    test('no profile with a video encoder: noProfile', () async {
      final camera = FakeOnvifCamera(profiles: const [FakeProfile('a', 'audio only', null, 0, 0, 'rtsp://x/a')]);
      await expectLater(
        _client(camera).read(),
        throwsA(isA<IpCameraException>().having((e) => e.kind, 'kind', IpCameraErrorKind.noProfile)),
      );
    });

    test('something that is not ONVIF: notOnvif', () async {
      Future<OnvifHttpAnswer> web(Uri url, Map<String, String> headers, List<int> body) async =>
          const OnvifHttpAnswer(404, {}, '<html><body>Not Found</body></html>');
      await expectLater(
        OnvifClient(host: '192.0.2.50', post: web).read(),
        throwsA(isA<IpCameraException>().having((e) => e.kind, 'kind', IpCameraErrorKind.notOnvif)),
      );
    });

    test('nothing secret in the logs', () async {
      final camera = FakeOnvifCamera(requireDigest: true);
      await _client(camera).read();
      await expectLater(_client(camera, password: 'wrong-pw-xyz').read(), throwsA(isA<IpCameraException>()));
      for (final line in logs) {
        expect(line, isNot(contains('synthetic-pw')));
        expect(line, isNot(contains('wrong-pw-xyz')));
        expect(line, isNot(contains('PasswordDigest')));
      }
    });
  });

  group('brands (public documentation, synthetic values)', () {
    test('Hikvision: the token at the camera clock, seven minutes off', () async {
      final camera = FakeBrands.hikvision();
      final client = _client(camera, host: '192.0.2.10');
      final reading = await client.read();
      expect(reading.clockOffset, const Duration(minutes: 7));
      expect(reading.device.label, 'HIKVISION DS-2CD0000');
      final stream = await client.streamUri(reading.services.media, pickOnvifProfiles(reading.profiles)!.main.token);
      expect(stream.url, 'rtsp://192.0.2.10:554/Streaming/Channels/101?transportmode=unicast&profile=Profile_1');
    });

    test('Dahua, Amcrest, Imou: HTTP Digest and the realmonitor query', () async {
      final camera = FakeBrands.dahua();
      final client = _client(camera, host: '192.0.2.11');
      final reading = await client.read();
      final picked = pickOnvifProfiles(reading.profiles)!;
      expect(picked.main.label, 'H.265 2688 x 1520');
      expect(
        (await client.streamUri(reading.services.media, picked.sub!.token)).pathAndQuery,
        '/cam/realmonitor?channel=1&subtype=1&unicast=true&proto=Onvif',
      );
    });

    test('Reolink on port 8000', () async {
      final camera = FakeBrands.reolink();
      final client = _client(camera, host: '192.0.2.12', port: 8000);
      final reading = await client.read();
      expect(reading.services.media.port, 8000);
      expect((await client.streamUri(reading.services.media, '000')).pathAndQuery, '/h264Preview_01_main');
    });

    test('Tapo on port 2020, every service on one address', () async {
      final camera = FakeBrands.tapo();
      final client = _client(camera, host: '192.0.2.13', port: 2020);
      final reading = await client.read();
      expect(reading.services.media.toString(), 'http://192.0.2.13:2020/onvif/service');
      expect((await client.streamUri(reading.services.media, 'profile_2')).url, 'rtsp://192.0.2.13:554/stream2');
    });

    test('Axis: HTTP Digest, a clock 95 s behind, an MJPEG profile left as the second choice', () async {
      final camera = FakeBrands.axis();
      final client = _client(camera, host: '192.0.2.14');
      final reading = await client.read();
      expect(reading.profiles.map((p) => p.encoding), ['H264', 'JPEG']);
      final stream = await client.streamUri(reading.services.media, 'profile_1_h264');
      expect(stream.port, 554);
      expect(stream.pathAndQuery, startsWith('/onvif-media/media.amp?profile=profile_1_h264'));
    });
  });

  group('the real HTTP of onvifHttpPost', () {
    test('a Content-Length, no chunks, no redirect followed', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      String? transferEncoding;
      int? length;
      server.listen((request) async {
        transferEncoding = request.headers.value('transfer-encoding');
        length = request.headers.contentLength;
        await request.drain<void>();
        if (request.uri.path == '/moved') {
          request.response
            ..statusCode = 302
            ..headers.set('location', 'http://192.0.2.99/elsewhere');
        } else {
          request.response.write('<ok/>');
        }
        await request.response.close();
      });
      addTearDown(server.close);
      final post = onvifHttpPost();
      final body = utf8.encode('<x/>');
      final answer = await post(Uri.parse('http://127.0.0.1:${server.port}/onvif/device_service'), const {}, body);
      expect(answer.status, 200);
      expect(answer.body, '<ok/>');
      expect(length, body.length);
      expect(transferEncoding, isNull);
      final moved = await post(Uri.parse('http://127.0.0.1:${server.port}/moved'), const {}, body);
      expect(moved.status, 302);
    });

    test('nothing listening: unreachable', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      await expectLater(
        onvifHttpPost()(Uri.parse('http://127.0.0.1:$port/onvif/device_service'), const {}, const []),
        throwsA(isA<IpCameraException>().having((e) => e.kind, 'kind', IpCameraErrorKind.unreachable)),
      );
    });
  });
}
