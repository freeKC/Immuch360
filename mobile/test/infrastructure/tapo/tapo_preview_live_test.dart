// The live view of a camera without RTSP through its media port, end to end on 127.0.0.1: the fake Streamd answers
// the preview request with the parts of a stream, the playlist is served by the real media bridge without any
// password; the C410 that takes only the MD5 of its password; a sleeping camera that misses the first connections; a
// camera that never answers (the step is connect), refuses the password (login) or the request (request, its code);
// "do stop" sent when the view stops.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_media_session.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_preview_live.dart';

import 'fake_streamd.dart';
import 'tapo_test_streams.dart';

const _password = 'synthetic-cloud-password';

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

Matcher _failedAt(TapoLiveStep step, TapoErrorKind kind, {int? code}) => isA<TapoLiveException>()
    .having((e) => e.step, 'step', step)
    .having((e) => e.kind, 'kind', kind)
    .having((e) => e.code, 'code', code);

void main() {
  late LocalMediaBridge bridge;
  late FakeStreamd streamd;

  setUp(() async {
    bridge = LocalMediaBridge();
    streamd = await FakeStreamd.start(password: _password);
    final frames = fixtureAccessUnits();
    streamd.preview = clipParts([...frames, ...frames, ...frames]);
  });
  tearDown(() async {
    await bridge.stop();
    await streamd.close();
  });

  TapoPreviewLiveHls live({
    bool hd = false,
    bool withAudio = true,
    int? port,
    TapoSocketConnector? connect,
    Duration firstSegmentTimeout = const Duration(seconds: 5),
  }) => TapoPreviewLiveHls(
    bridge: bridge,
    host: '127.0.0.1',
    port: port ?? streamd.port,
    password: _password,
    hd: hd,
    withAudio: withAudio,
    connectTimeout: const Duration(seconds: 1),
    wakePause: const Duration(milliseconds: 20),
    firstSegmentTimeout: firstSegmentTimeout,
    checkPeriod: const Duration(milliseconds: 50),
    connect: connect,
  );

  test('asks for the sub stream, serves the playlist and its segments, no password in the address', () async {
    final stream = live();
    addTearDown(stream.stop);
    final url = await stream.start();
    expect(url.host, '127.0.0.1');
    expect(url.port, bridge.port);
    expect(url.pathSegments.last, 'live.m3u8');
    expect(url.toString(), isNot(contains(_password)));
    expect(stream.hasAudio, isTrue);

    final preview = (streamd.requests.single['params']! as Map).cast<String, Object?>();
    expect(preview, tapoPreviewParams(hd: false));
    expect((preview['preview']! as Map)['resolutions'], ['VGA']);

    final (status, type, body) = await _get(url);
    expect((status, type), (HttpStatus.ok, 'application/vnd.apple.mpegurl'));
    final playlist = utf8.decode(body);
    expect(playlist, contains('#EXT-X-MAP:URI="init0.mp4"'));
    final segment = RegExp(r'^seg\d+\.m4s$', multiLine: true).firstMatch(playlist)!.group(0)!;
    final (segmentStatus, segmentType, segmentBytes) = await _get(url.resolve(segment));
    expect((segmentStatus, segmentType), (HttpStatus.ok, 'video/mp4'));
    expect(segmentBytes.length, greaterThan(100));
    final (initStatus, _, init) = await _get(url.resolve('init0.mp4'));
    expect(initStatus, HttpStatus.ok);
    // The sound of the camera as ALAC beside the video
    expect(latin1.decode(init, allowInvalid: true), contains('alac'));

    await stream.stop();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(streamd.stops, hasLength(1), reason: 'do stop frees the session slot of the camera');
    expect((await _get(url)).$1, HttpStatus.notFound);
  });

  test('asks for the main stream in HD, and the video alone when told to', () async {
    final stream = live(hd: true, withAudio: false);
    addTearDown(stream.stop);
    await stream.start();
    final preview = (streamd.requests.single['params']! as Map)['preview'] as Map;
    expect(preview['resolutions'], ['HD']);
    expect(stream.hasAudio, isFalse);
  });

  test('plays a C410 that announces SHA-256 but takes only MD5', () async {
    streamd.md5Only = true;
    final stream = live();
    addTearDown(stream.stop);
    final url = await stream.start();
    expect((await _get(url)).$1, HttpStatus.ok);
  });

  test('wakes a sleeping camera: the first connections that time out are tried again', () async {
    var attempts = 0;
    final stream = live(
      connect: (host, port, timeout) {
        attempts++;
        if (attempts <= 2) {
          throw TimeoutException('asleep');
        }
        return Socket.connect(host, port, timeout: timeout);
      },
    );
    addTearDown(stream.stop);
    await stream.start();
    expect(attempts, 4, reason: 'two missed, then the challenge and the login');
  });

  test('a camera that never answers fails at the connect step', () async {
    final stream = live(connect: (host, port, timeout) => throw TimeoutException('asleep'));
    await expectLater(stream.start(), throwsA(_failedAt(TapoLiveStep.connect, TapoErrorKind.unreachable)));
    expect(streamd.connections, 0);
  });

  test('a refused password fails at the login step, without a third try', () async {
    streamd.refusePassword = true;
    final stream = live();
    await expectLater(stream.start(), throwsA(_failedAt(TapoLiveStep.login, TapoErrorKind.mediaLocked, code: 401)));
    expect(streamd.connections, 4);
  });

  test('a refused request fails at the request step with the code of the camera', () async {
    streamd.refuseNext.add(-52405);
    final stream = live();
    await expectLater(stream.start(), throwsA(_failedAt(TapoLiveStep.request, TapoErrorKind.busy, code: -52405)));
  });

  test('a stream without a picture fails at the first picture step', () async {
    // The sound alone: no IDR picture ever comes
    streamd.preview = clipParts(fixtureAccessUnits()).where((part) => part.isAudio).toList();
    final stream = live(firstSegmentTimeout: const Duration(milliseconds: 600));
    await expectLater(
      stream.start(),
      throwsA(
        isA<TapoLiveException>()
            .having((e) => e.step, 'step', TapoLiveStep.firstPicture)
            .having((e) => e.detail, 'detail', isNotNull),
      ),
    );
  });

  test('tells the rate of the sound from two PES', () {
    expect(tapoAudioRate(800, 9000), 8000);
    expect(tapoAudioRate(1600, 9000), 16000);
    expect(tapoAudioRate(320, 1800), 16000);
    expect(tapoAudioRate(800, 0), isNull);
    expect(tapoAudioRate(800, 90000), isNull);
  });
}
