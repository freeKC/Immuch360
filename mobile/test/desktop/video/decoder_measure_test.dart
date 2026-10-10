// The measured correction (decoder_measure.dart): the store of the measures (file, classes, libmpv change, failures
// that expire), what the measures say about a question, and the sampler that measures a playback after it played
// steadily, on a fake player with mpv's properties given by the test.

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/decoder_measure.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immuch_desktop_video/immuch_desktop_video.dart';

import 'fake_playback_engine.dart';

const _mpv = 'mpv v0.39.0-179-g0f78584518';

DecodeMeasure _measure(
  String codec,
  int width,
  int height,
  String hwdec, {
  String gpu = 'gpu',
  int dropped = 0,
  int frames = 150,
  double frameRate = 30,
  String mpv = _mpv,
  DateTime? at,
}) => DecodeMeasure(
  gpu: gpu,
  codec: codec,
  width: width,
  height: height,
  frameRate: frameRate,
  hwdec: hwdec,
  frames: frames,
  dropped: dropped,
  mpvVersion: mpv,
  at: at ?? DateTime(2026, 10, 9),
);

void main() {
  late Directory folder;
  late DecoderMeasureStore store;
  final now = DateTime(2026, 10, 10);

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('decoder_measure_test');
    store = DecoderMeasureStore(folder: () async => folder);
  });

  tearDown(() => folder.delete(recursive: true));

  group('DecodeMeasure', () {
    test('keeps up when it drops one frame in twenty at most, never fewer than three', () {
      expect(_measure(VideoMime.hevc, 7680, 3840, 'd3d11va', dropped: 7).smooth, isTrue);
      expect(_measure(VideoMime.hevc, 7680, 3840, 'd3d11va', dropped: 8).smooth, isFalse);
      expect(_measure(VideoMime.hevc, 7680, 3840, 'd3d11va', dropped: 3, frames: 20).smooth, isTrue);
      expect(_measure(VideoMime.hevc, 7680, 3840, 'd3d11va', dropped: 4, frames: 20).smooth, isFalse);
    });

    test('the figures of the build: 8K HEVC copied back on an integrated GPU drops half its frames', () {
      final copied = decodeMeasuresOfTheBuild.firstWhere(
        (measure) => measure.gpu == MeasuredGpu.integrated && measure.copyBack,
      );
      expect(copied.smooth, isFalse);
      expect(copied.shownRate, closeTo(14.3, 0.1));
      final software = decodeMeasuresOfTheBuild.where((measure) => !measure.hardware);
      expect(software.map((measure) => (videoCodecLabel(measure.codec), measure.smooth)), [
        ('H.264', true),
        ('HEVC', false),
      ]);
    });

    test('goes to JSON and back without its source', () {
      final measure = _measure(VideoMime.avc, 5760, 2880, 'no', dropped: 2, at: DateTime.utc(2026, 10, 9, 21));
      expect(DecodeMeasure.fromJson(measure.toJson()), measure);
      expect(measure.describe(), 'H.264 5760x2880 at 30 fps through no, 2 of 150 frames dropped');
      expect(mimeOfMpvCodec('hevc'), VideoMime.hevc);
      expect(mimeOfMpvCodec('h264'), VideoMime.avc);
      expect(mimeOfMpvCodec('prores'), isNull);
    });
  });

  group('DecoderMeasureStore', () {
    test('keeps one measure per kind of video, in its file', () async {
      await store.record(_measure(VideoMime.hevc, 7680, 3840, 'd3d11va-copy', dropped: 80));
      await store.record(_measure(VideoMime.hevc, 7680, 3840, 'd3d11va-copy', frameRate: 29.97));
      await store.record(_measure(VideoMime.avc, 3840, 2160, 'd3d11va'));
      final again = DecoderMeasureStore(folder: () async => folder);
      final measures = await again.measures();
      expect(measures, hasLength(2));
      expect(measures.first.dropped, 0);
      expect(File('${folder.path}/${DecoderMeasureStore.fileName}').readAsStringSync(), isNot(contains('source')));
    });

    test('a new libmpv starts over', () async {
      await store.record(_measure(VideoMime.hevc, 7680, 3840, 'd3d11va-copy', dropped: 80));
      await store.record(_measure(VideoMime.avc, 3840, 2160, 'd3d11va', mpv: 'mpv v0.41.0'));
      expect((await store.measures()).map((measure) => measure.mpvVersion), ['mpv v0.41.0']);
    });

    test('a damaged file is no measure', () async {
      File('${folder.path}/${DecoderMeasureStore.fileName}').writeAsStringSync('{"measures": [');
      expect(await store.measures(), isEmpty);
      await store.record(_measure(VideoMime.avc, 3840, 2160, 'd3d11va'));
      expect(await DecoderMeasureStore(folder: () async => folder).measures(), hasLength(1));
    });

    test('keeps the latest measures only', () async {
      for (var i = 0; i < DecoderMeasureStore.maxMeasures + 5; i++) {
        await store.record(_measure(VideoMime.avc, 640 + 16 * i, 360, 'd3d11va'));
      }
      final measures = await store.measures();
      expect(measures, hasLength(DecoderMeasureStore.maxMeasures));
      expect(measures.first.width, 640 + 16 * 5);
    });

    test('a failure stops answering after two weeks, a success does not', () async {
      await store.record(_measure(VideoMime.hevc, 7680, 3840, 'd3d11va-copy', dropped: 80, at: DateTime(2026, 9, 20)));
      await store.record(_measure(VideoMime.avc, 3840, 2160, 'd3d11va', at: DateTime(2026, 9, 20)));
      expect(await store.ownOn('gpu', now: now), hasLength(1));
      expect(await store.ownOn('gpu', now: DateTime(2026, 9, 25)), hasLength(2));
      expect(await store.ownOn('other', now: now), isEmpty);
    });

    group('correction', () {
      Future<DecodeCorrection?> ask(
        String codec,
        int width,
        int height, {
        required bool hardware,
        bool? integrated = true,
        double frameRate = 30,
        int instances = 1,
        bool buildMeasures = true,
      }) => store.correction(
        gpu: 'gpu',
        integrated: integrated,
        codec: codec,
        width: width,
        height: height,
        frameRate: frameRate,
        hardware: hardware,
        instances: instances,
        buildMeasures: buildMeasures,
        now: now,
      );

      test('nothing measured, nothing said, except the software figures of the build', () async {
        expect(await ask(VideoMime.hevc, 7680, 3840, hardware: true), isNull);
        final export = await ask(VideoMime.avc, 5760, 2880, hardware: false);
        expect(export?.own, isFalse);
        expect(export?.measure.smooth, isTrue);
        expect(await ask(VideoMime.avc, 5760, 2880, hardware: false, buildMeasures: false), isNull);
        // 8K H.264 in software was not measured: no answer either way
        expect(await ask(VideoMime.avc, 7680, 3840, hardware: false), isNull);
        expect((await ask(VideoMime.hevc, 7680, 3840, hardware: false))?.measure.smooth, isFalse);
      });

      test('the same kind of video measured here answers whatever its path', () async {
        await store.record(_measure(VideoMime.hevc, 5760, 2880, 'no', dropped: 30));
        final verdict = await ask(VideoMime.hevc, 5760, 2880, hardware: true, frameRate: 29.97);
        expect(verdict?.own, isTrue);
        expect(verdict?.measure.smooth, isFalse);
        expect(verdict?.measure.hardware, isFalse);
      });

      test('a path measured here keeps up below a measure that kept up, and not above one that did not', () async {
        await store.record(_measure(VideoMime.hevc, 5760, 2880, 'd3d11va'));
        expect((await ask(VideoMime.hevc, 3840, 1920, hardware: true))?.measure.smooth, isTrue);
        // Above it, nothing of this computer: the build's zero copy figure at 8K
        final eightK = await ask(VideoMime.hevc, 7680, 3840, hardware: true);
        expect(eightK?.own, isFalse);
        expect(eightK?.measure.hwdec, 'd3d11va');
        await store.record(_measure(VideoMime.hevc, 7680, 4320, 'd3d11va', dropped: 50));
        expect((await ask(VideoMime.hevc, 8192, 4320, hardware: true))?.measure.smooth, isFalse);
        // Another codec is not compared
        expect(await ask(VideoMime.av1, 3840, 1920, hardware: true), isNull);
      });

      test('the latest hardware playback tells the path the build figures are taken for', () async {
        await store.record(_measure(VideoMime.avc, 1920, 1080, 'd3d11va-copy'));
        expect((await ask(VideoMime.hevc, 7680, 3840, hardware: true))?.measure.smooth, isFalse);
        expect((await ask(VideoMime.hevc, 7680, 3840, hardware: true, integrated: false))?.measure.smooth, isTrue);
        // A GPU of unknown kind: only the figures that hold for any
        expect(await ask(VideoMime.hevc, 7680, 3840, hardware: true, integrated: null), isNull);
        await store.record(_measure(VideoMime.avc, 1280, 720, 'd3d11va'));
        expect((await ask(VideoMime.hevc, 7680, 3840, hardware: true))?.measure.smooth, isTrue);
      });

      test('two streams are compared with two streams only', () async {
        await store.record(
          DecodeMeasure(
            gpu: 'gpu',
            codec: VideoMime.avc,
            width: 2880,
            height: 2880,
            frameRate: 29.97,
            hwdec: 'no',
            frames: 150,
            dropped: 0,
            instances: 2,
            mpvVersion: _mpv,
            at: DateTime(2026, 10, 9),
          ),
        );
        expect((await ask(VideoMime.avc, 2880, 2880, hardware: false, instances: 2))?.own, isTrue);
        expect((await ask(VideoMime.avc, 2880, 2880, hardware: false))?.own, isFalse);
      });
    });
  });

  group('PlaybackDecodeSampler', () {
    late FakePlaybackEngine engine;
    late Map<String, String> properties;
    late List<DecodeMeasure> recorded;
    final start = DateTime(2026, 10, 10, 1);

    setUp(() {
      engine = FakePlaybackEngine(PlayerKind.playback, 1);
      properties = {
        'frame-drop-count': '0',
        'decoder-frame-drop-count': '0',
        'speed': '1.000000',
        'lavfi-complex': '',
        'current-tracks/video/codec': 'hevc',
        'width': '7680',
        'height': '3840',
        'container-fps': '30.000000',
        'hwdec-current': 'd3d11va-copy',
        'mpv-version': _mpv,
      };
      recorded = [];
    });

    PlaybackDecodeSampler sampler(FakeAsync async, {bool Function()? shown}) => PlaybackDecodeSampler(
      engine,
      (name) async => properties[name] ?? '',
      record: (measure) async => recorded.add(measure),
      gpu: () async => 'gpu',
      appShown: shown ?? () => true,
      now: () => start.add(async.elapsed),
    );

    // libmpv's part: the position moves while the player plays
    Timer clock() => Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (engine.playing.value && !engine.buffering.value) {
        engine.position.value += const Duration(milliseconds: 100);
      }
    });

    test('measures once a file played steadily, with the frames dropped meanwhile', () {
      fakeAsync((async) {
        final watch = sampler(async);
        final ticking = clock();
        engine.load(const Duration(minutes: 1), size: (width: 7680, height: 3840));
        unawaited(engine.play());
        async.elapse(const Duration(seconds: 2));
        properties['frame-drop-count'] = '60';
        properties['decoder-frame-drop-count'] = '18';
        async.elapse(const Duration(seconds: 5));
        expect(recorded, hasLength(1));
        final measure = recorded.single;
        expect(measure.codec, VideoMime.hevc);
        expect((measure.width, measure.height, measure.frameRate), (7680, 3840, 30.0));
        expect(measure.hwdec, 'd3d11va-copy');
        expect((measure.frames, measure.dropped), (150, 78));
        expect(measure.smooth, isFalse);
        expect(measure.mpvVersion, _mpv);
        expect(measure.at, start.add(const Duration(seconds: 6)));
        // One measure per file: a seek plays on without a second one
        engine.emit(PlayerEventKind.restarted);
        async.elapse(const Duration(seconds: 10));
        expect(recorded, hasLength(1));
        // The next file is measured again
        engine.load(const Duration(minutes: 1));
        async.elapse(const Duration(seconds: 7));
        expect(recorded, hasLength(2));
        ticking.cancel();
        watch.dispose();
      });
    });

    test('a video that plays slower than the clock lost the frames it fell behind', () {
      fakeAsync((async) {
        final watch = sampler(async);
        // What a decoder that hands its frames late does without sound: 0.6 s of video a second, nothing dropped
        final slow = Timer.periodic(const Duration(milliseconds: 100), (_) {
          if (engine.playing.value) {
            engine.position.value += const Duration(milliseconds: 60);
          }
        });
        engine.load(const Duration(minutes: 1));
        unawaited(engine.play());
        async.elapse(const Duration(seconds: 7));
        final measure = recorded.single;
        expect((measure.frames, measure.dropped), (150, 57));
        expect(measure.smooth, isFalse);
        expect(measure.shownRate, closeTo(18.6, 0.1));
        slow.cancel();
        watch.dispose();
      });
    });

    test('a pause or a stall in the middle cancels the try, the next steady playback measures', () {
      fakeAsync((async) {
        final watch = sampler(async);
        final ticking = clock();
        engine.load(const Duration(minutes: 1));
        unawaited(engine.play());
        async.elapse(const Duration(seconds: 3));
        unawaited(engine.pause());
        async.elapse(const Duration(seconds: 5));
        expect(recorded, isEmpty);
        unawaited(engine.play());
        async.elapse(const Duration(seconds: 3));
        engine.buffering.value = true;
        async.elapse(const Duration(seconds: 4));
        expect(recorded, isEmpty);
        engine.buffering.value = false;
        async.elapse(const Duration(seconds: 7));
        expect(recorded, hasLength(1));
        ticking.cancel();
        watch.dispose();
      });
    });

    test('nothing measured from a jump of the position, another speed, a stack of two streams or a hidden window', () {
      fakeAsync((async) {
        var shown = true;
        final watch = sampler(async, shown: () => shown);
        final ticking = clock();
        void playFile() {
          engine.load(const Duration(minutes: 1));
          unawaited(engine.play());
        }

        playFile();
        async.elapse(const Duration(seconds: 2));
        engine.position.value += const Duration(seconds: 20);
        async.elapse(const Duration(seconds: 5));
        properties['speed'] = '2.000000';
        playFile();
        async.elapse(const Duration(seconds: 7));
        properties['speed'] = '1.000000';
        properties['lavfi-complex'] = '[vid1] [vid2] hstack [vo]';
        playFile();
        async.elapse(const Duration(seconds: 7));
        properties['lavfi-complex'] = '';
        shown = false;
        playFile();
        async.elapse(const Duration(seconds: 7));
        properties['current-tracks/video/codec'] = 'prores';
        shown = true;
        playFile();
        async.elapse(const Duration(seconds: 7));
        expect(recorded, isEmpty);
        properties['current-tracks/video/codec'] = 'h264';
        playFile();
        async.elapse(const Duration(seconds: 7));
        expect(recorded.single.codec, VideoMime.avc);
        ticking.cancel();
        watch.dispose();
      });
    });

    test('stops with the player', () {
      fakeAsync((async) {
        sampler(async);
        final ticking = clock();
        engine.load(const Duration(minutes: 1));
        unawaited(engine.play());
        async.elapse(const Duration(seconds: 3));
        unawaited(engine.dispose());
        async.elapse(const Duration(seconds: 7));
        expect(recorded, isEmpty);
        ticking.cancel();
      });
    });
  });
}
