// Where the AV2 videos come in (lot AD3): a file of this computer and a file of a share become the URL of their
// companion for the players (resolveDesktopVideoSource) and for the thumbnails (VideoThumbnailGrabber), the share read
// through the file system behind its bridge URL (LocalMediaBridge.fileOf); an .ivf of another codec goes to libmpv as it
// is. And the speeds of the AV2 formats kept with the decoder measures of this computer.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/network/immich_server_file_system.dart';
import 'package:immich_mobile/desktop/video/av2_playback.dart';
import 'package:immich_mobile/desktop/video/decoder_measure.dart';
import 'package:immich_mobile/desktop/video/desktop_video_sources.dart';
import 'package:immich_mobile/desktop/video/video_thumbnail_grabber.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:native_video_player/native_video_player.dart';

import '../fake_playback_engine.dart';
import 'av2_test_support.dart';

const _served = 'http://127.0.0.1:50123/AbCdEfGhIjKlMnOp0123456789abcdef/video.y4m';

/// The playbacks of the app without a companion: what they are asked to open, and what they answer
class _RecordingAv2 extends Av2Playbacks {
  _RecordingAv2() : super(companion: () async => null, runner: (_) => throw UnimplementedError(), enabled: () => true);

  /// What open does instead of serving: throws it when it is an exception, else gives [_served]
  Exception? answer;
  final opened = <String>[];
  final thumbnails = <String>[];
  final released = <String>[];

  @override
  Future<String> open(Av2Bytes bytes, {bool forThumbnail = false}) async {
    (forThumbnail ? thumbnails : opened).add(bytes.key);
    await bytes.close();
    final thrown = answer;
    if (thrown != null) {
      throw thrown;
    }
    return _served;
  }

  @override
  Future<void> release(String resource) async => released.add(resource);
}

