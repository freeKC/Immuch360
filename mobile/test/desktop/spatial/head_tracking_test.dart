// The head tracking of the Spatial page of the computers (lib/desktop/spatial/head_tracking.dart) over a fake webcam:
// the default webcam is never an infrared one and a chosen one wins; a computer with infrared cameras only has no
// webcam; the samples move the viewpoint the phones' way (the first face sets the centre, a head moving to the user's
// right moves it toward the right camera); a face lost long enough offers the slider; each error of the webcam is a
// problem, releases it and is never retried by itself; a stop while the webcams are listed opens none; automatic
// framing is read from the tracker; a start waits for the webcam the previous session still holds; a default webcam
// whose formats are all grey is skipped; the head's direction can be reversed. And the Spatial settings file
// (spatial_settings.dart).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';

const _webcam = HeadCamera(id: r'\\?\usb#vid_0001', name: 'USB2.0 FHD UVC WebCam');
const _infrared = HeadCamera(id: r'\\?\usb#vid_0002', name: 'USB2.0 IR UVC WebCam');
const _external = HeadCamera(id: r'\\?\usb#vid_0003', name: 'Logitech BRIO');

HeadSample sample(int sequence, {double faceX = double.nan, HeadFaceState? state, int? timeUs}) => HeadSample(
  timeUs: timeUs ?? sequence * 66667,
  sequence: sequence,
  faceX: faceX,
  faceY: faceX.isNaN ? double.nan : 0.4,
  faceWidth: faceX.isNaN ? double.nan : 0.2,
  faceHeight: faceX.isNaN ? double.nan : 0.27,
  confidence: faceX.isNaN ? 0 : 0.9,
  state: state ?? (faceX.isNaN ? HeadFaceState.noFace : HeadFaceState.face),
  detectUs: 3000,
  frameWidth: 160,
  frameHeight: 120,
  faces: faceX.isNaN ? 0 : 1,
);

/// A webcam session driven by the test: [push] gives a sample, [fail] the error that stops the camera. Its close waits
/// for [release] when one is given: the capture thread still holds the webcam meanwhile.
class FakeHeadSession {
  FakeHeadSession(this.camera, {this.colourOnly = false, Future<void> Function()? release}) {
    session = HeadTrackingSession.forTesting(
      latest: () => _latest,
      nowUs: () => nowUs,
      info: () => info,
      onClose: () async {
        closing = true;
        await release?.call();
        released = true;
      },
    );
  }

  final HeadCamera camera;
  final bool colourOnly;

  /// The close began; the webcam was let go
  bool closing = false;
  bool released = false;
  late final HeadTrackingSession session;
  ({HeadSample sample, int status})? _latest;
  int nowUs = 0;
  HeadTrackerInfo info = const HeadTrackerInfo(
    detector: FaceDetectorBuild.avx2,
    framing: AutoFramingState.unknown,
    width: 640,
    height: 480,
    fpsNumerator: 30,
    fpsDenominator: 1,
    nativeFourcc: 'NV12',
    hresult: 0,
  );

  void push(HeadSample value) {
    _latest = (sample: value, status: 0);
    nowUs = value.timeUs;
    session.signal(value.sequence, 0);
  }

  void fail(int status) {
    _latest = (sample: _latest?.sample ?? sample(0), status: status);
    session.signal(-1, status);
  }
}

/// The webcams of the test, and the sessions opened on them. Like a real webcam, one still held by a session that is
/// closing refuses to open again (busy); [greyOnly] cameras refuse a colour only open, before they stream.
class FakeHeadSource implements SpatialHeadSource {
  FakeHeadSource({this.list = const [_webcam]});

  List<HeadCamera> list;
  Exception? listError;
  Exception? startError;
  Completer<void>? holdList;

  /// The release of the webcam by a closing session waits for this
  Completer<void>? holdRelease;
  Set<String> greyOnly = const {};
  int listings = 0;
  final sessions = <FakeHeadSession>[];

  /// Opens refused because the previous session still held the webcam
  int busy = 0;

  FakeHeadSession get last => sessions.last;

  @override
  Future<List<HeadCamera>> cameras() async {
    listings++;
    await holdList?.future;
    final error = listError;
    if (error != null) {
      throw error;
    }
    return list;
  }

