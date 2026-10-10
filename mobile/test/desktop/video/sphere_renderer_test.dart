// Which renderer draws the 360° player of the computers, and when it goes a tier down (sphere_renderer.dart,
// renderer_probe.dart; DP1 of 2026-10-09): the first rendering per settings, what the probe kept applying only to the
// same kind of video, GPU and version of the app and never as flat, the chain of tiers down to the flat player, a
// forced tier that never moves, the settings file and Automatic picked again, the verdicts of the probe on the
// measures of the skeleton, a shortfall that is the decoder's, a renderer that draws nothing, and the memory watched
// over the first seconds and the drags only.

import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:immich_mobile/desktop/video/render/renderer_probe.dart';
import 'package:immich_mobile/desktop/video/render/sphere_renderer.dart';
import 'package:media_kit_video/media_kit_video.dart';

const _intel = 'ANGLE (Intel, Intel(R) UHD Graphics (0x0000A788) Direct3D11 vs_5_0 ps_5_0, D3D11)';
const _nvidia = 'ANGLE (NVIDIA, NVIDIA GeForce RTX 4060 Laptop GPU (0x000028E0) Direct3D11 vs_5_0 ps_5_0, D3D11)';

ProjectionStats _frames(int frames, {int failed = 0, double? drawMs, String? error}) => ProjectionStats(
  enabled: true,
  frames: frames,
  redraws: 0,
  failed: failed,
  frameMs: drawMs == null ? const [] : List.filled(frames, drawMs),
  redrawMs: const [],
  lockedMs: const [],
  frameWidth: 2880,
  frameHeight: 1440,
  error: error,
);

// The kinds of video of the measures quoted (V-360, 2026-10-10)
const _h264k57 = 'h264 5760x2880 30 fps software';
const _hevc4k = 'hevc 3840x1920 30 fps hardware';

