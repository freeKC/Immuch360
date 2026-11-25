// The head as a source of viewer positions and the lifecycle of its webcam (lib/desktop/spatial/
// head_position_source.dart), over fake webcams (head_fakes.dart) and the recorded landmark track of the clip
// (test/fixtures/spatial/painted-head-12s.track): the webcam opens only while a view shows the source, the window is
// shown, someone is there, the webcam is allowed and agreed to; it closes as soon as one of those stops; the card of
// the first time; usable false (the view takes the mouse) while the head cannot be used; the problems; the positions
// of the track, their centre, their loss; the settings.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/spatial/head_position_source.dart';
import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';

import 'head_fakes.dart';

class MemoryStore implements DesktopSpatialSettingsStore {
  MemoryStore([this.settings = const DesktopSpatialSettings()]);

  DesktopSpatialSettings settings;

  @override
  DesktopSpatialSettings read() => settings;

  @override
  Future<void> write(DesktopSpatialSettings value) async => settings = value;
}

/// The samples of the recorded track, as the native tracker gives them: the eye midpoint, head_x and its One Euro
/// filter (the Dart copy, which the native one matches: head_tracker_native_test.dart), and the filter's speed
List<HeadSample> trackSamples() {
  final filter = HeadXFilter();
  final samples = <HeadSample>[];
  var sequence = 0;
  var lastFace = 0;
  double? previous;
  var previousTime = 0;
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
      final speed = previous == null ? 0.0 : (filtered - previous) / ((timeUs - previousTime) / 1e6);
      previous = filtered;
      previousTime = timeUs;
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
          velocityX: speed,
        ),
      );
    } else {
      final lost = timeUs - lastFace > 300000;
      if (lost) {
        filter.lose();
        previous = null;
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
  late HeadPositionSource head;

  HeadPositionSource make({DesktopSpatialSettings settings = const DesktopSpatialSettings(), bool noTracker = false}) {
    store = MemoryStore(settings);
    return head = HeadPositionSource(
      store: store,
      source: noTracker ? null : source,
      away: away,
      observeLifecycle: false,
    );
  }

  setUp(() {
    source = FakeHeadSource(list: const [fakeInfrared, fakeWebcam]);
    away = ValueNotifier(false);
  });

  tearDown(() => head.close());

  bool cameraOpen() => source.sessions.isNotEmpty && !source.last.closing;

  group('the webcam', () {
    test('waits for the card of the first time; meanwhile the view takes the mouse', () async {
      make();
      expect(head.kind, ViewerPositionKind.head);
      expect(head.followTime, Duration.zero);
      expect(head.needsConsent, isFalse, reason: 'no view shows it yet');
      head.attach();
      await settle();
      expect(head.needsConsent, isTrue);
      expect(head.usable, isFalse);
      expect(source.sessions, isEmpty, reason: 'no webcam before the user agreed');
      expect(source.listings, 0, reason: 'not even listed');
      await head.acceptConsent();
      await settle();
      expect(store.settings.consent, isTrue);
      expect(head.needsConsent, isFalse);
      expect(head.usable, isTrue);
      expect(cameraOpen(), isTrue);
      expect(source.last.camera, fakeWebcam, reason: 'never the infrared camera by default');
      expect(head.cameraOpen, isTrue);
    });

    test('"Use the mouse" on the card: no webcam for this view, the card again for the next', () async {
      make().attach();
      head.declineConsent();
      await settle();
      expect(head.needsConsent, isFalse);
      expect(head.usable, isFalse);
      expect(store.settings.consent, isFalse);
      expect(source.sessions, isEmpty);
      await head.close();
      make().attach();
      await settle();
      expect(head.needsConsent, isTrue);
    });

    test('opens only while a view shows the source', () async {
      make(settings: const DesktopSpatialSettings(consent: true));
      await settle();
      expect(source.sessions, isEmpty, reason: 'not attached yet');
      head.attach();
      await settle();
      expect(cameraOpen(), isTrue);
      head.detach();
      await settle();
      expect(source.last.closing, isTrue);
      expect(source.last.released, isTrue, reason: 'the light off once the view is gone');
      head.attach();
      await settle();
      expect(source.sessions, hasLength(2));
      expect(cameraOpen(), isTrue);
    });

    test('closes when the window is minimised or hidden, opens again when it is restored', () async {
      make(settings: const DesktopSpatialSettings(consent: true)).attach();
      await settle();
      head.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await settle();
      expect(cameraOpen(), isTrue, reason: 'a window without the focus is still shown');
      head.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await settle();
      expect(source.last.released, isTrue);
      head.didChangeAppLifecycleState(AppLifecycleState.paused);
      head.didChangeAppLifecycleState(AppLifecycleState.inactive);
      head.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settle();
      expect(source.sessions, hasLength(2));
      expect(cameraOpen(), isTrue);
    });

    test('closes while the session is locked or the display off', () async {
      make(settings: const DesktopSpatialSettings(consent: true)).attach();
      await settle();
      away.value = true;
      await settle();
      expect(source.last.released, isTrue);
      expect(head.cameraOpen, isFalse);
      away.value = false;
      await settle();
      expect(source.sessions, hasLength(2));
      expect(cameraOpen(), isTrue);
    });

    test('"Use the webcam for head tracking" off closes it, and the view takes the mouse', () async {
      make(settings: const DesktopSpatialSettings(consent: true)).attach();
      await settle();
      await head.setWebcamAllowed(false);
      await settle();
      expect(source.last.released, isTrue);
      expect(head.usable, isFalse);
      expect(head.needsConsent, isFalse);
      expect(store.settings.webcam, isFalse);
      await head.setWebcamAllowed(true);
      await settle();
      expect(cameraOpen(), isTrue);
    });

    test('a refusal of the system is a problem: unusable, nothing retries but the user', () async {
      make(settings: const DesktopSpatialSettings(consent: true)).attach();
      await settle();
      source.last.fail(HeadTrackerStatus.accessDenied);
      await settle();
      expect(head.problem, SpatialTrackingProblem.cameraOff);
      expect(head.usable, isFalse);
      expect(head.cameraOpen, isFalse);
      head.detach();
      head.attach();
      await settle();
      expect(source.sessions, hasLength(1), reason: 'never reopened by itself');
      await head.retry();
      await settle();
      expect(source.sessions, hasLength(2));
      expect(head.problem, isNull);
      expect(head.usable, isTrue);
    });

    test('no webcam (infrared only): a problem, and the mouse', () async {
      source.list = const [fakeInfrared];
      make(settings: const DesktopSpatialSettings(consent: true)).attach();
      await settle();
      expect(head.problem, SpatialTrackingProblem.noCamera);
      expect(head.usable, isFalse);
      expect(source.sessions, isEmpty);
    });

    test('a computer without the tracker library asks nothing and is never usable', () async {
      make(noTracker: true).attach();
      await settle();
      expect(head.supported, isFalse);
      expect(head.needsConsent, isFalse);
      expect(head.usable, isFalse);
    });

    test('the webcam picked in the menu replaces the open one at once', () async {
      make(settings: const DesktopSpatialSettings(consent: true)).attach();
      await settle();
      source.list = const [fakeInfrared, fakeWebcam, fakeExternal];
      await head.setCamera(fakeExternal.id);
      await settle();
      expect(source.sessions, hasLength(2));
      expect(source.last.camera, fakeExternal);
      expect(store.settings.cameraId, fakeExternal.id);
    });

    test('close releases the webcam before it returns, and ends the stream', () async {
      make(settings: const DesktopSpatialSettings(consent: true)).attach();
      await settle();
      final done = head.positions.toList();
      await head.close();
      expect(source.last.released, isTrue);
      expect(await done, isEmpty);
    });
  });

  group('the positions', () {
    test('follow the head of the recorded track from the centre its first face sets, then the loss', () async {
      make(settings: const DesktopSpatialSettings(consent: true)).attach();
      await settle();
      final positions = <ViewerPosition>[];
      head.positions.listen(positions.add);
      final session = source.last;
      final samples = trackSamples();
      for (final value in samples) {
        session.push(value);
        await settle();
      }
      final faces = samples.where((s) => s.hasFace).length;
      // One position a face, and one lost position when the face is lost (from 8.3 s)
      expect(positions.where((p) => p.seen), hasLength(faces));
      expect(positions.where((p) => !p.seen), hasLength(1));
      expect(positions.first.x, closeTo(0, 1e-9), reason: 'the first face is the centre');
      // In order of their timestamps, the clock of the samples, one camera frame ahead
      for (var i = 1; i < positions.length; i++) {
        expect(positions[i].timestamp, greaterThan(positions[i - 1].timestamp));
      }
      // The painted head goes to the right of the frame in its first second, the user's left: x goes negative, the
      // view moving to the left camera
      final first = samples.firstWhere((s) => s.timeUs >= 900000);
      final atFirst = positions.firstWhere((p) => p.timestamp.inMicroseconds >= first.timeUs);
      expect(atFirst.x, lessThan(-1), reason: 'beyond the range: the view clamps');
      final lost = positions.firstWhere((p) => !p.seen);
      final lostSample = samples.firstWhere((s) => s.lost);
      expect(lost.timestamp.inMicroseconds, lessThan(lostSample.timeUs + 100000));
      expect(head.latest, positions.last);
    });

    test('recenter: the next face is the centre', () async {
      source = FakeHeadSource(list: const [fakeWebcam]);
      make(settings: const DesktopSpatialSettings(consent: true)).attach();
      await settle();
      final positions = <ViewerPosition>[];
      head.positions.listen(positions.add);
      final samples = trackSamples().where((s) => s.hasFace).toList();
      source.last.push(samples[0]);
      await settle();
      source.last.push(samples[20]);
      await settle();
      expect(positions.last.x.abs(), greaterThan(0.5));
      head.recenter();
      source.last.push(samples[21]);
      await settle();
      // The centre is the filtered head of that face; the position is that head one frame ahead by its speed
      final ahead = samples[21].velocityX.clamp(-2.0, 2.0) * HeadPositionSource.lookahead.inMicroseconds / 1e6;
      expect(positions.last.x, closeTo(ahead / HeadPositionSource.headRange, 1e-6));
    });

    test('a closed webcam ends with a lost position, so that the view glides back', () async {
      make(settings: const DesktopSpatialSettings(consent: true)).attach();
      await settle();
      final positions = <ViewerPosition>[];
      head.positions.listen(positions.add);
      source.last.push(trackSamples().firstWhere((s) => s.hasFace));
      await settle();
      head.detach();
      await settle();
      expect(positions.map((p) => p.seen), [true, false]);
    });
  });

  group('the settings', () {
    test('are app settings, with their defaults', () {
      expect(DesktopSpatialSettings.fromViewer(const ViewerConfig()), const DesktopSpatialSettings());
      const settings = DesktopSpatialSettings();
      expect(settings.webcam, isTrue, reason: 'on by default, the card still asks first');
      expect(settings.consent, isFalse);
      expect(settings.cameraId, isNull);
      final changed = const AppConfig()
          .write(SettingsKey.viewerSpatialWebcam, false)
          .write(SettingsKey.viewerSpatialWebcamConsent, true)
          .write(SettingsKey.viewerSpatialCamera, '/dev/video2');
      expect(
        DesktopSpatialSettings.fromViewer(changed.viewer),
        const DesktopSpatialSettings(webcam: false, consent: true, cameraId: '/dev/video2'),
      );
      expect(changed.read(SettingsKey.viewerSpatialCamera), '/dev/video2');
      expect(changed.write(SettingsKey.viewerSpatialCamera, null).viewer.spatialCamera, isNull);
      expect(DesktopSpatialSettings.fromViewer(const ViewerConfig(spatialCamera: '')).cameraId, isNull);
    });
  });
}
