// The Spatial 2.5D player of the computers as a route (lib/desktop/spatial/spatial_player_route.dart), on a pooled fake
// player, the Spatial passes over a fake plugin and a fake webcam: the passes are on before the file opens; the head
// moves the viewpoint sent to the plugin, read once per frame; the webcam closes with the page and when the window is
// minimised, and opens again when it comes back; camera access turned off shows the privacy message whose button opens
// the Windows settings, and the webcam is tried again once the user comes back from them, never in a loop; the arrow
// keys and the slider take the viewpoint over until R recenters; "Follow the mouse" closes the webcam and follows the
// pointer; reduced motion opens on the slider; the layout menu changes the passes; closing tells the opener where the
// video was and what was shown; refused passes play the video as it is with a message.

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/spatial/spatial_player_route.dart';
import 'package:immich_mobile/desktop/spatial/spatial_plugin_output.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/desktop/video/external_player_closed.provider.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';
import 'package:media_kit_video/media_kit_video.dart' as mkv;

import '../video/fake_playback_engine.dart';
import 'head_tracking_test.dart' show FakeHeadSource, sample;

const _gpu = 'ANGLE (Intel, Intel(R) UHD Graphics (0x0000A788) Direct3D11 vs_5_0 ps_5_0, D3D11)';

/// The plugin's side of the Spatial passes, recorded
class FakeSpatialChannel implements SpatialChannel {
  FakeSpatialChannel(this.players, {this.refuse});

  final FakePlayers players;
  final String? refuse;
  final setups = <mkv.SpatialSetup>[];
  final viewpoints = <double>[];
  final views = <(PluginView, bool)>[];
  final debug = <bool>[];
  final calls = <String>[];
  List<String>? playerCallsAtEnable;
  mkv.SpatialStats? stats_;

  @override
  Future<mkv.ProjectionResult> enable(int handle, mkv.SpatialSetup setup) async {
    calls.add('enable');
    setups.add(setup);
    playerCallsAtEnable ??= [...players.made.first.calls];
    if (refuse != null) {
      return mkv.ProjectionResult(ok: false, reason: refuse, clientVersion: 2, glRenderer: _gpu);
    }
    return mkv.ProjectionResult(
      ok: true,
      clientVersion: 3,
      glRenderer: _gpu,
      outputWidth: setup.outputWidth,
      outputHeight: setup.outputHeight,
    );
  }

  @override
  Future<mkv.ProjectionResult> disable(int handle) async {
    calls.add('disable with ${players.made.first.calls.where((call) => call == 'stop').length} stops');
    return const mkv.ProjectionResult(ok: true);
  }

  @override
  Future<bool> setViewpoint(int handle, double viewpoint) async {
    viewpoints.add(viewpoint);
    return true;
  }

  @override
  Future<bool> setView(int handle, PluginView view, {required bool sharp}) async {
    views.add((view, sharp));
    return true;
  }

  @override
  Future<bool> setDebug(int handle, {required bool disparityMap}) async {
    debug.add(disparityMap);
    return true;
  }

  @override
  Future<mkv.SpatialStats?> stats(int handle, {bool probe = false}) async => stats_;
}

typedef _Closing = ({int positionMs, bool wasPlaying, SpatialStereoLayout layout, SpatialProjection projection});

