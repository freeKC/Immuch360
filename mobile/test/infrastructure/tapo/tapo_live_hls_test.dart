// The live playlist of a camera for AVPlayer, end to end on 127.0.0.1: the fake camera's RTSP stream through the
// session, the segmenter and the real media bridge, read back over HTTP as AVPlayer would; the address without the
// account; the end of the stream when the camera stops sending or the player stops asking; the stop that tears the
// RTSP session down and takes the playlist off the bridge.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_live_hls.dart';

import 'fake_rtsp_camera.dart';
import 'rtp_test_streams.dart';

const _password = 'camera-account-pw';

Future<(int, String?, Uint8List)> _get(Uri url) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(url)).close();
    final body = BytesBuilder(copy: false);
    await response.forEach(body.add);
    return (response.statusCode, response.headers.contentType?.mimeType, body.takeBytes());
  } finally {
    client.close();
  }
}

void main() {
  late LocalMediaBridge bridge;

  setUp(() => bridge = LocalMediaBridge());
  tearDown(() => bridge.stop());

  List<(int, Uint8List)> stream({int loops = 3, bool audio = true}) =>
      interleaveByTime(h264RtpPackets(fixtureNalUnits(loops: loops)), audio ? alawRtpPackets(loops * 2.0) : const []);

  TapoLiveHls live(
    FakeRtspCamera camera, {
    bool withAudio = true,
    Duration stallTimeout = const Duration(seconds: 10),
    Duration idleTimeout = const Duration(seconds: 15),
    Duration firstSegmentTimeout = const Duration(seconds: 5),
  }) => TapoLiveHls(
    bridge: bridge,
    host: '127.0.0.1',
    port: camera.port,
    path: '/stream2',
    user: 'viewer',
    password: _password,
    withAudio: withAudio,
    stallTimeout: stallTimeout,
    idleTimeout: idleTimeout,
    firstSegmentTimeout: firstSegmentTimeout,
    checkPeriod: const Duration(milliseconds: 50),
  );

  test('serves the playlist, the init segment and the segments, the account staying out of the address', () async {
    final camera = await FakeRtspCamera.start(frames: stream());
    addTearDown(camera.close);
    final session = live(camera);
    addTearDown(session.stop);
    final url = await session.start();
    expect(url.scheme, 'http');
    expect(url.host, '127.0.0.1');
    expect(url.port, bridge.port);
    expect(url.pathSegments.last, 'live.m3u8');
    expect(url.toString(), isNot(contains('viewer')));
    expect(url.toString(), isNot(contains(_password)));
    expect(session.hasAudio, isTrue);

    final (status, type, body) = await _get(url);
    expect(status, HttpStatus.ok);
    expect(type, 'application/vnd.apple.mpegurl');
    final playlist = utf8.decode(body);
    expect(playlist, startsWith('#EXTM3U\n'));
    expect(playlist, contains('#EXT-X-MAP:URI="init0.mp4"'));
    expect(playlist, contains('seg0.m4s'));

    final (initStatus, initType, init) = await _get(url.resolve('init0.mp4'));
    expect((initStatus, initType), (HttpStatus.ok, 'video/mp4'));
    expect(ascii.decode(init.sublist(4, 8)), 'ftyp');
    expect(latin1.decode(init).contains('alac'), isTrue, reason: 'the sound track');
    final (segmentStatus, _, segment) = await _get(url.resolve('seg0.m4s'));
    expect(segmentStatus, HttpStatus.ok);
    expect(ascii.decode(segment.sublist(4, 8)), 'styp');
    expect((await _get(url.resolve('seg99.m4s'))).$1, HttpStatus.notFound);
  });

  test('without the sound, sets up the video alone', () async {
    final camera = await FakeRtspCamera.start(frames: stream());
    addTearDown(camera.close);
    final session = live(camera, withAudio: false);
    addTearDown(session.stop);
    final url = await session.start();
    expect(session.hasAudio, isFalse);
    expect(camera.methods.where((method) => method == 'SETUP'), hasLength(1));
    final (_, _, init) = await _get(url.resolve('init0.mp4'));
    expect(latin1.decode(init).contains('alac'), isFalse);
  });

  test('stops: TEARDOWN, and the playlist leaves the bridge', () async {
    final camera = await FakeRtspCamera.start(frames: stream());
    addTearDown(camera.close);
    final session = live(camera);
    final url = await session.start();
    await session.stop();
    await camera.tornDown.timeout(const Duration(seconds: 2));
    expect((await _get(url)).$1, HttpStatus.notFound);
    var ended = false;
    unawaited(session.ended.then((_) => ended = true));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(ended, isFalse, reason: 'a stop is no loss');
  });

  test('ends when the camera stops sending, and when it cuts the stream', () async {
    final quiet = await FakeRtspCamera.start(frames: stream());
    addTearDown(quiet.close);
    final first = live(quiet, stallTimeout: const Duration(milliseconds: 300));
    addTearDown(first.stop);
    final url = await first.start();
    expect(await first.ended.timeout(const Duration(seconds: 3)), tapoLiveStreamLost);
    expect((await _get(url)).$1, HttpStatus.notFound);

    final cut = await FakeRtspCamera.start(frames: stream());
    addTearDown(cut.close);
    final second = live(cut);
    addTearDown(second.stop);
    await second.start();
    cut.cut();
    expect(await second.ended.timeout(const Duration(seconds: 3)), tapoLiveStreamLost);
  });

  test('ends when the player stops asking', () async {
    final camera = await FakeRtspCamera.start(frames: stream());
    addTearDown(camera.close);
    final session = live(camera, idleTimeout: const Duration(milliseconds: 400));
    addTearDown(session.stop);
    final url = await session.start();
    // A player that asks keeps it
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect((await _get(url)).$1, HttpStatus.ok);
    }
    expect(await session.ended.timeout(const Duration(seconds: 3)), tapoLivePlayerGone);
    await camera.tornDown.timeout(const Duration(seconds: 2));
  });

  test('a camera that sends no picture', () async {
    final camera = await FakeRtspCamera.start(frames: interleaveByTime(const [], alawRtpPackets(1)));
    addTearDown(camera.close);
    final session = live(camera, firstSegmentTimeout: const Duration(milliseconds: 500));
    await expectLater(
      session.start(),
      throwsA(
        isA<TapoCameraException>()
            .having((e) => e.kind, 'kind', TapoErrorKind.unsupported)
            .having((e) => e.detail, 'detail', tapoLiveNoPicture),
      ),
    );
    await camera.tornDown.timeout(const Duration(seconds: 2));
  });

  test('a stop while it starts ends the start at once', () async {
    final camera = await FakeRtspCamera.start(frames: interleaveByTime(const [], alawRtpPackets(1)));
    addTearDown(camera.close);
    final session = live(camera, firstSegmentTimeout: const Duration(seconds: 30));
    final started = session.start();
    await camera.played.timeout(const Duration(seconds: 2));
    await session.stop();
    await expectLater(
      started.timeout(const Duration(seconds: 2)),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.cancelled)),
    );
  });

  test('tells a refused account and an H.265 camera', () async {
    final refusing = await FakeRtspCamera.start(password: 'another');
    addTearDown(refusing.close);
    await expectLater(
      live(refusing).start(),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.wrongPassword)),
    );
    final h265 = await FakeRtspCamera.start(sdp: fakeRtspSdp(video: 'H265'));
    addTearDown(h265.close);
    await expectLater(
      live(h265).start(),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.h265)),
    );
  });
}
