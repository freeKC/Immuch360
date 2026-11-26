// The 2.5D photo page of the computers with the head tracked by the webcam (spatial_photo_page.dart over
// head_position_source.dart), on the fake webcams of head_fakes.dart: the head offered and taken by default where a
// webcam is listed, the card of the first time with the webcam closed until the yes, the mouse while the head cannot
// move the view, the camera icon while the webcam is open, the page following the recorded head track of the clip
// (test/fixtures/spatial/painted-head-12s.track), R, the settings over the page closing the webcam, and the webcam
// never opened without the yes. The same track through the tracker's own library and its fake camera "track:" is
// spatial_photo_head_native_test.dart.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/spatial/head_position_source.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_page.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_render.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/desktop/spatial/spatial_viewpoint.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';

import '../../unit/presentation/presentation_context.dart';
import 'head_fakes.dart';
import 'head_position_source_test.dart' show trackSamples;

const _sbs = SpatialPhotoLayout(packing: SpatialPhotoPacking.sideBySide);

/// An image provider that hands over a picture at once
class _ImageOf extends ImageProvider<_ImageOf> {
  const _ImageOf(this.image);

  final ui.Image image;

  @override
  Future<_ImageOf> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_ImageOf key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: image.clone())));
}

Future<ui.Image> _picture(int width, int height, Color color) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = color);
  return recorder.endRecording().toImage(width, height);
}

