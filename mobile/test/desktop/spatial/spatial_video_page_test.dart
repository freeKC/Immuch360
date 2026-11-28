// The Spatial 2.5D page of 3D videos on the computers (spatial_video_page.dart, release 53 lot S1), on a pooled fake
// player and the passes over a fake channel:
// - the passes are on before the file opens, with the layout, the projection and the window's box, and the video
//   plays at once;
// - a recorded head track of the fake source moves the viewpoint sent to the plugin as the photo page moves its
//   uniform (0.675, 0.85, held, then back to the centre), at most once per frame, and a still head within the dead band
//   sends nothing;
// - the mouse moves the view while the head cannot be used (no tracker on the test machine), and in the mouse mode;
// - the layout picked is a new setup of the same passes; closing turns the passes off, reports where the video was and
//   the layout shown last, and lets the viewer behind take its video back;
// - the depth view a page left on the pooled player is turned off by the next page, and what changed while the first
//   enable ran (the layout, the window's box, the viewpoint) reaches the passes once it ends;
// - refused passes play the video as it is, with the message; the original failing plays the transcoded stream;
// - a VR180 3D video sets the view, turns with a drag and zooms with the wheel;
// - the video plays with its sound (the adapter starts silent), M mutes it and gives it back;
// - DesktopSpatialVideoApi: supported where a renderer exists and libmpv loaded, open pushes the page, its closing
//   reaches SpatialVideoEvents as the phones' players do.

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/platform/desktop_spatial_video_api.dart';
import 'package:immich_mobile/desktop/spatial/head_position_source.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/desktop/spatial/spatial_video_page.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position_sources.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart' show DesktopAudioTrack;
import 'package:immich_mobile/desktop/video/external_player_closed.provider.dart';
import 'package:immich_mobile/desktop/video/projection_params.dart' show ViewAngles;
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:media_kit_video/media_kit_video.dart' as mkv;

import '../../unit/presentation/presentation_context.dart';
import '../video/fake_playback_engine.dart';
import '../window/trackpad_pinch_sequences.dart';
import 'fake_viewer_position_source.dart';

class _Passes implements SpatialPassesChannel {
  _Passes(this.players, {this.refuse, this.debugShown = false, this.firstEnable});

  final FakePlayers players;
  final String? refuse;

  /// The depth view of the player's output, kept as Windows keeps it on a pooled player: neither disable nor a new
  /// enable turns it off
  bool debugShown;

  /// Holds the first enable until completed, when set: the first enable compiles every pass
  final Completer<void>? firstEnable;
  final calls = <String>[];
  final setups = <mkv.SpatialSetup>[];
  final viewpoints = <double>[];
  final views = <(ViewAngles, bool)>[];
  final debug = <bool>[];

  /// The calls of the player when the passes were first turned on
  List<String>? playerCallsAtEnable;

  @override
  Future<mkv.ProjectionResult> enable(int handle, mkv.SpatialSetup setup) async {
    calls.add('enable');
    setups.add(setup);
    final gate = firstEnable;
    if (gate != null && setups.length == 1) {
      await gate.future;
    }
    playerCallsAtEnable ??= [...players.made.first.calls];
    if (refuse != null) {
      return mkv.ProjectionResult(ok: false, reason: refuse);
    }
    return mkv.ProjectionResult(
      ok: true,
      glRenderer: 'Metal (Apple Paravirtual device)',
      outputWidth: setup.outputWidth,
      outputHeight: setup.outputHeight,
    );
  }

  @override
  Future<mkv.ProjectionResult> disable(int handle) async {
    calls.add('disable');
    return const mkv.ProjectionResult(ok: true);
  }

  @override
  Future<bool> setViewpoint(int handle, double viewpoint) async {
    viewpoints.add(viewpoint);
    return true;
  }

  @override
  Future<bool> setView(int handle, ViewAngles view, {required bool sharp}) async {
    views.add((view, sharp));
    return true;
  }

  @override
  Future<bool> setDebug(int handle, {required bool disparityMap}) async {
    debug.add(disparityMap);
    debugShown = disparityMap;
    return true;
  }

