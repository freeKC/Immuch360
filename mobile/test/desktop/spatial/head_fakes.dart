// The fake webcams of the tests of the Spatial 2.5D head tracking and of its input (head_tracking_test.dart,
// spatial_viewer_input_test.dart): sessions driven by the test, and a source that lists and opens them like a real
// webcam (one still held by a session that is closing answers busy).

import 'dart:async';

import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';

const fakeWebcam = HeadCamera(id: r'\\?\usb#vid_0001', name: 'USB2.0 FHD UVC WebCam');
const fakeInfrared = HeadCamera(id: r'\\?\usb#vid_0002', name: 'USB2.0 IR UVC WebCam');
const fakeExternal = HeadCamera(id: r'\\?\usb#vid_0003', name: 'Logitech BRIO');

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

  /// The error [status] stops the camera; [hresult]: the Windows code the tracker recorded with it
  void fail(int status, {int hresult = 0}) {
    if (hresult != 0) {
      info = HeadTrackerInfo(
        detector: info.detector,
        framing: info.framing,
        width: info.width,
        height: info.height,
        fpsNumerator: info.fpsNumerator,
        fpsDenominator: info.fpsDenominator,
        nativeFourcc: info.nativeFourcc,
        hresult: hresult,
      );
    }
    _latest = (sample: _latest?.sample ?? sample(0), status: status);
    session.signal(-1, status);
  }
}

/// The webcams of the test, and the sessions opened on them. Like a real webcam, one still held by a session that is
/// closing refuses to open again (busy); [greyOnly] cameras refuse a colour only open, before they stream.
class FakeHeadSource implements SpatialHeadSource {
  FakeHeadSource({this.list = const [fakeWebcam]});

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
