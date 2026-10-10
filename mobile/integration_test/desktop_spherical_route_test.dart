// The 360° player route of the computers on a real 360° clip (plan 2.4, V-360): renderer C draws the sphere, a drag
// turns the view through the plugin alone, a paused video is redrawn without mpv, the renderer probe keeps a tier,
// and closing reports to the session and gives the player back to the pool. It opens a window and plays a video, so
// it runs on the owner's PC, built as an app in profile mode and started with these variables (their values are
// never written to a record):
//   IMMUCH360_MEASURE_CLIPS   label=path of the clip, the first entry only (an equirectangular video of 40 s or more:
//                             the phases play it from its start without looping)
//   IMMUCH360_MEASURE_OUT     folder of the JSON record (route-<label>.json)
//   IMMUCH360_MEASURE_C_TIER  full, w4096 or w2880 to force the tier (default: Automatic, the probe decides)
// Built and run like the measurement harness:
//   win_flutter.sh build windows --profile -t integration_test/desktop_spherical_route_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/external_player_closed.provider.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:immich_mobile/desktop/video/render/sphere_renderer.dart';
import 'package:immich_mobile/desktop/video/spherical_player_route.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/player_events_hub.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart' show SphericalVideoEvents;
import 'package:integration_test/integration_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

class _Session implements SphericalVideoEvents {
  final closings = <String>[];

  @override
  void closed(StereoLayout stereoLayout, SphereCoverage coverage) =>
      closings.add('${stereoLayout.name}/${coverage.name}');
}

String _hex(int pixel) => '0x${pixel.toRadixString(16).padLeft(8, '0')}';

