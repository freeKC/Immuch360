// The Spatial 2.5D passes of the video plugin (package:media_kit_video, IMMUCH360-NOTE.md patches 17 and 18) in a built
// app, with a real player and the plugin's own thread: renderer C on Windows (the hosted runner has no GPU: ANGLE draws
// with WARP), Metal on macOS (the runner's paravirtual device). The clip test/fixtures/video/spatial-sbs-dots-4s.mp4 is
// side by side, each eye 640 x 360: green dots at disparity 0 and a square of red dots 24 pixels nearer, its left edge
// at x 332 in the left eye and 308 in the right one (spatial-sbs-dots.py next to it). It plays through the passes at
// MEDIUM without the adaptive rule, then pauses. Checked through SpatialStats and its probe:
// - the passes draw the frames mpv gives at the output size, estimate the disparity at 480 x 270 every other frame;
// - once paused they settle (Windows by a timer of their own, macOS on the first redraw of the still frame), and each
//   new viewpoint is drawn again from the frame kept, without mpv;
// - along the middle row of the output the square starts at x 332 at p = 0 and at x 308 at p = 1; half way it moved
//   by 12 pixels: red inside, and background over the 12 pixels beyond its edges, which a failed matching (the two
//   eyes blended where they are) would make half red;
// - the disparity map shows the square brighter than the mid grey background;
// - the same frame as a VR180 eye shows the picture ahead and black behind.
// Ported from the October branch feat-windows-spatial (desktop_spatial_renderer_test.dart), whose second test drove
// that branch's own route: the page of release 53 (spatial_video_page.dart) is tested with a fake plugin channel and
// recorded tracks in test/desktop/spatial/spatial_video_page_test.dart.
// The macOS debug app runs in its sandbox, so there the clip is the same pattern written as a y4m in its temporary
// folder. Run in the Windows and macOS build jobs of the desktop workflow:
//   flutter test integration_test/desktop_spatial_video_test.dart -d windows   (or -d macos)
//   IMMUCH360_SPATIAL_CLIP   another clip of the same pattern (default: the fixture, from the app's folder)

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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
  final fixture = p.absolute(p.join('test', 'fixtures', 'video', 'spatial-sbs-dots-4s.mp4'));
  if (File(fixture).existsSync()) {
    return fixture;
  }
  // The debug app of macOS runs in its sandbox, which reads no file of the repository: the same pattern written as
  // a y4m in its own temporary folder (the libmpv of the app reads y4m, as the macOS build job checks)
  return _writeDotsY4m(p.join(Directory.systemTemp.path, 'spatial-sbs-dots-4s.y4m'));
}

/// The pattern of test/fixtures/video/spatial-sbs-dots.py (each eye 640 x 360, green dots of 4 x 4 pixels at
/// disparity 0, a 160 x 180 square of red dots 24 pixels nearer, its left edge at x 332 in the left eye and 308 in
/// the right one), 4 s at 15 frames a second of uncompressed 4:2:0, BT.601 limited range
String _writeDotsY4m(String path) {
  const width = 640;
  const height = 360;
  const disparity = 24;
  const squareX = 332;
  const squareWidth = 160;
  const squareY = 90;
  const squareHeight = 180;
  const frameWidth = 2 * width;
  // The dots of the script's generator are not reproduced: any random dots of the same sizes do
  final random = math.Random(20261022);
  final background = List.generate((height ~/ 4) * (width ~/ 4), (_) => random.nextBool());
  final square = List.generate((squareHeight ~/ 4) * (squareWidth ~/ 4), (_) => random.nextBool());
  (int, int, int) rgb(int x, int y) {
    final eye = x < width ? 0 : 1;
    final ex = x - eye * width;
    final left = squareX - eye * disparity;
    if (ex >= left && ex < left + squareWidth && y >= squareY && y < squareY + squareHeight) {
      final bit = square[((y - squareY) ~/ 4) * (squareWidth ~/ 4) + (ex - left) ~/ 4];
      return (bit ? 220 : 70, 20, 20);
    }
    return (20, background[(y ~/ 4) * (width ~/ 4) + ex ~/ 4] ? 200 : 50, 20);
  }

  final luma = Uint8List(frameWidth * height);
  final cb = Uint8List(frameWidth * height ~/ 4);
  final cr = Uint8List(frameWidth * height ~/ 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < frameWidth; x++) {
      final (r, g, b) = rgb(x, y);
      luma[y * frameWidth + x] = (16 + (65.481 * r + 128.553 * g + 24.966 * b) / 255).round().clamp(0, 255);
    }
  }
  for (var y = 0; y < height ~/ 2; y++) {
    for (var x = 0; x < frameWidth ~/ 2; x++) {
      var r = 0;
      var g = 0;
      var b = 0;
      for (final (dx, dy) in const [(0, 0), (1, 0), (0, 1), (1, 1)]) {
        final (pr, pg, pb) = rgb(2 * x + dx, 2 * y + dy);
        r += pr;
        g += pg;
        b += pb;
      }
      final (fr, fg, fb) = (r / 4, g / 4, b / 4);
      cb[y * (frameWidth ~/ 2) + x] = (128 + (-37.797 * fr - 74.203 * fg + 112.0 * fb) / 255).round().clamp(0, 255);
      cr[y * (frameWidth ~/ 2) + x] = (128 + (112.0 * fr - 93.786 * fg - 18.214 * fb) / 255).round().clamp(0, 255);
    }
  }
  final out = File(path).openSync(mode: FileMode.write);
  try {
    out.writeStringSync('YUV4MPEG2 W$frameWidth H$height F15:1 Ip A1:1 C420jpeg\n');
    for (var frame = 0; frame < 60; frame++) {
      out
        ..writeStringSync('FRAME\n')
        ..writeFromSync(luma)
        ..writeFromSync(cb)
        ..writeFromSync(cr);
    }
  } finally {
    out.closeSync();
  }
  return path;
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

  testWidgets('a stereo clip through the Spatial passes of the plugin', (tester) async {
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
      if (Platform.isWindows) {
        expect(result.clientVersion, 3, reason: 'renderer C wants OpenGL ES 3.0');
      } else {
        expect(result.glRenderer, startsWith('Metal'), reason: 'the passes in Metal on macOS');
      }

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
      if (Platform.isWindows) {
        expect(settled.settleRuns, greaterThanOrEqualTo(4), reason: 'four more estimations once the frames stop');
      }

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
        if (Platform.isMacOS && viewpoint == 0.0) {
          // macOS settles on the first redraw of the still frame: three more estimations on the same eyes
          expect(moved.settleRuns, greaterThanOrEqualTo(3), reason: 'settled on the paused frame');
        }
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

      // The same frame as a VR180 eye, through the view of a 360 video (ProjectionOutput.setView)
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
}
