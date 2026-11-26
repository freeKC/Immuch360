// What the tracker gives: one sample per analysed frame, the errors that stop it, and what it runs with. The numbers
// mirror src/ht_api.h.

import 'dart:io';

/// Whether the analysed frame held a face
enum HeadFaceState {
  /// A face in this frame
  face,

  /// No face in this frame, the last one less than 300 ms ago: the viewpoint holds still
  noFace,

  /// No face for more than 300 ms (or none since the start): the viewpoint eases back to the middle
  lost,
}

/// Why the tracker cannot run or stopped
enum HeadTrackerError {
  /// The system refused the camera (the privacy settings of Windows or macOS, no access to the node on Linux): show the
  /// privacy message, with the [cameraPrivacySettingsUri] button where the system has such a page
  accessDenied,

  /// No capture system: a Windows N edition without the Media Feature Pack (or a Windows Server without the feature)
  noMediaFoundation,

  /// No camera, or not the one asked for
  noCamera,

  /// Another app holds the camera
  cameraBusy,

  /// The camera went away while streaming (unplugged, disabled)
  deviceLost,

  /// The face detector DLLs are missing from the app's folder
  noDetector,

  /// The AVX2 build was asked for on a computer without AVX2
  noAvx2,

  /// The source gives no frame the tracker can read
  format,

  /// A bad argument
  argument,

  /// Anything else (see [HeadTrackerException.hresult])
  failed,

  /// [HeadTrackerOptions.colourOnly] was asked for and the camera gives grey pictures only: an infrared camera, whatever
  /// its name. Found before it streams.
  greyOnly,
}

/// The Settings page where camera access for desktop apps is turned on, for the button of the privacy message
const windowsCameraPrivacyUri = 'ms-settings:privacy-webcam';

/// Privacy and Security, Camera, in the System Settings of macOS
const macosCameraPrivacyUri = 'x-apple.systempreferences:com.apple.preference.security?Privacy_Camera';

/// The page of the system where the app is allowed the camera, null where there is none (Linux: the webcam node's
/// access comes from the desktop session)
String? get cameraPrivacySettingsUri => Platform.isWindows
    ? windowsCameraPrivacyUri
    : Platform.isMacOS
    ? macosCameraPrivacyUri
    : null;

/// One face given as landmarks, as a recorded track holds it: fractions of the frame
class HeadLandmarks {
  const HeadLandmarks({required this.score, required this.eyeX, required this.eyeY, required this.eyeDistance});

  /// 0 to 100
  final int score;
  final double eyeX;
  final double eyeY;
  final double eyeDistance;
}

/// The limits of ht_predict (HT_PREDICT_* of ht_api.h)
abstract final class HeadPrediction {
  static const maxAheadUs = 40000;
  static const maxSpeed = 2.0;
  static const minConfidence = 0.6;
}

/// The status codes of ht_api.h
abstract final class HeadTrackerStatus {
  static const ok = 0;
  static const accessDenied = -1;
  static const noMediaFoundation = -2;
  static const noCamera = -3;
  static const cameraBusy = -4;
  static const deviceLost = -5;
  static const noDetector = -6;
  static const noAvx2 = -7;
  static const format = -8;
  static const argument = -9;
  static const failed = -10;
  static const greyOnly = -11;

  /// The error of a negative status, null for success
  static HeadTrackerError? errorOf(int status) => switch (status) {
    >= 0 => null,
    accessDenied => HeadTrackerError.accessDenied,
    noMediaFoundation => HeadTrackerError.noMediaFoundation,
    noCamera => HeadTrackerError.noCamera,
    cameraBusy => HeadTrackerError.cameraBusy,
    deviceLost => HeadTrackerError.deviceLost,
    noDetector => HeadTrackerError.noDetector,
    noAvx2 => HeadTrackerError.noAvx2,
    format => HeadTrackerError.format,
    argument => HeadTrackerError.argument,
    greyOnly => HeadTrackerError.greyOnly,
    _ => HeadTrackerError.failed,
  };
}

/// An error of the tracker, with the HRESULT behind it when Windows gave one
class HeadTrackerException implements Exception {
  const HeadTrackerException(this.error, {this.hresult = 0});

  /// The exception of a negative status of ht_api.h
  factory HeadTrackerException.fromStatus(int status, {int hresult = 0}) =>
      HeadTrackerException(HeadTrackerStatus.errorOf(status) ?? HeadTrackerError.failed, hresult: hresult);

  final HeadTrackerError error;
  final int hresult;

  @override
  String toString() =>
      'HeadTrackerException(${error.name}'
      '${hresult == 0 ? '' : ', 0x${(hresult & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0')}'})';
}

/// One analysed frame. Positions are fractions of the frame as the camera delivers it (not mirrored): [faceX] from 0
/// (left) to 1, [faceY] from 0 (top) to 1; NaN without a face.
class HeadSample {
  const HeadSample({
    required this.timeUs,
    required this.sequence,
    required this.faceX,
    required this.faceY,
    required this.faceWidth,
    required this.faceHeight,
    required this.confidence,
    required this.state,
    required this.detectUs,
    required this.frameWidth,
    required this.frameHeight,
    required this.faces,
    this.eyeX = double.nan,
    this.eyeY = double.nan,
    this.eyeDistance = double.nan,
    this.headPosition = double.nan,
    this.filteredX = double.nan,
    this.velocityX = 0,
    this.detectWidth = 0,
  });

  /// The frame's time: the camera clock of [HeadTrackingSession.nowUs], or the file's timestamp
  final int timeUs;

