// Video thumbnails on the computers (design 2.7): the grabber against a fake player (the frame past the start, at
// the middle of a short video, one grab at a time, the player given back), the scaling of mpv's frame, and the two
// callers: the share tiles (VideoThumbnailApi) and the videos of the folder library (LocalImageApi, in
// desktop_local_image_api_test.dart).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/platform/desktop_video_thumbnail_api.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/video_thumbnail_grabber.dart';

import 'fake_playback_engine.dart';

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);

void main() {
  late FakePlayers players;
  late VideoThumbnailGrabber grabber;

  setUp(() {
    players = FakePlayers(
      onCreate: (engine) => engine
        ..autoLoad = const Duration(seconds: 30)
        ..frame = _jpeg,
    );
    grabber = VideoThumbnailGrabber(
      pool: players.pool,
      openTimeout: const Duration(seconds: 2),
      frameTimeout: const Duration(seconds: 2),
    );
  });

  test('the frame past the start, scaled into the box, and the player given back stopped', () async {
    final frame = await grabber.grab(
      '/videos/a.mp4',
      time: const Duration(seconds: 1),
      box: (width: 320, height: 320, cover: true),
    );

    expect(frame, _jpeg);
    final engine = players.made.single;
    expect(engine.kind, PlayerKind.thumbnail);
    expect(engine.calls, ['open /videos/a.mp4 at 0', 'seek 1000', 'pause', 'stop']);
    expect(engine.boxes.single, (width: 320, height: 320, cover: true));
    expect(players.pool.activeCount(PlayerKind.thumbnail), 0);
    expect(players.pool.idleCount(PlayerKind.thumbnail), 1);
  });

  test('a video shorter than twice the time gives its middle frame; a bridge URL is streamed', () async {
    final first = await grabber.grab(
      'http://127.0.0.1:41000/token/smb-1/short.mp4',
      time: const Duration(seconds: 1),
      box: (width: 400, height: 1600, cover: false),
    );
    expect(first, isNotNull);
    final engine = players.made.single;
    expect(engine.calls.first, 'open http://127.0.0.1:41000/token/smb-1/short.mp4 at 0 streamed');
  });

  test('the middle of a short video', () async {
    players = FakePlayers(
      onCreate: (engine) => engine
        ..autoLoad = const Duration(milliseconds: 1200)
        ..frame = _jpeg,
    );
    grabber = VideoThumbnailGrabber(pool: players.pool);
    await grabber.grab(
      '/videos/short.mp4',
      time: const Duration(seconds: 1),
      box: (width: 320, height: 320, cover: true),
    );
    expect(players.made.single.calls, contains('seek 600'));
  });

  test('no frame when the file fails, or when nothing comes in time; the player is given back anyway', () async {
    players = FakePlayers(onCreate: (engine) => engine.frame = _jpeg);
    grabber = VideoThumbnailGrabber(
      pool: players.pool,
      openTimeout: const Duration(milliseconds: 300),
      frameTimeout: const Duration(milliseconds: 300),
    );
    // Nothing comes: no first frame
    expect(
      await grabber.grab(
        '/videos/never.mp4',
        time: const Duration(seconds: 1),
        box: (width: 8, height: 8, cover: true),
      ),
      isNull,
    );
    final engine = players.made.single;
    expect(engine.calls.last, 'stop');

    // A failure ends the wait at once
    final failing = grabber.grab(
      '/videos/broken.mp4',
      time: const Duration(seconds: 1),
      box: (width: 8, height: 8, cover: true),
    );
    await pumpEventQueue();
    engine.emit(PlayerEventKind.failed, 'libmpv: unrecognized file format');
    expect(await failing, isNull);
    expect(players.pool.activeCount(PlayerKind.thumbnail), 0);
  });

  test('one grab at a time, in the order asked', () async {
    final order = <String>[];
    final results = await Future.wait([
      for (final name in ['a', 'b', 'c'])
        grabber
            .grab('/videos/$name.mp4', time: Duration.zero, box: (width: 8, height: 8, cover: true))
            .whenComplete(() => order.add(name)),
    ]);
    expect(results, everyElement(_jpeg));
    expect(order, ['a', 'b', 'c']);
    expect(players.made, hasLength(1), reason: 'one grabber player, reused');
  });

  group('frame scaling', () {
    test('inside the box or covering it, never larger than the frame', () {
      expect(frameSizeIn(7680, 3840, (width: 400, height: 1600, cover: false)), (width: 400, height: 200));
      expect(frameSizeIn(7680, 3840, (width: 320, height: 320, cover: true)), (width: 640, height: 320));
      expect(frameSizeIn(1080, 1920, (width: 320, height: 320, cover: true)), (width: 320, height: 569));
      expect(frameSizeIn(200, 100, (width: 1024, height: 1024, cover: true)), (width: 200, height: 100));
    });

    test('BGR0 rows become RGBA pixels, each the mean of its area', () {
      // 4 x 2 source, rows of 20 bytes (padding of 4); left half red, right half blue
      const stride = 20;
      final source = Uint8List(stride * 2);
      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 4; x++) {
          final i = y * stride + x * 4;
          source[i] = x < 2 ? 0 : 200; // B
          source[i + 1] = 10; // G
          source[i + 2] = x < 2 ? 100 : 0; // R
        }
      }
      final rgba = scaleBgr0ToRgba(source, sourceWidth: 4, sourceHeight: 2, stride: stride, width: 2, height: 1);
      expect(rgba, [100, 10, 0, 255, 0, 10, 200, 255]);
    });
  });

  group('share tiles', () {
    test('a bridge URL gets the frame at the width asked; its headers go nowhere', () async {
      final api = DesktopVideoThumbnailApi(grabber: grabber, available: true);
      final bytes = await api.thumbnailForUrl(
        'http://127.0.0.1:41000/token/smb-1/a.mp4',
        const {'cookie': 'secret'},
        1000,
        400,
      );
      expect(bytes, _jpeg);
      expect(players.made.single.boxes.single, (width: 400, height: 1600, cover: false));
    });

    test('no frame without libmpv, or for an address that is not the bridge', () async {
      expect(
        await DesktopVideoThumbnailApi(
          grabber: grabber,
          available: false,
        ).thumbnailForUrl('http://127.0.0.1:41000/token/smb-1/a.mp4', const {}, 1000, 400),
        isEmpty,
      );
      final api = DesktopVideoThumbnailApi(grabber: grabber, available: true);
      expect(await api.thumbnailForUrl('https://server.example/api/assets/1/original', const {}, 1000, 400), isEmpty);
      expect(await api.thumbnailForUrl('http://u:p@127.0.0.1:41000/t/a.mp4', const {}, 1000, 400), isEmpty);
      expect(players.made, isEmpty);
    });
  });
}
