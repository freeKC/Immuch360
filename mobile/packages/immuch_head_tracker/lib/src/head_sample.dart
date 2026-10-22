// What the tracker gives: one sample per analysed frame, the errors that stop it, and what it runs with. The numbers
// mirror src/ht_api.h.

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
  /// Camera access is turned off for desktop apps (Settings, Privacy and security, Camera): show the privacy message
  /// with the [cameraPrivacySettingsUri] button
  accessDenied,

  /// No Media Foundation: a Windows N edition without the Media Feature Pack (or a Windows Server without the feature)
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
}

/// The Settings page where camera access for desktop apps is turned on, for the button of the privacy message
const cameraPrivacySettingsUri = 'ms-settings:privacy-webcam';

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

  /// Faces found in the frame (the sample describes the largest)
  final int faces;

  /// [timeUs] in the nanoseconds of [HeadViewpoint] and [OneEuroFilter]
  int get timeNanos => timeUs * 1000;

  bool get hasFace => state == HeadFaceState.face;
  bool get lost => state == HeadFaceState.lost;

  /// The head's horizontal position as the phones measure it (HeadTracker.kt): -0.5 to 0.5 in the mirrored picture,
  /// larger when the head moves to the user's right. A webcam does not mirror its frames, so a head moving to the user's
  /// right moves to the left of the frame: headX = 0.5 - faceX. NaN without a face.
  double get headX => hasFace ? (0.5 - faceX).clamp(-0.5, 0.5) : double.nan;

  @override
  String toString() =>
      'HeadSample(#$sequence at $timeUs us, ${state.name}, x ${faceX.toStringAsFixed(4)}, '
      'confidence ${confidence.toStringAsFixed(2)}, $detectUs us)';
}

/// The detector build: [auto] takes the AVX2 build when the processor and Windows allow it (unless the environment
/// variable IMMUCH360_FACE_DETECTOR is "plain")
enum FaceDetectorBuild { auto, plain, avx2 }

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
  });

  final FaceDetectorBuild detector;

  /// Analyse one frame in this many (2 by default: 15 analyses a second from a 30 fps camera)
  final int detectEvery;

  /// The lowest detector score, 1 to 100, that counts as a face (50 by default)
  final int minScore;

  /// The long side of the detector image (160 by default)
  final int detectLongSide;

  /// The camera stream asked for (640 x 480 at 30 by default)
  final int width;
  final int height;
  final int fps;
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
