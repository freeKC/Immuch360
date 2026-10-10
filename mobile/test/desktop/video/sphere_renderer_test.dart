// Which renderer draws the 360° player of the computers, and when it goes a tier down (sphere_renderer.dart,
// renderer_probe.dart; DP1 of 2026-10-09): the first rendering per settings, what the probe kept applying only to the
// same GPU and version of the app, the chain of tiers down to the flat player, a forced tier that never moves, the
// settings file, and the verdicts of the probe on the measures of the skeleton.

import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:immich_mobile/desktop/video/render/renderer_probe.dart';
import 'package:immich_mobile/desktop/video/render/sphere_renderer.dart';
import 'package:media_kit_video/media_kit_video.dart';

const _intel = 'ANGLE (Intel, Intel(R) UHD Graphics (0x0000A788) Direct3D11 vs_5_0 ps_5_0, D3D11)';
const _nvidia = 'ANGLE (NVIDIA, NVIDIA GeForce RTX 4060 Laptop GPU (0x000028E0) Direct3D11 vs_5_0 ps_5_0, D3D11)';

ProjectionStats _frames(int frames) => ProjectionStats(
  enabled: true,
  frames: frames,
  redraws: 0,
  failed: 0,
  frameMs: const [],
  redrawMs: const [],
  lockedMs: const [],
  frameWidth: 2880,
  frameHeight: 1440,
);

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

    test('what the probe kept applies to the same GPU and the same version only', () {
      const kept = RememberedRendering(appVersion: '3.3.0+21', glRenderer: _intel, tier: PluginTier.w2880);
      const settings = SphereRendererSettings(remembered: kept);
      SphereRendering after({required String gpu, String version = '3.3.0+21', PluginTier start = PluginTier.full}) =>
          tierAfterAttach(settings, startTier: start, glRenderer: gpu, appVersion: version);

      expect(after(gpu: _intel), const SphereRendering.plugin(PluginTier.w2880));
      expect(after(gpu: _nvidia), const SphereRendering.plugin(PluginTier.full), reason: 'another GPU: measured again');
      expect(after(gpu: _intel, version: '3.3.0+22'), const SphereRendering.plugin(PluginTier.full));
      // Nothing kept up last time: flat at once, without measuring again on this GPU and version
      const flat = SphereRendererSettings(
        remembered: RememberedRendering(appVersion: '3.3.0+21', glRenderer: _intel, tier: null),
      );
      expect(
        tierAfterAttach(flat, startTier: PluginTier.w2880, glRenderer: _intel, appVersion: '3.3.0+21'),
        const SphereRendering.flat(FlatReason.tooSlow),
      );
      // A forced tier wins over what was kept
      expect(
        tierAfterAttach(
          const SphereRendererSettings(choice: SphereRendererChoice.pluginFull, remembered: kept),
          startTier: PluginTier.w2880,
          glRenderer: _intel,
          appVersion: '3.3.0+21',
        ),
        const SphereRendering.plugin(PluginTier.full),
      );
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
        (kept.appVersion, kept.glRenderer, kept.tier, kept.framesPerSecond),
        ('3.3.0+21', _intel, PluginTier.w2880, 27.3),
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

    test('a kept tier is reported once, then only memory growth', () {
      fakeAsync((async) {
        var memory = 1000;
        final results = <ProbeVerdict>[];
        final probe = RendererProbe(
          stats: () async => _frames(30),
          targetFramesPerSecond: () async => 30,
          memoryMB: () => memory,
          measuring: () => true,
        );
        probe.start(lowestTier: false, onResult: (verdict, _) => results.add(verdict));
        async.elapse(const Duration(seconds: 7));
        expect(results, [ProbeVerdict.keep]);
        async.elapse(const Duration(seconds: 30));
        expect(results, [ProbeVerdict.keep]);
        memory += 600;
        async.elapse(const Duration(seconds: 1));
        expect(results, [ProbeVerdict.keep, ProbeVerdict.stepDown]);
        expect(probe.running, isFalse);
      });
    });
  });
}
