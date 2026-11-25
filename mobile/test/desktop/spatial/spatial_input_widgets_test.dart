// What a Spatial 2.5D view shows about the head tracking (lib/desktop/spatial/spatial_input_widgets.dart), over a fake
// webcam: the card of the first time, the camera icon while the webcam is open and gone with it, the webcam closed
// when the view is covered by another page or leaves, the messages of the problems with "Try the webcam again", and
// the text of each problem on each system.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/spatial/head_position_source.dart';
import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immich_mobile/desktop/spatial/spatial_input_widgets.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';

import '../../widget_tester_extensions.dart';
import 'head_fakes.dart';

class _Store implements DesktopSpatialSettingsStore {
  _Store(this.settings);

  DesktopSpatialSettings settings;

  @override
  DesktopSpatialSettings read() => settings;

  @override
  Future<void> write(DesktopSpatialSettings value) async => settings = value;
}

/// The app's English texts, from a widget of the page
Translations tr(WidgetTester tester) => tester.element(find.byType(Scaffold).first).t;

void main() {
  late FakeHeadSource source;
  late HeadPositionSource head;

  HeadPositionSource make(DesktopSpatialSettings settings) => head = HeadPositionSource(
    store: _Store(settings),
    source: source,
    away: ValueNotifier(false),
    observeLifecycle: false,
  );

  Widget view({bool shown = true}) => TickerMode(
    enabled: shown,
    child: Scaffold(
      body: SizedBox(
        width: 800,
        height: 600,
        child: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.black)),
            Positioned.fill(child: HeadTrackingOverlay(source: head)),
          ],
        ),
      ),
    ),
  );

  setUp(() => source = FakeHeadSource());

  tearDown(() => head.close());

  testWidgets('the card of the first time, then the camera icon while the webcam is open', (tester) async {
    make(const DesktopSpatialSettings());
    await tester.pumpConsumerWidget(view());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('spatial_consent_card')), findsOneWidget);
    expect(find.text(tr(tester).desktop_spatial_camera_intro), findsOneWidget);
    expect(find.byKey(const Key('spatial_camera_indicator')), findsNothing);
    expect(source.sessions, isEmpty);

    await tester.tap(find.byKey(const Key('spatial_consent_webcam')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('spatial_consent_card')), findsNothing);
    expect(source.sessions, hasLength(1));
    expect(find.byKey(const Key('spatial_camera_indicator')), findsOneWidget);
    final tooltip = tester.widget<Tooltip>(find.byKey(const Key('spatial_camera_indicator')));
    expect(tooltip.message, tr(tester).desktop_spatial_camera_on);

    // Covered by another page: the webcam closes and its icon goes
    await tester.pumpConsumerWidget(view(shown: false));
    await tester.pumpAndSettle();
    expect(source.last.released, isTrue);
    expect(find.byKey(const Key('spatial_camera_indicator')), findsNothing);
    // Shown again: opened again
    await tester.pumpConsumerWidget(view());
    await tester.pumpAndSettle();
    expect(source.sessions, hasLength(2));

    // The view leaves: closed
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    expect(source.last.released, isTrue);
  });

  testWidgets('"Use the mouse" on the card: no webcam, the head unusable for this view', (tester) async {
    make(const DesktopSpatialSettings());
    await tester.pumpConsumerWidget(view());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('spatial_consent_mouse')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('spatial_consent_card')), findsNothing);
    expect(source.sessions, isEmpty);
    expect(head.usable, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a problem shows its message, and "Try the webcam again" tries once more', (tester) async {
    make(const DesktopSpatialSettings(consent: true));
    await tester.pumpConsumerWidget(view());
    await tester.pumpAndSettle();
    source.last.fail(HeadTrackerStatus.cameraBusy);
    await tester.pumpAndSettle();
    expect(find.text(tr(tester).desktop_spatial_camera_busy), findsOneWidget);
    expect(find.byKey(const Key('spatial_camera_indicator')), findsNothing);
    await tester.tap(find.byKey(const Key('spatial_try_again')));
    await tester.pumpAndSettle();
    expect(source.sessions, hasLength(2));
    expect(find.text(tr(tester).desktop_spatial_camera_busy), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('each problem has its text on each system, the camera off one naming the system', (tester) async {
    make(const DesktopSpatialSettings());
    await tester.pumpConsumerWidget(const Scaffold());
    final context = tester.element(find.byType(Scaffold).first);
    for (final problem in SpatialTrackingProblem.values) {
      for (final platform in [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) {
        final text = spatialProblemText(context, problem, platform: platform);
        expect(text, isNotEmpty);
        for (final word in ['experimental', 'beta', 'preview']) {
          expect(text.toLowerCase(), isNot(contains(word)));
        }
      }
    }
    expect(
      spatialProblemText(context, SpatialTrackingProblem.cameraOff, platform: TargetPlatform.windows),
      contains('Windows'),
    );
    expect(
      spatialProblemText(context, SpatialTrackingProblem.cameraOff, platform: TargetPlatform.macOS),
      contains('Privacy'),
    );
  });
}