void main() {
  group('the renderer chain', () {
    test('Automatic: the plugin, its tier decided once the GPU is known; flat where no plugin exists', () {
      const automatic = SphereRendererSettings();
      expect(firstRendering(automatic, pluginSupported: true), isNull);
      expect(firstRendering(automatic, pluginSupported: false), const SphereRendering.flat(FlatReason.unsupported));
      expect(
        firstRendering(const SphereRendererSettings(choice: SphereRendererChoice.flat), pluginSupported: true),
        const SphereRendering.flat(FlatReason.chosen),
      );
      expect(
        firstRendering(const SphereRendererSettings(choice: SphereRendererChoice.plugin4096), pluginSupported: true),
        const SphereRendering.plugin(PluginTier.w4096),
      );
    });

    test('the kind of video: codec, size, rate and decoding path', () {
      expect(sphereVideoClass(codec: 'h264', width: 5760, height: 2880, framesPerSecond: 29.97, hwdec: 'no'), _h264k57);
      expect(
        sphereVideoClass(codec: 'hevc', width: 3840, height: 1920, framesPerSecond: 30, hwdec: 'd3d11va'),
        _hevc4k,
      );
      expect(
        sphereVideoClass(codec: 'hevc', width: 7680, height: 3840, framesPerSecond: 30, hwdec: 'd3d11va-copy'),
        'hevc 7680x3840 30 fps copy',
      );
      expect(
        sphereVideoClass(codec: null, width: 1920, height: 960, framesPerSecond: null, hwdec: null),
        '? 1920x960 ? fps unknown',
      );
      expect(sphereVideoClass(codec: 'h264', width: 0, height: 0, framesPerSecond: 30, hwdec: 'no'), isNull);
    });

    test('what the probe kept applies to the same kind of video, GPU and version only', () {
      const kept = RememberedRendering(
        appVersion: '3.3.0+21',
        glRenderer: _nvidia,
        tier: PluginTier.w4096,
        videoClass: 'hevc 7680x3840 30 fps hardware',
      );
      const settings = SphereRendererSettings(measured: [kept]);
      PluginTier tier({
        String gpu = _nvidia,
        String version = '3.3.0+21',
        String videoClass = 'hevc 7680x3840 30 fps hardware',
      }) => tierForVideo(
        settings,
        startTier: PluginTier.full,
        glRenderer: gpu,
        appVersion: version,
        videoClass: videoClass,
      );

      expect(tier(), PluginTier.w4096);
      expect(
        tier(videoClass: _hevc4k),
        PluginTier.full,
        reason: 'a step down for one 8K video says nothing of a 4K one',
      );
      expect(tier(gpu: _intel), PluginTier.full, reason: 'another GPU: measured again');
      expect(tier(version: '3.3.0+22'), PluginTier.full);
      // A forced tier wins over what was kept
      expect(
        tierForVideo(
          const SphereRendererSettings(choice: SphereRendererChoice.plugin2880, measured: [kept]),
          startTier: PluginTier.full,
          glRenderer: _nvidia,
          appVersion: '3.3.0+21',
          videoClass: 'hevc 7680x3840 30 fps hardware',
        ),
        PluginTier.w2880,
      );
    });

    test('a video that played flat is never shown flat from memory: the next of its kind is measured again', () {
      // The review's case: one 8K HEVC video copied back on the Intel UHD at 11 fps of 30 played flat
      const flat = RememberedRendering(
        appVersion: '3.3.0+21',
        glRenderer: _intel,
        tier: null,
        videoClass: 'hevc 7680x3840 30 fps copy',
        reason: '11.0 of 30.0 fps',
      );
      const settings = SphereRendererSettings(measured: [flat]);
      expect(
        tierForVideo(
          settings,
          startTier: PluginTier.w2880,
          glRenderer: _intel,
          appVersion: '3.3.0+21',
          videoClass: 'hevc 7680x3840 30 fps copy',
        ),
        PluginTier.w2880,
        reason: 'the lowest tier, measured again',
      );
      expect(
        tierForVideo(
          settings,
          startTier: PluginTier.w2880,
          glRenderer: _intel,
          appVersion: '3.3.0+21',
          videoClass: _hevc4k,
        ),
        PluginTier.w2880,
        reason: 'and the 4K video the probe kept plays in 360° as before',
      );
    });

    test('one entry per kind; the measures of another version go; at most 32 kinds; Automatic forgets them', () {
      var settings = const SphereRendererSettings();
      RememberedRendering entry(String videoClass, PluginTier? tier, {String version = '3.3.0+21'}) =>
          RememberedRendering(appVersion: version, glRenderer: _intel, tier: tier, videoClass: videoClass);
      settings = settings.remembering(entry('old', PluginTier.w2880, version: '3.3.0+20'));
      settings = settings.remembering(entry(_h264k57, PluginTier.w2880));
      settings = settings.remembering(entry(_hevc4k, PluginTier.w2880));
      settings = settings.remembering(entry(_h264k57, null));
      expect(
        [for (final kept in settings.measured) (kept.videoClass, kept.tier)],
        [(_hevc4k, PluginTier.w2880), (_h264k57, null)],
      );
      expect(settings.remembered?.videoClass, _h264k57, reason: 'the newest, for the troubleshooting page');
      for (var i = 0; i < 40; i++) {
        settings = settings.remembering(entry('kind $i', PluginTier.w2880));
      }
      expect(settings.measured, hasLength(SphereRendererSettings.maxMeasured));
      expect(settings.measured.last.videoClass, 'kind 39');
      expect(
        settings.withChoice(SphereRendererChoice.plugin4096).measured,
        hasLength(SphereRendererSettings.maxMeasured),
      );
      expect(settings.withChoice(SphereRendererChoice.automatic).measured, isEmpty);
    });

    test('a tier down each time, then flat; a forced tier never moves', () {
      var rendering = const SphereRendering.plugin(PluginTier.full);
      final seen = <SphereRendering>[rendering];
      while (!rendering.isFlat) {
        rendering = stepDown(rendering, SphereRendererChoice.automatic);
        seen.add(rendering);
      }
      expect(seen, const [
        SphereRendering.plugin(PluginTier.full),
        SphereRendering.plugin(PluginTier.w4096),
        SphereRendering.plugin(PluginTier.w2880),
        SphereRendering.flat(FlatReason.tooSlow),
      ]);
      expect(
        stepDown(const SphereRendering.plugin(PluginTier.w4096), SphereRendererChoice.plugin4096),
        const SphereRendering.plugin(PluginTier.w4096),
      );
    });
  });

  group('the settings file', () {
    late Directory folder;

    setUp(() {
      folder = Directory.systemTemp.createTempSync('sphere_renderer_test');
      SphereRendererStore.forget();
      SphereRendererStore.folder = () async => folder;
    });

    tearDown(() {
      SphereRendererStore.forget();
      folder.deleteSync(recursive: true);
    });

    test('Automatic without a file; the choice and what the probe kept survive a restart', () async {
      expect((await SphereRendererStore.load()).choice, SphereRendererChoice.automatic);
      await SphereRendererStore.saveChoice(SphereRendererChoice.plugin2880);
      await SphereRendererStore.remember(
        const RememberedRendering(
          appVersion: '3.3.0+21',
          glRenderer: _intel,
          tier: PluginTier.w2880,
          videoClass: _h264k57,
          reason: '22.2 of 30.0 fps',
          framesPerSecond: 27.3,
          targetFramesPerSecond: 30,
        ),
      );
      SphereRendererStore.forget();
      final settings = await SphereRendererStore.load();
      expect(settings.choice, SphereRendererChoice.plugin2880);
      final kept = settings.remembered!;
      expect(
        (kept.appVersion, kept.glRenderer, kept.tier, kept.videoClass, kept.framesPerSecond),
        ('3.3.0+21', _intel, PluginTier.w2880, _h264k57, 27.3),
      );
    });

    test('Automatic picked again forgets what the probe kept, also after a restart', () async {
      await SphereRendererStore.remember(
        const RememberedRendering(appVersion: '3.3.0+21', glRenderer: _intel, tier: null, videoClass: _h264k57),
      );
      await SphereRendererStore.saveChoice(SphereRendererChoice.automatic);
      SphereRendererStore.forget();
      expect((await SphereRendererStore.load()).measured, isEmpty);
    });

    test('the single measure of the first test builds is left out: it held for every video', () async {
      File('${folder.path}/${SphereRendererStore.fileName}').writeAsStringSync(
        '{"choice":"automatic","remembered":{"appVersion":"3.3.0+21","glRenderer":"$_intel","tier":null}}',
      );
      final settings = await SphereRendererStore.load();
      expect(settings.measured, isEmpty);
      expect(
        tierForVideo(
          settings,
          startTier: PluginTier.w2880,
          glRenderer: _intel,
          appVersion: '3.3.0+21',
          videoClass: _hevc4k,
        ),
        PluginTier.w2880,
      );
    });

    test('a damaged file is Automatic', () async {
      File('${folder.path}/${SphereRendererStore.fileName}').writeAsStringSync('{not json');
      expect((await SphereRendererStore.load()).choice, SphereRendererChoice.automatic);
    });
  });

  group('the verdicts of the probe', () {
    ProbeSample sample(double fps, {double target = 30, int? memory}) =>
        ProbeSample(seconds: 5, frames: (fps * 5).round(), targetFramesPerSecond: target, memoryGrowthMB: memory);

    test('the skeleton measures: the RTX at 30 and the Intel at 27.3 of 30 keep their tier', () {
      expect(judgeProbe(sample(30), lowestTier: false), ProbeVerdict.keep);
      expect(judgeProbe(sample(27.4), lowestTier: true), ProbeVerdict.keep);
    });

    test('below 0.9 of the rate a tier down; at the lowest tier flat below 0.6 only', () {
      expect(judgeProbe(sample(22.2), lowestTier: false), ProbeVerdict.stepDown);
      expect(judgeProbe(sample(22.2), lowestTier: true), ProbeVerdict.keep);
      expect(judgeProbe(sample(15), lowestTier: true), ProbeVerdict.fail);
    });

    test('a 60 fps video is measured against 60, an unknown rate keeps the tier', () {
      expect(judgeProbe(sample(50, target: 60), lowestTier: false), ProbeVerdict.stepDown);
      expect(
        judgeProbe(const ProbeSample(seconds: 5, frames: 10), lowestTier: false),
        ProbeVerdict.keep,
        reason: 'no rate: nothing to compare with',
      );
    });

    test('kept at the lowest tier below the rate: the user hears that a dedicated GPU helps', () {
      // The Intel UHD at 2880 on a 5.7K H.264 video decoded in software (V-360, 2026-10-10): 20.6 of 30
      expect(judgeProbe(sample(20.6), lowestTier: true), ProbeVerdict.keep);
      expect(slowAtLowestTier(sample(20.6), lowestTier: true), isTrue);
      expect(slowAtLowestTier(sample(29.8), lowestTier: true), isFalse);
      expect(slowAtLowestTier(sample(20.6), lowestTier: false), isFalse, reason: 'a tier down first');
    });

    test('memory that grows by more than 512 MiB takes a tier down, whatever the frames', () {
      expect(judgeProbe(sample(30, memory: 600), lowestTier: false), ProbeVerdict.stepDown);
      expect(judgeProbe(sample(30, memory: 600), lowestTier: true), ProbeVerdict.fail);
      expect(judgeProbe(sample(30, memory: 400), lowestTier: false), ProbeVerdict.keep);
    });

    test('draws that all fail: renderer C is refused, whatever the tier', () {
      const nothing = ProbeSample(seconds: 3, frames: 0, failed: 90, error: 'intermediate FBO incomplete (36054)');
      expect(judgeProbe(nothing, lowestTier: false), ProbeVerdict.refused);
      expect(judgeProbe(nothing, lowestTier: true), ProbeVerdict.refused);
    });

    test(
      'a shortfall is the decoder\'s when the processor decodes, or when the plugin draws in a fraction of a frame',
      () {
        ProbeSample timed(double fps, double drawMs) =>
            ProbeSample(seconds: 5, frames: (fps * 5).round(), targetFramesPerSecond: 30, drawMs: drawMs);
        // The Intel UHD on a 5.7K H.264 video the processor decodes: 20.6 of 30, draws of 40 to 52 ms (V-360)
        expect(decodeLimited(timed(20.6, 46), hwdec: 'no'), isTrue);
        // 8K HEVC copied back at 11 fps while the plugin draws each frame in 8 ms: the frames come late
        expect(decodeLimited(timed(11, 8), hwdec: 'd3d11va-copy'), isTrue);
        // The Intel at 4096 on a 5.7K video it decodes: 15.5 fps with draws of 61 ms, the drawing is the limit (V-C)
        expect(decodeLimited(timed(15.5, 61), hwdec: 'd3d11va'), isFalse);
        expect(decodeLimited(timed(29.8, 5), hwdec: 'no'), isFalse, reason: 'no shortfall');
        expect(decodeLimited(timed(20, 8)), isTrue, reason: 'the decoder not known: the draw time tells');
        expect(decodeLimited(const ProbeSample(seconds: 5, frames: 50, targetFramesPerSecond: 30)), isFalse);
      },
    );
  });

  group('the probe on a player', () {
    test('measures from the interval after the first frame, leaves paused time out, judges after 5 s', () {
      fakeAsync((async) {
        var frames = 0;
        var playing = true;
        const memory = 1000;
        final results = <(ProbeVerdict, ProbeSample)>[];
        final probe = RendererProbe(
          stats: () async => _frames(frames),
          targetFramesPerSecond: () async => 29.97,
          memoryMB: () => memory,
          measuring: () => playing,
        );
        probe.start(lowestTier: false, onResult: (verdict, sample) => results.add((verdict, sample)));

        // Opening: nothing drawn yet
        async.elapse(const Duration(seconds: 2));
        // The first frame, then 22 a second (the Intel at 4096 on a 5.7K video)
        frames = 4;
        async.elapse(const Duration(seconds: 1));
        frames = 22;
        async.elapse(const Duration(seconds: 2));
        // Paused for 3 s: not measured
        playing = false;
        async.elapse(const Duration(seconds: 3));
        expect(results, isEmpty);
        playing = true;
        async.elapse(const Duration(seconds: 3));
        expect(results, hasLength(1));
        final (verdict, sample) = results.single;
        expect(verdict, ProbeVerdict.stepDown);
        expect(sample.seconds, 5);
        expect(sample.framesPerSecond, 22);
        expect(sample.targetFramesPerSecond, closeTo(29.97, 1e-9));
        expect(probe.running, isFalse, reason: 'the page starts it again at the next tier');
      });
    });

    test('the memory the open takes before the first frame (decoder surfaces, mpv textures) is no growth', () {
      fakeAsync((async) {
        var frames = 0;
        var memory = 150;
        final results = <ProbeVerdict>[];
        final probe = RendererProbe(
          stats: () async => _frames(frames),
          targetFramesPerSecond: () async => 30,
          memoryMB: () => memory,
          measuring: () => true,
        );
        probe.start(lowestTier: false, onResult: (verdict, _) => results.add(verdict));
        async.elapse(const Duration(seconds: 1));
        // An 8K video opens on the RTX 4060: the process goes from 150 MB to 950 MB before its first frame
        memory = 950;
        frames = 30;
        async.elapse(const Duration(seconds: 7));
        expect(results, [ProbeVerdict.keep]);
      });
    });

    test('the median draw time is in the verdict', () {
      fakeAsync((async) {
        final results = <ProbeSample>[];
        final probe = RendererProbe(
          stats: () async => _frames(20, drawMs: 9),
          targetFramesPerSecond: () async => 30,
          memoryMB: () => 1000,
          measuring: () => true,
        );
        probe.start(lowestTier: true, onResult: (_, sample) => results.add(sample));
        async.elapse(const Duration(seconds: 7));
        expect(results.single.drawMs, 9);
        expect(decodeLimited(results.single), isTrue);
      });
    });

    test('a kept tier is reported once, then only memory that grows while the view moves', () {
      fakeAsync((async) {
        var memory = 1000;
        var moving = false;
        final results = <ProbeVerdict>[];
        final probe = RendererProbe(
          stats: () async => _frames(30),
          targetFramesPerSecond: () async => 30,
          memoryMB: () => memory,
          measuring: () => true,
          moving: () => moving,
        );
        probe.start(lowestTier: false, onResult: (verdict, _) => results.add(verdict));
        async.elapse(const Duration(seconds: 7));
        expect(results, [ProbeVerdict.keep]);
        // The demuxer caches of a streamed pair fill over a minute, the rest of the app syncs: not the renderer's
        for (var i = 0; i < 60; i++) {
          memory += 15;
          async.elapse(const Duration(seconds: 1));
        }
        expect(results, [ProbeVerdict.keep]);
        // A drag that takes 600 MiB more in 3 s: what renderer A did per view change
        moving = true;
        async.elapse(const Duration(seconds: 1));
        memory += 300;
        async.elapse(const Duration(seconds: 1));
        expect(results, [ProbeVerdict.keep]);
        memory += 300;
        async.elapse(const Duration(seconds: 1));
        expect(results, [ProbeVerdict.keep, ProbeVerdict.stepDown]);
        expect(probe.running, isFalse);
      });
    });

    test('a drag measures from its own start', () {
      fakeAsync((async) {
        var memory = 1000;
        var moving = false;
        final results = <ProbeVerdict>[];
        final probe = RendererProbe(
          stats: () async => _frames(30),
          targetFramesPerSecond: () async => 30,
          memoryMB: () => memory,
          measuring: () => true,
          moving: () => moving,
        );
        probe.start(lowestTier: false, onResult: (verdict, _) => results.add(verdict));
        async.elapse(const Duration(seconds: 7));
        memory += 450;
        moving = true;
        async.elapse(const Duration(seconds: 1));
        memory += 100;
        async.elapse(const Duration(seconds: 2));
        moving = false;
        async.elapse(const Duration(seconds: 1));
        memory += 450;
        moving = true;
        async.elapse(const Duration(seconds: 2));
        expect(results, [ProbeVerdict.keep], reason: 'two drags of 100 MiB and none, 1000 MiB over the whole time');
      });
    });

    test(
      'draws that fail while the video plays and none that succeeds: refused after 3 s, with the plugin\'s error',
      () {
        fakeAsync((async) {
          var playing = false;
          final results = <(ProbeVerdict, ProbeSample)>[];
          final probe = RendererProbe(
            stats: () async => _frames(0, failed: 30, error: 'shader: ERROR: 0:12: syntax error'),
            targetFramesPerSecond: () async => 30,
            memoryMB: () => 1000,
            measuring: () => playing,
          );
          probe.start(lowestTier: false, onResult: (verdict, sample) => results.add((verdict, sample)));
          // While the video opens, a failed draw is a view asked before the first frame
          async.elapse(const Duration(seconds: 10));
          expect(results, isEmpty);
          playing = true;
          async.elapse(const Duration(seconds: 2));
          expect(results, isEmpty);
          async.elapse(const Duration(seconds: 1));
          final (verdict, sample) = results.single;
          expect(verdict, ProbeVerdict.refused);
          expect((sample.frames, sample.failed, sample.error), (0, 90, 'shader: ERROR: 0:12: syntax error'));
          expect(probe.running, isFalse);
        });
      },
    );
  });
}
