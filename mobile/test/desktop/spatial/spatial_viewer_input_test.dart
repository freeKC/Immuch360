// The input of a Spatial 2.5D view and the lifecycle of its webcam (lib/desktop/spatial/spatial_viewer_input.dart),
// over fake webcams (head_fakes.dart) and the recorded landmark track of the clip
// (test/fixtures/spatial/painted-head-12s.track): the webcam opens only while the view is on screen, the head chosen,
// the webcam allowed and agreed to, the window shown and someone there; it closes as soon as one of those stops; the
// card of the first time; the mouse while the head cannot be used; the problems; the other inputs; the settings.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/desktop/spatial/spatial_viewer_input.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';

import 'head_fakes.dart';

class MemoryStore implements DesktopSpatialSettingsStore {
  MemoryStore([this.settings = const DesktopSpatialSettings()]);

  DesktopSpatialSettings settings;
  int writes = 0;

  @override
  DesktopSpatialSettings read() => settings;

  @override
  Future<void> write(DesktopSpatialSettings value) async {
    settings = value;
    writes++;
  }
}

/// The samples of the recorded track, as the native tracker gives them: the eye midpoint, head_x and its One Euro
/// filter (the Dart copy, which the native one matches: head_tracker_native_test.dart)
List<HeadSample> trackSamples() {
  final filter = HeadXFilter();
  final samples = <HeadSample>[];
  var sequence = 0;
  var lastFace = 0;
  for (final line in File('test/fixtures/spatial/painted-head-12s.track').readAsLinesSync()) {
    final text = line.split('#').first.trim();
    if (text.isEmpty) {
      continue;
    }
    final numbers = text.split(RegExp(r'\s+')).map(double.parse).toList();
    final timeUs = numbers.first.round();
    sequence++;
    if (numbers.length >= 5) {
      lastFace = timeUs;
      final eyeX = numbers[2];
      final headX = 0.5 - eyeX;
      final filtered = filter.addFace(headX, timeUs * 1000);
      samples.add(
        HeadSample(
          timeUs: timeUs,
          sequence: sequence,
          faceX: eyeX,
          faceY: numbers[3],
          faceWidth: numbers[4] * 3,
          faceHeight: numbers[4] * 3,
          confidence: numbers[1] / 100,
          state: HeadFaceState.face,
          detectUs: 2000,
          frameWidth: 320,
          frameHeight: 240,
          faces: 1,
          eyeX: eyeX,
          eyeY: numbers[3],
          eyeDistance: numbers[4],
          headPosition: headX,
          filteredX: filtered,
        ),
      );
    } else {
      final lost = timeUs - lastFace > 300000;
      if (lost) {
        filter.lose();
      }
      samples.add(sample(sequence, timeUs: timeUs, state: lost ? HeadFaceState.lost : HeadFaceState.noFace));
    }
  }
  return samples;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeHeadSource source;
  late MemoryStore store;
  late ValueNotifier<bool> away;
  late Duration now;
  late SpatialViewerInput input;

  SpatialViewerInput make({DesktopSpatialSettings? settings, SpatialHeadSource? headSource, bool noSource = false}) {
    store = MemoryStore(settings ?? const DesktopSpatialSettings());
    input = SpatialViewerInput(
      store: store,
      source: noSource ? null : headSource ?? source,
      away: away,
      clock: () => now,
      observeLifecycle: false,
    );
    return input;
  }

  setUp(() {
    source = FakeHeadSource(list: const [fakeInfrared, fakeWebcam]);
    away = ValueNotifier(false);
    now = Duration.zero;
  });

  tearDown(() => input.dispose());

  bool cameraOpen() => source.sessions.isNotEmpty && !source.last.closing;

  group('the webcam', () {
    test('waits for the card of the first time; meanwhile the mouse moves the view', () async {
      make();
      expect(input.chosen, ViewerInput.head);
      expect(input.needsConsent, isFalse, reason: 'not on screen yet');
      input.attach();
      await settle();
      expect(input.needsConsent, isTrue);
      expect(input.input, ViewerInput.mouse);
      expect(source.sessions, isEmpty, reason: 'no webcam before the user agreed');
      expect(source.listings, 0, reason: 'not even listed');
      await input.acceptConsent();
      await settle();
      expect(store.settings.consent, isTrue);
      expect(input.needsConsent, isFalse);
      expect(cameraOpen(), isTrue);
      expect(source.last.camera, fakeWebcam, reason: 'never the infrared camera by default');
      expect(input.cameraOpen, isTrue);
      expect(input.input, ViewerInput.head);
    });

    test('"Use the mouse" on the card: no webcam, the mouse stays the choice', () async {
      make()..attach();
      await input.declineConsent();
      await settle();
      expect(input.needsConsent, isFalse);
      expect(input.chosen, ViewerInput.mouse);
      expect(store.settings.input, ViewerInput.mouse);
      expect(store.settings.consent, isFalse);
      expect(source.sessions, isEmpty);
    });

    test('opens only while the view is on screen', () async {
      make(settings: const DesktopSpatialSettings(consent: true));
      await settle();
      expect(source.sessions, isEmpty, reason: 'not attached yet');
      input.attach();
      await settle();
      expect(cameraOpen(), isTrue);
      input.detach();
      await settle();
      expect(source.last.closing, isTrue);
      expect(source.last.released, isTrue, reason: 'the light off once the page is gone');
      input.attach();
      await settle();
      expect(source.sessions, hasLength(2));
      expect(cameraOpen(), isTrue);
    });

    test('closes when the window is minimised or hidden, opens again when it is restored', () async {
      make(settings: const DesktopSpatialSettings(consent: true))..attach();
      await settle();
      input.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await settle();
      expect(cameraOpen(), isTrue, reason: 'a window without the focus is still shown');
      input.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await settle();
      expect(source.last.released, isTrue);
      input.didChangeAppLifecycleState(AppLifecycleState.paused);
      input.didChangeAppLifecycleState(AppLifecycleState.inactive);
      input.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settle();
      expect(source.sessions, hasLength(2));
      expect(cameraOpen(), isTrue);
    });

    test('closes while the session is locked or the display off', () async {
      make(settings: const DesktopSpatialSettings(consent: true))..attach();
      await settle();
      away.value = true;
      await settle();
      expect(source.last.released, isTrue);
      expect(input.cameraOpen, isFalse);
      away.value = false;
      await settle();
      expect(source.sessions, hasLength(2));
      expect(cameraOpen(), isTrue);
    });

    test('"Use the webcam for head tracking" off closes it, and the mouse moves the view', () async {
      make(settings: const DesktopSpatialSettings(consent: true))..attach();
      await settle();
      await input.setWebcamAllowed(false);
      await settle();
      expect(source.last.released, isTrue);
      expect(input.input, ViewerInput.mouse);
      expect(input.needsConsent, isFalse);
      expect(store.settings.webcam, isFalse);
      await input.setWebcamAllowed(true);
      await settle();
      expect(cameraOpen(), isTrue);
    });

    test('a refusal of the system is a problem: the mouse moves the view, nothing retries but the user', () async {
      make(settings: const DesktopSpatialSettings(consent: true))..attach();
      await settle();
      source.last.fail(HeadTrackerStatus.accessDenied);
      await settle();
      expect(input.problem, SpatialTrackingProblem.cameraOff);
      expect(input.input, ViewerInput.mouse);
      expect(input.cameraOpen, isFalse);
      input.detach();
      input.attach();
      await settle();
      expect(source.sessions, hasLength(1), reason: 'never reopened by itself');
      await input.retry();
      await settle();
      expect(source.sessions, hasLength(2));
      expect(input.problem, isNull);
      expect(input.input, ViewerInput.head);
    });

    test('no webcam: a problem, and the mouse', () async {
      source.list = const [fakeInfrared];
      make(settings: const DesktopSpatialSettings(consent: true))..attach();
      await settle();
      expect(input.problem, SpatialTrackingProblem.noCamera);
      expect(input.input, ViewerInput.mouse);
      expect(source.sessions, isEmpty);
    });

    test('a computer without the tracker library offers no head and asks nothing', () async {
      make(noSource: true)..attach();
      await settle();
      expect(input.headSupported, isFalse);
      expect(input.needsConsent, isFalse);
      expect(input.input, ViewerInput.mouse);
    });

    test('the arrow keys take over for this view only and close the webcam', () async {
      make(settings: const DesktopSpatialSettings(consent: true))..attach();
      await settle();
      input.step(SpatialViewerInput.keyStep);
      await settle();
      expect(input.input, ViewerInput.keys);
      expect(input.position.x, closeTo(0.55, 1e-9));
      expect(source.last.released, isTrue);
      expect(store.settings.input, isNull, reason: 'the choice kept in the settings stays');
    });

    test('the webcam picked in the menu replaces the open one at once', () async {
      make(settings: const DesktopSpatialSettings(consent: true))..attach();
      await settle();
      source.list = const [fakeInfrared, fakeWebcam, fakeExternal];
      await input.setCamera(fakeExternal.id);
      await settle();
      expect(source.sessions, hasLength(2));
      expect(source.last.camera, fakeExternal);
      expect(store.settings.cameraId, fakeExternal.id);
    });
  });

  group('the viewpoint', () {
    test('the head moves it along the recorded track, the face lost brings it back to the middle', () async {
      make(settings: const DesktopSpatialSettings(consent: true))..attach();
      await settle();
      final session = source.last;
      final samples = trackSamples();
      final positions = <ViewerPosition>[];
      for (final value in samples) {
        session.push(value);
        positions.add(input.position);
      }
      // The painted head goes to the right of the frame in its first second, the user's left: the view moves toward
      // the left camera, as on the phones
      final atOneSecond = positions[samples.indexWhere((s) => s.timeUs >= 1000000)];
      expect(atOneSecond.input, ViewerInput.head);
      expect(atOneSecond.tracking, isTrue);
      expect(atOneSecond.x, lessThan(0.4));
      expect(positions.every((p) => p.x >= ViewerPosition.min && p.x <= ViewerPosition.max), isTrue);
      // A second after the face is lost (8.3 s), the view is back in the middle
      final lostIndex = samples.indexWhere((s) => s.lost);
      final settled = samples.indexWhere((s) => s.timeUs >= samples[lostIndex].timeUs + 1000000);
      expect(positions[settled].x, closeTo(0.5, 0.02));
      expect(positions[settled].tracking, isFalse);
    });

    test('reversed, the same head moves it the other way', () async {
      make(settings: const DesktopSpatialSettings(consent: true, reverseHead: true))..attach();
      await settle();
      final session = source.last;
      final samples = trackSamples();
      ViewerPosition? atOneSecond;
      for (final value in samples) {
        session.push(value);
        if (atOneSecond == null && value.timeUs >= 1000000) {
          atOneSecond = input.position;
        }
      }
      expect(atOneSecond!.x, greaterThan(0.6));
    });

    test('the mouse: its x over the picture, smoothed', () {
      make(settings: const DesktopSpatialSettings(input: ViewerInput.mouse))..attach();
      expect(input.position, const ViewerPosition(input: ViewerInput.mouse));
      for (var i = 0; i < 60; i++) {
        now = Duration(milliseconds: 16 * i);
        input.pointer(1);
      }
      expect(input.position.x, closeTo(ViewerPosition.max, 1e-3));
      now += const Duration(milliseconds: 16);
      input.pointer(0);
      expect(input.position.x, greaterThan(ViewerPosition.min), reason: 'filtered, not a jump');
      input.recenter();
      expect(input.position.x, 0.5);
    });

    test('the automatic sway: 0.5 + 0.2 sin(2 pi t / 4 s)', () {
      make(settings: const DesktopSpatialSettings(input: ViewerInput.sway))..attach();
      for (final ms in [0, 500, 1000, 2000, 3000, 3700]) {
        now = Duration(milliseconds: ms);
        expect(input.position.x, closeTo(0.5 + 0.2 * math.sin(2 * math.pi * ms / 4000), 1e-9));
        expect(input.position.input, ViewerInput.sway);
      }
      expect(source.sessions, isEmpty);
    });

    test('the keys: steps within the limits, R in the middle', () {
      make(settings: const DesktopSpatialSettings(input: ViewerInput.keys))..attach();
      for (var i = 0; i < 20; i++) {
        input.step(-SpatialViewerInput.keyStep);
      }
      expect(input.position.x, ViewerPosition.min);
      input.recenter();
      expect(input.position.x, ViewerPosition.centreX);
    });
  });

  group('the settings', () {
    test('are app settings, with their defaults', () {
      const viewer = ViewerConfig();
      final settings = DesktopSpatialSettings.fromViewer(viewer);
      expect(settings, const DesktopSpatialSettings());
      expect(settings.startInput, ViewerInput.head);
      expect(settings.webcam, isTrue, reason: 'on by default, the card still asks first');
      expect(settings.consent, isFalse);
      expect(settings.sensitivity, 3.0);
      const config = AppConfig();
      final changed = config
          .write(SettingsKey.viewerSpatialInput, 'sway')
          .write(SettingsKey.viewerSpatialWebcam, false)
          .write(SettingsKey.viewerSpatialWebcamConsent, true)
          .write(SettingsKey.viewerSpatialCamera, '/dev/video2')
          .write(SettingsKey.viewerSpatialReverseHead, true)
          .write(SettingsKey.viewerSpatialSensitivity, 25);
      expect(
        DesktopSpatialSettings.fromViewer(changed.viewer),
        const DesktopSpatialSettings(
          input: ViewerInput.sway,
          webcam: false,
          consent: true,
          cameraId: '/dev/video2',
          reverseHead: true,
          sensitivity: 2.5,
        ),
      );
      expect(changed.read(SettingsKey.viewerSpatialCamera), '/dev/video2');
      expect(changed.write(SettingsKey.viewerSpatialCamera, null).viewer.spatialCamera, isNull);
      // An unknown input or a sensitivity out of range read back within the limits
      final odd = DesktopSpatialSettings.fromViewer(
        const ViewerConfig(spatialInput: 'telepathy', spatialSensitivity: 99),
      );
      expect(odd.input, isNull);
      expect(odd.sensitivity, HeadViewpoint.maxSensitivity);
      expect(const DesktopSpatialSettings(webcam: false).startInput, ViewerInput.mouse);
    });
  });
}
