// The clips of a day: under the hours of the camera's time (Europe/Brussels here, whatever the zone of the test), with
// their time, length, kind and copy on this device; a clip is fetched with its progress and a Cancel before it opens
// alone in the video page; a failure is told on the sheet; a kept copy opens at once and is deleted by a long press.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/presentation/pages/camera/camera_day.page.dart';
import 'package:timezone/data/latest.dart';

import 'camera_fakes.dart';

void main() {
  setUpAll(initializeTimeZones);

  late CameraTestStorage storage;
  late FakeTapoRecordings recordings;

  // 2026-09-18 in Brussels (UTC+2): 00:11:00, 04:53:20 and 18:46:40
  final motion = fakeClip(1789683060, 1789683144);
  final person = fakeClip(1789700000, 1789700060, kind: TapoClipKind.person);
  final continuous = fakeClip(1789750000, 1789750600, kind: TapoClipKind.continuous);

  setUp(() {
    recordings = FakeTapoRecordings(
      clipsByDay: {
        '2026-09-18': [motion, person, continuous],
      },
    );
  });

  tearDown(() => storage.dispose());

  Future<void> pump(WidgetTester tester, {String day = '2026-09-18'}) async {
    storage = await CameraTestStorage.create(sources: [cameraSource()]);
    await pumpCameraApp(
      tester,
      home: CameraDayPage(sourceId: cameraId, day: day),
      overrides: [
        ...storage.overrides,
        ...cameraOverrides(recordings: recordings),
      ],
    );
  }

  testWidgets('lists the clips under the hours of the camera, with their time, length and kind', (tester) async {
    await pump(tester);
    expect(find.text('Friday, September 18, 2026'), findsOneWidget);
    expect(find.byKey(const Key('camera_hour_0')), findsOneWidget);
    expect(find.byKey(const Key('camera_hour_4')), findsOneWidget);
    expect(find.byKey(const Key('camera_hour_18')), findsOneWidget);
    expect(find.textContaining('00:11:00'), findsOneWidget);
    expect(find.textContaining('1:24'), findsOneWidget);
    expect(find.textContaining('18:46:40'), findsOneWidget);
    expect(find.text('Motion'), findsOneWidget);
    expect(find.text('Person'), findsOneWidget);
    expect(find.text('Continuous'), findsOneWidget);
    expect(recordings.thumbnailsAsked, containsAll([motion.path, person.path]));
  });

  testWidgets('fetches a clip with its progress, then opens it alone in the video page', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('camera_clip_1789683060')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Getting the video from the camera: 0%'), findsOneWidget);
    recordings.fetchProgress!(0.5);
    await tester.pump();
    expect(find.text('Getting the video from the camera: 50%'), findsOneWidget);
    recordings.fetching!.complete();
    await tester.pumpAndSettle();
    expect(find.text('video $cameraId ${motion.path} alone'), findsOneWidget);
  });

  testWidgets('cancels a fetch', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('camera_clip_1789683060')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('camera_clip_cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('camera_clip_fetching')), findsNothing);
    expect(find.textContaining('video '), findsNothing);
    expect(recordings.fetched, isEmpty);
  });

  testWidgets('tells why a fetch failed', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('camera_clip_1789683060')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    recordings.fetching!.completeError(const TapoCameraException(TapoErrorKind.busy, code: -52405));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'The video could not be fetched: The camera is busy with another viewer, such as the Tapo app. Try again in a minute.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('camera_clip_cancel')));
    await tester.pumpAndSettle();
    expect(find.textContaining('video '), findsNothing);
  });

  testWidgets('opens a kept copy at once, and deletes it by a long press', (tester) async {
    recordings.fetched.add(person.path);
    await pump(tester);
    expect(find.text('On this device'), findsOneWidget);
    await tester.longPress(find.byKey(const Key('camera_clip_1789700000')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('camera_clip_delete_copy')));
    await tester.pumpAndSettle();
    expect(recordings.deleted, [person.path]);
    expect(find.text('On this device'), findsNothing);

    recordings.fetched.add(continuous.path);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('camera_clip_1789750000')));
    await tester.pumpAndSettle();
    expect(find.text('video $cameraId ${continuous.path} alone'), findsOneWidget);
    expect(recordings.fetching, isNull);
  });

  testWidgets('says when the day has no clip', (tester) async {
    await pump(tester, day: '2026-09-17');
    expect(find.byKey(const Key('camera_day_empty')), findsOneWidget);
  });
}
