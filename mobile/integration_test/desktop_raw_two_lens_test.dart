// The 360° player route on a raw file of two streams (plan 2.4, V-RAW2): the plan is made from the file as the viewer
// makes it (RawVideoResolver, the calibration of the file's trailer, the other file of a split pair found next to it),
// the route stacks both streams in one mpv core with lavfi-complex when the switch says this computer keeps up, else
// shows one lens with the phones' message; the stack is measured over 5 s of play, and the measure kept. The record
// says what played: the step, mpv's options and frame, the frames renderer C drew, five pixels of the view looking to
// the front and to the back (both lenses show only when both streams are decoded), the sound, and that the player
// went back to the pool with mpv's options as the pool gave them. It opens a window and plays a video, so it runs on
// the owner's PC, built as an app in profile mode and started with these variables (their values are never written
// to a record):
//   IMMUCH360_MEASURE_CLIPS   label=path of the raw file, the first entry only (for a split pair, its _00_ file: the
//                             _10_ file is found next to it)
//   IMMUCH360_MEASURE_OUT     folder of the JSON record (raw-<label>.json)
// Built and run like the measurement harness:
//   win_flutter.sh build windows --profile -t integration_test/desktop_raw_two_lens_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/video/decoder_measure.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/desktop/video/raw_two_stream_switch.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:immich_mobile/desktop/video/render/sphere_renderer.dart';
import 'package:immich_mobile/desktop/video/spherical_player_route.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dji_osv.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_calibration_store.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_plan.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/providers/raw/dual_fisheye.provider.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

/// Range reads of a file of this computer
RawFileReader _fileReader(File file) {
  final handle = file.openSync();
  return (
    size: handle.lengthSync(),
    read: (int offset, int length) async {
      handle.setPositionSync(offset);
      return Uint8List.fromList(handle.readSync(length));
    },
    close: () async => handle.closeSync(),
  );
}

/// The calibrations of the files themselves, nothing kept
class _FileCalibrations implements RawVideoCalibrations {
  final _store = DualFisheyeCalibrationStore(() async => null);

  @override
  Future<DualFisheyeCalibration> forInput(RawVideoInput input, {int? frameSquare}) async {
    final file = await input.open();
    try {
      return (await resolveDualFisheyeCalibration(
        read: file?.read,
        fileSize: file?.size,
        isPhoto: false,
        store: _store,
        frameSquare: frameSquare,
      )).calibration;
    } finally {
      await file?.close();
    }
  }

  @override
  Future<DualFisheyeCalibration> forDji(RawVideoInput input) async => nominalOsmo360();
}

RawVideoInput _input(File file) => RawVideoInput(
  name: file.uri.pathSegments.last,
  key: 'test:${file.path}',
  url: file.path,
  open: () async => _fileReader(file),
);

String _hex(int pixel) => '0x${pixel.toRadixString(16).padLeft(8, '0')}';