void main() {
  late LocalMediaBridge bridge;
  late _RecordingAv2 av2;

  setUp(() async {
    bridge = LocalMediaBridge();
    await bridge.start();
    av2 = _RecordingAv2();
  });

  tearDown(() => bridge.stop());

  Future<String> resolve(String path, VideoSourceType type) async => resolveDesktopVideoSource(
    await VideoSource.init(path: path, type: type),
    bridge: bridge,
    serverEndpoint: null,
    serverFileSystem: () => ImmichServerFileSystem(endpoint: () => null, client: http.Client.new),
    av2: av2,
  );

  test('an AV2 file of this computer plays from its companion; another video stays a path', () async {
    final path = Platform.isWindows ? r'C:\Vidéos\phare.ivf' : '/home/u/Vidéos/phare.ivf';
    expect(await resolve(path, VideoSourceType.file), _served);
    expect(av2.opened, [path]);
    expect(await resolve(Platform.isWindows ? r'C:\v\a.mp4' : '/v/a.mp4', VideoSourceType.file), isNot(_served));
    expect(av2.opened, hasLength(1));
  });

  test('an AV2 file of a share: its units read through the share behind the bridge URL', () async {
    final share = MemoryShare(av2Fixture('av2-256x144-8bit.obu'), path: '/clips/phare.obu');
    bridge.register(share);
    final url = bridge.urlFor(share.source.id, '/clips/phare.obu').toString();
    expect(bridge.fileOf(Uri.parse(url))?.path, '/clips/phare.obu');
    expect(bridge.fileOf(Uri.parse(url))?.fileSystem, same(share));
    expect(bridge.fileOf(Uri.parse('http://127.0.0.1:1/another-token/av2-share/clips/phare.obu')), isNull);
    expect(await resolve(url, VideoSourceType.network), _served);
    expect(av2.opened, ['av2-share:/clips/phare.obu']);
    // The other videos of the share as before
    final mp4 = bridge.urlFor(share.source.id, '/clips/a.mp4').toString();
    expect(await resolve(mp4, VideoSourceType.network), mp4);
  });

  test('an .ivf of another codec goes to libmpv as it is; a refusal reaches the player', () async {
    final path = Platform.isWindows ? r'C:\v\av1.ivf' : '/v/av1.ivf';
    av2.answer = const Av2NotAv2('its first bytes');
    expect(await resolve(path, VideoSourceType.file), path);
    av2.answer = const Av2TooSlow(fps: 7, needed: 24, key: 'k');
    await expectLater(resolve(path, VideoSourceType.file), throwsA(isA<Av2TooSlow>()));
    av2.answer = const Av2DecoderMissing();
    await expectLater(resolve(path, VideoSourceType.file), throwsA(isA<Av2DecoderMissing>()));
  });

  test('the thumbnail of an AV2 video comes through its companion, which stops after the grab', () async {
    final players = FakePlayers(
      onCreate: (engine) => engine
        ..autoLoad = const Duration(seconds: 4)
        ..frame = Uint8List.fromList([0xFF, 0xD8, 1]),
    );
    final share = MemoryShare(av2Fixture('av2-256x144-8bit.ivf'));
    bridge.register(share);
    final playbacks = _RecordingAv2();
    final grabber = VideoThumbnailGrabber(
      pool: players.pool,
      av2: () => Av2Playbacks(
        companion: () async => null,
        runner: (_) => throw UnimplementedError(),
        enabled: () => true,
        bridge: bridge.fileOf,
      ),
    );
    // Without the decoder: no frame, nothing downloaded
    expect(
      await grabber.grab('/v/clip.ivf', time: const Duration(seconds: 1), box: (width: 320, height: 320, cover: true)),
      isNull,
    );
    expect(players.made, isEmpty);

    final installed = VideoThumbnailGrabber(pool: players.pool, av2: () => playbacks);
    final frame = await installed.grab(
      bridge.urlFor(share.source.id, share.path).toString(),
      time: const Duration(seconds: 1),
      box: (width: 320, height: 320, cover: true),
    );
    expect(frame, isNotNull);
    // The recording playbacks answer through openResource, which reads the bridge it was given: none here, so the
    // share URL is opened as it is; the path of this computer goes through open
    await installed.grab('/v/clip.ivf', time: const Duration(seconds: 1), box: (width: 320, height: 320, cover: true));
    expect(playbacks.thumbnails, ['/v/clip.ivf']);
    expect(players.made.single.calls, contains('open $_served at 0 streamed'));
    expect(playbacks.released, [_served]);
    expect(playbacks.opened, isEmpty, reason: 'a thumbnail asks no measure of speed');
  });

  test('the speeds of the AV2 formats are kept beside the decoder measures, per format and decoder', () async {
    final folder = Directory.systemTemp.createTempSync('av2-speeds-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final store = DecoderMeasureStore(folder: () async => folder);
    const uhd10 = Av2Format(width: 4096, height: 2160, bits: 10, frameRate: 24);
    const hd8 = Av2Format(width: 1920, height: 1080, bits: 8, frameRate: 30);
    expect(await store.av2Speed(uhd10, '30140b5-1'), isNull);
    await store.recordAv2Speed(
      Av2SpeedMeasure(format: uhd10, fps: 7.4, decoder: '30140b5-1', at: DateTime(2026, 11, 2)),
    );
    await store.recordAv2Speed(const Av2SpeedMeasure(format: hd8, fps: 232, decoder: '30140b5-1'));
    await store.recordAv2Speed(const Av2SpeedMeasure(format: uhd10, fps: 8.6, decoder: '30140b5-1'));
    expect((await store.av2Speed(uhd10, '30140b5-1'))?.fps, 8.6, reason: 'the last one of the format');
    expect(
      (await store.av2Speed(const Av2Format(width: 4096, height: 2160, bits: 10, frameRate: 23.976), '30140b5-1'))?.fps,
      8.6,
      reason: 'a frame rate within half a frame is the same format',
    );
    expect(await store.av2Speed(uhd10, 'another-dav2d'), isNull, reason: 'another decoder says nothing');
    // The decoder measures of mpv are kept beside, and both come back from the file
    await store.record(
      const DecodeMeasure(
        gpu: 'unknown',
        codec: 'video/av01',
        width: 1920,
        height: 1080,
        frameRate: 30,
        hwdec: 'no',
        frames: 150,
        dropped: 0,
      ),
    );
    final again = DecoderMeasureStore(folder: () async => folder);
    expect((await again.av2Speed(hd8, '30140b5-1'))?.fps, 232);
    expect(await again.measures(), hasLength(1));
    // A newer decoder: the measures of the previous one go
    await again.recordAv2Speed(const Av2SpeedMeasure(format: hd8, fps: 250, decoder: 'newer'));
    expect(await again.av2Speed(uhd10, '30140b5-1'), isNull);
    expect((await again.av2Speed(hd8, 'newer'))?.fps, 250);
  });
}
