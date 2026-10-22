// The live stream pulled in Dart for iPhone and iPad, against a fake camera on 127.0.0.1: Digest on every request
// once challenged, the interleaved SETUP of the video and the sound, PLAY and its RTP-Info, the packets on their
// channels whatever the TCP cuts, the keep alive with the session, TEARDOWN; the refusals told as such, a Basic
// challenge never answered, an H.265 camera, and a camera that cuts the stream.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_session.dart';

import 'fake_rtsp_camera.dart';
import 'rtp_test_streams.dart';

const _password = 'camera-account-pw';

void main() {
  Future<RtspSession> open(
    FakeRtspCamera camera, {
    bool withAudio = true,
    Duration? keepAlive,
    String path = '/stream2',
  }) => RtspSession.open(
    '127.0.0.1',
    port: camera.port,
    path: path,
    user: 'viewer',
    password: _password,
    withAudio: withAudio,
    keepAlive: keepAlive,
    timeout: const Duration(seconds: 3),
  );

  for (final qop in [false, true]) {
    test('plays the video and the sound with the camera account${qop ? ', qop auth' : ''}', () async {
      final camera = await FakeRtspCamera.start(qop: qop);
      addTearDown(camera.close);
      final session = await open(camera);
      addTearDown(session.close);

      expect(camera.methods, ['OPTIONS', 'DESCRIBE', 'DESCRIBE', 'SETUP', 'SETUP', 'PLAY']);
      final base = 'rtsp://127.0.0.1:${camera.port}/stream2';
      final setups = camera.requests.where((request) => request.startsWith('SETUP')).toList();
      expect(setups[0].split(' ')[1], '$base/track1');
      expect(FakeRtspCamera.header(setups[0], 'Transport'), 'RTP/AVP/TCP;unicast;interleaved=0-1');
      expect(setups[1].split(' ')[1], '$base/track2');
      expect(FakeRtspCamera.header(setups[1], 'Transport'), 'RTP/AVP/TCP;unicast;interleaved=2-3');
      // The session of the first SETUP on every next request; the account answered on each one after the challenge
      expect(FakeRtspCamera.header(setups[0], 'Session'), isNull);
      expect(FakeRtspCamera.header(setups[1], 'Session'), fakeRtspSession);
      final play = camera.requests.last;
      expect(play.split(' ')[1], '$base/');
      expect(FakeRtspCamera.header(play, 'Session'), fakeRtspSession);
      for (final request in camera.requests.skip(2)) {
        expect(FakeRtspCamera.header(request, 'Authorization'), startsWith('Digest username="viewer"'));
      }
      if (qop) {
        // A new nonce count for each request
        final counts = [
          for (final request in camera.requests.skip(2))
            RegExp(r'nc=([0-9a-f]{8})').firstMatch(FakeRtspCamera.header(request, 'Authorization')!)!.group(1),
        ];
        expect(counts, ['00000001', '00000002', '00000003', '00000004']);
      }

      expect(session.video.encoding, 'H264');
      expect(session.video.fmtp['sprop-parameter-sets'], fakeSpropParameterSets);
      expect(session.audio?.encoding, 'PCMA');
      expect(session.audio?.clockRate, 8000);
      expect((session.videoRtpTime, session.audioRtpTime), (3000000, 160000));
    });
  }

  test('hands the packets on their channels, whatever the TCP cuts', () async {
    final video = h264RtpPackets(fixtureNalUnits());
    final audio = alawRtpPackets(2);
    final frames = interleaveByTime(video, audio);
    final camera = await FakeRtspCamera.start(frames: frames, chunkSize: 77);
    addTearDown(camera.close);
    final session = await open(camera);
    addTearDown(session.close);
    final received = <(int, Uint8List)>[];
    final all = Completer<void>();
    session.packets.listen((packet) {
      received.add((packet.channel, Uint8List.fromList(packet.data)));
      if (received.length == frames.length) {
        all.complete();
      }
    });
    await all.future.timeout(const Duration(seconds: 5));
    expect([for (final (channel, _) in received) channel], [for (final (channel, _) in frames) channel]);
    for (var i = 0; i < frames.length; i++) {
      expect(received[i].$2, frames[i].$2, reason: 'packet $i');
    }
  });

  test('keeps the session alive and ends it with TEARDOWN', () async {
    final camera = await FakeRtspCamera.start();
    addTearDown(camera.close);
    final session = await open(camera, keepAlive: const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 180));
    final keepAlives = camera.requests.skip(6).where((request) => request.startsWith('OPTIONS')).toList();
    expect(keepAlives.length, greaterThanOrEqualTo(2));
    expect(FakeRtspCamera.header(keepAlives.first, 'Session'), fakeRtspSession);
    await session.close();
    await camera.tornDown.timeout(const Duration(seconds: 2));
    final teardown = camera.requests.lastWhere((request) => request.startsWith('TEARDOWN'));
    expect(teardown.split(' ')[1], 'rtsp://127.0.0.1:${camera.port}/stream2/');
    expect(FakeRtspCamera.header(teardown, 'Session'), fakeRtspSession);
    final count = camera.requests.length;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(camera.requests, hasLength(count), reason: 'no keep alive after the end');
  });

  test('without the sound, sets up the video alone', () async {
    final camera = await FakeRtspCamera.start();
    addTearDown(camera.close);
    final session = await open(camera, withAudio: false);
    addTearDown(session.close);
    expect(camera.methods.where((method) => method == 'SETUP'), hasLength(1));
    expect(session.audio, isNull);
  });

  test('plays the video alone when the camera refuses its sound track', () async {
    final camera = await FakeRtspCamera.start(refuseAudio: true);
    addTearDown(camera.close);
    final session = await open(camera);
    addTearDown(session.close);
    expect(camera.methods, ['OPTIONS', 'DESCRIBE', 'DESCRIBE', 'SETUP', 'SETUP', 'PLAY']);
    expect(session.audio, isNull);
  });

  test('a camera without sound, or with another one, plays its video', () async {
    final camera = await FakeRtspCamera.start(sdp: fakeRtspSdp(audio: 'MPEG4-GENERIC'));
    addTearDown(camera.close);
    final session = await open(camera);
    addTearDown(session.close);
    expect(session.audio, isNull);
    expect(camera.methods.where((method) => method == 'SETUP'), hasLength(1));
  });

  test('reads the session timeout for the keep alive, and an aggregate control of the SDP', () async {
    final camera = await FakeRtspCamera.start(sessionTimeout: null, sdp: fakeRtspSdp(sessionControl: true));
    addTearDown(camera.close);
    final session = await open(camera);
    addTearDown(session.close);
    expect(camera.requests.last.split(' ')[1], 'rtsp://127.0.0.1:${camera.port}/stream2/');
  });

  test('opens the connection again when the camera closes it after its challenge', () async {
    final camera = await FakeRtspCamera.start(closeAfterChallenge: true);
    addTearDown(camera.close);
    final session = await open(camera);
    addTearDown(session.close);
    expect(camera.methods.last, 'PLAY');
  });

  test('tells a wrong camera account, after one try', () async {
    final camera = await FakeRtspCamera.start(password: 'another');
    addTearDown(camera.close);
    await expectLater(
      open(camera),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.wrongPassword)),
    );
    expect(camera.methods, ['OPTIONS', 'DESCRIBE', 'DESCRIBE']);
  });

  test('never answers a Basic challenge', () async {
    final camera = await FakeRtspCamera.start(basicOnly: true);
    addTearDown(camera.close);
    await expectLater(
      open(camera),
      throwsA(
        isA<TapoCameraException>()
            .having((e) => e.kind, 'kind', TapoErrorKind.unsupported)
            .having((e) => e.detail, 'detail', 'RTSP authentication'),
      ),
    );
    expect(camera.requests.where((request) => FakeRtspCamera.header(request, 'Authorization') != null), isEmpty);
  });

  test('tells an H.265 camera before setting anything up', () async {
    final camera = await FakeRtspCamera.start(sdp: fakeRtspSdp(video: 'H265'));
    addTearDown(camera.close);
    await expectLater(
      open(camera),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.h265)),
    );
    expect(camera.methods, isNot(contains('SETUP')));
  });

  test('tells a camera that serves enough viewers already', () async {
    final camera = await FakeRtspCamera.start(playStatus: 453);
    addTearDown(camera.close);
    await expectLater(
      open(camera),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.busy)),
    );
  });

  test('tells a camera that does not answer', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    await expectLater(
      RtspSession.open('127.0.0.1', port: port, user: 'viewer', password: _password),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.unreachable)),
    );
  });

  test('ends the packets with an error when the camera cuts the stream', () async {
    final camera = await FakeRtspCamera.start();
    addTearDown(camera.close);
    final session = await open(camera);
    addTearDown(session.close);
    final ended = Completer<Object>();
    session.packets.listen((_) {}, onError: (Object error) => ended.complete(error));
    camera.cut();
    final error = await ended.future.timeout(const Duration(seconds: 2));
    expect(error, isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.unreachable));
  });

  test('never puts the account in a request line or in clear in a header', () async {
    final camera = await FakeRtspCamera.start();
    addTearDown(camera.close);
    final session = await open(camera, keepAlive: const Duration(milliseconds: 30));
    await Future<void>.delayed(const Duration(milliseconds: 70));
    await session.close();
    for (final request in camera.requests) {
      expect(request, isNot(contains(_password)));
      expect(request.split('\r\n').first, isNot(contains('viewer')));
    }
  });
}