  @override
  HeadTrackingSession start(HeadCamera camera, {bool colourOnly = false}) {
    final error = startError;
    if (error != null) {
      throw error;
    }
    final held = sessions.any((session) => session.closing && !session.released);
    // Read when the session closes: the test may hold the release after the session opened
    final fake = FakeHeadSession(camera, colourOnly: colourOnly, release: () async => holdRelease?.future);
    sessions.add(fake);
    if (held) {
      // The capture thread of the previous session has not let the webcam go
      busy++;
      scheduleMicrotask(() => fake.fail(HeadTrackerStatus.cameraBusy));
    } else if (colourOnly && greyOnly.contains(camera.id)) {
      scheduleMicrotask(() => fake.fail(HeadTrackerStatus.greyOnly));
    }
    return fake.session;
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('SpatialHeadTracking', () {
    late FakeHeadSource source;
    late SpatialHeadTracking tracking;

    setUp(() {
      source = FakeHeadSource(list: const [_infrared, _webcam, _external]);
      tracking = SpatialHeadTracking(source: source, manualAfterLost: const Duration(milliseconds: 20));
    });

    tearDown(() => tracking.dispose());

    test('opens the first webcam that is not infrared, or the one chosen when it is listed', () async {
      await tracking.start();
      expect(source.last.camera, _webcam);
      expect(tracking.state, SpatialTrackingState.running);
      expect(tracking.cameraOpen, isTrue);
      expect(tracking.cameras, [_infrared, _webcam, _external]);
      await tracking.stop();
      expect(source.last.session.isClosed, isTrue, reason: 'the light goes off');
      expect(tracking.cameraOpen, isFalse);

      await tracking.start(cameraId: _external.id);
      expect(source.last.camera, _external);
      await tracking.stop();
      await tracking.start(cameraId: 'unplugged');
      expect(source.last.camera, _webcam, reason: 'a webcam no longer listed gives the default one');
    });

    test('a computer with an infrared camera only has no webcam, and opens none', () async {
      source.list = const [_infrared];
      await tracking.start();
      expect(source.sessions, isEmpty);
      expect(tracking.problem, SpatialTrackingProblem.noCamera);
      expect(tracking.state, SpatialTrackingState.failed);
      // The infrared one is still in the menu, for whoever picks it
      await tracking.start(cameraId: _infrared.id);
      expect(source.last.camera, _infrared);
    });

    test('the head moves the viewpoint the phones way, from the centre the first face sets', () async {
      tracking.sensitivity = HeadViewpoint.desktopSensitivity;
      await tracking.start();
      final webcam = source.last;
      expect(tracking.viewpointNow(), 0.5);
      // The face in the middle of the picture: the centre
      for (var i = 1; i <= 10; i++) {
        webcam.push(sample(i, faceX: 0.5));
      }
      await settle();
      expect(tracking.viewpointNow(), closeTo(0.5, 1e-6));
      // The picture is not mirrored: a head moving to the user's right shows on the left of the picture
      for (var i = 11; i <= 60; i++) {
        webcam.push(sample(i, faceX: 0.45));
      }
      await settle();
      expect(tracking.viewpointNow(), closeTo(0.5 + 0.05 * 3, 0.01), reason: 'toward the right camera');
      for (var i = 61; i <= 110; i++) {
        webcam.push(sample(i, faceX: 0.9));
      }
      await settle();
      expect(tracking.viewpointNow(), HeadViewpoint.minViewpoint, reason: 'kept within 0.15 and 0.85');
      // Recenter: the next face is the new centre, eased in over 0.3 s
      tracking.recenter();
      webcam.push(sample(111, faceX: 0.9));
      await settle();
      webcam.nowUs += 400000;
      expect(tracking.viewpointNow(), closeTo(0.5, 1e-6));
    });

    test('a face lost long enough offers the slider, and a face found again takes it back', () async {
      await tracking.start();
      final webcam = source.last;
      var changes = 0;
      tracking.addListener(() => changes++);
      webcam.push(sample(1, faceX: 0.5));
      await settle();
      expect(tracking.faceLost, isFalse);
      webcam.push(sample(2, state: HeadFaceState.lost));
      await settle();
      expect(tracking.faceLost, isTrue);
      expect(tracking.lostTooLong, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(tracking.lostTooLong, isTrue);
      webcam.push(sample(3, faceX: 0.5));
      await settle();
      expect(tracking.faceLost, isFalse);
      expect(tracking.lostTooLong, isFalse);
      expect(changes, 3, reason: 'one change each: lost, lost too long, found; not one per sample');
    });

    test('camera access turned off is a problem, releases the webcam and is not tried again by itself', () async {
      await tracking.start();
      final webcam = source.last;
      webcam.fail(HeadTrackerStatus.accessDenied);
      await settle();
      expect(tracking.problem, SpatialTrackingProblem.cameraOff);
      expect(tracking.state, SpatialTrackingState.failed);
      expect(tracking.cameraOpen, isFalse);
      expect(webcam.session.isClosed, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(source.sessions, hasLength(1));
      expect(tracking.viewpointNow(), isNull, reason: 'the page falls back to the slider');
      // The user turns it on again: tried once more
      await tracking.start();
      expect(source.sessions, hasLength(2));
      expect(tracking.problem, isNull);
    });

    test('each error of the webcam has its message', () async {
      final cases = {
        HeadTrackerStatus.cameraBusy: SpatialTrackingProblem.cameraBusy,
        HeadTrackerStatus.deviceLost: SpatialTrackingProblem.cameraLost,
        HeadTrackerStatus.noCamera: SpatialTrackingProblem.noCamera,
        HeadTrackerStatus.format: SpatialTrackingProblem.failed,
      };
      for (final MapEntry(key: status, value: problem) in cases.entries) {
        await tracking.start();
        source.last.fail(status);
        await settle();
        expect(tracking.problem, problem, reason: 'status $status');
      }
      source.listError = const HeadTrackerException(HeadTrackerError.noMediaFoundation);
      await tracking.start();
      expect(tracking.problem, SpatialTrackingProblem.mediaFeaturePack);
      source.listError = null;
      source.startError = const HeadTrackerException(HeadTrackerError.noDetector);
      await tracking.start();
      expect(tracking.problem, SpatialTrackingProblem.failed);
      expect(tracking.cameraOpen, isFalse);
    });

    test('a stop while the webcams are listed opens none', () async {
      source.holdList = Completer<void>();
      final starting = tracking.start();
      await settle();
      expect(tracking.state, SpatialTrackingState.starting);
      await tracking.stop();
      source.holdList!.complete();
      await starting;
      expect(source.sessions, isEmpty);
      expect(tracking.state, SpatialTrackingState.off);
    });

    test('reads automatic framing from the tracker once the camera streams', () async {
      await tracking.start();
      final webcam = source.last;
      webcam.push(sample(1, faceX: 0.5));
      await settle();
      expect(tracking.framing, AutoFramingState.unknown);
      webcam.info = HeadTrackerInfo(
        detector: webcam.info.detector,
        framing: AutoFramingState.stuckOn,
        width: 640,
        height: 480,
        fpsNumerator: 30,
        fpsDenominator: 1,
        nativeFourcc: 'MJPG',
        hresult: 0,
      );
      webcam.push(sample(2, faceX: 0.5, timeUs: 66667 * 2));
      await settle();
      expect(tracking.framing, AutoFramingState.unknown, reason: 'read twice a second at most');
      webcam.push(sample(20, faceX: 0.5));
      await settle();
      expect(tracking.framing, AutoFramingState.stuckOn);
      expect(tracking.info()?.nativeFourcc, 'MJPG');
    });

    test('a start waits for the webcam the previous session still holds', () async {
      source.holdRelease = Completer<void>();
      await tracking.start();
      final first = source.last;
      final stopping = tracking.stop();
      await settle();
      expect(first.closing, isTrue);
      expect(first.released, isFalse, reason: 'the capture thread still holds the webcam');
      // Minimised and restored at once: the second start waits rather than finding the webcam busy
      final starting = tracking.start();
      await settle();
      expect(source.sessions, hasLength(1));
      expect(tracking.state, SpatialTrackingState.starting);
      source.holdRelease!.complete();
      await stopping;
      await starting;
      await settle();
      expect(source.sessions, hasLength(2));
      expect(source.busy, 0);
      expect(tracking.problem, isNull);
      expect(tracking.state, SpatialTrackingState.running);
      // The listing for the menu waits as well
      source.holdRelease = Completer<void>();
      final again = tracking.stop();
      final listings = source.listings;
      final listing = tracking.refreshCameras();
      await settle();
      expect(source.listings, listings);
      source.holdRelease!.complete();
      await again;
      await listing;
      expect(source.listings, listings + 1);
      await tracking.released;
    });

    test('a default webcam whose formats are all grey is skipped, and marked infrared', () async {
      const plain = HeadCamera(id: r'\\?\usb#vid_0004', name: 'Integrated Camera');
      source
        ..list = const [plain, _webcam]
        ..greyOnly = {plain.id};
      await tracking.start();
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      await tracking.released;
      await settle();
      expect(source.sessions.map((session) => (session.camera, session.colourOnly)), [(plain, true), (_webcam, true)]);
      expect(source.sessions.first.session.isClosed, isTrue);
      expect(tracking.camera, _webcam);
      expect(tracking.problem, isNull);
      expect(tracking.state, SpatialTrackingState.running);
      expect(tracking.cameras!.first.infrared, isTrue, reason: 'the menu says it');
      await tracking.stop();
      // Picked by the user, it opens without the check, as it is
      await tracking.start(cameraId: plain.id);
      expect(source.last.camera, plain);
      expect(source.last.colourOnly, isFalse);
    });

    test("reversed, a head moving to the user's right moves the viewpoint toward the left camera", () async {
      await tracking.start();
      final webcam = source.last;
      tracking.reversed = true;
      for (var i = 1; i <= 10; i++) {
        webcam.push(sample(i, faceX: 0.5));
      }
      for (var i = 11; i <= 60; i++) {
        webcam.push(sample(i, faceX: 0.45));
      }
      await settle();
      expect(tracking.viewpointNow(), closeTo(0.5 - 0.05 * 3, 0.01));
    });

    test('lists the webcams for the menu without opening any', () async {
      await tracking.refreshCameras();
      expect(tracking.cameras, [_infrared, _webcam, _external]);
      expect(source.sessions, isEmpty);
      expect(tracking.cameraOpen, isFalse);
    });

    test('without the tracker DLL, tracking fails quietly', () async {
      final none = SpatialHeadTracking(source: null);
      await none.start();
      expect(none.problem, SpatialTrackingProblem.failed);
      expect(none.viewpointNow(), isNull);
      none.dispose();
    });
  });

  group('DesktopSpatialSettings', () {
    late Directory folder;

    setUp(() {
      folder = Directory.systemTemp.createTempSync('spatial_settings_test');
      DesktopSpatialSettingsStore.forget();
      DesktopSpatialSettingsStore.folder = () async => folder;
    });

    tearDown(() {
      DesktopSpatialSettingsStore.forget();
      folder.deleteSync(recursive: true);
    });

    test('starts with the head at the desktop sensitivity and the default webcam', () async {
      final settings = await DesktopSpatialSettingsStore.load();
      expect(settings.source, SpatialViewpointSource.head);
      expect(settings.sensitivity, 3.0);
      expect(settings.cameraId, isNull);
      expect(settings.cameraAgreed, isFalse, reason: 'the page asks before it opens the webcam the first time');
      expect(settings.reverseHead, isFalse);
    });

    test('keeps the choices in a file, and reads them back in a new session', () async {
      const chosen = DesktopSpatialSettings(
        source: SpatialViewpointSource.mouse,
        sensitivity: 2.4,
        cameraId: 'cam',
        cameraAgreed: true,
        reverseHead: true,
      );
      await DesktopSpatialSettingsStore.save(chosen);
      DesktopSpatialSettingsStore.forget();
      expect(await DesktopSpatialSettingsStore.load(), chosen);
      final text = File('${folder.path}/${DesktopSpatialSettingsStore.fileName}').readAsStringSync();
      expect(
        text,
        '{"source":"mouse","sensitivity":2.4,"camera":"cam","cameraAgreed":true,"reverseHead":true}',
        reason: 'the choices only, never a picture',
      );
      // A file of the first version: the webcam not agreed to yet, the head not reversed
      expect(
        DesktopSpatialSettings.fromJson(const {'source': 'head', 'sensitivity': 3.0}),
        const DesktopSpatialSettings(),
      );
    });

    test('a damaged or odd file gives the defaults, a sensitivity out of range is kept within it', () async {
      File('${folder.path}/${DesktopSpatialSettingsStore.fileName}').writeAsStringSync('{"source":');
      expect(await DesktopSpatialSettingsStore.load(), const DesktopSpatialSettings());
      expect(
        DesktopSpatialSettings.fromJson(const {'source': 'telepathy', 'sensitivity': 9, 'camera': ''}),
        const DesktopSpatialSettings(sensitivity: 4.0),
      );
    });
  });
}
