// Which renderer draws the 360° player of the computers, and when it goes a tier down (sphere_renderer.dart,
// RendererProbe of media_kit_video/sphere.dart; DP1 of 2026-10-09): the first rendering per settings, what the probe
// kept applying only to the same kind of video, GPU and version of the app and never as flat, the chain of tiers down
// to the flat player, a forced tier that never moves, the settings file and Automatic picked again. The verdicts of the probe and the probe
// on a player are tested in media_kit_360 (packages/media_kit_video/test/sphere/renderer_probe_test.dart).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/render/sphere_renderer.dart';
import 'package:media_kit_video/sphere.dart';

const _intel = 'ANGLE (Intel, Intel(R) UHD Graphics (0x0000A788) Direct3D11 vs_5_0 ps_5_0, D3D11)';
const _nvidia = 'ANGLE (NVIDIA, NVIDIA GeForce RTX 4060 Laptop GPU (0x000028E0) Direct3D11 vs_5_0 ps_5_0, D3D11)';

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
}
