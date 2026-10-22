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
// Run in the Windows job of the desktop workflow, after the build:
//   flutter test integration_test/desktop_spatial_renderer_test.dart -d windows
//   IMMUCH360_SPATIAL_CLIP   another clip of the same pattern (default: the fixture, from the app's folder)

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
      await logSubscription.cancel();
      await player.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
