// The Dart side of the Spatial passes of renderer C (packages/media_kit_video/lib/src/spatial_output.dart,
// IMMUCH360-NOTE.md patch 11), without the plugin: the arguments each call puts on the channel, in the order of the
// phones' EyeLayout, and the statistics read back, with renderer C's draws.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.alexmercerind/media_kit_video');
  final calls = <MethodCall>[];
  Object? answer;

  setUp(() {
    calls.clear();
    answer = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('enable sends the setup, the layouts numbered as the phones\' EyeLayout', () async {
    answer = {'ok': true, 'clientVersion': 3, 'glRenderer': 'ANGLE (WARP)', 'outputWidth': 640, 'outputHeight': 360};
    final result = await SpatialOutput.enable(
      42,
      const SpatialSetup(
        layout: SpatialLayout.topBottomSwapped,
        projection: SpatialProjection.equirect,
        halfSphere: true,
        quality: SpatialQuality.high,
        adaptiveQuality: false,
        viewpoint: 1.4,
        outputWidth: 1280,
        outputHeight: 720,
      ),
    );
    expect(result.ok, isTrue);
    expect(result.outputWidth, 640);
    expect(calls.single.method, 'VideoOutputManager.SetSpatial');
    expect(calls.single.arguments, {
      'handle': 42,
      'enabled': true,
      'layout': 3,
      'projection': 1,
      'halfSphere': true,
      'quality': 2,
      'adaptive': false,
      'viewpoint': 1.0,
      'maxFrameWidth': 3840,
      'maxFramePixels': 3840 * 2160,
      'outputWidth': 1280,
      'outputHeight': 720,
      'maxOutputHeight': 1440,
    });
    expect(SpatialLayout.values.map((layout) => layout.name), [
      'sideBySide',
      'topBottom',
      'sideBySideSwapped',
      'topBottomSwapped',
      'none',
    ]);
  });

  test('a setup without a viewpoint keeps the one set last', () {
    final arguments = const SpatialSetup(outputWidth: 2, outputHeight: 2).toArguments(1);
    expect(arguments.containsKey('viewpoint'), isFalse);
    expect(arguments['layout'], 0);
    expect(arguments['quality'], 1);
    expect(arguments['adaptive'], isTrue);
  });

  test('a refusal carries its reason', () async {
    answer = {'ok': false, 'reason': 'shader disparity: error', 'clientVersion': 3};
    final result = await SpatialOutput.enable(7, const SpatialSetup(outputWidth: 640, outputHeight: 360));
    expect(result.ok, isFalse);
    expect(result.reason, 'shader disparity: error');
  });

  test('disable, the viewpoint and the disparity map', () async {
    answer = {'ok': true};
    expect((await SpatialOutput.disable(5)).ok, isTrue);
    answer = true;
    expect(await SpatialOutput.setViewpoint(5, -0.2), isTrue);
    expect(await SpatialOutput.setDebug(5, disparityMap: true), isTrue);
    answer = null;
    expect(await SpatialOutput.setViewpoint(5, 0.25), isFalse, reason: 'no video output');
    expect(
      [for (final call in calls) '${call.method} ${call.arguments}'],
      [
        'VideoOutputManager.SetSpatial {handle: 5, enabled: false}',
        'VideoOutputManager.SetViewpoint {handle: 5, viewpoint: 0.0}',
        'VideoOutputManager.SetSpatialDebug {handle: 5, disparityMap: true}',
        'VideoOutputManager.SetViewpoint {handle: 5, viewpoint: 0.25}',
      ],
    );
  });

  test('the statistics, with renderer C\'s draws and the probe row', () async {
    answer = {
      'enabled': true,
      'frames': 12,
      'redraws': 3,
      'failed': 0,
      'frameMs': [4.5, 5.0],
      'redrawMs': [1.0],
      'lockedMs': [0.01],
      'frameWidth': 1280,
      'frameHeight': 360,
      'outputWidth': 640,
      'outputHeight': 360,
      'error': '',
      'glRenderer': 'ANGLE (Microsoft Basic Render Driver)',
      'probe': [0xff14c814, 0xff14c814, 0xff14c814, 0xff14c814, 0xff14c814],
      'spatial': true,
      'stereo': true,
      'quality': 0,
      'renderFps': 29.5,
      'disparityFps': 7.25,
      'renderMs': 11,
      'disparityWidth': 320,
      'disparityHeight': 180,
      'eyeWidth': 640,
      'eyeHeight': 360,
      'viewpoint': 0.5,
      'requestedViewpoint': 0.75,
      'gpuTimer': true,
      'halfFloatMaps': true,
      'spatialDraws': 15,
      'disparityRuns': 4,
      'settleRuns': 2,
      'qualityChanges': 1,
      'drawnWidth': 640,
      'drawnHeight': 360,
      'showDisparity': false,
      'probeRow': [1, 2, 3],
    };
    final stats = (await SpatialOutput.stats(9, probe: true))!;
    expect(calls.single.method, 'VideoOutputManager.SpatialStats');
    expect(calls.single.arguments, {'handle': 9, 'probe': true});
    expect(stats.spatial, isTrue);
    expect(stats.stereo, isTrue);
    expect(stats.quality, SpatialQuality.low);
    expect(stats.renderFps, 29.5);
    expect(stats.renderMs, 11.0);
    expect((stats.disparityWidth, stats.disparityHeight), (320, 180));
    expect((stats.eyeWidth, stats.eyeHeight), (640, 360));
    expect((stats.viewpoint, stats.requestedViewpoint), (0.5, 0.75));
    expect((stats.gpuTimer, stats.halfFloatMaps), (true, true));
    expect((stats.spatialDraws, stats.disparityRuns, stats.settleRuns, stats.qualityChanges), (15, 4, 2, 1));
    expect((stats.drawnWidth, stats.drawnHeight), (640, 360));
    expect(stats.probeRow, [1, 2, 3]);
    expect(stats.draws.frames, 12);
    expect(stats.draws.redraws, 3);
    expect(stats.draws.error, isNull);
    expect(stats.draws.probe, hasLength(5));

    answer = null;
    expect(await SpatialOutput.stats(9), isNull, reason: 'no video output');
  });
}