  /// Analysed frames since the tracker opened, from 1
  final int sequence;
  final double faceX;
  final double faceY;
  final double faceWidth;
  final double faceHeight;

  /// The detector's score of the face, 0 to 1
  final double confidence;
  final HeadFaceState state;

  /// How long the detector took
  final int detectUs;
  final int frameWidth;
  final int frameHeight;

  /// Faces found in the frame scoring enough (the sample describes the one followed)
  final int faces;

  /// The midpoint of the eyes from the detector's landmarks, fractions of the frame; NaN without a face
  final double eyeX;
  final double eyeY;

  /// The distance between the eyes as a fraction of the frame width
  final double eyeDistance;

  /// The tracker's own head_x (0.5 - [eyeX]); NaN without a face, or from a sample made without the tracker
  final double headPosition;

  /// [headX] through the tracker's One Euro filter (the phones' filter, started afresh after a loss); NaN without a
  /// face, or when the sample was not made by the tracker
  final double filteredX;

  /// The filter's speed, headX per second
  final double velocityX;

  /// The width of the detector image of this frame (160, or 320 for a face far away)
  final int detectWidth;

  /// [timeUs] in the nanoseconds of [HeadViewpoint] and [OneEuroFilter]
  int get timeNanos => timeUs * 1000;

  bool get hasFace => state == HeadFaceState.face;
  bool get lost => state == HeadFaceState.lost;

  /// The head's horizontal position as the phones measure it (HeadTracker.kt): -0.5 to 0.5 in the mirrored picture,
  /// larger when the head moves to the user's right. A webcam does not mirror its frames, so a head moving to the user's
  /// right moves to the left of the frame: headX = 0.5 - faceX. NaN without a face.
  /// From the eyes when the tracker measured them, else from the box centre.
  double get headX => !hasFace
      ? double.nan
      : headPosition.isFinite
      ? headPosition
      : (0.5 - faceX).clamp(-0.5, 0.5);

  /// The head position at [nowUs] in the clock of [timeUs], as ht_predict gives it: [filteredX] moved on by
  /// [velocityX] for at most 40 ms, the speed kept under 2 a second, no move when the confidence is under 0.6; null
  /// without a face or a filtered position
  double? predictedAt(int nowUs) {
    if (!hasFace || !filteredX.isFinite) {
      return null;
    }
    var x = filteredX;
    if (confidence >= HeadPrediction.minConfidence && velocityX.isFinite) {
      final ahead = (nowUs - timeUs).clamp(0, HeadPrediction.maxAheadUs);
      x += velocityX.clamp(-HeadPrediction.maxSpeed, HeadPrediction.maxSpeed) * ahead / 1e6;
    }
    return x.clamp(-0.5, 0.5).toDouble();
  }

  @override
  String toString() =>
      'HeadSample(#$sequence at $timeUs us, ${state.name}, x ${faceX.toStringAsFixed(4)}, '
      'confidence ${confidence.toStringAsFixed(2)}, $detectUs us)';
}

/// The detector build: [auto] takes the AVX2 build when the processor and the system allow it (unless the environment
/// variable IMMUCH360_FACE_DETECTOR is "plain"); [neon] is the arm64 slice of the macOS library
enum FaceDetectorBuild { auto, plain, avx2, neon }

/// What the tracker knows of Windows Studio Effects automatic framing on the camera
enum AutoFramingState {
  /// Not known yet: the camera has not delivered a frame
  unknown,

  /// The camera has no automatic framing
  absent,

  /// It was on and the tracker turned it off for its stream (and gives it back when it stops)
  turnedOff,

  /// The camera has it, and it was off
  off,

  /// It is on and the driver did not let the tracker turn it off: the face stays in the middle, show the message with
  /// the camera settings
  stuckOn,
}

/// The options of a tracker; zero values take the defaults of ht_api.h
class HeadTrackerOptions {
  const HeadTrackerOptions({
    this.detector = FaceDetectorBuild.auto,
    this.detectEvery = 0,
    this.minScore = 0,
    this.detectLongSide = 0,
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.colourOnly = false,
  });

  /// HT_FLAG_COLOUR_ONLY of ht_api.h
  static const colourOnlyFlag = 1;

  final FaceDetectorBuild detector;

  /// Analyse one frame in this many (1 by default: every frame of a 30 fps camera)
  final int detectEvery;

  /// The lowest detector score, 1 to 100, that counts as a face (50 by default)
  final int minScore;

  /// The long side of the detector image (160 by default, at most 320; twice that while the face is small)
  final int detectLongSide;

  /// The camera stream asked for (640 x 480 at 30 by default)
  final int width;
  final int height;
  final int fps;

  /// Refuse a camera whose formats are all grey ([HeadTrackerError.greyOnly]): for a camera taken by default, never for
  /// one the user picked
  final bool colourOnly;
}

/// What a tracker runs with
class HeadTrackerInfo {
  const HeadTrackerInfo({
    required this.detector,
    required this.framing,
    required this.width,
    required this.height,
    required this.fpsNumerator,
    required this.fpsDenominator,
    required this.nativeFourcc,
    required this.hresult,
  });

  final FaceDetectorBuild detector;
  final AutoFramingState framing;
  final int width;
  final int height;
  final int fpsNumerator;
  final int fpsDenominator;

  /// The camera's or the file's own format ("NV12", "YUY2", "MJPG", "H264"), empty when not known
  final String nativeFourcc;
  final int hresult;

  double? get fps => fpsDenominator == 0 ? null : fpsNumerator / fpsDenominator;
}
