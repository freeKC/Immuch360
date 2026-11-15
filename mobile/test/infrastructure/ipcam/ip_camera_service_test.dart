// What the pages of a camera of another brand ask of the network, against the fake ONVIF camera and a fake RTSP probe:
// the usual ONVIF ports tried in turn when the address has none, the main and sub streams picked and brought to the
// host of the source, the test of a stream with what each player makes of its codecs, the RTSP failures in the words
// of the pages, and an RTSPS link tested through the plain port of a UniFi console only.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/ip_camera.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/ipcam/camera_address.dart';
import 'package:immich_mobile/infrastructure/ipcam/ip_camera_service.dart';
import 'package:immich_mobile/infrastructure/ipcam/onvif_client.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_probe.dart';

import 'fake_onvif_camera.dart';

/// The fake camera on [port] only: nothing answers on the others
OnvifPost _onPort(FakeOnvifCamera camera, int port, List<int> asked) => (url, headers, body) {
  asked.add(url.port);
  if (url.port != port) {
    throw const IpCameraException(IpCameraErrorKind.unreachable);
  }
  return camera.post(url, headers, body);
};

void main() {
  group('readOnvif', () {
    test('an address without a port: the usual ports in turn, the streams on the host of the source', () async {
      final camera = FakeBrands.reolink();
      final asked = <int>[];
      final service = IpCameraService(post: _onPort(camera, 8000, asked));
      final setup = await service.readOnvif(
        host: '192.0.2.12',
        path: camera.devicePath,
        user: camera.user,
        password: camera.password,
      );
      expect(setup.port, 8000);
      // 80 first, then Reolink's 8000; nothing after the one that answered
      expect(asked.toSet(), {80, 8000});
      expect(setup.mainStream!.host, '192.0.2.12');
      expect(setup.mainStream!.pathAndQuery, '/h264Preview_01_main');
      expect(setup.main.pixels, greaterThan(setup.sub!.pixels));
      expect(setup.subStream, isNotNull);
    });

    test('a typed port is the only one asked', () async {
      final camera = FakeBrands.tapo();
      final asked = <int>[];
      final service = IpCameraService(post: _onPort(camera, 2020, asked));
      final setup = await service.readOnvif(
        host: '192.0.2.13',
        port: 2020,
        path: camera.devicePath,
        user: camera.user,
        password: camera.password,
      );
      expect(asked.toSet(), {2020});
      expect(setup.mainStream!.url, 'rtsp://192.0.2.13:554/stream1');
      expect(setup.subStream!.url, 'rtsp://192.0.2.13:554/stream2');
    });

    test('nothing answers on any port: unreachable', () async {
      final service = IpCameraService(post: _onPort(FakeOnvifCamera(), 1, []));
      await expectLater(
        service.readOnvif(host: '192.0.2.99'),
        throwsA(isA<IpCameraException>().having((e) => e.kind, 'kind', IpCameraErrorKind.unreachable)),
      );
    });

    test('a refused account stops at the first port that answers as ONVIF: one try only', () async {
      final camera = FakeOnvifCamera();
      final asked = <int>[];
      final service = IpCameraService(post: _onPort(camera, 80, asked));
      await expectLater(
        service.readOnvif(host: '192.0.2.50', user: camera.user, password: 'wrong'),
        throwsA(isA<IpCameraException>().having((e) => e.kind, 'kind', IpCameraErrorKind.wrongPassword)),
      );
      expect(asked.toSet(), {80});
      expect(camera.requests.where((r) => r.action == 'GetDeviceInformation'), hasLength(1));
    });

    test('a camera without a video profile: noProfile', () async {
      final camera = FakeOnvifCamera(profiles: const []);
      final service = IpCameraService(post: camera.post);
      await expectLater(
        service.readOnvif(host: '192.0.2.50', port: 80, user: camera.user, password: camera.password),
        throwsA(isA<IpCameraException>().having((e) => e.kind, 'kind', IpCameraErrorKind.noProfile)),
      );
    });
  });

  group('testStream', () {
    const address = CameraStreamAddress(secure: false, host: '192.0.2.7', port: 554, pathAndQuery: '/live/main');

    IpCameraService probing(TapoLiveProbe Function(CameraStreamAddress address) answer, List<String> asked) =>
        IpCameraService(
          probe: (address, user, password) async {
            asked.add('${address.url} ${user.isEmpty ? 'no account' : 'account'}');
            return answer(address);
          },
        );

    test('what each player makes of the codecs', () async {
      final asked = <String>[];
      final service = probing((_) => const TapoLiveProbe(video: 'H265', audio: 'MPEG4-GENERIC'), asked);
      expect((await service.testStream(address, player: CameraPlayer.media3)).playsHere, isTrue);
      expect((await service.testStream(address, player: CameraPlayer.libmpv)).playsHere, isTrue);
      expect((await service.testStream(address, player: CameraPlayer.dartHls)).playsHere, isFalse);
      expect(asked, everyElement('rtsp://192.0.2.7:554/live/main no account'));
    });

    test('the codecs per player', () {
      expect(playsVideo(CameraPlayer.media3, 'H264'), isTrue);
      expect(playsVideo(CameraPlayer.media3, 'JPEG'), isFalse);
      expect(playsVideo(CameraPlayer.dartHls, 'H264'), isTrue);
      expect(playsVideo(CameraPlayer.dartHls, 'HEVC'), isFalse);
      expect(playsVideo(CameraPlayer.libmpv, 'JPEG'), isTrue);
      expect(playsVideo(CameraPlayer.media3, null), isNull);
    });

    test('a UniFi Protect RTSPS link is tested on the plain port, another RTSPS link nowhere but a computer', () async {
      final asked = <String>[];
      final service = probing((_) => const TapoLiveProbe(video: 'H264'), asked);
      final unifi = parseCameraStreamAddress('rtsps://192.0.2.1:7441/Tok3nSynthetic?enableSrtp')!;
      await service.testStream(unifi, player: CameraPlayer.media3);
      expect(asked.single, 'rtsp://192.0.2.1:7447/Tok3nSynthetic no account');
      final other = parseCameraStreamAddress('rtsps://192.0.2.1:8322/x')!;
      await expectLater(
        service.testStream(other, player: CameraPlayer.media3),
        throwsA(isA<IpCameraException>().having((e) => e.kind, 'kind', IpCameraErrorKind.secureNotHere)),
      );
      final onComputer = await service.testStream(other, player: CameraPlayer.libmpv);
      expect(onComputer.playsHere, isNull);
      expect(asked, hasLength(1));
    });

    test('the RTSP failures in the words of the pages', () async {
      Future<IpCameraErrorKind> kindOf(TapoCameraException error, {String user = ''}) async {
        final service = IpCameraService(probe: (_, _, _) async => throw error);
        try {
          await service.testStream(address, user: user, password: user.isEmpty ? '' : 'pw');
        } on IpCameraException catch (failure) {
          return failure.kind;
        }
        fail('no failure');
      }

      expect(
        await kindOf(const TapoCameraException(TapoErrorKind.wrongPassword, code: 401, detail: rtspNeedsAccount)),
        IpCameraErrorKind.needsAccount,
      );
      expect(
        await kindOf(const TapoCameraException(TapoErrorKind.wrongPassword, code: 401), user: 'admin'),
        IpCameraErrorKind.wrongPassword,
      );
      expect(await kindOf(const TapoCameraException(TapoErrorKind.unreachable)), IpCameraErrorKind.unreachable);
      expect(
        await kindOf(const TapoCameraException(TapoErrorKind.unsupported, detail: 'RTSP authentication')),
        IpCameraErrorKind.basicOnly,
      );
      expect(
        await kindOf(const TapoCameraException(TapoErrorKind.unsupported, code: 404, detail: 'RTSP DESCRIBE 404')),
        IpCameraErrorKind.noProfile,
      );
      expect(
        await kindOf(const TapoCameraException(TapoErrorKind.unsupported, code: 500, detail: 'RTSP DESCRIBE 500')),
        IpCameraErrorKind.other,
      );
    });
  });
}
