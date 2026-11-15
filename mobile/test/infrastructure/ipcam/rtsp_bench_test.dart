// The shared RTSP client against a real RTSP server, for the cameras of other brands: skipped unless
// IMMUCH_RTSP_BENCH holds the address of a MediaMTX (MIT) bench, as `IMMUCH_RTSP_BENCH=127.0.0.1:8554 flutter test
// test/infrastructure/ipcam/rtsp_bench_test.dart`. The bench serves synthetic streams only (FFmpeg's testsrc2 and a
// sine, published by ffmpeg), over TCP, with Digest authentication:
//
//   open              H.264 640x360 15 fps and G.711 A-law 8 kHz, no account
//   h265              H.265 640x360 and AAC 16 kHz, no account
//   cam/realmonitor   H.264 320x180 and G.711 mu-law, no account, asked with Dahua's query
//   auth              H.264, Digest account viewer / S3cret+word
//
// What it proves beyond the fakes: the probe and the live session of iPhone and iPad (the Dart RTSP to HLS path)
// read a server they were not written against, a first IDR picture comes within 3 s, a query in the path survives,
// an H.265 stream is told before any SETUP, and an account goes with Digest only when the server asks.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/ip_camera.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/ipcam/camera_address.dart';
import 'package:immich_mobile/infrastructure/ipcam/ip_camera_service.dart';
import 'package:immich_mobile/infrastructure/tapo/rtp_h264.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_probe.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_session.dart';

const _user = 'viewer';
const _password = 'S3cret+word';

void main() {
  final bench = Platform.environment['IMMUCH_RTSP_BENCH'];
  final skip = bench == null || bench.isEmpty ? 'no RTSP bench (IMMUCH_RTSP_BENCH)' : null;
  final host = (bench ?? '127.0.0.1:8554').split(':').first;
  final port = int.tryParse((bench ?? '127.0.0.1:8554').split(':').last) ?? 8554;

  Future<Duration> firstIdr(RtspSession session) async {
    final watch = Stopwatch()..start();
    final idr = Completer<void>();
    final depacketizer = H264Depacketizer((unit) {
      if (unit.isIdr && !idr.isCompleted) {
        idr.complete();
      }
    });
    final subscription = session.packets.listen((packet) {
      if (packet.channel == rtspVideoChannel) {
        final rtp = RtpPacket.parse(packet.data);
        if (rtp != null) {
          depacketizer.add(rtp);
        }
      }
    });
    try {
      await idr.future.timeout(const Duration(seconds: 3));
      return watch.elapsed;
    } finally {
      await subscription.cancel();
    }
  }

  test('the probe reads the codecs of each stream', () async {
    final open = await probeTapoRtsp(host, port: port, path: '/open', user: '', password: '');
    expect((open.video, open.audio), ('H264', 'PCMA'));
    final h265 = await probeTapoRtsp(host, port: port, path: '/h265', user: '', password: '');
    expect((h265.video, h265.audio), ('H265', 'MPEG4-GENERIC'));
    final dahua = await probeTapoRtsp(
      host,
      port: port,
      path: '/cam/realmonitor?channel=1&subtype=0',
      user: '',
      password: '',
    );
    expect((dahua.video, dahua.audio), ('H264', 'PCMU'));
  }, skip: skip);

  test('the account: asked for and none given, refused, then answered with Digest', () async {
    await expectLater(
      probeTapoRtsp(host, port: port, path: '/auth', user: '', password: ''),
      throwsA(isA<TapoCameraException>().having((e) => e.detail, 'detail', rtspNeedsAccount)),
    );
    await expectLater(
      probeTapoRtsp(host, port: port, path: '/auth', user: _user, password: 'wrong'),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.wrongPassword)),
    );
    final probe = await probeTapoRtsp(host, port: port, path: '/auth', user: _user, password: _password);
    expect(probe.video, 'H264');
  }, skip: skip);

  test('the live session of iPhone and iPad: video and G.711 sound, a first IDR picture within 3 s', () async {
    for (final path in ['/open', '/cam/realmonitor?channel=1&subtype=0']) {
      final session = await RtspSession.open(host, port: port, path: path, user: '', password: '');
      try {
        expect(session.video.encoding, 'H264');
        expect(session.audio?.encoding, path == '/open' ? 'PCMA' : 'PCMU');
        expect(await firstIdr(session), lessThan(const Duration(seconds: 3)));
      } finally {
        await session.close();
      }
    }
    final session = await RtspSession.open(host, port: port, path: '/auth', user: _user, password: _password);
    try {
      expect(await firstIdr(session), lessThan(const Duration(seconds: 3)));
    } finally {
      await session.close();
    }
  }, skip: skip);

  test('an H.265 stream is told before any SETUP on iPhone and iPad', () async {
    await expectLater(
      RtspSession.open(host, port: port, path: '/h265', user: '', password: ''),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.h265)),
    );
  }, skip: skip);

  test('the test of a pasted link, per player', () async {
    final service = IpCameraService();
    final h265 = parseCameraStreamAddress('rtsp://$host:$port/h265')!;
    expect((await service.testStream(h265, player: CameraPlayer.media3)).playsHere, isTrue);
    expect((await service.testStream(h265, player: CameraPlayer.dartHls)).playsHere, isFalse);
    final auth = parseCameraStreamAddress('rtsp://$host:$port/auth')!;
    await expectLater(
      service.testStream(auth, player: CameraPlayer.media3),
      throwsA(isA<IpCameraException>().having((e) => e.kind, 'kind', IpCameraErrorKind.needsAccount)),
    );
    final missing = parseCameraStreamAddress('rtsp://$host:$port/nothing-here')!;
    await expectLater(service.testStream(missing, player: CameraPlayer.media3), throwsA(isA<IpCameraException>()));
  }, skip: skip);
}
