// The Spatial passes of renderer C (packages/media_kit_video, IMMUCH360-NOTE.md patch 11) in a built app, with a real
// player and the plugin's own thread, on a Windows with or without a GPU (the hosted runner of the desktop workflow
// has none: ANGLE draws with WARP). The clip test/fixtures/video/spatial-sbs-dots-4s.mp4 is side by side, each eye
// 640 x 360: green dots at disparity 0 and a square of red dots 24 pixels nearer, its left edge at x 332 in the left
// eye and 308 in the right one (spatial-sbs-dots.py next to it). It plays through the Spatial passes at MEDIUM
// without the adaptive rule, then pauses. Checked through SpatialStats and its probe:
// - the passes draw the frames mpv gives at the output size, estimate the disparity at 480 x 270 every other frame;
// - once paused they settle, and each new viewpoint is drawn again from the frame kept, without mpv;
// - along the middle row of the output the square starts at x 332 at p = 0 and at x 308 at p = 1; half way it moved
//   by 12 pixels: red inside, and background over the 12 pixels beyond its edges, which a failed matching (the two
//   eyes blended where they are) would make half red (the edges themselves blend both eyes, as on the phones);
// - the disparity map shows the square brighter than the mid grey background;
// - the same frame as a VR180 eye shows the picture ahead and black behind, through renderer C's view.
// Then the Spatial route of the app (lib/desktop/spatial/spatial_player_route.dart) on the same clip, its head followed
// through the head tracker's webcam path on the recorded painted head (test/fixtures/video/painted-head-12s.mp4, played
// at its own pace by the tracker's "file:" test camera, as the runner has no webcam): the viewpoint the route sends to
// the plugin must follow the head the right way (a face on the right of the picture sends it under 0.3, toward the
// left camera; on the left, over 0.7), toward the left camera within the clip's first second and toward the right one
// within its third, in the clip's own time (the face on the right at 1 s, on the left at 3 s); WARP being far too slow
// for the clip's 15 frames a second, the route's measure of the frames must take the passes a step down, mpv then
// drawing the frame smaller; and the webcam must be released, its capture thread ended, when the route goes.
// Run in the Windows job of the desktop workflow, after the build:
//   flutter test integration_test/desktop_spatial_renderer_test.dart -d windows
//   IMMUCH360_SPATIAL_CLIP   another clip of the same pattern (default: the fixture, from the app's folder)

import 'dart:io';
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immich_mobile/desktop/spatial/spatial_player_route.dart';
import 'package:immich_mobile/desktop/spatial/spatial_plugin_output.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart' show SpatialStereoLayout;
import 'package:immuch_head_tracker/immuch_head_tracker.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

String _clip() {
  final given = Platform.environment['IMMUCH360_SPATIAL_CLIP'];
  if (given != null && given.isNotEmpty) {
    return given;
  }
  return p.absolute(p.join('test', 'fixtures', 'video', 'spatial-sbs-dots-4s.mp4'));
}

/// The webcam of the route: the recorded head, played at its own pace through the tracker's capture thread
class _RecordedHead implements SpatialHeadSource {
  _RecordedHead(this._tracker, this._clip);

  final HeadTracker _tracker;
  final String _clip;

  @override
  Future<List<HeadCamera>> cameras() async => [HeadCamera(id: 'file:$_clip', name: 'Recorded head')];

  @override
  HeadTrackingSession start(HeadCamera camera, {bool colourOnly = false}) =>
      _tracker.start(camera, options: HeadTrackerOptions(colourOnly: colourOnly));
}

int _red(int pixel) => pixel & 0xff;
int _green(int pixel) => (pixel >> 8) & 0xff;
int _blue(int pixel) => (pixel >> 16) & 0xff;

/// The share of red in the red and green of the pixels [from] to [to] of a row: about 0.15 to 0.3 for the background
/// dots, 0.8 to 0.9 for the square's
double _redness(List<int> row, int from, int to) {
  var sum = 0.0;
  for (var x = from; x <= to; x++) {
    sum += _red(row[x]) / math.max(1, _red(row[x]) + _green(row[x]));
  }
  return sum / (to - from + 1);
}

