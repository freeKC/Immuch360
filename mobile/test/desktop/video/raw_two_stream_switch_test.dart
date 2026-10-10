// The measured switch of raw files of two streams (raw_two_stream_switch.dart): which decoding path stacks them on an
// integrated and on a dedicated GPU from the measures of spike 5 until this computer measured its own, the pixel rate
// above which nothing is stacked, a path measured too slow left for the playback and for 14 days, the store of the
// measures, and the sampler of a stacked playback (frames dropped and fallen behind the clock).

import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/decoder_measure.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/raw_two_stream_switch.dart';
import 'package:immich_mobile/desktop/video/raw_two_streams.dart';
import 'package:immuch_desktop_video/immuch_desktop_video.dart';

import 'fake_playback_engine.dart';

const _copy = 'd3d11va-copy';

TwoStreamQuestion _x3Pair({bool? integrated, String gpu = 'gpu-a', double frameRate = 0}) =>
    (gpu: gpu, integrated: integrated, codec: VideoMime.avc, width: 2880, height: 2880, frameRate: frameRate);

TwoStreamQuestion _x4({bool? integrated, String gpu = 'gpu-a'}) =>
    (gpu: gpu, integrated: integrated, codec: VideoMime.hevc, width: 3840, height: 3840, frameRate: 29.97);

DecodeMeasure _measure({
  String gpu = 'gpu-a',
  String codec = VideoMime.avc,
  int size = 2880,
  String hwdec = 'no',
  int dropped = 0,
  DateTime? at,
}) => DecodeMeasure(
  gpu: gpu,
  codec: codec,
  width: size,
  height: size,
  frameRate: 29.97,
  hwdec: hwdec,
  frames: 150,
  dropped: dropped,
  instances: 2,
  at: at,
);