void main() {
  late FakePlayers players;
  late FakeSpatialChannel channel;
  late FakeHeadSource webcams;
  late ProviderContainer container;
  late List<String> mpv;
  late List<_Closing> closings;
  late List<Uri> opened;
  late List<DesktopSpatialSettings> saved;

  setUp(() {
    container = ProviderContainer();
    mpv = [];
    closings = [];
    opened = [];
    saved = [];
  });

  tearDown(() => container.dispose());

  /// A page with a button that opens the player, as DesktopSpatialVideoApi pushes it
  Future<void> pumpLauncher(
    WidgetTester tester,
    SpatialPlayerArgs args, {
    DesktopSpatialSettings settings = const DesktopSpatialSettings(),
    List<HeadCamera>? cameras,
    Exception? listError,
    String? refuse,
    bool reducedMotion = false,
  }) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    players = FakePlayers(onCreate: (engine) => engine.autoLoad = const Duration(seconds: 60));
    channel = FakeSpatialChannel(players, refuse: refuse);
    webcams = FakeHeadSource();
    if (cameras != null) {
      webcams.list = cameras;
    }
    webcams.listError = listError;
    final deps = SpatialPlayerDependencies(
      pool: players.pool,
      resolve: (source) async => source.path,
      outputFor: (engine) => SpatialPluginOutput(
        handle: () async => 42,
        setMpvProperty: (name, value) async => mpv.add('$name=$value'),
        channel: channel,
      ),
      headSource: () => webcams,
      loadSettings: () async => settings,
      saveSettings: (value) async => saved.add(value),
      openUri: (uri) async {
        opened.add(uri);
        return true;
      },
      statsInterval: const Duration(milliseconds: 200),
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
              // The system's reduced motion, as Windows gives it
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
                child: child!,
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => unawaited(
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => DesktopSpatialPlayerPage(
                            args: args,
                            dependencies: deps,
                            onClosed: (positionMs, wasPlaying, layout, projection) => closings.add((
                              positionMs: positionMs,
                              wasPlaying: wasPlaying,
                              layout: layout,
                              projection: projection,
                            )),
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
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  DesktopSpatialPlayerPageState page(WidgetTester tester) =>
      tester.state<DesktopSpatialPlayerPageState>(find.byType(DesktopSpatialPlayerPage));

  Future<void> showControls(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(800, 30));
    await mouse.moveTo(const Offset(810, 35));
    await tester.pump();
    await mouse.removePointer();
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await showControls(tester);
    await tester.tap(find.byKey(const Key('spatial_close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
  }

  /// Samples of a face at [faceX] in the webcam's picture, one every 1/15 s, from sequence [from]
  Future<int> faces(WidgetTester tester, double faceX, {required int from, int count = 30}) async {
    for (var i = from; i < from + count; i++) {
      webcams.last.push(sample(i, faceX: faceX));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    return from + count;
  }

  const sbs = SpatialPlayerArgs(url: '/videos/stereo.mp4', title: 'stereo.mp4', layout: SpatialStereoLayout.sideBySide);

  testWidgets('the passes are on before the file opens, and the video plays from where the viewer was', (tester) async {
    await pumpLauncher(
      tester,
      const SpatialPlayerArgs(
        url: '/videos/stereo.mp4',
        title: 'stereo.mp4',
        layout: SpatialStereoLayout.topBottom,
        start: Duration(seconds: 3),
      ),
    );
    final engine = players.made.single;
    expect(channel.playerCallsAtEnable, isNot(contains(startsWith('open'))));
    expect(engine.calls, contains('open /videos/stereo.mp4 at 3000'));
    expect(engine.calls.last, 'play');
    expect(mpv, ['keepaspect=no']);
    final setup = channel.setups.first;
    expect(setup.layout, mkv.SpatialLayout.topBottom);
    expect(setup.projection, mkv.SpatialProjection.flat);
    expect((setup.outputWidth, setup.outputHeight), (1600, 900), reason: 'the window, in physical pixels');
    expect((setup.maxFrameWidth, setup.maxFramePixels), (3840, 3840 * 2160), reason: 'two eyes of 1920 x 1080');
    expect(page(tester).drawing, isTrue);
    expect(find.text('stereo.mp4'), findsOneWidget);
    await close(tester);
  });

  testWidgets('the head moves the viewpoint of the plugin, once per frame', (tester) async {
    await pumpLauncher(tester, sbs);
    expect(webcams.sessions, hasLength(1), reason: 'head tracking is the default');
    expect(page(tester).tracking.cameraOpen, isTrue);
    expect(find.byKey(const Key('spatial_camera_on')), findsOneWidget, reason: 'the webcam on says so');
    var next = await faces(tester, 0.5, from: 1);
    expect(page(tester).viewpoint, closeTo(0.5, 0.01));
    final sentBefore = channel.viewpoints.length;
    // A head moving to the user's right shows on the left of the picture: toward the right camera
    next = await faces(tester, 0.42, from: next);
    expect(channel.viewpoints.last, closeTo(0.5 + 0.08 * 3, 0.02));
    expect(channel.viewpoints.length - sentBefore, lessThanOrEqualTo(34), reason: 'at most one per frame');
    // To the left
    await faces(tester, 0.6, from: next);
    expect(channel.viewpoints.last, closeTo(0.5 - 0.1 * 3, 0.02));
    await close(tester);
  });

  testWidgets('the webcam closes with the page, and the opener hears what was shown', (tester) async {
    await pumpLauncher(tester, sbs);
    final webcam = webcams.last;
    players.made.single.position.value = const Duration(seconds: 7);
    await tester.pump(const Duration(milliseconds: 300));
    await close(tester);
    expect(webcam.session.isClosed, isTrue, reason: 'the light goes off');
    expect(closings, hasLength(1));
    expect(closings.single.positionMs, 7000);
    expect(closings.single.wasPlaying, isTrue);
    expect(closings.single.layout, SpatialStereoLayout.sideBySide);
    expect(closings.single.projection, SpatialProjection.flat);
    expect(channel.calls.last, 'disable with 0 stops', reason: 'the passes go off before the player is stopped');
    expect(container.read(externalPlayerClosedProvider), 1, reason: 'the viewer behind takes its video back');
  });

  testWidgets('a minimised window closes the webcam, which opens again when it comes back', (tester) async {
    await pumpLauncher(tester, sbs);
    final first = webcams.last;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(first.session.isClosed, isTrue);
    expect(page(tester).tracking.cameraOpen, isFalse);
    expect(find.byKey(const Key('spatial_camera_on')), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(webcams.sessions, hasLength(2));
    expect(page(tester).tracking.cameraOpen, isTrue);
    // A focus change alone opens nothing more
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(webcams.sessions, hasLength(2));
    await close(tester);
  });

  testWidgets('camera access turned off shows the privacy message, tried again once back from the settings', (
    tester,
  ) async {
    await pumpLauncher(tester, sbs);
    webcams.last.fail(HeadTrackerStatus.accessDenied);
    await tester.pump();
    await tester.pump();
    expect(
      find.text(
        'Camera access is turned off for desktop apps in the privacy settings of Windows: the slider moves the '
        'viewpoint.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('spatial_viewpoint')), findsOneWidget, reason: 'the slider takes over');
    // Focus changes do not try the webcam again
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(webcams.sessions, hasLength(1));
    await tester.tap(find.byKey(const Key('spatial_message_problem_cameraOff_action')));
    await tester.pump();
    expect(opened, [Uri.parse('ms-settings:privacy-webcam')]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(webcams.sessions, hasLength(2), reason: 'once, on the way back from the settings');
    expect(page(tester).tracking.cameraOpen, isTrue);
    expect(find.text('Open camera settings'), findsNothing);
    await close(tester);
  });

  testWidgets('without a webcam, says so and offers the slider', (tester) async {
    await pumpLauncher(tester, sbs, cameras: const []);
    expect(find.text('No webcam found: the slider, the arrow keys or the mouse move the viewpoint.'), findsOneWidget);
    expect(find.byKey(const Key('spatial_viewpoint')), findsOneWidget);
    expect(webcams.sessions, isEmpty);
    await close(tester);
  });

  testWidgets('without the Media Feature Pack, says so and offers the slider', (tester) async {
    await pumpLauncher(tester, sbs, listError: const HeadTrackerException(HeadTrackerError.noMediaFoundation));
    expect(
      find.text('Head tracking needs the Media Feature Pack of Windows: the slider moves the viewpoint.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('spatial_viewpoint')), findsOneWidget);
    expect(webcams.sessions, isEmpty);
    await close(tester);
  });

  testWidgets('the arrow keys and the slider take the viewpoint over until R recenters', (tester) async {
    await pumpLauncher(tester, sbs);
    var next = await faces(tester, 0.5, from: 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 16));
    expect(channel.viewpoints.last, closeTo(0.6, 1e-9));
    expect(find.byKey(const Key('spatial_viewpoint')), findsOneWidget, reason: 'the slider shows what is held');
    // The head no longer moves it
    next = await faces(tester, 0.4, from: next);
    expect(channel.viewpoints.last, closeTo(0.6, 1e-9));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    // R: the next face is the centre again
    await faces(tester, 0.4, from: next);
    expect(channel.viewpoints.last, closeTo(0.5, 0.01));
    await close(tester);
  });

  testWidgets('"Follow the mouse" closes the webcam and follows the pointer', (tester) async {
    await pumpLauncher(tester, sbs);
    final webcam = webcams.last;
    await showControls(tester);
    await tester.tap(find.byKey(const Key('spatial_source')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('spatial_source_mouse')));
    await tester.pumpAndSettle();
    expect(webcam.session.isClosed, isTrue);
    expect(page(tester).source, SpatialViewpointSource.mouse);
    expect(saved.last.source, SpatialViewpointSource.mouse);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 450));
    await mouse.moveTo(const Offset(1200, 450));
    await tester.pump(const Duration(milliseconds: 16));
    expect(channel.viewpoints.last, closeTo(mouseViewpoint(0.75), 1e-9));
    await mouse.moveTo(const Offset(0, 450));
    await tester.pump(const Duration(milliseconds: 16));
    expect(channel.viewpoints.last, closeTo(HeadViewpoint.minViewpoint, 1e-9));
    await mouse.removePointer();
    await close(tester);
    expect(webcams.sessions, hasLength(1), reason: 'never opened again');
  });

  testWidgets('with reduced motion the page opens on the slider, the webcam closed', (tester) async {
    // A computer: reduced motion is the desktop's rule (desktopReducedMotion)
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpLauncher(tester, sbs, reducedMotion: true);
      expect(webcams.sessions, isEmpty);
      expect(page(tester).source, SpatialViewpointSource.manual);
      expect(find.byKey(const Key('spatial_viewpoint')), findsOneWidget);
      expect(saved, isEmpty, reason: 'the setting itself is not changed');
      await close(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the layout menu redraws the passes, and the layout picked goes to the opener', (tester) async {
    await pumpLauncher(
      tester,
      const SpatialPlayerArgs(url: '/videos/stereo.mp4', title: 'stereo.mp4'),
      settings: const DesktopSpatialSettings(source: SpatialViewpointSource.manual),
    );
    expect(channel.setups.last.layout, mkv.SpatialLayout.sideBySide, reason: 'Auto on a 16:9 frame');
    expect(find.text('Auto: Side by side'), findsOneWidget);
    await tester.tap(find.byKey(const Key('spatial_layout')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Top and bottom, eyes swapped').last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(channel.setups.last.layout, mkv.SpatialLayout.topBottomSwapped);
    expect(players.made.single.calls.where((call) => call.startsWith('open')), hasLength(1), reason: 'nothing of mpv');
    await close(tester);
    expect(closings.map((closing) => closing.layout), [SpatialStereoLayout.topBottomSwapped]);
  });

  testWidgets('a 360° stereo video turns with a drag, and switches between 360 and 180', (tester) async {
    await pumpLauncher(
      tester,
      const SpatialPlayerArgs(
        url: '/videos/vr180.mp4',
        title: 'vr180.mp4',
        layout: SpatialStereoLayout.sideBySide,
        projection: SpatialProjection.equirectangular180,
      ),
      settings: const DesktopSpatialSettings(source: SpatialViewpointSource.manual),
    );
    final setup = channel.setups.last;
    expect(setup.projection, mkv.SpatialProjection.equirect);
    expect(setup.halfSphere, isTrue);
    expect(setup.maxFrameWidth, PluginTier.w2880.maxFrameWidth, reason: "renderer C's start tier of an Intel UHD");
    await tester.dragFrom(const Offset(800, 450), const Offset(200, 0));
    await tester.pump(const Duration(milliseconds: 200));
    expect(channel.views, isNotEmpty);
    expect(channel.views.last.$1.yaw, lessThan(0), reason: 'the picture follows the pointer');
    await showControls(tester);
    await tester.tap(find.byKey(const Key('spatial_coverage')));
    await tester.pump();
    expect(channel.setups.last.halfSphere, isFalse);
    await close(tester);
    expect(closings.single.projection, SpatialProjection.equirectangular);
  });

  testWidgets('refused passes play the video as it is, with a message', (tester) async {
    await pumpLauncher(tester, sbs, refuse: 'software rendering');
    expect(page(tester).drawing, isFalse);
    expect(find.text('This computer cannot draw the depth of this video: it plays flat.'), findsOneWidget);
    expect(mpv, ['keepaspect=no', 'keepaspect=yes']);
    expect(players.made.single.calls, contains('open /videos/stereo.mp4 at 0'));
    await close(tester);
  });

  testWidgets('the webcam menu lists the infrared camera by name, and the one picked is kept', (tester) async {
    const ir = HeadCamera(id: 'ir', name: 'USB2.0 IR UVC WebCam');
    const color = HeadCamera(id: 'color', name: 'USB2.0 FHD UVC WebCam');
    await pumpLauncher(tester, sbs, cameras: const [ir, color]);
    expect(webcams.last.camera, color);
    await showControls(tester);
    await tester.tap(find.byKey(const Key('spatial_source')));
    await tester.pumpAndSettle();
    expect(find.text('USB2.0 IR UVC WebCam (infrared)'), findsOneWidget);
    await tester.tap(find.text('USB2.0 IR UVC WebCam (infrared)'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(webcams.last.camera, ir);
    expect(webcams.sessions.first.session.isClosed, isTrue);
    expect(saved.last.cameraId, 'ir');
    await close(tester);
  });

  testWidgets('troubleshooting shows the figures and the disparity map', (tester) async {
    await pumpLauncher(
      tester,
      const SpatialPlayerArgs(url: '/videos/stereo.mp4', title: 'stereo.mp4', debugOverlay: true),
    );
    channel.stats_ = mkv.SpatialStats.fromMap(const {
      'enabled': true,
      'spatial': true,
      'stereo': true,
      'quality': 1,
      'renderFps': 30.0,
      'disparityFps': 15.0,
      'renderMs': 4.2,
      'disparityWidth': 480,
      'disparityHeight': 270,
      'eyeWidth': 1920,
      'eyeHeight': 1080,
      'gpuTimer': true,
      'halfFloatMaps': true,
    });
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(find.textContaining('medium, 30.0 draws/s, 15.0 estimations/s, 4.2 ms (GPU timer)'), findsOneWidget);
    await showControls(tester);
    await tester.tap(find.byKey(const Key('spatial_source')));
    // The figures come twice a second: pumped, never settled
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.byKey(const Key('spatial_disparity')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(channel.debug, [true]);
    await close(tester);
  });

  test('Auto takes the frame shape, as SpatialVideoActivity guesses it', () {
    mkv.SpatialLayout auto(int width, int height, [SpatialProjection projection = SpatialProjection.flat]) =>
        spatialEyeLayout(SpatialStereoLayout.auto, width: width, height: height, projection: projection);
    expect(auto(3840, 1080), mkv.SpatialLayout.sideBySide);
    expect(auto(1920, 2160), mkv.SpatialLayout.topBottom);
    expect(auto(1920, 1080), mkv.SpatialLayout.sideBySide);
    expect(auto(4096, 4096, SpatialProjection.equirectangular), mkv.SpatialLayout.topBottom);
    expect(auto(8192, 2048, SpatialProjection.equirectangular), mkv.SpatialLayout.sideBySide);
    expect(auto(2880, 5760, SpatialProjection.equirectangular180), mkv.SpatialLayout.topBottom);
    expect(auto(5760, 2880, SpatialProjection.equirectangular180), mkv.SpatialLayout.sideBySide);
    expect(spatialEyeLayout(SpatialStereoLayout.auto), mkv.SpatialLayout.sideBySide, reason: 'before the size');
    expect(spatialEyeLayout(SpatialStereoLayout.topBottomSwapped), mkv.SpatialLayout.topBottomSwapped);
    expect(spatialEyeLayout(SpatialStereoLayout.none), mkv.SpatialLayout.none);
  });

  test('the mouse keeps within the range of the head', () {
    expect(mouseViewpoint(0), HeadViewpoint.minViewpoint);
    expect(mouseViewpoint(0.5), closeTo(0.5, 1e-12));
    expect(mouseViewpoint(2), HeadViewpoint.maxViewpoint);
  });
}
