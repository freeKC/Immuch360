// The live tile and its platform view, with the live view API faked: the account goes only through setSource, the
// SD or HD stream, the sound, the states the view reports, the player stopped when the view goes and while the app is
// away, and the tile without a live view (no camera account, iPhone and iPad).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/platform/camera_live_api.g.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_live_view.widget.dart';
import 'package:immich_mobile/providers/tapo/tapo_camera.provider.dart';

import '../../pages/camera/camera_fakes.dart';

void main() {
  late FakeCameraLiveApi live;

  setUp(() => live = FakeCameraLiveApi());

  Future<void> pump(
    WidgetTester tester, {
    String user = 'viewer',
    String? password = cameraAccountPassword,
    bool preferHd = false,
    ValueNotifier<bool>? shown,
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
      overrides: cameraOverrides(live: live),
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

  testWidgets('on iPhone and iPad, says the live view comes later', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await pump(tester);
      expect(
        find.text('The live view comes to iPhone and iPad in a later version. The recordings play here already.'),
        findsOneWidget,
      );
      expect(live.sources, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('builds the RTSP address without the account', () {
    expect(cameraRtspUrl('192.0.2.30', 554, hd: true), 'rtsp://192.0.2.30:554/stream1');
    expect(cameraRtspUrl('192.0.2.30', 8554, hd: false), 'rtsp://192.0.2.30:8554/stream2');
  });
}
