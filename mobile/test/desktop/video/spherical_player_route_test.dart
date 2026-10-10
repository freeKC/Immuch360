// The 360° player of the computers as a route (spherical_player_route.dart, design 2.6), on a pooled fake player and
// renderer C over a fake plugin: the view is on before the file opens, so the first frame is already the view; a drag
// turns the view through the plugin only; the 3D button changes the projection; closing gives the plugin up before
// the player goes back to the pool, tells the session the layout and coverage shown last (PlayerEventsHub) and the
// viewer behind that it can take its video back (externalPlayerClosedProvider); a failure of the original plays the
// transcoded stream; a refused plugin plays flat with the message; a pair of raw files plays both lenses stacked by
// lavfi-complex when the switch says this computer keeps up, else the phones' fallback chain with their messages.

import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/video/decoder_measure.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/external_player_closed.provider.dart';
import 'package:immich_mobile/desktop/video/raw_two_stream_switch.dart';
import 'package:immich_mobile/desktop/video/raw_two_streams.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:immich_mobile/desktop/video/render/sphere_renderer.dart';
import 'package:immich_mobile/desktop/video/spherical_player_route.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/player_events_hub.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart' show SphericalVideoEvents;
import 'package:immuch_desktop_video/immuch_desktop_video.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'fake_playback_engine.dart';

const _intel = 'ANGLE (Intel, Intel(R) UHD Graphics (0x0000A788) Direct3D11 vs_5_0 ps_5_0, D3D11)';

// An X3 pair (example C of raw_video_plan_test.dart, its lenses shortened to what the stitch reads)
const _pair =
    '{"version":2,"kind":"dualFisheye","layout":"twoFiles","camera":"Insta360 X3","frameWidth":5760,'
    '"frameHeight":2880,"tracks":[{"file":0,"videoTrack":0,"trackId":1,"width":2880,"height":2880,"codec":"hvc1",'
    '"codecs":"hvc1.1.6.L153","bitDepth":8},{"file":1,"videoTrack":0,"trackId":1,"width":2880,"height":2880,'
    '"codec":"hvc1","codecs":"hvc1.1.6.L153","bitDepth":8}],"secondUrl":null,"secondFallbackUrl":null,'
    '"trackOrder":[1,0],"trackOrderSource":"fileName","calibrationSource":"file","gravitySource":"imu",'
    '"model":"mei","canvasSquare":5952.0,"maxTheta":100.0,"blendStart":85.0,"blendEnd":95.0,"lenses":['
    '{"texture":1,"region":[0.0,0.0,1.0,1.0],"cx":2967.48,"cy":2999.85,"fx":4627.54,"fy":4627.46,"xi":1.94817,'
    '"k1":0.388,"k2":1.295,"k3":-3.968,"k4":0.0,"k5":0.0,"p1":0.0,"p2":0.0,'
    '"viewToLens":[-1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,-1.0]},'
    '{"texture":0,"region":[0.0,0.0,1.0,1.0],"cx":8933.2,"cy":2998.62,"fx":4615.53,"fy":4615.53,"xi":1.94817,'
    '"k1":0.393,"k2":1.256,"k3":-3.907,"k4":0.0,"k5":0.0,"p1":0.0,"p2":0.0,'
    '"viewToLens":[1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0]}]}';

class _Channel implements PluginChannel {
  _Channel(this.players, {this.refuse});

  final FakePlayers players;
  final String? refuse;
  final calls = <String>[];
  final setups = <ProjectionSetup>[];
  final views = <(PluginView, bool)>[];

  /// What the player had been asked when the plugin was turned on
  List<String>? playerCallsAtEnable;

  @override
  Future<ProjectionResult> enable(int handle, ProjectionSetup setup) async {
    calls.add('enable');
    setups.add(setup);
    playerCallsAtEnable ??= [...players.made.first.calls];
    if (refuse != null) {
      return ProjectionResult(ok: false, reason: refuse, clientVersion: 2, glRenderer: _intel);
    }
    return ProjectionResult(
      ok: true,
      clientVersion: 3,
      glRenderer: _intel,
      outputWidth: setup.outputWidth,
      outputHeight: setup.outputHeight,
    );
  }