Map<String, Object?> _summary(ProjectionStats? stats) {
  if (stats == null) {
    return {'stats': null};
  }
  double p50(List<double> values) {
    if (values.isEmpty) {
      return 0;
    }
    final sorted = [...values]..sort();
    return (sorted[sorted.length ~/ 2] * 100).round() / 100;
  }

  return {
    'frames': stats.frames,
    'redraws': stats.redraws,
    'failed': stats.failed,
    'frameMsP50': p50(stats.frameMs),
    'redrawMsP50': p50(stats.redrawMs),
    'frame': [stats.frameWidth, stats.frameHeight],
    'output': [stats.outputWidth, stats.outputHeight],
    'error': ?stats.error,
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // The engine draws the video texture as it comes, as in the app
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final env = Platform.environment;
  final clips = (env['IMMUCH360_MEASURE_CLIPS'] ?? '').split(RegExp(r'[;\n]')).where((e) => e.contains('=')).toList();
  // Needs a clip, on Windows (renderer C exists there only)
  final skip = clips.isEmpty || !Platform.isWindows;

  testWidgets(
    '360 route on a clip',
    (tester) async {
      final entry = clips.first;
      final label = entry.substring(0, entry.indexOf('=')).trim();
      final path = entry.substring(entry.indexOf('=') + 1).trim();
      final outDir = env['IMMUCH360_MEASURE_OUT'] ?? Directory.systemTemp.path;
      final forced = PluginTier.values.where((tier) => tier.name == env['IMMUCH360_MEASURE_C_TIER']).firstOrNull;
      final record = <String, Object?>{'clip': label, 'forcedTier': forced?.name};
      final watch = Stopwatch()..start();
      // Each step also goes to a progress file at once, so that a run that hangs says where
      final progress = File('$outDir${Platform.pathSeparator}route-$label.progress.txt');
      void note(String what) => progress.writeAsStringSync(
        '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} $what\n',
        mode: FileMode.append,
        flush: true,
      );
      void step(String what) {
        record['t_$what'] = (watch.elapsedMilliseconds / 1000).toStringAsFixed(1);
        note(what);
      }

      setUpDesktopVideo();
      expect(desktopVideoAvailable, isTrue, reason: 'libmpv loaded');
      final settingsFolder = Directory.systemTemp.createTempSync('immuch360-v360-route');
      SphereRendererStore.folder = () async => settingsFolder;
      if (forced != null) {
        await SphereRendererStore.saveChoice(switch (forced) {
          PluginTier.full => SphereRendererChoice.pluginFull,
          PluginTier.w4096 => SphereRendererChoice.plugin4096,
          PluginTier.w2880 => SphereRendererChoice.plugin2880,
        });
      }
      final session = _Session();
      PlayerEventsHub.setUpSpherical(session);
      final container = ProviderContainer();
      PluginRenderer? renderer;
      final dependencies = SphericalPlayerDependencies(
        // A path of this computer, as the folder library hands it
        resolve: (source) async => source.path,
        pluginFor: (engine) {
          final videoController = engine.videoController;
          if (videoController == null) {
            return null;
          }
          return renderer = PluginRenderer.forController(
            videoController,
            maxOutputHeight: DesktopPlayerOptions.maxRenderHeight,
          );
        },
        appVersion: () async => 'v360-route-harness',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: EasyLocalization(
            supportedLocales: locales.values.toList(),
            path: translationsPath,
            startLocale: locales.values.first,
            fallbackLocale: locales.values.first,
            saveLocale: false,
            useFallbackTranslations: true,
            assetLoader: const CodegenLoader(),
            child: Builder(
              builder: (context) => MaterialApp(
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                home: Builder(
                  builder: (context) => Scaffold(
                    body: Center(
                      child: TextButton(
                        onPressed: () => unawaited(
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => DesktopSphericalPlayerPage(
                                args: SphericalPlayerArgs(url: path, title: '360 clip'),
                                dependencies: dependencies,
                              ),
                            ),
                          ),
                        ),
                        child: const Text('open'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pump();
      step('opened');

      DesktopSphericalPlayerPageState page() =>
          tester.state<DesktopSphericalPlayerPageState>(find.byType(DesktopSphericalPlayerPage));
      Future<void> wait(Duration duration) async {
        final end = DateTime.now().add(duration);
        var lastNote = DateTime.now();
        while (DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
          if (DateTime.now().difference(lastNote) > const Duration(seconds: 1)) {
            lastNote = DateTime.now();
            final shown = find.byType(DesktopSphericalPlayerPage).evaluate().isNotEmpty;
            final controller = shown ? page().controller : null;
            note(
              '  at ${controller?.onPlaybackPositionChanged.value} ms, ${controller?.onPlaybackStatusChanged.value.name}',
            );
          }
        }
      }

      // Until renderer C draws, at most 20 s
      for (var i = 0; i < 200 && (renderer == null || !renderer!.attached); i++) {
        await wait(const Duration(milliseconds: 100));
      }
      record['attached'] = renderer?.attached ?? false;
      record['rendering'] = page().rendering?.toString();
      record['glRenderer'] = renderer?.glRenderer;
      step('attached');
      // The probe measures its first 5 s of playback, then keeps the tier (or goes down): what it kept, after 9 s
      await wait(const Duration(seconds: 9));
      final kept = (await SphereRendererStore.load()).remembered;
      record['probe'] = kept?.toJson()?..remove('appVersion');
      record['renderingAfterProbe'] = page().rendering?.toString();
      record['playingAtProbe'] = page().controller.onPlaybackStatusChanged.value.name;
      step('probed');

      final plugin = renderer;
      if (plugin != null && plugin.attached) {
        note('rest');
        // Playing, the view at rest for 3 s
        await plugin.stats();
        await wait(const Duration(seconds: 3));
        record['playingRest3s'] = _summary(await plugin.stats());

        // Playing, a drag of 3 s to the left and back: the plugin draws each frame of mpv and the views between
        final center = tester.getCenter(find.byType(DesktopSphericalPlayerPage));
        note('drag playing');
        final yaw0 = page().view.yaw;
        await tester.timedDragFrom(center, const Offset(-600, 0), const Duration(milliseconds: 1500));
        record['yawAfterPlayingDrag'] = [yaw0, page().view.yaw];
        await tester.timedDragFrom(center, const Offset(600, 0), const Duration(milliseconds: 1500));
        record['playingDrag3s'] = _summary(await plugin.stats());

        // Playing, the view turned by the renderer itself at 60 a second for 3 s, as the V-C harness did: tells the cost
        // of the gesture path (pointer events, the page) from the plugin's
        await plugin.stats();
        note('setView playing');
        final turnWatch = Stopwatch()..start();
        var turns = 0;
        while (turnWatch.elapsedMilliseconds < 3000) {
          turns++;
          plugin.setView(PluginView(yaw: turns * 2.0, pitch: 10, fov: 90));
          await Future<void>.delayed(const Duration(milliseconds: 16));
          await tester.pump();
        }
        record['playingSetView3s'] = {..._summary(await plugin.stats()), 'views': turns};

        // Paused: five pixels of the view, a drag, five pixels again; nothing of mpv draws meanwhile
        note('pause');
        await page().controller.pause();
        await wait(const Duration(seconds: 1));
        await plugin.stats(probe: true);
        await wait(const Duration(milliseconds: 500));
        note('paused probe');
        final before = await plugin.stats();
        final yawBefore = page().view.yaw;
        await tester.timedDragFrom(center, const Offset(-800, 0), const Duration(milliseconds: 1000));
        await wait(const Duration(milliseconds: 600));
        final yawAfter = page().view.yaw;
        final pausedDrag = await plugin.stats(probe: true);
        await wait(const Duration(milliseconds: 500));
        final after = await plugin.stats();
        record['pausedDrag'] = {
          ..._summary(pausedDrag),
          'yaw': [yawBefore, yawAfter],
          'pixelsBefore': before?.probe?.map(_hex).toList(),
          'pixelsAfter': after?.probe?.map(_hex).toList(),
          'pixelsChanged':
              before?.probe != null && after?.probe != null && before!.probe!.join() != after!.probe!.join(),
        };
        await page().controller.play();
        step('dragged');
      }

      // Close as the user does: the close button
      note('close');
      final closeButton = find.byKey(const Key('spherical_close'));
      record['closeButton'] = closeButton.evaluate().length;
      await tester.tap(closeButton, warnIfMissed: false);
      await wait(const Duration(seconds: 2));
      record['closedPage'] = find.byType(DesktopSphericalPlayerPage).evaluate().isEmpty;
      record['sessionClosings'] = session.closings;
      record['externalPlayerClosed'] = container.read(externalPlayerClosedProvider);
      record['idlePlayers'] = desktopPlayerPool.idleCount(PlayerKind.playback);
      record['activePlayers'] = desktopPlayerPool.activeCount(PlayerKind.playback);
      step('closed');

      // Never the path of the clip in the record
      final text = const JsonEncoder.withIndent('  ').convert(record).replaceAll(path, '<clip>');
      File('$outDir${Platform.pathSeparator}route-$label.json').writeAsStringSync(text);
      // ignore: avoid_print
      print('V360 ${jsonEncode(record).replaceAll(path, '<clip>')}');
      PlayerEventsHub.setUpSpherical(null);
      expect(record['attached'], isTrue);
      expect(record['closedPage'], isTrue);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
