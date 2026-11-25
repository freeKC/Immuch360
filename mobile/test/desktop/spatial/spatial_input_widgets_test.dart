// What a Spatial 2.5D view shows about its input (lib/desktop/spatial/spatial_input_widgets.dart), over a fake webcam:
// the card of the first time, the camera icon while the webcam is open and gone with it, the webcam closed when the
// view is covered by another page or leaves, the arrow keys and R, the mouse over the picture, the messages of the
// problems with the button of the camera settings where the system has one.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immich_mobile/desktop/spatial/spatial_input_widgets.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/desktop/spatial/spatial_viewer_input.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';

import 'head_fakes.dart';

class _Store implements DesktopSpatialSettingsStore {
  _Store(this.settings);

  DesktopSpatialSettings settings;

  @override
  DesktopSpatialSettings read() => settings;

  @override
  Future<void> write(DesktopSpatialSettings value) async => settings = value;
}

void main() {
  late FakeHeadSource source;
  late SpatialViewerInput input;

  SpatialViewerInput make(DesktopSpatialSettings settings) => input = SpatialViewerInput(
    store: _Store(settings),
    source: source,
    away: ValueNotifier(false),
    observeLifecycle: false,
  );

  Widget page({bool shown = true}) => MaterialApp(
    home: TickerMode(
      enabled: shown,
      child: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: SpatialViewerInputArea(
            input: input,
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    ),
  );

  setUp(() => source = FakeHeadSource());

  testWidgets('the card of the first time, then the camera icon while the webcam is open', (tester) async {
    make(const DesktopSpatialSettings());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('spatial_consent_card')), findsOneWidget);
    expect(find.text(t.desktop_spatial_camera_intro), findsOneWidget);
    expect(find.byKey(const Key('spatial_camera_indicator')), findsNothing);
    expect(source.sessions, isEmpty);

    await tester.tap(find.byKey(const Key('spatial_consent_webcam')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('spatial_consent_card')), findsNothing);
    expect(source.sessions, hasLength(1));
    expect(find.byKey(const Key('spatial_camera_indicator')), findsOneWidget);
    final tooltip = tester.widget<Tooltip>(find.byKey(const Key('spatial_camera_indicator')));
    expect(tooltip.message, t.desktop_spatial_camera_on);

    // Covered by another page: the webcam closes and its icon goes
    await tester.pumpWidget(page(shown: false));
    await tester.pumpAndSettle();
    expect(source.last.released, isTrue);
    expect(find.byKey(const Key('spatial_camera_indicator')), findsNothing);
    // Shown again: opened again
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(source.sessions, hasLength(2));

    // The page leaves: closed
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    expect(source.last.released, isTrue);
    input.dispose();
  });

  testWidgets('"Use the mouse" on the card: the pointer over the picture moves the view', (tester) async {
    make(const DesktopSpatialSettings());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('spatial_consent_mouse')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('spatial_consent_card')), findsNothing);
    expect(source.sessions, isEmpty);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(790, 300));
    await gesture.moveTo(const Offset(795, 300));
    await tester.pump();
    expect(input.position.input, ViewerInput.mouse);
    expect(input.position.x, greaterThan(0.8));
    await gesture.removePointer();
    input.dispose();
  });

  testWidgets('the arrow keys step the viewpoint and R recenters', (tester) async {
    make(const DesktopSpatialSettings(input: ViewerInput.keys));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(input.position.x, closeTo(0.6, 1e-9));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    expect(input.position.x, 0.5);
    await tester.pumpWidget(const SizedBox());
    input.dispose();
  });

  testWidgets('a problem shows its message, and "Try the webcam again" tries once more', (tester) async {
    make(const DesktopSpatialSettings(consent: true));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    source.last.fail(HeadTrackerStatus.cameraBusy);
    await tester.pumpAndSettle();
    expect(find.text(t.desktop_spatial_camera_busy), findsOneWidget);
    expect(find.byKey(const Key('spatial_camera_indicator')), findsNothing);
    await tester.tap(find.byKey(const Key('spatial_try_again')));
    await tester.pumpAndSettle();
    expect(source.sessions, hasLength(2));
    expect(find.text(t.desktop_spatial_camera_busy), findsNothing);
    await tester.pumpWidget(const SizedBox());
    input.dispose();
  });

  test('each problem has its text on each system, the camera off one naming the system', () {
    for (final problem in SpatialTrackingProblem.values) {
      for (final platform in [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) {
        final text = spatialProblemText(problem, platform: platform);
        expect(text, isNotEmpty);
        expect(text.toLowerCase(), isNot(contains('experimental')));
      }
    }
    expect(spatialProblemText(SpatialTrackingProblem.cameraOff, platform: TargetPlatform.windows), contains('Windows'));
    expect(spatialProblemText(SpatialTrackingProblem.cameraOff, platform: TargetPlatform.macOS), contains('Privacy'));
  });
}