/// A pixel of the view that shows something (the black of a lens that is off is 0xff000000 or so)
bool _lit(int pixel) => ((pixel >> 16) & 0xff) + ((pixel >> 8) & 0xff) + (pixel & 0xff) > 24;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final env = Platform.environment;
  final clips = (env['IMMUCH360_MEASURE_CLIPS'] ?? '').split(RegExp(r'[;\n]')).where((e) => e.contains('=')).toList();
  final skip = clips.isEmpty || !Platform.isWindows;

  testWidgets(
    'raw file of two streams in the 360 route',
    (tester) async {
      final entry = clips.first;
      final label = entry.substring(0, entry.indexOf('=')).trim();
      final path = entry.substring(entry.indexOf('=') + 1).trim();
      final folder = File(path).parent.path;
      final outDir = env['IMMUCH360_MEASURE_OUT'] ?? Directory.systemTemp.path;
      final record = <String, Object?>{'clip': label};
      final watch = Stopwatch()..start();
      final progress = File('$outDir${Platform.pathSeparator}raw-$label.progress.txt');
      void note(String what) => progress.writeAsStringSync(
        '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} $what\n',
        mode: FileMode.append,
        flush: true,
      );

      setUpDesktopVideo();
      expect(desktopVideoAvailable, isTrue, reason: 'libmpv loaded');
      final state = Directory.systemTemp.createTempSync('immuch360-raw2');
      SphereRendererStore.folder = () async => state;

      // The plan, as the viewer makes it for a file of a folder
      final name = File(path).uri.pathSegments.last;
      final kind = rawMediaKindOfName(name, isVideo: true);
      final resolver = RawVideoResolver(
        calibrations: _FileCalibrations(),
        support: const RawVideoPlaybackSupport(twoStreams: true),
      );
      final plan = await resolver.resolve(
        kind: kind!,
        input: _input(File(path)),
        findSibling: (sibling) async {
          final file = File('$folder${Platform.pathSeparator}$sibling');
          return file.existsSync() ? _input(file) : null;
        },
      );
      record['plan'] = {
        'layout': plan.layout.name,
        'camera': plan.camera,
        'tracks': [for (final track in plan.tracks) '${track.codec} ${track.width}x${track.height} file ${track.file}'],
        'trackOrder': plan.trackOrder,
        'calibration': plan.calibration?.source.name,
      };
      note('plan ${plan.layout.name}');

      // The switch keeps its measures in the test's own folder: the measures of the build decide the first time
      final twoStreams = TwoStreamSwitch(
        store: TwoStreamMeasureStore(folder: () async => state),
        decoderMeasures: DecoderMeasureStore(folder: () async => state),
      );
      PlaybackEngine? engine;
      PluginRenderer? renderer;
      NativePlayer? mpv() => engine?.videoController?.player.platform as NativePlayer?;
      Future<String> read(String property) async {
        try {
          return await mpv()?.getProperty(property) ?? '';
        } catch (_) {
          return '';
        }
      }

      final dependencies = SphericalPlayerDependencies(
        resolve: (source) async => source.path,
        pluginFor: (player) {
          engine = player;
          final videoController = player.videoController;
          return videoController == null
              ? null
              : renderer = PluginRenderer.forController(
                  videoController,
                  maxOutputHeight: DesktopPlayerOptions.maxRenderHeight,
                );
        },
        twoStreams: () => twoStreams,
        appVersion: () async => 'v-raw2-harness',
      );

      await tester.pumpWidget(
        ProviderScope(
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
                                args: SphericalPlayerArgs(
                                  url: plan.url,
                                  title: 'raw clip',
                                  rawProjection: plan.toNativeJson(),
                                ),
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
      note('opened');

      DesktopSphericalPlayerPageState page() =>
          tester.state<DesktopSphericalPlayerPageState>(find.byType(DesktopSphericalPlayerPage));
      Future<void> wait(Duration duration) async {
        final end = DateTime.now().add(duration);
        while (DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
        }
      }

      Future<Map<String, Object?>> mpvState() async => {
        'lavfiComplex': (await read('lavfi-complex')).isNotEmpty,
        'externalFiles': (await read('external-files')).isNotEmpty,
        'hwdec': await read('hwdec'),
        'hwdecCurrent': await read('hwdec-current'),
        'vid': await read('vid'),
        'frame': '${await read('video-params/w')}x${await read('video-params/h')}',
        'audio': await read('current-tracks/audio/codec'),
        'frameDrops': await read('frame-drop-count'),
        'decoderDrops': await read('decoder-frame-drop-count'),
      };

      // Until renderer C draws, at most 20 s
      for (var i = 0; i < 200 && (renderer == null || !renderer!.attached); i++) {
        await wait(const Duration(milliseconds: 100));
      }
      record['attached'] = renderer?.attached ?? false;
      record['glRenderer'] = renderer?.glRenderer;
      record['stepAtStart'] = '${page().rawStep}';
      await wait(const Duration(seconds: 2));
      record['mpvAtStart'] = await mpvState();
      note('playing ${page().rawStep}');

      // The switch measures 5 s of steady play after 1 s; then the step stays or changes. Read through a store of its
      // own: the switch's is the one that writes.
      final measured = TwoStreamMeasureStore(folder: () async => state);
      for (var i = 0; i < 24; i++) {
        await wait(const Duration(milliseconds: 500));
        measured.forget();
        if ((await measured.measures()).isNotEmpty) {
          break;
        }
      }
      // The step a slow stack switches to opens in a moment
      await wait(const Duration(seconds: 1));
      record['measures'] = [
        for (final measure in await measured.measures()) {...measure.toJson()..remove('at'), 'smooth': measure.smooth},
      ];
      record['stepAfterMeasure'] = '${page().rawStep}';
      record['mpvAfterMeasure'] = await mpvState();
      record['notice'] = find.byKey(const Key('spherical_notice')).evaluate().isNotEmpty;
      note('measured ${page().rawStep}');

      // Then renderer C's probe reads the plugin's counts for 5 s from its first frame (it is their only reader); the
      // frames drawn are counted after it, over 3 s, when the clip lasts that long
      await wait(const Duration(seconds: 7));
      // Read now: a step that opened another file knows its duration once that file is loaded
      final duration = page().controller.videoInfo?.duration ?? 0;
      final left = duration - page().controller.onPlaybackPositionChanged.value;
      if (left > 3500) {
        final playStart = page().controller.onPlaybackPositionChanged.value;
        final clockStart = DateTime.now();
        await renderer?.stats();
        await wait(const Duration(seconds: 3));
        final drawn = await renderer?.stats();
        final seconds = DateTime.now().difference(clockStart).inMilliseconds / 1000;
        record['playing3s'] = {
          'framesDrawn': drawn?.frames,
          'fpsDrawn': drawn == null ? null : (drawn.frames / seconds * 10).round() / 10,
          'videoSecondsPlayed': (page().controller.onPlaybackPositionChanged.value - playStart) / 1000,
          'clockSeconds': seconds,
          'intermediate': '${drawn?.frameWidth}x${drawn?.frameHeight}',
          'output': '${drawn?.outputWidth}x${drawn?.outputHeight}',
          'frameMsP50': () {
            final times = [...?drawn?.frameMs]..sort();
            return times.isEmpty ? null : (times[times.length ~/ 2] * 100).round() / 100;
          }(),
        };
        record['mpvAfter3s'] = await mpvState();
      } else {
        record['playing3s'] = 'clip too short: $left ms left';
      }
      note('drawn');

      // Paused: five pixels of the view to the front, then to the back
      final plugin = renderer;
      if (plugin != null && plugin.attached) {
        await page().controller.pause();
        await wait(const Duration(milliseconds: 600));
        final views = <String, Object?>{};
        for (final yaw in [0.0, 180.0]) {
          // The request redraws the paused view as it is and reads its pixels: the view turns first. The renderer
          // probe has judged by now, so nothing else reads the plugin's counts and takes the pixels.
          plugin.setView(PluginView(yaw: yaw, pitch: 0, fov: 90));
          await wait(const Duration(milliseconds: 500));
          await plugin.stats(probe: true);
          await wait(const Duration(milliseconds: 500));
          final probed = (await plugin.stats())?.probe;
          views['yaw$yaw'] = {'pixels': probed?.map(_hex).toList(), 'lit': probed?.where(_lit).length};
        }
        record['views'] = views;
        note('probed');
      }

      // Closed with the close button, as the user does
      final engineUsed = engine;
      await tester.tap(find.byKey(const Key('spherical_close')), warnIfMissed: false);
      await wait(const Duration(seconds: 2));
      record['closedPage'] = find.byType(DesktopSphericalPlayerPage).evaluate().isEmpty;
      record['idlePlayers'] = desktopPlayerPool.idleCount(PlayerKind.playback);
      engine = engineUsed;
      record['mpvAfterClose'] = await mpvState();
      record['seconds'] = watch.elapsedMilliseconds / 1000;
      note('closed');

      // Never a path of the clips in the record
      var text = const JsonEncoder.withIndent('  ').convert(record);
      text = text.replaceAll(path, '<clip>').replaceAll(folder, '<folder>');
      File('$outDir${Platform.pathSeparator}raw-$label.json').writeAsStringSync(text);
      // ignore: avoid_print
      print('VRAW2 ${jsonEncode(jsonDecode(text))}');
      state.deleteSync(recursive: true);
      expect(record['attached'], isTrue);
      expect(record['closedPage'], isTrue);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
