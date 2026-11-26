// The head tracking of the Spatial page of the computers (lib/desktop/spatial/head_tracking.dart) over a fake webcam:
// the default webcam is never an infrared one and a chosen one wins; a computer with infrared cameras only has no
// webcam; the samples move the viewpoint the phones' way (the first face sets the centre, a head moving to the user's
// right moves it toward the right camera); a face lost long enough offers the slider; each error of the webcam is a
// problem, releases it and is never retried by itself; a stop while the webcams are listed opens none; automatic
// framing is read from the tracker; a start waits for the webcam the previous session still holds; a default webcam
// whose formats are all grey is skipped; the head's direction can be reversed; a transient failure (the Windows camera
// service's call broken, the webcam gone in its first seconds) is tried again once after a pause, never with two
// readers, never after a stop, on the same webcam only, three times at most per start, and a second failure in a row
// is the problem.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';

import 'head_fakes.dart';

void main() {
  group('SpatialHeadTracking', () {
    late FakeHeadSource source;
    late SpatialHeadTracking tracking;

    setUp(() {
      source = FakeHeadSource(list: const [fakeInfrared, fakeWebcam, fakeExternal]);
      tracking = SpatialHeadTracking(
        source: source,
        manualAfterLost: const Duration(milliseconds: 20),
        retryPause: const Duration(milliseconds: 10),
      );
    });

    tearDown(() => tracking.dispose());

    test('opens the first webcam that is not infrared, or the one chosen when it is listed', () async {
      await tracking.start();
      expect(source.last.camera, fakeWebcam);
      expect(tracking.state, SpatialTrackingState.running);
      expect(tracking.cameraOpen, isTrue);
      expect(tracking.cameras, [fakeInfrared, fakeWebcam, fakeExternal]);
      await tracking.stop();
      expect(source.last.session.isClosed, isTrue, reason: 'the light goes off');
      expect(tracking.cameraOpen, isFalse);

      await tracking.start(cameraId: fakeExternal.id);
      expect(source.last.camera, fakeExternal);
      await tracking.stop();
      await tracking.start(cameraId: 'unplugged');
      expect(source.last.camera, fakeWebcam, reason: 'a webcam no longer listed gives the default one');
    });

    test('a computer with an infrared camera only has no webcam, and opens none', () async {
      source.list = const [fakeInfrared];
      await tracking.start();
      expect(source.sessions, isEmpty);
      expect(tracking.problem, SpatialTrackingProblem.noCamera);
      expect(tracking.state, SpatialTrackingState.failed);
      // The infrared one is still in the menu, for whoever picks it
      await tracking.start(cameraId: fakeInfrared.id);
      expect(source.last.camera, fakeInfrared);
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
        HeadTrackerStatus.format: SpatialTrackingProblem.unsupportedFormat,
        HeadTrackerStatus.failed: SpatialTrackingProblem.failed,
      };
      for (final MapEntry(key: status, value: problem) in cases.entries) {
        await tracking.start();
        source.last.fail(status);
        await settle();
        if (status == HeadTrackerStatus.deviceLost) {
          // Gone at once: a transient failure, tried again once; gone again, it is the problem
          expect(tracking.problem, isNull);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          source.last.fail(status);
          await settle();
        }
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
        ..list = const [plain, fakeWebcam]
        ..greyOnly = {plain.id};
      await tracking.start();
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      await tracking.released;
      await settle();
      expect(source.sessions.map((session) => (session.camera, session.colourOnly)), [
        (plain, true),
        (fakeWebcam, true),
      ]);
      expect(source.sessions.first.session.isClosed, isTrue);
      expect(tracking.camera, fakeWebcam);
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
      expect(tracking.cameras, [fakeInfrared, fakeWebcam, fakeExternal]);
      expect(source.sessions, isEmpty);
      expect(tracking.cameraOpen, isFalse);
    });

    group('a transient failure', () {
      // RPC_S_CALL_FAILED as the tracker's info gives it: a signed 32 bit value
      const rpcCallFailed = 0x800706BE - 0x100000000;
      const pause = Duration(milliseconds: 30);

      test('is tried again once after a pause, once the webcam is released, and then runs', () async {
        await tracking.start();
        final first = source.last;
        source.holdRelease = Completer<void>();
        first.fail(HeadTrackerStatus.failed, hresult: rpcCallFailed);
        await settle();
        expect(tracking.state, SpatialTrackingState.starting, reason: 'no message, the page waits');
        expect(tracking.problem, isNull);
        expect(tracking.cameraOpen, isFalse, reason: 'the light goes off meanwhile');
        expect(first.closing, isTrue);
        // The page asking again meanwhile starts nothing of its own
        await tracking.start();
        await Future<void>.delayed(pause);
        expect(source.sessions, hasLength(1), reason: 'the capture thread still holds the webcam: nothing opens');
        source.holdRelease!.complete();
        await tracking.released;
        await settle();
        await settle();
        expect(source.sessions, hasLength(2));
        expect(source.busy, 0, reason: 'never two readers');
        expect(source.last.camera, fakeWebcam);
        expect(tracking.state, SpatialTrackingState.running);
        expect(tracking.problem, isNull);
        source.last.push(sample(1, faceX: 0.5));
        await settle();
        expect(tracking.latest?.sequence, 1);
      });

      test('failing again is the problem: the webcam released, the slider, and no third try', () async {
        await tracking.start();
        source.last.fail(HeadTrackerStatus.failed, hresult: rpcCallFailed);
        await Future<void>.delayed(pause);
        expect(source.sessions, hasLength(2));
        source.last.fail(HeadTrackerStatus.failed, hresult: rpcCallFailed);
        await settle();
        expect(tracking.problem, SpatialTrackingProblem.failed);
        expect(tracking.state, SpatialTrackingState.failed);
        expect(tracking.cameraOpen, isFalse);
        expect(source.last.session.isClosed, isTrue);
        expect(tracking.viewpointNow(), isNull, reason: 'the page falls back');
        await Future<void>.delayed(pause * 3);
        expect(source.sessions, hasLength(2), reason: 'no third try');
        // The user asks again: a start of its own, with its own new try
        await tracking.start();
        expect(source.sessions, hasLength(3));
        source.last.fail(HeadTrackerStatus.failed, hresult: rpcCallFailed);
        await Future<void>.delayed(pause);
        expect(source.sessions, hasLength(4));
      });

      test('a stop during the pause opens nothing afterwards', () async {
        await tracking.start(cameraId: fakeExternal.id);
        source.last.fail(HeadTrackerStatus.failed, hresult: rpcCallFailed);
        await settle();
        expect(tracking.state, SpatialTrackingState.starting);
        await tracking.stop();
        expect(tracking.state, SpatialTrackingState.off);
        await Future<void>.delayed(pause * 3);
        expect(source.sessions, hasLength(1));
        expect(tracking.cameraOpen, isFalse);
        expect(tracking.problem, isNull);
      });

      test('the page saying no by the end of the pause opens nothing', () async {
        var allowed = true;
        tracking.mayRetry = () => allowed;
        await tracking.start();
        source.last.fail(HeadTrackerStatus.failed, hresult: rpcCallFailed);
        allowed = false;
        await Future<void>.delayed(pause);
        expect(source.sessions, hasLength(1));
        expect(tracking.state, SpatialTrackingState.off);
      });

      test('the new try opens the webcam the page asked for', () async {
        await tracking.start(cameraId: fakeExternal.id);
        source.last.fail(HeadTrackerStatus.failed, hresult: rpcCallFailed);
        await Future<void>.delayed(pause);
        expect(source.sessions.map((session) => session.camera), [fakeExternal, fakeExternal]);
      });

      test('the new try opens the same webcam or none: one unplugged meanwhile is never replaced by another', () async {
        // The webcam picked, unplugged in its first seconds: the built-in one never turns on by itself
        await tracking.start(cameraId: fakeExternal.id);
        source.last.push(sample(1, faceX: 0.5, timeUs: 1000000));
        source.list = const [fakeInfrared, fakeWebcam];
        source.last.fail(HeadTrackerStatus.deviceLost);
        await Future<void>.delayed(pause);
        expect(source.sessions.map((session) => session.camera), [fakeExternal]);
        expect(tracking.problem, SpatialTrackingProblem.cameraLost, reason: 'the message, and the mouse');
        expect(tracking.state, SpatialTrackingState.failed);
        expect(tracking.cameraOpen, isFalse);
        // The webcam taken by default, unplugged the same way: the next one is not taken by itself either
        source.list = const [fakeInfrared, fakeWebcam, fakeExternal];
        await tracking.start();
        expect(source.last.camera, fakeWebcam);
        source.list = const [fakeInfrared, fakeExternal];
        source.last.fail(HeadTrackerStatus.deviceLost);
        await Future<void>.delayed(pause);
        expect(source.sessions.map((session) => session.camera), [fakeExternal, fakeWebcam]);
        expect(tracking.problem, SpatialTrackingProblem.cameraLost);
        // The user's own start takes the default one
        await tracking.start();
        expect(source.last.camera, fakeExternal);
      });

      test('the new try of a webcam taken by default opens it as colour only again', () async {
        await tracking.start();
        source.last.fail(HeadTrackerStatus.failed, hresult: rpcCallFailed);
        await Future<void>.delayed(pause);
        expect(source.sessions.map((session) => (session.camera, session.colourOnly)), [
          (fakeWebcam, true),
          (fakeWebcam, true),
        ]);
      });

      test('three new tries at most per start, even when each session ran well before it failed', () async {
        await tracking.start();
        source.last.fail(HeadTrackerStatus.failed, hresult: rpcCallFailed);
        await Future<void>.delayed(pause);
        for (var i = 0; i < 3; i++) {
          source.last.push(sample(1, faceX: 0.5, timeUs: 11000000));
          source.last.fail(HeadTrackerStatus.failed, hresult: rpcCallFailed);
          await Future<void>.delayed(pause);
        }
        expect(source.sessions, hasLength(4), reason: 'the start and its three new tries');
        expect(tracking.problem, SpatialTrackingProblem.failed);
        expect(tracking.state, SpatialTrackingState.failed);
        expect(tracking.cameraOpen, isFalse);
        // The user asks again: three new tries of its own
        await tracking.start();
        source.last.fail(HeadTrackerStatus.failed, hresult: rpcCallFailed);
        await Future<void>.delayed(pause);
        expect(source.sessions, hasLength(6));
        expect(tracking.state, SpatialTrackingState.running);
      });

      test('the webcam gone: tried again in its first seconds only', () async {
        await tracking.start();
        source.last.push(sample(1, faceX: 0.5, timeUs: 2000000));
        source.last.fail(HeadTrackerStatus.deviceLost);
        await Future<void>.delayed(pause);
        expect(source.sessions, hasLength(2), reason: 'gone after 2 s: tried again');
        expect(tracking.state, SpatialTrackingState.running);
        // After 11 s: unplugged, not a hiccup
        source.last.push(sample(1, faceX: 0.5, timeUs: 11000000));
        source.last.fail(HeadTrackerStatus.deviceLost);
        await Future<void>.delayed(pause);
        expect(source.sessions, hasLength(2));
        expect(tracking.problem, SpatialTrackingProblem.cameraLost);
      });

      test('a new try that ran well has a new try of its own for a later failure', () async {
        await tracking.start();
        source.last.fail(HeadTrackerStatus.failed, hresult: rpcCallFailed);
        await Future<void>.delayed(pause);
        expect(source.sessions, hasLength(2));
        source.last.push(sample(1, faceX: 0.5, timeUs: 60000000));
        source.last.fail(HeadTrackerStatus.failed, hresult: rpcCallFailed);
        await Future<void>.delayed(pause);
        expect(source.sessions, hasLength(3));
        expect(tracking.state, SpatialTrackingState.running);
      });

      test('other failures are not tried again', () async {
        for (final status in [HeadTrackerStatus.accessDenied, HeadTrackerStatus.cameraBusy, HeadTrackerStatus.failed]) {
          await tracking.start();
          final count = source.sessions.length;
          source.last.fail(status, hresult: status == HeadTrackerStatus.failed ? 0x80004005 - 0x100000000 : 0);
          await Future<void>.delayed(pause);
          expect(source.sessions, hasLength(count), reason: 'status $status');
          expect(tracking.state, SpatialTrackingState.failed);
        }
      });

      test('is told by its HRESULT', () {
        for (final hresult in transientWebcamHresults) {
          expect(
            isTransientWebcamFailure(HeadTrackerException(HeadTrackerError.failed, hresult: hresult), early: false),
            isTrue,
          );
          expect(
            isTransientWebcamFailure(
              HeadTrackerException(HeadTrackerError.failed, hresult: hresult - 0x100000000),
              early: false,
            ),
            isTrue,
            reason: 'signed as the tracker gives it',
          );
        }
        const lost = HeadTrackerException(HeadTrackerError.deviceLost, hresult: 0xC00D3EA2);
        expect(isTransientWebcamFailure(lost, early: true), isTrue);
        expect(isTransientWebcamFailure(lost, early: false), isFalse);
        const denied = HeadTrackerException(HeadTrackerError.accessDenied, hresult: 0x80070005);
        expect(isTransientWebcamFailure(denied, early: true), isFalse);
      });
    });

    test('without the tracker DLL, tracking fails quietly', () async {
      final none = SpatialHeadTracking(source: null);
      await none.start();
      expect(none.problem, SpatialTrackingProblem.failed);
      expect(none.viewpointNow(), isNull);
      none.dispose();
    });
  });
}