  @override
  Future<mkv.SpatialStats?> stats(int handle, {bool probe = false}) async => null;
}

class _Store implements DesktopSpatialSettingsStore {
  DesktopSpatialSettings settings = const DesktopSpatialSettings();

  @override
  DesktopSpatialSettings read() => settings;

  @override
  Future<void> write(DesktopSpatialSettings settings) async => this.settings = settings;
}

class _Session implements SpatialVideoEvents {
  final closings = <(int, bool, SpatialStereoLayout, SpatialProjection)>[];

  @override
  void closed(int positionMs, bool wasPlaying, SpatialStereoLayout layout, SpatialProjection projection) =>
      closings.add((positionMs, wasPlaying, layout, projection));
}

void main() {
  late PresentationContext context;
  late FakePlayers players;
  late _Passes passes;
  late List<String> mpv;
  var now = Duration.zero;

  setUp(() async {
    context = await PresentationContext.create();
    now = Duration.zero;
    players = FakePlayers(onCreate: (engine) => engine.autoLoad = const Duration(seconds: 20));
  });

  tearDown(() async {
    await context.dispose();
  });

  Future<void> advance(WidgetTester tester, int ms) async {
    now += Duration(milliseconds: ms);
    await tester.pump(Duration(milliseconds: ms));
  }

  /// A launcher whose button pushes the page, as DesktopSpatialVideoApi does
  Future<List<(int, bool, SpatialStereoLayout, SpatialProjection)>> pumpPage(
    WidgetTester tester, {
    SpatialVideoArgs args = const SpatialVideoArgs(
      url: '/videos/salon_3D_SBS.mp4',
      title: 'salon_3D_SBS.mp4',
      layout: SpatialStereoLayout.sideBySide,
    ),
    Map<ViewerPositionKind, ViewerPositionSource Function()>? sources,
    String? refuse,
    bool debugLeftOn = false,
    Completer<void>? firstEnable,
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    passes = _Passes(players, refuse: refuse, debugShown: debugLeftOn, firstEnable: firstEnable);
    mpv = [];
    final closings = <(int, bool, SpatialStereoLayout, SpatialProjection)>[];
    final deps = SpatialVideoDependencies(
      pool: players.pool,
      resolve: (source) async => source.path,
      passes: passes,
      handleOf: (engine) async => 7,
      setMpv: (engine, name, value) async => mpv.add('$name=$value'),
      clock: () => now,
    );
    await tester.pumpTestWidget(
      context,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => unawaited(
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SpatialVideoPage(
                  args: args,
                  dependencies: deps,
                  onClosed: (position, playing, layout, projection) =>
                      closings.add((position, playing, layout, projection)),
                ),
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
      overrides: [if (sources != null) spatialVideoPositionSourcesProvider.overrideWithValue(sources), ...overrides],
      expectSettle: false,
    );
    // The translations load first, as in the 360° player's tests
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    await tester.tap(find.text('open'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    // The pool makes its player out of the fake clock
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    return closings;
  }

  SpatialVideoPageState page(WidgetTester tester) => tester.state<SpatialVideoPageState>(find.byType(SpatialVideoPage));

  Future<void> close(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(800, 450));
    await mouse.moveTo(const Offset(810, 455));
    await tester.pump();
    await tester.tap(find.byKey(const Key('spatial_video_close')));
    await tester.pump();
    // The route's way out, then its dispose
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await mouse.removePointer();
    expect(find.byType(SpatialVideoPage), findsNothing, reason: 'the page closed');
  }

  test('an Auto layout is the frame shape, as SpatialVideoActivity guesses it', () {
    expect(spatialEyeLayout(SpatialStereoLayout.auto, width: 3840, height: 1080), mkv.SpatialLayout.sideBySide);
    expect(spatialEyeLayout(SpatialStereoLayout.auto, width: 1920, height: 2160), mkv.SpatialLayout.topBottom);
    expect(
      spatialEyeLayout(
        SpatialStereoLayout.auto,
        width: 4096,
        height: 4096,
        projection: SpatialProjection.equirectangular,
      ),
      mkv.SpatialLayout.topBottom,
    );
    expect(
      spatialEyeLayout(
        SpatialStereoLayout.auto,
        width: 4096,
        height: 2048,
        projection: SpatialProjection.equirectangular180,
      ),
      mkv.SpatialLayout.sideBySide,
    );
    // A 360° 3D video (3840x3840, two 2:1 eyes stacked) whose coverage was set to 180°: side by side would cut across
    // both eyes (night tests of 27 November 2026, D1)
    expect(
      spatialEyeLayout(
        SpatialStereoLayout.auto,
        width: 3840,
        height: 3840,
        projection: SpatialProjection.equirectangular180,
      ),
      mkv.SpatialLayout.topBottom,
    );
    expect(spatialEyeLayout(SpatialStereoLayout.topBottomSwapped), mkv.SpatialLayout.topBottomSwapped);
    expect(spatialEyeLayout(SpatialStereoLayout.auto), mkv.SpatialLayout.sideBySide, reason: 'size unknown');
  });

  testWidgets('the passes are on before the file opens, and the video plays at once', (tester) async {
    await pumpPage(tester, sources: {ViewerPositionKind.mouse: MousePositionSource.new});
    expect(passes.calls.first, 'enable');
    expect(passes.playerCallsAtEnable!.where((call) => call.startsWith('open')), isEmpty, reason: 'before the open');
    final setup = passes.setups.first;
    expect(setup.layout, mkv.SpatialLayout.sideBySide);
    expect(setup.projection, mkv.SpatialProjection.flat);
    expect(setup.halfSphere, isFalse);
    expect(setup.viewpoint, 0.5);
    expect(setup.maxOutputHeight, 1440);
    expect(players.made.first.calls, contains('open /videos/salon_3D_SBS.mp4 at 0'));
    expect(players.made.first.calls, contains('play'));
    expect(page(tester).drawing, isTrue);
    expect(mpv, ['keepaspect=no'], reason: 'the frame keeps the video\'s shape exactly');
    expect(find.text('Move the pointer across the picture to look around the scene; R recenters'), findsOneWidget);
    // The window's box reaches the passes once it stopped changing
    await tester.pump(SpatialVideoPageState.resizeDelay * 2);
    expect(passes.setups.last.outputWidth, 1600);
    expect(passes.setups.last.outputHeight, 900);
    await close(tester);
  });

  testWidgets('the video plays with its sound, M mutes it and M again gives it back', (tester) async {
    await pumpPage(tester, sources: {ViewerPositionKind.mouse: MousePositionSource.new});
    final engine = players.made.first;
    // A file with its sound: no "No sound" mark, whose icon is the one of a muted sound
    engine.audioTracks.value = const [DesktopAudioTrack(id: '1', language: 'fre', channels: 2)];
    await tester.pump();
    expect(engine.calls, contains('play'));
    // The adapter starts silent: without the page's volume the sound button showed on while nothing played (D2)
    expect(engine.volume, 1, reason: 'the page plays with sound, as the viewer');
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(engine.volume, 0);
    expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(engine.volume, 1);
    await close(tester);
  });

  testWidgets('a video without any audio track says "No sound" beside the sound button; one with a track does not', (
    tester,
  ) async {
    await pumpPage(tester, sources: {ViewerPositionKind.mouse: MousePositionSource.new});
    final engine = players.made.first;
    expect(engine.hasVideo.value, isTrue, reason: 'the file is open');
    await tester.pump();
    expect(find.byKey(const Key('desktop_no_sound')), findsOneWidget);
    expect(find.byKey(const Key('spatial_video_mute')), findsOneWidget);
    engine.audioTracks.value = const [DesktopAudioTrack(id: '1', language: 'fre', channels: 2)];
    await tester.pump();
    expect(find.byKey(const Key('desktop_no_sound')), findsNothing);
    await close(tester);
  });

  testWidgets('a recorded head track moves the viewpoint sent to the plugin as on the photo page', (tester) async {
    final fake = FakeViewerPositionSource();
    await SettingsRepository.instance.write(SettingsKey.viewerSpatialMoveWith, ViewerPositionKind.head);
    await pumpPage(
      tester,
      sources: {ViewerPositionKind.head: () => fake, ViewerPositionKind.mouse: MousePositionSource.new},
    );
    expect(page(tester).kind, ViewerPositionKind.head);
    expect(find.text('Move your head: the scene moves as if seen through a window; R recenters'), findsOneWidget);

    // The recorded track, each position timed by the page's clock as the tracker times its samples
    final seen = <double>[];
    final sends = <int>[];
    for (final (ms, x, confidence) in [
      (33, 0.5, 0.9),
      (33, 0.502, 0.9),
      (33, 1.0, 0.9),
      (33, 0.0, 0.0),
      (500, 0.0, 0.0),
    ]) {
      await advance(tester, ms);
      fake.add(ViewerPosition(x: x, y: 0, timestamp: now, confidence: confidence));
      await advance(tester, 0);
      seen.add(page(tester).sentViewpoint);
      sends.add(passes.viewpoints.length);
    }
    expect(seen[0], closeTo(0.675, 1e-9), reason: 'p = 0.5 + 0.35 x at the default strength');
    expect(sends[1], sends[0], reason: 'a still head within the dead band sends nothing');
    expect(seen[2], closeTo(0.85, 1e-9), reason: 'the end of the range');
    // No one seen: held, then half way back after half a second
    expect(seen[3], closeTo(0.85, 1e-9));
    expect(seen[4], closeTo(0.675, SpatialVideoPageState.viewpointDeadBand));
    for (var i = 0; i < 40; i++) {
      await advance(tester, 16);
    }
    expect(page(tester).sentViewpoint, closeTo(0.5, 0.003), reason: 'back to the centre');
    expect(passes.viewpoints, everyElement(inInclusiveRange(0.15, 0.85)));

    // R reaches the source
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    expect(fake.recenters, 1);
    await close(tester);
    expect(fake.closed, isTrue, reason: 'the source closes with the page');
  });

  testWidgets('the mouse moves the view while the head cannot be used, and in the mouse mode', (tester) async {
    final store = _Store();
    // No tracker library on this machine: the head is not usable, the pointer moves the view
    HeadPositionSource head() => HeadPositionSource(store: store, away: ValueNotifier(false));
    await SettingsRepository.instance.write(SettingsKey.viewerSpatialMoveWith, ViewerPositionKind.head);
    await pumpPage(tester, sources: {ViewerPositionKind.head: head, ViewerPositionKind.mouse: MousePositionSource.new});
    expect(page(tester).kind, ViewerPositionKind.head);
    expect(
      find.text('Move the pointer across the picture to look around the scene; R recenters'),
      findsOneWidget,
      reason: 'the hint of what moves the view now',
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(800, 450));
    await mouse.moveTo(const Offset(1599, 450));
    for (var i = 0; i < 60; i++) {
      await advance(tester, 16);
    }
    expect(page(tester).sentViewpoint, closeTo(0.85, 0.01), reason: 'the right edge');
    await mouse.moveTo(const Offset(1, 450));
    for (var i = 0; i < 60; i++) {
      await advance(tester, 16);
    }
    expect(page(tester).sentViewpoint, closeTo(0.15, 0.01), reason: 'the left edge');
    await mouse.removePointer();
    await close(tester);
  });

  testWidgets('the layout picked is a new setup; closing turns the passes off and reports', (tester) async {
    final closings = await pumpPage(tester, sources: {ViewerPositionKind.mouse: MousePositionSource.new});
    var raised = 0;
    final container = ProviderScope.containerOf(tester.element(find.byType(SpatialVideoPage)));
    final subscription = container.listen(externalPlayerClosedProvider, (_, _) => raised++);
    addTearDown(subscription.close);

    await tester.tap(find.byKey(const Key('spatial_video_layout')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('spatial_video_layout_topBottom')).last);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.pump();
    expect(passes.setups.last.layout, mkv.SpatialLayout.topBottom);
    expect(players.made.first.calls.where((call) => call.startsWith('open')).length, 1, reason: 'nothing of mpv');

    await close(tester);
    await tester.pump();
    expect(passes.calls.last, 'disable');
    expect(mpv.last, 'keepaspect=yes', reason: 'the pool keeps the player as the other pages want it');
    expect(closings.single.$3, SpatialStereoLayout.topBottom);
    expect(closings.single.$4, SpatialProjection.flat);
    expect(raised, 1);
  });

  testWidgets('the depth view left on by an earlier page on the pooled player is turned off', (tester) async {
    await pumpPage(tester, sources: {ViewerPositionKind.mouse: MousePositionSource.new}, debugLeftOn: true);
    expect(page(tester).drawing, isTrue);
    expect(passes.debugShown, isFalse, reason: 'the depth button is off: the view shows, not the depth map');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.pump();
    expect(passes.debugShown, isTrue, reason: 'one press shows the depth map');
    await close(tester);
  });

  testWidgets('what changed while the first enable ran reaches the passes once it ends', (tester) async {
    final firstEnable = Completer<void>();
    await pumpPage(tester, sources: {ViewerPositionKind.mouse: MousePositionSource.new}, firstEnable: firstEnable);
    expect(page(tester).drawing, isFalse, reason: 'the first enable still runs');
    await tester.tap(find.byKey(const Key('spatial_video_layout')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('spatial_video_layout_topBottom')).last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(page(tester).layout, SpatialStereoLayout.topBottom, reason: 'the menu took it');
    // The pointer moved meanwhile: the page keeps the viewpoint it could not send yet
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(800, 450));
    await mouse.moveTo(const Offset(1599, 450));
    for (var i = 0; i < 60; i++) {
      await advance(tester, 16);
    }
    final viewpoint = page(tester).sentViewpoint;
    expect(viewpoint, greaterThan(0.6));
    expect(passes.setups, hasLength(1), reason: 'nothing else sent before the passes are on');

    firstEnable.complete();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(page(tester).drawing, isTrue);
    expect(passes.setups.last.layout, mkv.SpatialLayout.topBottom, reason: 'the layout shown is the one picked');
    expect(passes.setups.last.outputWidth, 1600, reason: 'the window\'s box');
    expect(passes.setups.last.outputHeight, 900);
    expect(passes.setups.last.viewpoint, closeTo(viewpoint, SpatialVideoPageState.viewpointDeadBand));
    await mouse.removePointer();
    await close(tester);
  });

  testWidgets('refused passes: the video plays as it is, with the message', (tester) async {
    await pumpPage(tester, sources: {ViewerPositionKind.mouse: MousePositionSource.new}, refuse: 'no Metal device');
    expect(page(tester).flat, isTrue);
    expect(mpv, ['keepaspect=no', 'keepaspect=yes']);
    expect(page(tester).drawing, isFalse);
    expect(find.text('Spatial 2.5D could not start on this graphics card: the video plays as it is'), findsOneWidget);
    expect(players.made.first.calls, contains('play'), reason: 'the video still plays');
    await close(tester);
  });

  testWidgets('a VR180 3D video: its view set, turned by a drag, zoomed by the wheel', (tester) async {
    await pumpPage(
      tester,
      args: const SpatialVideoArgs(
        url: '/videos/concert_VR180.mp4',
        title: 'concert_VR180.mp4',
        layout: SpatialStereoLayout.sideBySide,
        projection: SpatialProjection.equirectangular180,
      ),
      sources: {ViewerPositionKind.keys: KeysPositionSource.new},
    );
    expect(passes.setups.first.projection, mkv.SpatialProjection.equirect);
    expect(passes.setups.first.halfSphere, isTrue);
    expect(passes.views.first.$1, const ViewAngles());
    await tester.drag(find.byType(SpatialVideoPage), const Offset(-200, 0));
    await tester.pump();
    expect(page(tester).view.yaw, greaterThan(0), reason: 'dragging to the left turns the view to the right');
    expect(passes.views.last.$2, isTrue, reason: 'sharp once the drag ends');
    final fov = page(tester).view.fov;
    await tester.sendEventToBinding(const PointerScrollEvent(position: Offset(800, 450), scrollDelta: Offset(0, -100)));
    await tester.pump();
    expect(page(tester).view.fov, lessThan(fov), reason: 'the wheel zooms in');
    // A pinch of the touchpad zooms too, and the pan Windows sends with it does not turn the view
    final turned = page(tester).view;
    const at = Offset(1100, 600);
    await sendPanZoom(tester, at, windowsPinch(2, at));
    expect(page(tester).view.fov, closeTo(turned.fov / 2, 0.01), reason: 'a pinch zooms in');
    // The first reports, before the scale says it is a pinch, turn it by their 2 px of pan at most
    expect(page(tester).view.yaw, closeTo(turned.yaw, 0.5), reason: 'and turns nothing');
    expect(page(tester).view.pitch, closeTo(turned.pitch, 0.5));
    tester.binding.handlePointerEvent(const PointerScaleEvent(position: at, scale: 0.8));
    await tester.pump();
    expect(page(tester).view.fov, closeTo(turned.fov / 2 / 0.8, 0.01), reason: 'a scale signal zooms out');
    // Keys only: the arrows move the viewpoint
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    for (var i = 0; i < 20; i++) {
      await advance(tester, 16);
    }
    expect(page(tester).sentViewpoint, greaterThan(0.5));
    await close(tester);
  });

  group('DesktopSpatialVideoApi', () {
    test('supported only where a renderer exists and libmpv loaded', () async {
      expect(
        (await DesktopSpatialVideoApi(rendererExists: true, videoAvailable: () => true).capabilities()).supported,
        isTrue,
      );
      final linux = await DesktopSpatialVideoApi(rendererExists: false, videoAvailable: () => true).capabilities();
      expect(linux.supported, isFalse);
      expect(linux.reason, contains('renderer'));
      expect(
        (await DesktopSpatialVideoApi(rendererExists: true, videoAvailable: () => false).capabilities()).supported,
        isFalse,
      );
      expect(
        () => DesktopSpatialVideoApi(rendererExists: false, videoAvailable: () => true).open(
          SpatialOpenRequest(
            url: '/v.mp4',
            headers: const {},
            title: 'v.mp4',
            layout: SpatialStereoLayout.sideBySide,
            projection: SpatialProjection.flat,
            startPositionMs: 0,
            autoplay: true,
            debugOverlay: false,
            labels: const {},
          ),
        ),
        throwsA(isA<PlatformException>()),
      );
    });

    testWidgets('open pushes the page; its closing reaches SpatialVideoEvents as on the phones', (tester) async {
      final session = _Session();
      SpatialVideoEvents.setUp(session);
      addTearDown(() => SpatialVideoEvents.setUp(null));
      final key = GlobalKey<NavigatorState>();
      SpatialVideoArgs? pushed;
      final api = DesktopSpatialVideoApi(
        navigator: () => key,
        rendererExists: true,
        videoAvailable: () => true,
        routeFor: (args, onClosed) {
          pushed = args;
          return MaterialPageRoute<void>(
            builder: (context) => TextButton(
              onPressed: () {
                onClosed(4200, true, SpatialStereoLayout.topBottom, SpatialProjection.flat);
                Navigator.of(context).pop();
              },
              child: const Text('close'),
            ),
          );
        },
      );
      await tester.pumpWidget(MaterialApp(navigatorKey: key, home: const SizedBox()));
      await api.open(
        SpatialOpenRequest(
          url: 'http://127.0.0.1:9/bridge/a.mp4',
          headers: const {'x-immich-user-token': 'secret'},
          title: 'a_3D_TB.mp4',
          layout: SpatialStereoLayout.topBottom,
          projection: SpatialProjection.flat,
          startPositionMs: 1500,
          autoplay: false,
          debugOverlay: false,
          labels: const {},
        ),
      );
      await tester.pumpAndSettle();
      expect(pushed!.url, 'http://127.0.0.1:9/bridge/a.mp4');
      expect(pushed!.start, const Duration(milliseconds: 1500));
      expect(pushed!.autoplay, isFalse);
      await tester.tap(find.text('close'));
      await tester.pumpAndSettle();
      expect(session.closings.single, (4200, true, SpatialStereoLayout.topBottom, SpatialProjection.flat));
    });
  });
}