void main() {
  late PresentationContext context;
  late ui.Image frame;
  late ui.Image map;
  late ui.FragmentProgram program;
  late FakeHeadSource webcams;
  var now = Duration.zero;

  /// The head sources the page made, the newest last
  final heads = <HeadPositionSource>[];

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    frame = await _picture(64, 16, const Color(0xFF336699));
    map = await _picture(32, 16, const Color(0xFF808080));
    program = await ui.FragmentProgram.fromAsset(spatialPhotoShaderAsset);
  });

  setUp(() async {
    context = await PresentationContext.create();
    now = Duration.zero;
    webcams = FakeHeadSource(list: const [fakeInfrared, fakeWebcam]);
    heads.clear();
  });

  tearDown(() async {
    for (final head in heads) {
      await head.close();
    }
    await context.dispose();
  });

  List<Override> overrides({bool tracker = true}) => [
    spatialPhotoProgramProvider.overrideWithValue(() async => program),
    spatialPhotoDepthProvider.overrideWithValue(
      (image, layout) async => SpatialPhotoDepth(map: map.clone(), minimum: -2, range: 4),
    ),
    spatialHeadSourceProvider.overrideWithValue(tracker ? webcams : null),
    // The app's factory, with the app's settings, but no session presence nor lifecycle of a real window
    headPositionSourceFactoryProvider.overrideWithValue(
      tracker
          ? () {
              final head = HeadPositionSource(
                store: const AppSpatialSettingsStore(),
                source: webcams,
                away: ValueNotifier(false),
                observeLifecycle: false,
              );
              heads.add(head);
              return head;
            }
          : null,
    ),
  ];

  Future<void> pumpPage(WidgetTester tester, {bool tracker = true}) async {
    await tester.pumpTestWidget(
      context,
      SpatialPhotoPage(image: _ImageOf(frame), layout: _sbs, title: 'salon_3D_LRF_Full_SBS.jpg', clock: () => now),
      overrides: overrides(tracker: tracker),
      expectSettle: false,
    );
    // The shader, the depth, the listing of the webcams and the start of the webcam come in futures; the overlay
    // attaches the head after a frame
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
  }

  SpatialPhotoPainter painter(WidgetTester tester) =>
      tester.widget<CustomPaint>(find.byKey(const Key('spatial_photo_canvas'))).painter! as SpatialPhotoPainter;

  String status(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('spatial_photo_status'))).data!;

  Future<void> advance(WidgetTester tester, int ms) async {
    now += Duration(milliseconds: ms);
    await tester.pump(Duration(milliseconds: ms));
  }

  /// The webcam is open: a session that has not begun to close
  bool cameraOpen() => webcams.sessions.isNotEmpty && !webcams.last.closing;

  Finder card() => find.byKey(const Key('spatial_consent_card'));
  Finder indicator() => find.byKey(const Key('spatial_camera_indicator'));

  const mouseHint = 'Move the pointer across the picture to look around the scene; R recenters';
  const headHint = 'Move your head: the scene moves as if seen through a window; R recenters';

  group('the head in the 2.5D photo page', () {
    testWidgets('offered and taken by default once a webcam is listed; the card, and no webcam before the yes', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(find.text('Head (webcam)'), findsOneWidget, reason: 'the head is the source in the bar');
      expect(card(), findsOneWidget);
      expect(find.text('Follow your head with the webcam?'), findsOneWidget);
      expect(webcams.listings, 1, reason: 'listed once, to know a webcam is there');
      expect(webcams.sessions, isEmpty, reason: 'no webcam before the user agreed');
      expect(indicator(), findsNothing);
      // Meanwhile the mouse moves the view
      expect(status(tester), mouseHint);
      final canvas = tester.getRect(find.byKey(const Key('spatial_photo_canvas')));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset(canvas.center.dx, canvas.top + 4));
      await advance(tester, 16);
      await mouse.moveTo(Offset(canvas.right - 1, canvas.top + 4));
      for (var i = 0; i < 60; i++) {
        await advance(tester, 16);
      }
      expect(painter(tester).viewpoint.value, closeTo(spatialViewpointMax, 0.01));
      await mouse.removePointer();
      await advance(tester, 1100);

      await tester.tap(find.byKey(const Key('spatial_consent_webcam')));
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      expect(SettingsRepository.instance.appConfig.viewer.spatialWebcamConsent, isTrue);
      expect(card(), findsNothing);
      expect(cameraOpen(), isTrue);
      expect(webcams.last.camera, fakeWebcam, reason: 'never the infrared camera by default');
      expect(indicator(), findsOneWidget);
      expect(
        tester.widget<Tooltip>(indicator()).message,
        'Webcam on: its pictures stay in memory, only the position of your face is used',
      );
      expect(status(tester), headHint);

      // Closing the page closes the webcam
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(webcams.last.closing, isTrue);
      expect(webcams.last.released, isTrue);
    });

    testWidgets('follows the recorded head track of the clip, glides back when the face is lost, R recenters', (
      tester,
    ) async {
      await SettingsRepository.instance.write(SettingsKey.viewerSpatialWebcamConsent, true);
      await pumpPage(tester);
      expect(card(), findsNothing);
      expect(webcams.listings, 1, reason: 'listed by the start of the webcam only');
      expect(cameraOpen(), isTrue, reason: 'the yes was given before: the webcam opens with the page');
      expect(indicator(), findsOneWidget);
      final head = heads.single;
      final session = webcams.last;

      final samples = trackSamples();
      final base = now;
      final seen = <int, double>{};
      HeadSample? lost;
      for (final sample in samples) {
        now = base + Duration(microseconds: sample.timeUs);
        session.push(sample);
        await tester.pump(const Duration(milliseconds: 1));
        final p = painter(tester).viewpoint.value;
        seen[sample.timeUs] = p;
        expect(p, inInclusiveRange(spatialViewpointMin, spatialViewpointMax));
        if ((sample.timeUs >= 1000000 && sample.timeUs < 1066666) ||
            (sample.timeUs >= 3000000 && sample.timeUs < 3066666)) {
          // Past the glide of the first face, the view is where the head's position asks, at once (the tracker filters)
          expect(head.latest!.seen, isTrue);
          expect(p, closeTo(spatialViewpointOf(head.latest!.x), 1e-9));
        }
        if (sample.lost) {
          lost = sample;
          break;
        }
      }
      // The painted head goes to the right of the frame in its first second (the user's left): the view moves to the
      // left eye; at 3 s it is on the other side
      expect(seen[1000000], lessThan(spatialViewpointCentre));
      expect(seen[3000000], greaterThan(spatialViewpointCentre));
      // The face lost in the gap of the clip: the view glides back to the centre within a second
      expect(lost, isNotNull);
      expect(head.latest!.seen, isFalse);
      for (var i = 0; i < 11; i++) {
        await advance(tester, 100);
      }
      expect(painter(tester).viewpoint.value, closeTo(spatialViewpointCentre, 1e-9));

      // R: the next face is the centre
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      final found = samples.firstWhere((s) => s.timeUs > lost!.timeUs && s.hasFace);
      now += const Duration(milliseconds: 33);
      session.push(found);
      await tester.pump(const Duration(milliseconds: 1));
      expect(head.latest!.x, closeTo(0.0, 1e-6), reason: 'the head where R was pressed is the centre');
    });

    testWidgets('"Use the mouse": no webcam, the mouse moves the view, and the card comes back next time', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(card(), findsOneWidget);
      await tester.tap(find.byKey(const Key('spatial_consent_mouse')));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(card(), findsNothing);
      expect(webcams.sessions, isEmpty);
      expect(indicator(), findsNothing);
      expect(status(tester), mouseHint);
      expect(SettingsRepository.instance.appConfig.viewer.spatialWebcamConsent, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await pumpPage(tester);
      expect(card(), findsOneWidget, reason: 'no answer was kept');
      expect(webcams.sessions, isEmpty, reason: 'the webcam is never opened without the yes');
    });

    testWidgets(
      'the webcam off in the settings: no card, no webcam, not even listed; the head picked takes the mouse',
      (tester) async {
        await SettingsRepository.instance.write(SettingsKey.viewerSpatialWebcam, false);
        await pumpPage(tester);
        expect(find.text('Mouse'), findsOneWidget);
        expect(card(), findsNothing);
        expect(webcams.listings, 0);

        await tester.tap(find.byKey(const Key('spatial_photo_move_with')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('spatial_photo_move_head')), findsOneWidget);
        await tester.tap(find.byKey(const Key('spatial_photo_move_head')));
        await tester.pumpAndSettle();
        expect(SettingsRepository.instance.appConfig.viewer.spatialMoveWith, ViewerPositionKind.head);
        expect(card(), findsNothing);
        expect(webcams.sessions, isEmpty);
        expect(status(tester), mouseHint);
      },
    );

    testWidgets('no webcam listed: the mouse, and no card', (tester) async {
      webcams.list = const [fakeInfrared];
      await pumpPage(tester);
      expect(webcams.listings, 1);
      expect(find.text('Mouse'), findsOneWidget);
      expect(card(), findsNothing);
      expect(webcams.sessions, isEmpty);
    });

    testWidgets('no head tracker on this computer: no head in the menu', (tester) async {
      await pumpPage(tester, tracker: false);
      await tester.tap(find.byKey(const Key('spatial_photo_move_with')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spatial_photo_move_head')), findsNothing);
      expect(find.byKey(const Key('spatial_photo_move_mouse')), findsOneWidget);
    });

    testWidgets('the settings over the page close the webcam, which opens again on the way back', (tester) async {
      await SettingsRepository.instance.write(SettingsKey.viewerSpatialWebcamConsent, true);
      await pumpPage(tester);
      expect(cameraOpen(), isTrue);
      await tester.tap(find.byKey(const Key('spatial_photo_settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spatial_settings_page')), findsOneWidget);
      expect(find.text('Move the view with'), findsOneWidget);
      expect(find.text('Use the webcam for head tracking'), findsOneWidget);
      expect(cameraOpen(), isFalse, reason: 'the page is covered: its webcam closes');

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(cameraOpen(), isTrue);
      expect(webcams.sessions, hasLength(2));
      expect(webcams.busy, 0);

      // The webcam turned off there holds once back on the page
      await tester.tap(find.byKey(const Key('spatial_photo_settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use the webcam for head tracking'));
      await tester.pumpAndSettle();
      expect(SettingsRepository.instance.appConfig.viewer.spatialWebcam, isFalse);
      await tester.pageBack();
      // The mouse takes over: the view glides back to the centre on the page's clock
      for (var i = 0; i < 15; i++) {
        await advance(tester, 100);
      }
      expect(cameraOpen(), isFalse);
      expect(webcams.sessions, hasLength(2));
      expect(status(tester), mouseHint);
    });
  });
}
