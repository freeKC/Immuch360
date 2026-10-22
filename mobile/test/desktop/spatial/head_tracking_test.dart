// The head tracking of the Spatial page of the computers (lib/desktop/spatial/head_tracking.dart) over a fake webcam:
// the default webcam is never an infrared one and a chosen one wins; a computer with infrared cameras only has no
// webcam; the samples move the viewpoint the phones' way (the first face sets the centre, a head moving to the user's
// right moves it toward the right camera); a face lost long enough offers the slider; each error of the webcam is a
// problem, releases it and is never retried by itself; a stop while the webcams are listed opens none; automatic
// framing is read from the tracker. And the Spatial settings file (spatial_settings.dart).

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

/// A webcam session driven by the test: [push] gives a sample, [fail] the error that stops the camera
class FakeHeadSession {
  FakeHeadSession(this.camera) {
    session = HeadTrackingSession.forTesting(latest: () => _latest, nowUs: () => nowUs, info: () => info);
  }

  final HeadCamera camera;
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

/// The webcams of the test, and the sessions opened on them
class FakeHeadSource implements SpatialHeadSource {
  FakeHeadSource({this.list = const [_webcam]});

  List<HeadCamera> list;
  Exception? listError;
  Exception? startError;
  Completer<void>? holdList;
  int listings = 0;
  final sessions = <FakeHeadSession>[];

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
  HeadTrackingSession start(HeadCamera camera) {
    final error = startError;
    if (error != null) {
      throw error;
    }
    final fake = FakeHeadSession(camera);
    sessions.add(fake);
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
    });

    test('keeps the choices in a file, and reads them back in a new session', () async {
      const chosen = DesktopSpatialSettings(source: SpatialViewpointSource.mouse, sensitivity: 2.4, cameraId: 'cam');
      await DesktopSpatialSettingsStore.save(chosen);
      DesktopSpatialSettingsStore.forget();
      expect(await DesktopSpatialSettingsStore.load(), chosen);
      final text = File('${folder.path}/${DesktopSpatialSettingsStore.fileName}').readAsStringSync();
      expect(text, '{"source":"mouse","sensitivity":2.4,"camera":"cam"}');
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