void main() {
  group('the choice of a decoding path', () {
    test('an X3 pair: software on an integrated GPU, the copy back on a dedicated one (spike 5)', () {
      final integrated = chooseTwoStreamPath(_x3Pair(integrated: true), own: const [], copyBack: _copy);
      expect(integrated.hwdec, 'no');
      expect(integrated.reason, contains('Intel UHD: 30 fps'));
      final dedicated = chooseTwoStreamPath(_x3Pair(integrated: false), own: const [], copyBack: _copy);
      expect(dedicated.hwdec, _copy);
      expect(dedicated.reason, contains('RTX 4060'));
    });

    test('a GPU not known starts with software decoding, which does not depend on it', () {
      expect(chooseTwoStreamPath(_x3Pair(), own: const [], copyBack: _copy).hwdec, 'no');
    });

    test('an X4 is above the pixel rate stacked smoothly so far: not stacked, on any GPU', () {
      for (final integrated in [true, false, null]) {
        final choice = chooseTwoStreamPath(
          _x4(integrated: integrated),
          own: const [],
          copyBack: _copy,
        );
        expect(choice.hwdec, isNull);
        expect(choice.reason, contains('Mpx/s'));
      }
    });

    test('unless this computer stacked as much smoothly itself', () {
      final own = [_measure(codec: VideoMime.hevc, size: 3840, hwdec: _copy)];
      final choice = chooseTwoStreamPath(_x4(integrated: false), own: own, copyBack: _copy);
      expect(choice.hwdec, _copy);
      expect(choice.reason, contains('measured on this computer'));
      // Another GPU of this computer measured it: not this one
      expect(
        chooseTwoStreamPath(
          _x4(integrated: false, gpu: 'gpu-b'),
          own: own,
          copyBack: _copy,
        ).hwdec,
        isNull,
      );
    });

    test('a path this computer measured too slow is left for the next one; the Intel\'s copy back is known slow', () {
      final dedicated = chooseTwoStreamPath(
        _x3Pair(integrated: false),
        own: [_measure(hwdec: _copy, dropped: 90)],
        copyBack: _copy,
      );
      expect(dedicated.hwdec, 'no', reason: 'software, not measured on a dedicated GPU yet: tried');
      final integrated = chooseTwoStreamPath(_x3Pair(integrated: true), own: [_measure(dropped: 60)], copyBack: _copy);
      expect(integrated.hwdec, isNull, reason: 'the copy back of an integrated GPU dropped 137 of 180 at this rate');
      expect(integrated.reason, contains('measured on this computer'));
      expect(integrated.reason, contains('7.1 fps'));
    });

    test('what this computer measured comes before the build: a smooth copy back on an integrated GPU is taken', () {
      final choice = chooseTwoStreamPath(
        _x3Pair(integrated: true, frameRate: 29.97),
        own: [
          _measure(dropped: 60),
          _measure(hwdec: _copy),
        ],
        copyBack: _copy,
      );
      expect(choice.hwdec, _copy);
    });

    test('the paths measured too slow during this playback are skipped', () {
      expect(
        chooseTwoStreamPath(_x3Pair(integrated: false), own: const [], failed: {_copy}, copyBack: _copy).hwdec,
        'no',
      );
      expect(
        chooseTwoStreamPath(_x3Pair(integrated: false), own: const [], failed: {_copy, 'no'}, copyBack: _copy).hwdec,
        isNull,
      );
    });

    test('streams of unknown size or codec are tried, as on the phones', () {
      const unknown = (gpu: 'g', integrated: false, codec: null, width: null, height: null, frameRate: 0.0);
      expect(chooseTwoStreamPath(unknown, own: const [], copyBack: _copy).hwdec, _copy);
      expect(chooseTwoStreamPath(unknown, own: const [], failed: {_copy}, copyBack: _copy).hwdec, 'no');
    });

    test('a GoPro MAX (two 4096 x 1344 HEVC tracks) is below the X3 pair: tried through the GPU\'s first path', () {
      const max = (gpu: 'g', integrated: false, codec: VideoMime.hevc, width: 4096, height: 1344, frameRate: 29.97);
      expect(chooseTwoStreamPath(max, own: const [], copyBack: _copy).hwdec, _copy);
    });
  });

  group('the store of the measures', () {
    late Directory folder;

    setUp(() => folder = Directory.systemTemp.createTempSync('raw_two_stream_switch_test'));
    tearDown(() => folder.deleteSync(recursive: true));

    test('one measure per kind of video and path, kept in the file', () async {
      final store = TwoStreamMeasureStore(folder: () async => folder);
      await store.record(_measure(hwdec: _copy, dropped: 90));
      await store.record(_measure());
      await store.record(_measure(dropped: 2));
      expect((await store.measures()).map((m) => (m.hwdec, m.dropped)), [(_copy, 90), ('no', 2)]);
      final again = TwoStreamMeasureStore(folder: () async => folder);
      expect((await again.measures()).map((m) => (m.hwdec, m.dropped)), [(_copy, 90), ('no', 2)]);
      final text = File('${folder.path}/${TwoStreamMeasureStore.fileName}').readAsStringSync();
      expect(jsonDecode(text), isA<Map<String, Object?>>());
    });

    test('a path too slow is tried again after 14 days; a smooth one stays', () async {
      final store = TwoStreamMeasureStore(folder: () async => folder);
      final then = DateTime(2026, 10, 1);
      await store.record(_measure(hwdec: _copy, dropped: 90, at: then));
      await store.record(_measure(at: then));
      expect(await store.measures(now: then.add(const Duration(days: 13))), hasLength(2));
      expect((await store.measures(now: then.add(const Duration(days: 15)))).map((m) => m.hwdec), ['no']);
    });

    test('a damaged file costs the measures, nothing else', () async {
      File('${folder.path}/${TwoStreamMeasureStore.fileName}').writeAsStringSync('{not json');
      expect(await TwoStreamMeasureStore(folder: () async => folder).measures(), isEmpty);
    });

    test('the switch keeps a measure in both stores and leaves a slow path for the playback', () async {
      final store = TwoStreamMeasureStore(folder: () async => folder);
      final decoders = DecoderMeasureStore(folder: () async => folder);
      final adapter = GpuAdapter.fromJson(const {
        'name': 'Intel(R) UHD Graphics',
        'vendorId': 0x8086,
        'integrated': true,
      });
      final twoStreams = TwoStreamSwitch(store: store, decoderMeasures: decoders, adapter: () async => adapter);
      final raw = RawStreams.fromJson(const {
        'layout': 'twoFiles',
        'tracks': [
          {'file': 0, 'videoTrack': 0, 'width': 2880, 'height': 2880, 'codec': 'avc1', 'codecs': 'avc1.640033'},
          {'file': 1, 'videoTrack': 0, 'width': 2880, 'height': 2880, 'codec': 'avc1', 'codecs': 'avc1.640033'},
        ],
      });
      final question = await twoStreams.question(raw);
      expect((question.gpu, question.integrated, question.codec), (adapter.key, true, VideoMime.avc));
      expect((await twoStreams.choose(raw)).hwdec, 'no');
      await twoStreams.record(_measure(gpu: adapter.key, dropped: 70));
      expect(twoStreams.failed, {'no'});
      expect(await twoStreams.startPath(), TwoStreamPaths.copyBack);
      expect(await store.measures(), hasLength(1));
      final decoderMeasures = await decoders.measures();
      expect(decoderMeasures.single.instances, 2, reason: 'the viewer\'s warning asks about two streams');
    });
  });

  group('the sampler of a stacked playback', () {
    test('5 s of steady play: the drops and the time fallen behind the clock count, once', () {
      fakeAsync((async) {
        final engine = FakePlaybackEngine(PlayerKind.playback, 1);
        var clock = DateTime(2026, 10, 10, 12);
        var drops = 0;
        final measures = <DecodeMeasure>[];
        final sampler = TwoStreamSampler(
          engine,
          (name) async => switch (name) {
            'frame-drop-count' => '$drops',
            'decoder-frame-drop-count' => '0',
            'container-fps' => '',
            'estimated-vf-fps' => '29.97',
            'mpv-version' => 'mpv test',
            _ => '',
          },
          gpu: 'gpu-a',
          codec: VideoMime.avc,
          width: 2880,
          height: 2880,
          hwdec: 'no',
          onMeasure: measures.add,
          now: () => clock,
        );
        engine.playing.value = true;
        async.elapse(const Duration(seconds: 1));
        // Over the window: 20 frames dropped, and 4.5 s of video played in 5 s (0.4 s behind beyond the slack)
        drops = 20;
        engine.position.value = const Duration(milliseconds: 4500);
        clock = clock.add(const Duration(seconds: 5));
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(measures, hasLength(1));
        final measure = measures.single;
        expect((measure.instances, measure.hwdec, measure.frameRate), (2, 'no', 29.97));
        expect(measure.frames, 150);
        expect(measure.dropped, 20 + 12);
        expect(measure.smooth, isFalse);
        expect(sampler.done, isTrue);
        // Never twice for one step
        async.elapse(const Duration(seconds: 20));
        expect(measures, hasLength(1));
        sampler.dispose();
      });
    });

    test('a pause in the middle cancels the try; the next steady play measures', () {
      fakeAsync((async) {
        final engine = FakePlaybackEngine(PlayerKind.playback, 1);
        var clock = DateTime(2026, 10, 10, 12);
        final measures = <DecodeMeasure>[];
        final sampler = TwoStreamSampler(
          engine,
          (name) async => name == 'container-fps' ? '30' : '0',
          gpu: 'gpu-a',
          codec: VideoMime.avc,
          width: 2880,
          height: 2880,
          hwdec: _copy,
          onMeasure: measures.add,
          now: () => clock,
        );
        engine.playing.value = true;
        async.elapse(const Duration(seconds: 2));
        engine.playing.value = false;
        async.elapse(const Duration(seconds: 6));
        expect(measures, isEmpty);
        engine.playing.value = true;
        async.elapse(const Duration(seconds: 1));
        engine.position.value = const Duration(seconds: 5);
        clock = clock.add(const Duration(seconds: 5));
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(measures.single.smooth, isTrue);
        expect(measures.single.hwdec, _copy);
        sampler.dispose();
      });
    });
  });
}
