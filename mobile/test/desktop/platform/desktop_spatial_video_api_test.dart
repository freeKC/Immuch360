// SpatialVideoApi on the computers (lib/desktop/platform/desktop_spatial_video_api.dart): supported on Windows when
// libmpv loaded, the message that it comes later elsewhere; open pushes the Spatial route with what the viewer asked
// for (the headers dropped) and returns at once; the closing of the route reaches whoever listens to
// SpatialVideoEvents, as the closing of the phones' native players does, and so SpatialVideoSession.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/platform/desktop_spatial_video_api.dart';
import 'package:immich_mobile/desktop/spatial/spatial_player_route.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';

class _Events implements SpatialVideoEvents {
  final closings = <(int, bool, SpatialStereoLayout, SpatialProjection)>[];

  @override
  void closed(int positionMs, bool wasPlaying, SpatialStereoLayout layout, SpatialProjection projection) =>
      closings.add((positionMs, wasPlaying, layout, projection));
}

SpatialOpenRequest _request() => SpatialOpenRequest(
  url: 'https://demo.immich.app/api/assets/1/original',
  headers: const {'x-immich-user-token': 'secret'},
  title: 'concert.SBS.mp4',
  layout: SpatialStereoLayout.sideBySide,
  projection: SpatialProjection.equirectangular180,
  startPositionMs: 4200,
  autoplay: false,
  debugOverlay: true,
  labels: const {},
  fallbackUrl: 'https://demo.immich.app/api/assets/1/video/playback',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('supported on Windows with libmpv, and only there', () async {
    final windows = await DesktopSpatialVideoApi(windows: true, videoAvailable: () => true).capabilities();
    expect(windows.supported, isTrue);
    expect(windows.cameraPermissionGranted, isTrue, reason: 'Windows has no prompt: the page tells when it is off');
    final linux = await DesktopSpatialVideoApi(windows: false, videoAvailable: () => true).capabilities();
    expect(linux.supported, isFalse);
    expect(linux.reason, 'desktop', reason: 'the viewer then says it comes in a later version');
    final noLibmpv = await DesktopSpatialVideoApi(windows: true, videoAvailable: () => false).capabilities();
    expect(noLibmpv.supported, isFalse);
  });

  testWidgets('open pushes the Spatial route with the request, and returns at once', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    SpatialPlayerArgs? pushed;
    SpatialClosedCallback? onClosed;
    await tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: const SizedBox()));
    final api = DesktopSpatialVideoApi(
      navigator: () => navigator,
      windows: true,
      videoAvailable: () => true,
      routeFor: (args, closed) {
        pushed = args;
        onClosed = closed;
        return MaterialPageRoute<void>(builder: (_) => const Text('Spatial'));
      },
    );
    await api.open(_request());
    await tester.pumpAndSettle();
    expect(find.text('Spatial'), findsOneWidget);
    expect(pushed!.url, 'https://demo.immich.app/api/assets/1/original');
    expect(pushed!.title, 'concert.SBS.mp4');
    expect(pushed!.layout, SpatialStereoLayout.sideBySide);
    expect(pushed!.projection, SpatialProjection.equirectangular180);
    expect(pushed!.start, const Duration(milliseconds: 4200));
    expect(pushed!.autoplay, isFalse);
    expect(pushed!.debugOverlay, isTrue);
    expect(pushed!.fallbackUrl, 'https://demo.immich.app/api/assets/1/video/playback');
    expect(onClosed, DesktopSpatialVideoApi.reportClosed);
  });

  test('open refuses off Windows and without a navigator, as a phone without the player', () async {
    expect(
      () => DesktopSpatialVideoApi(windows: false, videoAvailable: () => true).open(_request()),
      throwsA(isA<PlatformException>()),
    );
    expect(
      () => DesktopSpatialVideoApi(windows: true, videoAvailable: () => true).open(_request()),
      throwsA(isA<PlatformException>()),
    );
  });

  test('the closing reaches the handler of SpatialVideoEvents, as from a native player', () async {
    final events = _Events();
    SpatialVideoEvents.setUp(events);
    addTearDown(() => SpatialVideoEvents.setUp(null));
    DesktopSpatialVideoApi.reportClosed(
      12345,
      true,
      SpatialStereoLayout.topBottomSwapped,
      SpatialProjection.equirectangular,
    );
    await Future<void>.delayed(Duration.zero);
    expect(events.closings, [(12345, true, SpatialStereoLayout.topBottomSwapped, SpatialProjection.equirectangular)]);
  });
}