double _meanGreen(List<int> row, int from, int to) {
  var sum = 0;
  for (var x = from; x <= to; x++) {
    sum += _green(row[x]);
  }
  return sum / (to - from + 1);
}

/// The first x of the row where three pixels in a row are red, -1 when none
int _squareEdge(List<int> row) {
  for (var x = 0; x + 2 < row.length; x++) {
    if (_redness(row, x, x + 2) > 0.6) {
      return x;
    }
  }
  return -1;
}

String _describe(SpatialStats stats) =>
    'spatial ${stats.spatial}, stereo ${stats.stereo}, ${stats.quality.name}, frames ${stats.draws.frames}, redraws '
    '${stats.draws.redraws}, failed ${stats.draws.failed}, spatial draws ${stats.spatialDraws}, disparity runs '
    '${stats.disparityRuns}, settle runs ${stats.settleRuns}, disparity ${stats.disparityWidth} x '
    '${stats.disparityHeight}, eyes ${stats.eyeWidth} x ${stats.eyeHeight}, output ${stats.drawnWidth} x '
    '${stats.drawnHeight}, frame ${stats.draws.frameWidth} x ${stats.draws.frameHeight}, ${stats.renderFps.toStringAsFixed(1)} '
    'draws/s, ${stats.disparityFps.toStringAsFixed(1)} estimations/s, ${stats.renderMs.toStringAsFixed(1)} ms '
    '(${stats.gpuTimer ? 'GPU timer' : 'CPU timing'}), ${stats.halfFloatMaps ? 'RGBA16F' : 'RGBA8'} maps, viewpoint '
    '${stats.viewpoint}, error ${stats.draws.error}';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Frames as in the app: the engine draws the video texture as it comes
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('a stereo clip through the Spatial passes of renderer C', (tester) async {
    final clip = _clip();
    expect(File(clip).existsSync(), isTrue, reason: 'the clip $clip');
    MediaKit.ensureInitialized();
    final player = Player(configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn));
    final native = player.platform! as NativePlayer;
    final logs = <String>[];
    final logSubscription = player.stream.log.listen((log) => logs.add('${log.prefix}: ${log.text}'));
    final controller = VideoController(player);
    try {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: ColoredBox(
            color: Colors.black,
            child: Center(
              child: SizedBox(
                width: 640,
                height: 360,
                child: Video(controller: controller, controls: NoVideoControls, wakelock: false),
              ),
            ),
          ),
        ),
      );
      await controller.platform.future;
      final handle = await player.handle;
      // The frame keeps the video's shape exactly, as renderer C's pages ask (plugin_renderer.dart)
      await native.setProperty('keepaspect', 'no');

      Future<SpatialStats> stats({bool probe = false}) async =>
          (await SpatialOutput.stats(handle, probe: probe)) ?? (throw StateError('no video output'));
      // The five pixels and the middle row of the next draw, which the probe asks for
      Future<SpatialStats> probe() async {
        await stats(probe: true);
        for (var i = 0; i < 40; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final probed = await stats();
          if (probed.probeRow != null) {
            return probed;
          }
        }
        throw StateError('the probe never came');
      }

      // The video output is made on a thread of its own: until it exists the answer is "no video output"
      Future<ProjectionResult> enable(SpatialSetup setup) async {
        var result = await SpatialOutput.enable(handle, setup);
        for (var attempt = 0; attempt < 50 && !result.ok && result.reason == 'no video output'; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          result = await SpatialOutput.enable(handle, setup);
        }
        // ignore: avoid_print
        print('SetSpatial: $result');
        return result;
      }

      final watch = Stopwatch()..start();
      final result = await enable(
        const SpatialSetup(adaptiveQuality: false, viewpoint: 0, outputWidth: 640, outputHeight: 360),
      );
      // ignore: avoid_print
      print('the passes compiled in ${watch.elapsedMilliseconds} ms');
      expect(result.ok, isTrue, reason: 'SetSpatial: ${result.reason}');
      expect(result.clientVersion, 3);

      await player.setPlaylistMode(PlaylistMode.loop);
      await player.open(Media(clip));
      await controller.waitUntilFirstFrameRendered.timeout(const Duration(seconds: 30));
      await stats();
      await Future<void>.delayed(const Duration(seconds: 4));
      final playing = await stats();
      // ignore: avoid_print
      print('playing: ${_describe(playing)}');
      expect(playing.spatial, isTrue);
      expect(playing.stereo, isTrue);
      expect(playing.draws.error, isNull);
      expect(
        playing.draws.frames,
        greaterThanOrEqualTo(8),
        reason: 'new frames of mpv drawn through the passes in 4 s',
      );
      expect(playing.disparityRuns, greaterThanOrEqualTo(4), reason: 'MEDIUM estimates every other new frame');
      expect(playing.quality, SpatialQuality.medium);
      expect((playing.disparityWidth, playing.disparityHeight), (480, 270));
      expect((playing.eyeWidth, playing.eyeHeight), (640, 360));
      expect(
        (playing.drawnWidth, playing.drawnHeight),
        (640, 360),
        reason: 'the shape of one eye in the 640 x 360 box',
      );
      expect((playing.draws.frameWidth, playing.draws.frameHeight), (1280, 360));

      await player.pause();
      await Future<void>.delayed(const Duration(seconds: 2));
      final settled = await stats();
      // ignore: avoid_print
      print('paused: ${_describe(settled)}');
      expect(settled.settleRuns, greaterThanOrEqualTo(4), reason: 'four more estimations once the frames stop');

      final rows = <double, List<int>>{};
      for (final viewpoint in [0.0, 1.0, 0.5]) {
        await stats();
        expect(await SpatialOutput.setViewpoint(handle, viewpoint), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 700));
        final moved = await stats();
        // ignore: avoid_print
        print('p $viewpoint: ${_describe(moved)}');
        expect(moved.draws.redraws, greaterThanOrEqualTo(1), reason: 'the paused frame drawn again at p $viewpoint');
        expect(moved.draws.frames, 0, reason: 'without a frame of mpv');
        expect(moved.viewpoint, closeTo(viewpoint, 1e-6));
        final row = (await probe()).probeRow!;
        expect(row, hasLength(640));
        rows[viewpoint] = row;
        // ignore: avoid_print
        print(
          'p $viewpoint: square from x ${_squareEdge(row)}, redness 310-318 ${_redness(row, 310, 318).toStringAsFixed(2)}, '
          '322-330 ${_redness(row, 322, 330).toStringAsFixed(2)}, 336-464 ${_redness(row, 336, 464).toStringAsFixed(2)}, '
          '470-478 ${_redness(row, 470, 478).toStringAsFixed(2)}, 482-490 ${_redness(row, 482, 490).toStringAsFixed(2)}',
        );
      }
      expect(_squareEdge(rows[0.0]!), inInclusiveRange(329, 335), reason: 'p = 0: the left eye, the square from x 332');
      expect(
        _squareEdge(rows[1.0]!),
        inInclusiveRange(305, 311),
        reason: 'p = 1: the right eye, the square from x 308',
      );
      final halfWay = rows[0.5]!;
      expect(_redness(halfWay, 336, 464), greaterThan(0.7), reason: 'half way: inside the square');
      expect(_redness(halfWay, 310, 318), lessThan(0.4), reason: 'half way: background before the square');
      expect(_redness(halfWay, 482, 490), lessThan(0.4), reason: 'half way: background after the square');

      // The disparity map instead of the view
      expect(await SpatialOutput.setDebug(handle, disparityMap: true), isTrue);
      final map = (await probe()).probeRow!;
      final square = _meanGreen(map, 350, 470);
      final background = _meanGreen(map, 20, 300);
      // ignore: avoid_print
      print('disparity map: square $square, background $background');
      expect(square, greaterThan(background + 40), reason: 'the square is nearer');
      expect(background, closeTo(128, 25), reason: 'disparity 0 is mid grey');
      expect(await SpatialOutput.setDebug(handle, disparityMap: false), isTrue);

      // The same frame as a VR180 eye, through renderer C's view
      final sphere = await enable(
        const SpatialSetup(
          projection: SpatialProjection.equirect,
          halfSphere: true,
          adaptiveQuality: false,
          viewpoint: 0.5,
          outputWidth: 640,
          outputHeight: 360,
        ),
      );
      expect(sphere.ok, isTrue, reason: 'SetSpatial VR180: ${sphere.reason}');
      Future<int> centre({required double yaw}) async {
        expect(await ProjectionOutput.setView(handle, yaw: yaw, pitch: 0, fov: 60, sharp: false), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return (await probe()).probeRow![320];
      }

      final ahead = await centre(yaw: 0);
      final behind = await centre(yaw: 180);
      // ignore: avoid_print
      print('VR180: ahead 0x${ahead.toRadixString(16)}, behind 0x${behind.toRadixString(16)}');
      expect(_red(ahead) + _green(ahead), greaterThan(60), reason: 'ahead shows the picture');
      expect(_red(behind) + _green(behind) + _blue(behind), lessThan(12), reason: 'behind a VR180 eye is black');

      final off = await SpatialOutput.disable(handle);
      expect(off.ok, isTrue, reason: off.reason);
      expect((await stats()).spatial, isFalse);
    } finally {
      for (final line in logs.take(40)) {
        // ignore: avoid_print
        print('mpv: $line');
      }
      // The tree goes while this test runs, so that its focus changes are done before the next test's binding state
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 100));
      await logSubscription.cancel();
      await player.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
  testWidgets('the Spatial route follows a recorded head through the webcam path', (tester) async {
    final clip = _clip();
    final head = p.absolute(p.join('test', 'fixtures', 'video', 'painted-head-12s.mp4'));
    expect(File(head).existsSync(), isTrue, reason: 'the recorded head $head');
    MediaKit.ensureInitialized();
    desktopVideoAvailable = true;
    await EasyLocalization.ensureInitialized();
    final tracker = HeadTracker.windows();
    expect(tracker, isNotNull, reason: 'the head tracker DLL next to the app');
    SpatialPluginOutput? output;
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
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: DesktopSpatialPlayerPage(
                args: SpatialPlayerArgs(url: clip, title: 'dots', layout: SpatialStereoLayout.sideBySide),
                dependencies: SpatialPlayerDependencies(
                  resolve: (source) async => source.path,
                  outputFor: (engine) {
                    final controller = engine.videoController;
                    return output = controller == null ? null : SpatialPluginOutput.forController(controller);
                  },
                  headSource: () => _RecordedHead(tracker!, head),
                  loadSettings: () async => const DesktopSpatialSettings(cameraAgreed: true),
                  saveSettings: (_) async {},
                  // A shorter measure than the app's 5 s, so that its steps come within the test
                  probeWindow: const Duration(milliseconds: 2500),
                  probeInterval: const Duration(milliseconds: 500),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // EasyLocalization loads the texts before it builds the page
    final route = find.byType(DesktopSpatialPlayerPage);
    for (var i = 0; i < 100 && route.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final page = tester.state<DesktopSpatialPlayerPageState>(route);
    // The 4 s clip loops, so that the frames are measured as long as the test watches
    await page.controller.setLoop(true);
    final watch = Stopwatch()..start();
    // The clip's own time of a sample: the tracker analyses one frame in two (the default of HtOptions) of the 15 fps
    // clip. A loaded runner plays it slower than real time, which the time of the test would count.
    double clipSeconds(HeadSample sample) => (sample.sequence - 1) * 2 / 15;
    // Each reading: the clip's time of the newest sample, where the face was in the picture, the viewpoint sent last
    final readings = <({double seconds, double faceX, double sent})>[];
    final requested = <double>[];
    var faces = 0;
    var lastSequence = -1;
    while (watch.elapsed < const Duration(seconds: 9)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final sample = page.tracking.latest;
      if (sample != null && sample.sequence != lastSequence) {
        lastSequence = sample.sequence;
        if (sample.hasFace) {
          faces++;
        }
      }
      final sent = output?.sentViewpoint;
      if (sample != null && sample.hasFace && sent != null) {
        readings.add((seconds: clipSeconds(sample), faceX: sample.faceX, sent: sent));
      }
      // The figures through a reader of their own: the route's measure keeps all of its draws
      final stats = await output?.stats(reader: #test);
      if (stats != null && stats.spatial) {
        requested.add(stats.requestedViewpoint);
      }
    }
    final low = readings.where((reading) => reading.sent < 0.3).firstOrNull;
    final high = readings.where((reading) => reading.sent > 0.7).firstOrNull;
    final lowest = requested.isEmpty ? double.nan : requested.reduce(math.min);
    final highest = requested.isEmpty ? double.nan : requested.reduce(math.max);
    // ignore: avoid_print
    print(
      'Spatial route: webcam ${page.tracking.camera}, problem ${page.tracking.problem}, $faces faces seen, '
      '${readings.length} readings, first under 0.3 at ${low?.seconds} s, first over 0.7 at ${high?.seconds} s, '
      'the plugin asked for ${lowest.toStringAsFixed(2)} to ${highest.toStringAsFixed(2)}, drawing ${page.drawing}, '
      '${page.stepDowns} step(s) down',
    );
    expect(page.tracking.problem, isNull, reason: 'the recorded head plays through the capture thread');
    expect(page.drawing, isTrue, reason: 'the passes draw the route');
    expect(faces, greaterThan(20), reason: 'the face found on the way');
    expect(low, isNotNull, reason: 'the face on the right of the picture: toward the left camera');
    expect(high, isNotNull, reason: 'then on the left: toward the right camera');
    expect(low!.seconds, inInclusiveRange(0.1, 1.5), reason: 'toward the left camera as the face goes right (1 s)');
    expect(high!.seconds, inInclusiveRange(1.9, 3.7), reason: 'toward the right camera as it goes left (3 s)');
    // The sign held end to end: every reading far to one side sent the viewpoint the matching way
    for (final reading in readings) {
      if (reading.faceX > 0.75) {
        expect(reading.sent, lessThan(0.5), reason: 'face at ${reading.faceX} after ${reading.seconds} s');
      } else if (reading.faceX < 0.25) {
        expect(reading.sent, greaterThan(0.5), reason: 'face at ${reading.faceX} after ${reading.seconds} s');
      }
    }
    expect(lowest, lessThan(0.3), reason: 'the plugin got the viewpoints');
    expect(highest, greaterThan(0.7));

    // WARP draws a frame in 100 to 200 ms, the clip has 15 a second: the measure steps the passes down, and the plugin
    // then draws mpv's frame smaller than the clip's 1280 x 360 (once the frames keep up, the measure keeps that step)
    final measure = Stopwatch()..start();
    var frameWidth = 0;
    while (measure.elapsed < const Duration(seconds: 20) && page.drawing) {
      final stats = await output?.stats(reader: #test);
      if (stats != null && stats.draws.frameWidth > 0) {
        frameWidth = stats.draws.frameWidth;
      }
      if (page.stepDowns >= 1 && frameWidth > 0 && frameWidth < 1280) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    // ignore: avoid_print
    print(
      'Spatial measure on WARP: ${page.stepDowns} step(s) down, frame share '
      '${page.output == null ? '-' : SpatialPluginOutput.flatFrameScales[page.output!.flatStep]}, frame $frameWidth '
      'wide, LOW held ${page.output?.forcedLow}, drawing ${page.drawing}; verdicts: ${page.measures.join('; ')}',
    );
    expect(page.stepDowns, greaterThanOrEqualTo(1), reason: 'the measure took the passes a step down');
    if (page.drawing) {
      expect(frameWidth, inExclusiveRange(0, 1280), reason: 'mpv draws the frame smaller');
    }

    final tracking = page.tracking;
    expect(tracking.cameraOpen, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
    // The native close in its background isolate: the capture thread ends and the webcam is let go
    await tracking.released.timeout(const Duration(seconds: 10));
    expect(tracking.cameraOpen, isFalse, reason: 'the webcam is released when the route goes');
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
