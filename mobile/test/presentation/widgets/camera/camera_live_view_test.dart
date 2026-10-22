// The live tile and its platform view, with the live view API faked: the account goes only through setSource, the
// SD or HD stream, the sound, the states the view reports, the player stopped when the view goes and while the app is
// away, and the tile without a live view (no camera account). On iPhone and iPad: the live playlist made in Dart with
// the account, the player given its address alone, the video alone after a refusal of the player, the H.265 cameras,
// a lost stream opened again, and the UiKitView of the live view.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test/flutter_test.dart' as flutter_test show testWidgets;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_live_hls.dart';
import 'package:immich_mobile/platform/camera_live_api.g.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_live_view.widget.dart';
import 'package:immich_mobile/providers/tapo/tapo_camera.provider.dart';

import '../../pages/camera/camera_fakes.dart';

void main() {
  late FakeCameraLiveApi live;
  late FakeLiveHlsStarter hls;

  setUp(() {
    live = FakeCameraLiveApi();
    hls = FakeLiveHlsStarter();
  });

  Future<void> pump(
    WidgetTester tester, {
    String user = 'viewer',
    String? password = cameraAccountPassword,
    bool preferHd = false,
    ValueNotifier<bool>? shown,
    bool realPlatformView = false,
  }) async {
    final visible = shown ?? ValueNotifier(true);
    await pumpCameraApp(
      tester,
      home: Scaffold(
        body: ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (context, show, _) => show
              ? SizedBox(
                  width: 640,
                  height: 360,
                  child: CameraLiveTile(
                    host: cameraHost,
                    port: 554,
                    user: user,
                    password: password,
                    fullScreen: false,
                    preferHd: preferHd,
                    onFullScreen: (_) {},
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
      overrides: cameraOverrides(live: live, liveHls: hls, realPlatformView: realPlatformView),
    );
  }

  CameraLiveEventsHub hub(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(Scaffold).first)).read(cameraLiveEventsProvider);

  testWidgets('gives the stream and the account through setSource only, muted', (tester) async {
    await pump(tester);
    final (viewId, source) = live.sources.single;
    expect(viewId, cameraViewId);
    expect(source.url, 'rtsp://$cameraHost:554/stream2');
    expect(source.url, isNot(contains('viewer')));
    expect((source.username, source.password, source.isHls), ('viewer', cameraAccountPassword, false));
    expect(live.mutes.single, (cameraViewId, true));
  });

  testWidgets('switches between the SD and HD streams, HD first on the Quest', (tester) async {
    await pump(tester, preferHd: true);
    expect(live.sources.single.$2.url, endsWith('/stream1'));
    expect(find.text('HD'), findsOneWidget);
    await tester.tap(find.byKey(const Key('camera_live_quality')));
    await tester.pumpAndSettle();
    expect(live.sources.last.$2.url, endsWith('/stream2'));
    expect(find.text('SD'), findsOneWidget);
  });

  testWidgets('shows the states the view reports', (tester) async {
    await pump(tester);
    expect(find.text('Connecting to the camera'), findsOneWidget);
    hub(tester).stateChanged(cameraViewId, CameraLiveState.playing, null, true);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('camera_live_badge')), findsOneWidget);
    hub(tester).stateChanged(cameraViewId, CameraLiveState.failed, 'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED', true);
    await tester.pumpAndSettle();
    expect(find.text('The live view did not start: ERROR_CODE_IO_NETWORK_CONNECTION_FAILED'), findsOneWidget);
    expect(find.byKey(const Key('camera_live_badge')), findsNothing);
  });

  testWidgets('stops the player when the view goes, and while the app is away', (tester) async {
    final shown = ValueNotifier(true);
    await pump(tester, shown: shown);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(live.stops, [cameraViewId]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(live.sources, hasLength(2));
    shown.value = false;
    await tester.pumpAndSettle();
    expect(live.stops, [cameraViewId, cameraViewId]);
  });

  testWidgets('without a camera account, says how to get the live view', (tester) async {
    await pump(tester, user: '', password: null);
    expect(find.text('Add the camera account to see the live view.'), findsOneWidget);
    expect(live.sources, isEmpty);
  });

  group('on iPhone and iPad', () {
    // The platform is set back inside the test: flutter_test checks it before the tear downs
    void testWidgets(String description, WidgetTesterCallback body) =>
        flutter_test.testWidgets(description, (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
          try {
            await body(tester);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });

    testWidgets('makes the live playlist with the account, the player gets its address alone', (tester) async {
      await pump(tester);
      await tester.pumpAndSettle();
      final stream = hls.streams.single;
      expect(
        (stream.path, stream.user, stream.password, stream.withAudio),
        ('/stream2', 'viewer', cameraAccountPassword, true),
      );
      final (viewId, source) = live.sources.single;
      expect(viewId, cameraViewId);
      expect(source.url, FakeLiveHls.address.toString());
      expect((source.username, source.password, source.isHls), (null, null, true));
      expect(live.mutes.last, (cameraViewId, true));
      expect(find.text('Connecting to the camera'), findsOneWidget);

      hub(tester).stateChanged(cameraViewId, CameraLiveState.playing, null, true);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('camera_live_badge')), findsOneWidget);
      await tester.tap(find.byKey(const Key('camera_live_sound')));
      await tester.pumpAndSettle();
      expect(live.mutes.last, (cameraViewId, false));
    });

    testWidgets('the HD stream is a new playlist, the previous one stopped first', (tester) async {
      await pump(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('camera_live_quality')));
      await tester.pumpAndSettle();
      expect(hls.streams.map((stream) => stream.path), ['/stream2', '/stream1']);
      expect(hls.streams.first.stopped, isTrue);
      expect(hls.streams.last.stopped, isFalse);
      expect(live.sources, hasLength(2));
    });

    testWidgets('a player that refuses the playlist before its first frame gets it once more without the sound', (
      tester,
    ) async {
      await pump(tester);
      await tester.pumpAndSettle();
      hub(tester).stateChanged(cameraViewId, CameraLiveState.failed, 'CoreMediaErrorDomain -12927', true);
      await tester.pumpAndSettle();
      expect(hls.streams.map((stream) => stream.withAudio), [true, false]);
      expect(hls.streams.first.stopped, isTrue);
      expect(live.sources, hasLength(2));
      expect(find.text('Connecting to the camera'), findsOneWidget);

      hub(tester).stateChanged(cameraViewId, CameraLiveState.playing, null, false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('camera_live_badge')), findsOneWidget);
      final sound = tester.widget<IconButton>(find.byKey(const Key('camera_live_sound')));
      expect(sound.onPressed, isNull, reason: 'no sound to turn on');
      expect(sound.tooltip, 'No sound on this device');

      // The video alone fails too: the reason, and no other try
      hub(tester).stateChanged(cameraViewId, CameraLiveState.failed, 'CoreMediaErrorDomain -12927', false);
      await tester.pump();
      expect(hls.streams, hasLength(2));
    });

    testWidgets('tells an H.265 camera, and a refused account, without trying again', (tester) async {
      hls.autoReady = false;
      await pump(tester);
      await tester.pumpAndSettle();
      hls.streams.single.refuse(const TapoCameraException(TapoErrorKind.h265));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This camera sends H.265. Its live view comes to iPhone and iPad in a later version; its recordings play '
          'here already.',
        ),
        findsOneWidget,
      );
      expect(live.sources, isEmpty);
      // The SD stream of the same camera may be H.264
      expect(find.byKey(const Key('camera_live_quality')), findsOneWidget);

      await tester.tap(find.byKey(const Key('camera_live_quality')));
      await tester.pumpAndSettle();
      hls.streams.last.refuse(const TapoCameraException(TapoErrorKind.wrongPassword, code: 401));
      await tester.pumpAndSettle();
      expect(find.text('The live view did not start: the camera refused the account'), findsOneWidget);
      await tester.pump(const Duration(minutes: 2));
      expect(hls.streams, hasLength(2));
    });

    testWidgets('a stream that played and was lost is opened again', (tester) async {
      await pump(tester);
      await tester.pumpAndSettle();
      hub(tester).stateChanged(cameraViewId, CameraLiveState.playing, null, true);
      await tester.pumpAndSettle();
      hls.streams.single.lose(tapoLiveStreamLost);
      await tester.pump();
      await tester.pump();
      expect(find.text('Connecting to the camera'), findsOneWidget, reason: 'buffering while it comes back');
      expect(hls.streams.single.stopped, isTrue);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(hls.streams, hasLength(2));
      expect(live.sources, hasLength(2));
      hub(tester).stateChanged(cameraViewId, CameraLiveState.playing, null, true);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('camera_live_badge')), findsOneWidget);
    });

    testWidgets('stops the playlist and the player while the app is away and when the view goes', (tester) async {
      final shown = ValueNotifier(true);
      await pump(tester, shown: shown);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(hls.streams.single.stopped, isTrue);
      expect(live.stops, [cameraViewId]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(hls.streams, hasLength(2));
      expect(live.sources, hasLength(2));
      shown.value = false;
      await tester.pumpAndSettle();
      expect(hls.streams.last.stopped, isTrue);
      expect(live.stops, [cameraViewId, cameraViewId]);
    });

    testWidgets('the platform view is a UiKitView of the live view type, without creation parameters', (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, null),
      );
      await pump(tester, realPlatformView: true);
      await tester.pumpAndSettle();
      final create = calls.firstWhere((call) => call.method == 'create');
      final arguments = create.arguments as Map<Object?, Object?>;
      expect(arguments['viewType'], cameraLiveViewType);
      expect(arguments['params'], isNull);
      expect(find.byType(UiKitView), findsOneWidget);
      expect(live.sources.single.$2.isHls, isTrue);
      expect(live.sources.single.$1, arguments['id']);
    });
  });

  test('builds the RTSP address without the account', () {
    expect(cameraRtspUrl('192.0.2.30', 554, hd: true), 'rtsp://192.0.2.30:554/stream1');
    expect(cameraRtspUrl('192.0.2.30', 8554, hd: false), 'rtsp://192.0.2.30:8554/stream2');
  });
}