  @override
  Future<ProjectionResult> disable(int handle) async {
    calls.add('disable with ${players.made.first.calls.where((call) => call == 'stop').length} stops');
    return const ProjectionResult(ok: true);
  }

  @override
  Future<bool> setView(int handle, PluginView view, {required bool sharp}) async {
    views.add((view, sharp));
    return true;
  }

  @override
  Future<ProjectionStats?> stats(int handle, {bool probe = false}) async => null;
}

class _Session implements SphericalVideoEvents {
  final closings = <(StereoLayout, SphereCoverage)>[];

  @override
  void closed(StereoLayout stereoLayout, SphereCoverage coverage) => closings.add((stereoLayout, coverage));
}

void main() {
  late Directory folder;
  late FakePlayers players;
  late _Channel channel;
  late _Session session;
  late ProviderContainer container;
  late List<String> mpv;
  late Map<String, String> mpvValues;
  late DateTime clock;
  late bool externalReadable;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('spherical_player_route_test');
    SphereRendererStore.forget();
    SphereRendererStore.folder = () async => folder;
    session = _Session();
    PlayerEventsHub.setUpSpherical(session);
    container = ProviderContainer();
    mpv = [];
    mpvValues = {};
    clock = DateTime(2026, 10, 10, 12);
    externalReadable = true;
  });

  tearDown(() {
    PlayerEventsHub.setUpSpherical(null);
    container.dispose();
    SphereRendererStore.forget();
    folder.deleteSync(recursive: true);
  });

  SphericalPlayerDependencies dependencies({String? refuse, bool silent = false, bool integrated = true}) {
    // Made in the test's own zone: the pool's futures then complete as the test pumps
    players = FakePlayers(onCreate: (engine) => engine.autoLoad = silent ? null : const Duration(seconds: 60));
    // The measures stay in memory: a folder that cannot be had, so that no file of the app is touched
    Future<Directory> noFolder() => Future.error(const FileSystemException('no folder in the tests'));
    final adapter = GpuAdapter.fromJson({
      'name': integrated ? 'Intel(R) UHD Graphics' : 'NVIDIA GeForce RTX 4060 Laptop GPU',
      'vendorId': integrated ? 0x8086 : 0x10de,
      'integrated': integrated,
    });
    channel = _Channel(players, refuse: refuse);
    return SphericalPlayerDependencies(
      pool: players.pool,
      resolve: (source) async => source.path,
      pluginFor: (engine) => PluginRenderer(
        handle: () async => 42,
        setMpvProperty: (name, value) async => mpv.add('$name=$value'),
        channel: channel,
      ),
      setMpv: (engine, name, value) async => mpv.add('$name=$value'),
      mpvCommand: (engine, command) async => mpv.add(command.join(' ')),
      readMpv: (engine, name) async => mpvValues[name] ?? '',
      twoStreams: () => TwoStreamSwitch(
        store: TwoStreamMeasureStore(folder: noFolder),
        decoderMeasures: DecoderMeasureStore(folder: noFolder),
        adapter: () async => adapter,
      ),
      readable: (url) async => !url.contains('LRV_') && externalReadable,
      firstFrameTimeout: const Duration(seconds: 3),
      now: () => clock,
      framesPerSecond: (_) async => 30,
      appVersion: () async => 'test',
      pluginSupported: true,
      memoryMB: () => 100,
    );
  }

  /// A page with a button that opens the player, as DesktopSphericalVideoApi pushes it
  Future<void> pumpLauncher(
    WidgetTester tester,
    SphericalPlayerArgs args, {
    String? refuse,
    bool silent = false,
    bool integrated = true,
  }) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final deps = dependencies(refuse: refuse, silent: silent, integrated: integrated);
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
                  body: TextButton(
                    onPressed: () => unawaited(
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => DesktopSphericalPlayerPage(args: args, dependencies: deps),
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

  DesktopSphericalPlayerPageState page(WidgetTester tester) =>
      tester.state<DesktopSphericalPlayerPageState>(find.byType(DesktopSphericalPlayerPage));

  Future<void> close(WidgetTester tester) async {
    // The mouse moves first: the controls hide 3 s after the last move while the video plays
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(800, 450));
    await mouse.moveTo(const Offset(810, 455));
    await tester.pump();
    await mouse.removePointer();
    await tester.pump();
    await tester.tap(find.byKey(const Key('spherical_close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
  }

  testWidgets('the view is on before the file opens, and the video plays at once', (tester) async {
    await pumpLauncher(tester, const SphericalPlayerArgs(url: '/videos/sphere.mp4', title: 'sphere.mp4'));
    final engine = players.made.single;
    expect(channel.playerCallsAtEnable, isNot(contains(startsWith('open'))));
    expect(engine.calls, contains('open /videos/sphere.mp4 at 0'));
    expect(engine.calls.last, 'play');
    expect(mpv, ['keepaspect=no']);
    final setup = channel.setups.last;
    expect(setup.kind, ProjectionKind.equirect);
    expect((setup.outputWidth, setup.outputHeight), (1600, 900), reason: 'the window, in physical pixels');
    expect(setup.maxFrameWidth, 2880, reason: 'an integrated GPU starts at 2880');
    expect(page(tester).rendering, const SphereRendering.plugin(PluginTier.w2880));
    expect(find.text('sphere.mp4'), findsOneWidget);
    await close(tester);
  });

  testWidgets('a drag turns the view through the plugin, never through mpv', (tester) async {
    await pumpLauncher(tester, const SphericalPlayerArgs(url: '/videos/sphere.mp4', title: 'sphere.mp4'));
    channel.views.clear();
    final mpvBefore = [...mpv];
    final enablesBefore = channel.setups.length;
    await tester.dragFrom(const Offset(800, 450), const Offset(-200, 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final view = page(tester).view;
    // 90 degrees over 900 pixels: a drag of 200 to the left turns 20 degrees to the right, 100 down looks 10 up
    expect(view.yaw, greaterThan(15));
    expect(view.pitch, greaterThan(7));
    expect(channel.views, isNotEmpty);
    expect(channel.views.any((sent) => !sent.$2), isTrue, reason: 'bilinear while it moves');
    // Inertia, then the sharper filter at rest
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    expect(channel.views.last.$2, isTrue);
    expect(mpv, mpvBefore, reason: 'no mpv property changes while the view moves');
    expect(channel.setups.length, enablesBefore, reason: 'nor the setup of the plugin');
    await close(tester);
  });

  testWidgets('the 3D button cycles the layout through the plugin; closing reports it and gives the player back', (
    tester,
  ) async {
    final closings = <int>[];
    container.listen(externalPlayerClosedProvider, (_, next) => closings.add(next));
    await pumpLauncher(tester, const SphericalPlayerArgs(url: '/videos/sphere.mp4', title: 'sphere.mp4'));
    await tester.tap(find.byKey(const Key('spherical_layout')));
    await tester.pump();
    expect(channel.setups.last.eye, [0, 0, 1, 0.5], reason: 'top and bottom: the left eye on top');
    await tester.tap(find.byKey(const Key('spherical_coverage')));
    await tester.pump();
    expect(channel.setups.last.crop, [0.25, 0, 0.5, 1]);

    await close(tester);
    expect(session.closings, [(StereoLayout.topBottom, SphereCoverage.half)]);
    expect(closings, [1]);
    expect(channel.calls.where((call) => call.startsWith('disable')), [
      'disable with 0 stops',
    ], reason: 'the plugin is given up before the pool stops the player');
    expect(players.made.single.calls, contains('stop'));
    expect(mpv.last, 'keepaspect=yes');
    expect(players.pool.idleCount(PlayerKind.playback), 1);
  });

  testWidgets('the original fails: the transcoded stream plays, with a word about it', (tester) async {
    await pumpLauncher(
      tester,
      const SphericalPlayerArgs(url: '/videos/original.mp4', title: 'x.mp4', fallbackUrl: '/videos/transcoded.mp4'),
    );
    final engine = players.made.single;
    engine.emit(PlayerEventKind.failed, 'libmpv: loading failed');
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(engine.calls, contains('open /videos/transcoded.mp4 at 0'));
    expect(find.text("The original could not be played: playing the server's transcoded stream."), findsOneWidget);
    await close(tester);
  });

  testWidgets('a context without OpenGL ES 3.0: the frame flat, with the message', (tester) async {
    await pumpLauncher(
      tester,
      const SphericalPlayerArgs(url: '/videos/sphere.mp4', title: 'sphere.mp4'),
      refuse: 'OpenGL ES 2.0 context: renderer C needs ES 3.0',
    );
    expect(page(tester).rendering, const SphereRendering.flat(FlatReason.refused));
    expect(find.text('This computer cannot show the 360° view of this video: it plays flat.'), findsOneWidget);
    expect(players.made.single.calls, contains('open /videos/sphere.mp4 at 0'));
    expect(mpv, ['keepaspect=no', 'keepaspect=yes'], reason: 'mpv keeps the shape of the flat frame');
    await close(tester);
  });

  // The X3 pair with its second file next to it
  final pair = _pair.replaceFirst('"secondUrl":null', '"secondUrl":"/videos/VID_20240908_193126_10_004.insv"');
  const first = '/videos/VID_20240908_193126_00_004.insv';

  /// The mpv options of a raw file before its open, in the order the page sets them
  List<String> rawOptions({required String hwdec, String vid = 'auto', String? external, String graph = ''}) => [
    'lavfi-complex=',
    'external-files=',
    'hwdec=$hwdec',
    'vid=$vid',
    if (external != null) 'change-list external-files append $external',
    if (graph.isNotEmpty) 'lavfi-complex=$graph',
  ];

  /// mpv's counters over the 5 s the switch measures, [dropped] frames lost
  Future<void> measureStack(WidgetTester tester, FakePlaybackEngine engine, {required int dropped}) async {
    mpvValues['frame-drop-count'] = '0';
    mpvValues['container-fps'] = '29.97';
    await tester.pump(const Duration(milliseconds: 1100));
    mpvValues['frame-drop-count'] = '$dropped';
    clock = clock.add(const Duration(seconds: 5));
    engine.position.value += const Duration(seconds: 5);
    await tester.pump(const Duration(seconds: 5));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('an X3 pair on an integrated GPU: both files stacked, decoded in software, the regions in the frame', (
    tester,
  ) async {
    await pumpLauncher(tester, SphericalPlayerArgs(url: first, title: 'x3.insv', rawProjection: pair));
    final engine = players.made.single;
    expect(engine.calls, contains('open $first at 0'));
    expect(mpv.take(7), [
      ...rawOptions(
        hwdec: 'no',
        external: '/videos/VID_20240908_193126_10_004.insv',
        graph: '[vid1] [vid2] hstack [vo]',
      ),
      'keepaspect=no',
    ]);
    expect(page(tester).rawStep?.mode, RawMode.stacked);
    final setup = channel.setups.last;
    expect(setup.kind, ProjectionKind.fisheyePair);
    expect(setup.tracks, 1, reason: 'one stacked frame');
    expect(setup.streamsEnabled, [1, 1]);
    expect(find.byKey(const Key('spherical_notice')), findsNothing);
    expect(find.byKey(const Key('spherical_layout')), findsNothing, reason: 'no 3D cycle for a raw file');
    // Smooth: the stack stays, and the renderer probe takes over
    await measureStack(tester, engine, dropped: 0);
    expect(page(tester).rawStep?.hwdec, 'no');
    expect(engine.calls.where((call) => call.startsWith('open')), hasLength(1));
    await close(tester);
    expect(mpv.sublist(mpv.length - 4), ['lavfi-complex=', 'external-files=', 'hwdec=auto-safe', 'vid=auto']);
    expect(session.closings, [(StereoLayout.mono, SphereCoverage.full)]);
  });

  testWidgets('a dedicated GPU stacks through its copy back', (tester) async {
    await pumpLauncher(
      tester,
      SphericalPlayerArgs(url: first, title: 'x3.insv', rawProjection: pair),
      integrated: false,
    );
    expect(mpv, contains('hwdec=${TwoStreamPaths.copyBack}'));
    await close(tester);
  });

  testWidgets('a stack measured too slow: the other decoding path from where it was, then one lens with the message', (
    tester,
  ) async {
    await pumpLauncher(tester, SphericalPlayerArgs(url: first, title: 'x3.insv', rawProjection: pair));
    final engine = players.made.single;
    await measureStack(tester, engine, dropped: 60);
    expect(page(tester).rawStep?.hwdec, TwoStreamPaths.copyBack);
    expect(engine.calls, contains('open $first at 5000'), reason: 'from where the video was');
    expect(mpv, contains('hwdec=${TwoStreamPaths.copyBack}'));
    expect(find.byKey(const Key('spherical_notice')), findsNothing);

    mpv.clear();
    await measureStack(tester, engine, dropped: 60);
    final step = page(tester).rawStep!;
    expect((step.mode, '${step.streams}', step.notice), (RawMode.oneLens, '[0]', RawNotice.oneLensDecoder));
    expect(engine.calls, contains('open $first at 10000'));
    expect(mpv.take(4), rawOptions(hwdec: 'auto-safe', vid: '1'));
    expect(channel.setups.last.streamsEnabled, [1, 0]);
    expect(find.textContaining('hvc1 2880x2880'), findsOneWidget);
    await close(tester);
  });

  testWidgets('the stack fails and the other file cannot be read: the file opened plays its lens alone', (
    tester,
  ) async {
    await pumpLauncher(tester, SphericalPlayerArgs(url: first, title: 'x3.insv', rawProjection: pair));
    final engine = players.made.single;
    externalReadable = false;
    engine.emit(PlayerEventKind.failed, 'libmpv: loading failed');
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final step = page(tester).rawStep!;
    expect((step.mode, '${step.streams}', step.notice), (RawMode.oneLens, '[0]', RawNotice.oneLensFile));
    expect(
      find.text('The file of the other lens cannot be read. One lens shows: half of the sphere stays black.'),
      findsOneWidget,
    );
    await close(tester);
  });

  testWidgets('a stack that shows no frame in time (a libmpv without hstack): one lens', (tester) async {
    await pumpLauncher(tester, SphericalPlayerArgs(url: first, title: 'x3.insv', rawProjection: pair), silent: true);
    await tester.pump(const Duration(seconds: 4));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(page(tester).rawStep?.mode, RawMode.oneLens);
    await close(tester);
  });

  testWidgets('two streams above what stacks smoothly (an X4): one lens from the start, the phones\' message', (
    tester,
  ) async {
    final x4 = pair
        .replaceFirst('"layout":"twoFiles"', '"layout":"twoTracks"')
        .replaceAll('"width":2880,"height":2880', '"width":3840,"height":3840')
        .replaceFirst('{"file":1,"videoTrack":0', '{"file":0,"videoTrack":1');
    await pumpLauncher(tester, SphericalPlayerArgs(url: '/videos/x4.insv', title: 'x4.insv', rawProjection: x4));
    expect(page(tester).rawStep?.mode, RawMode.oneLens);
    // Lens 1 faces the front and lives in the first track
    expect(mpv.take(4), rawOptions(hwdec: 'auto-safe', vid: '1'));
    expect(players.made.single.calls, contains('open /videos/x4.insv at 0'));
    expect(find.textContaining('hvc1 3840x3840'), findsOneWidget);
    await close(tester);
    expect(mpv.last, 'vid=auto');
  });
}
