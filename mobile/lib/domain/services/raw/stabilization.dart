// Stabilisation of a 360° video at playback with the motion track of its camera (issue 14): the orientation of the
// camera at each frame, a target view that keeps the horizon level and follows the heading of the camera slowly, and
// the rotation from one to the other for each frame, the table the player applies.
//
// Quaternions are (w, x, y, z), Hamilton product, rotations acting on vectors: R(p q) = R(p) R(q).
//
// 1. Orientation of the body. The gyroscope gives the rate of the body in its own frame (x right, y down, z along lens
//    0, dual_fisheye_math.dart). From one sample to the next the rate is taken constant, the mean of the two, and the
//    rotation of the step is its exact exponential: q_k = q_(k-1) exp((w_(k-1) + w_k) / 2 dt), exp(v) = (cos |v| / 2,
//    sin(|v| / 2) v / |v|), q the rotation from the body to the world of the first sample. A frame is taken at its
//    record 4 time less half its exposure plus 4 ms (the offset measured against the picture, research.md section 3),
//    inside its step with the same rate. Cameras that write their orientation (GoPro, DJI) give q themselves, blended
//    (slerp) to the frame times (cameraOrientationTrackOf), seen from the view of their stitch (goProViewToGpmf,
//    djiViewToBody).
// 2. View frame. The stitch shows the camera's view: B = bodyFrame(downBody), the rotation from the view (x right, y
//    down, z forward, levelled by the gravity the stitch uses) to the body. With G = R(q_0) B for the first frame, the
//    camera's view at frame i into the view of the first frame (the world from now on) is C_i = G^T R(q_i) B, so C_0 =
//    identity.
// 3. Up. The accelerometer turned into the world, R(q) a, averaged over 2 s windows of the video clock; a window is kept
//    when it spans at least 1 s and its mean is 0.95 to 1.05 g (a vehicle leaning in a turn reads more: those are left
//    out). The unit means of the kept windows are smoothed with the two sided exponential of 30 s, exp(-|t - t_j| /
//    30 s) normalised, the filter forward then backward with its weights normalised at the ends; then interpolated at
//    each frame. This takes out the slow drift of the gyroscope without following the turns. With no window kept the
//    level of the stitch stays (up = -y of the first view). A camera that levels its own attitude gives the up of its
//    world instead; one that gives gravity per frame (GoPro GRAV) feeds the windows with it.
// 4. Heading. The azimuth of the camera's view forward C_i z about the up, from the world forward laid level (positive
//    to the right), unwrapped; held where the view looks within 6 degrees of the vertical (no azimuth there). Smoothed
//    with the two sided exponential of 1 s: the file is known whole, so the view follows the road without lag and
//    without the shake. A headset (the immersive viewer of the Meta Quest) smooths over 2 s and caps the speed of the
//    heading (StabilizationOptions.headset): in a headset a sudden turn of the world is worse than the shake. The cap
//    limits the change from frame to frame, once forward and once backward, and takes the mean of the two passes, so
//    that the view starts a fast turn early and ends it late rather than only late.
// 5. Target and correction. The target view T_i is level (down = -up) and looks at the smoothed heading. The player
//    turns the sphere of the stitched frame by K_i = T_i^T C_i: the point at direction d of the camera's view goes to
//    K_i d, where the viewer looking at K_i d sees the world direction C_i d, so the viewer at direction e sees T_i e,
//    the world as the target sees it. Written with the orientations from the world to the view (c = C^T, t = T^T, the
//    way GoPro writes CORI), k = t c^-1: k x camera = target.
// 6. Start of a DJI file. The fusion of the Osmo 360 leans in the first seconds of a ride (20 degrees at 0 s, under 1
//    degree after 4 s on the sample, while its picture stays level, lot a3): the correction of its frames fades in
//    from none at the first frame of the video to the whole of it after djiFadeInSeconds, so that the horizon does not
//    slide by the lean of the fusion while it settles.
// 7. Time of a frame. The player looks the correction up by the presentation time of each frame. GoPro and DJI give
//    their frames on the timeline of the video (frame n at n frame durations, a frame without a record leaving a gap):
//    with the frame duration given, each frame is put on the nearest multiple of it. The frames of an Insta360 are on
//    the clock of the camera, which runs about 33 ppm off: frame i is at i frame durations.
//
// Memory: the samples go through one chunk at a time; the tables hold one orientation per frame.
//
// Pure Dart: the reader of the motion track reads the bytes, from a file on the device or with HTTP range requests.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/raw/camera_motion.dart';
import 'package:immich_mobile/domain/models/raw/stabilization.dart';
import 'package:immich_mobile/domain/services/raw/dji_motion.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart' show Mat3, Vec3, bodyFrame;
import 'package:immich_mobile/domain/services/raw/gopro_motion.dart';
import 'package:immich_mobile/domain/services/raw/insta360_motion.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart' show ByteRangeReader;
import 'package:logging/logging.dart';

final _log = Logger('Stabilization');

/// Most bytes of IMU samples read for a stabilisation: about 80 minutes of raw samples at 1 kHz, read in chunks
const insta360MaxStabilizationImuLength = 96 * 1024 * 1024;

/// Samples whose accelerometer levels the view when no gravity is given: the 1 MiB of raw samples the stitch levels a
/// video with (insta360MaxImuLength)
const stabilizationLevelSamples = 1024 * 1024 ~/ 20;

// A step between two samples longer than this, in seconds, is counted as a gap
const _gapSeconds = 0.02;

// Below this length of the level part of the view forward (the sine of 6 degrees from the vertical) the heading holds
const _minLevelForward = 0.1;

const _degrees = 180 / math.pi;

/// The settings of a stabilisation, measured on the X3, X4 and X5 (study of 5 November 2026)
class StabilizationOptions {
  const StabilizationOptions({
    this.gyroOffsetSeconds = 0.004,
    this.headingTimeConstant = 1.0,
    this.levelTimeConstant = 30.0,
    this.levelWindowSeconds = 2.0,
    this.levelMinNorm = 0.95,
    this.levelMaxNorm = 1.05,
    this.djiFadeInSeconds = 5.0,
    this.headingMaxDegreesPerSecond,
  });

  /// The settings of the immersive viewer of the Meta Quest (issue 14, lot d3): the heading smoothed over 2 s and
  /// turning at most 30 degrees a second, since in a headset a sudden turn of the world is worse than the shake
  static const headset = StabilizationOptions(headingTimeConstant: 2.0, headingMaxDegreesPerSecond: 30);

  /// Added to the time of a frame less half its exposure to take the gyroscope at that frame, in seconds
  final double gyroOffsetSeconds;

  /// Time constant of the smoothing of the heading, forward and backward, in seconds
  final double headingTimeConstant;

  /// Time constant of the smoothing of the up, forward and backward, in seconds
  final double levelTimeConstant;

  /// Length of the windows the accelerometer is averaged over, in seconds
  final double levelWindowSeconds;

  /// Norms of the mean of a window, in g, between which it levels the view
  final double levelMinNorm;
  final double levelMaxNorm;

  /// Time over which the correction of a DJI file fades in from its first frame, in seconds, while the fusion of the
  /// camera settles (head of this file, step 6); 0 applies it whole from the start
  final double djiFadeInSeconds;

  /// Fastest the smoothed heading turns, in degrees a second (head of this file, step 4); null for no limit
  final double? headingMaxDegreesPerSecond;

  @override
  String toString() =>
      'StabilizationOptions(heading: $headingTimeConstant s'
      '${headingMaxDegreesPerSecond == null ? '' : ', at most $headingMaxDegreesPerSecond degrees/s'})';
}

/// The steps of a table frame by frame, filled when given to a builder: for the tests and the measures
class StabilizationDetails {
  /// The rotation from the world (the view of the first frame) to the camera's view at each frame, four values each
  Float64List camera = Float64List(0);

  /// The rotation from the world to the target view at each frame, four values each
  Float64List target = Float64List(0);

  /// The up the frame is levelled with, in the world, three values each
  Float64List up = Float64List(0);

  /// The heading of the camera, unwrapped, and smoothed, in radians
  Float64List heading = Float64List(0);
  Float64List smoothedHeading = Float64List(0);

  /// The time each orientation was taken at, in seconds on the clock of the track
  Float64List times = Float64List(0);

  /// The rotation from the view to the body frame the table was built with
  Mat3 viewToBody = Mat3.identity;
}

/// Reads the motion track of the Insta360 video of [fileSize] bytes that [read] reads chunk after chunk (see
/// [readInsta360Motion]) and builds its stabilisation table; memory holds one chunk of samples and one orientation per
/// frame. [downBody] is the gravity the stitch levels the video with (DualFisheyeCalibration.downBody); null takes it
/// from the first samples as the stitch does. [frameDurationUs] is the duration of a frame on the timeline of the
/// video: given, frame i is at i times it (the timeline of the file); null, at the time of its entry in record 4 (the
/// clock of the camera, which runs about 33 ppm off the nominal 29.97 frames a second of the X3 to X5 files: a frame
/// off after 15 minutes). Null when the file has no motion track or no frame times.
Future<StabilizationTable?> readInsta360Stabilization(
  ByteRangeReader read,
  int fileSize, {
  List<double>? downBody,
  double? frameDurationUs,
  StabilizationOptions options = const StabilizationOptions(),
  int maxImuLength = insta360MaxStabilizationImuLength,
  int chunkLength = insta360MotionChunkLength,
  StabilizationDetails? details,
}) async {
  final stabilizer = GyroStabilizer(downBody: downBody, frameDurationUs: frameDurationUs, options: options);
  final track = await readInsta360Motion(
    read,
    fileSize,
    maxImuLength: maxImuLength,
    chunkLength: chunkLength,
    sink: stabilizer,
  );
  if (track == null) {
    return null;
  }
  if (track.truncated) {
    _log.warning('Stabilization: the motion track was read in part, the last frames hold the last orientation');
  }
  return stabilizer.finish(details: details);
}

/// The stabilisation table of a motion track whose samples were read whole; see [readInsta360Stabilization] for
/// [downBody] and [frameDurationUs]. The samples go to the integration [chunkSamples] at a time, as a read chunk after
/// chunk gives them.
StabilizationTable? stabilizationOfMotionTrack(
  CameraMotionTrack track, {
  List<double>? downBody,
  double? frameDurationUs,
  StabilizationOptions options = const StabilizationOptions(),
  int chunkSamples = 65536,
  StabilizationDetails? details,
}) {
  final stabilizer = GyroStabilizer(downBody: downBody, frameDurationUs: frameDurationUs, options: options);
  stabilizer.begin(track);
  final samples = track.samples;
  final step = math.max(1, chunkSamples);
  for (var start = 0; start < samples.length; start += step) {
    final end = math.min(samples.length, start + step);
    stabilizer.add(
      CameraMotionSamples(
        times: Float64List.sublistView(samples.times, start, end),
        rotationRates: Float32List.sublistView(samples.rotationRates, 3 * start, 3 * end),
        accelerations: Float32List.sublistView(samples.accelerations, 3 * start, 3 * end),
      ),
    );
  }
  return stabilizer.finish(details: details);
}

/// The stabilisation table of a camera that writes its own orientation ([CameraOrientationTrack]): its orientations
/// blended (slerp) to [frameTimes] (seconds, the clock of the track; a reader shifts its times by an offset it
/// measured), its gravity blended the same way when it gives one, [viewToBody] the rotation from the view frame of the
/// stitch (x right, y down, z forward) to the body frame of its orientations. [framesOnVideoTimeline]: the frame times
/// are on the timeline of the video (time 0 at its first frame, as GoPro and DJI give them); each frame is then at its
/// time put on the nearest multiple of [frameDurationUs] when given, at its time otherwise. Not on it (the clock of a
/// camera), frame i is at i times [frameDurationUs], or at its time less the time of frame 0 without it. The
/// correction fades in over the first [fadeInSeconds] of the video (0 for none). Null without frames or orientations.
StabilizationTable? stabilizationOfOrientations(
  CameraOrientationTrack track, {
  required Float64List frameTimes,
  required Mat3 viewToBody,
  double? frameDurationUs,
  bool framesOnVideoTimeline = true,
  double fadeInSeconds = 0,
  StabilizationOptions options = const StabilizationOptions(),
  StabilizationDetails? details,
}) {
  final count = frameTimes.length;
  if (count == 0 || track.length == 0) {
    _log.info('Stabilization: ${track.label} has no ${count == 0 ? 'frame' : 'orientation'}, no table');
    return null;
  }
  final times = track.times;
  final source = track.orientations;
  final gravity = track.gravity;
  final worldUp = track.worldUp;
  final orientations = Float64List(4 * count);
  final windows = _LevelWindows(options.levelWindowSeconds);
  var outside = 0;
  var j = 0;
  for (var i = 0; i < count; i++) {
    final time = frameTimes[i];
    while (j + 1 < times.length && times[j + 1] <= time) {
      j++;
    }
    final int a;
    final int b;
    final double share;
    if (time <= times.first) {
      a = b = 0;
      share = 0;
      outside += time < times.first ? 1 : 0;
    } else if (j + 1 >= times.length) {
      a = b = times.length - 1;
      share = 0;
      outside += time > times.last ? 1 : 0;
    } else {
      a = j;
      b = j + 1;
      final span = times[b] - times[a];
      share = span <= 0 ? 0.0 : (time - times[a]) / span;
    }
    final q = slerpQuaternion(
      [source[4 * a], source[4 * a + 1], source[4 * a + 2], source[4 * a + 3]],
      [source[4 * b], source[4 * b + 1], source[4 * b + 2], source[4 * b + 3]],
      share,
    );
    orientations.setRange(4 * i, 4 * i + 4, q);
    if (gravity != null && worldUp == null) {
      // Up is opposite to gravity; blended, made unit long, turned into the world
      final gx = gravity[3 * a] + share * (gravity[3 * b] - gravity[3 * a]);
      final gy = gravity[3 * a + 1] + share * (gravity[3 * b + 1] - gravity[3 * a + 1]);
      final gz = gravity[3 * a + 2] + share * (gravity[3 * b + 2] - gravity[3 * a + 2]);
      final norm = math.sqrt(gx * gx + gy * gy + gz * gz);
      if (norm > 1e-9 && norm.isFinite) {
        final up = _rotate(q[0], q[1], q[2], q[3], -gx / norm, -gy / norm, -gz / norm);
        windows.add(time, up.x, up.y, up.z);
      }
    }
  }
  windows.finish();
  return _buildTable(
    label: track.label,
    orientations: orientations,
    times: frameTimes,
    presentationTimesUs: _presentationTimes(frameTimes, frameDurationUs, onVideoTimeline: framesOnVideoTimeline),
    frameTimes: frameTimes,
    viewToBody: viewToBody,
    windows: gravity != null && worldUp == null ? windows : null,
    worldUp: worldUp,
    options: options,
    outside: outside,
    fadeInSeconds: framesOnVideoTimeline ? fadeInSeconds : 0,
    details: details,
  );
}

/// The rotation from the view frame of the stitch of a GoPro .360 (x right, y down, z forward: the view gopro_eac.dart
/// shows, upright when the camera stands) to the axes of its GPMF camera frame (CORI, GRAV), row major: GPMF x is the
/// view's down, y its left, z its forward. Measured on the picture of the MAX sample GS010013.360 (study of 5 November
/// 2026, lots/gopro_vision.py and gopro_sky.py): the camera turns about GPMF y and the picture about the view's x axis,
/// and GRAV follows the down of the sky in the picture within 3 degrees over a turn of 150 degrees once taken as
/// pointing down. The angle about GPMF y cannot be told from that one turn (the fits give 15 to 22 degrees, the bias of
/// the sky and the parallax of the ground nearby): the axes of the camera are taken square. The MAX 2 has its own,
/// [goProMax2ViewToGpmf].
const goProViewToGpmf = Mat3([0, 1, 0, -1, 0, 0, 0, 0, 1]);

/// The rotation from the view frame of the stitch of a GoPro MAX 2 .360 to the axes of its GPMF camera frame: the same
/// axes, GPMF x the view's right, y its down, z its forward. The MAX's matrix with the quarter turn of its faces
/// ([goProViewToCamera]) taken off. Measured on three MAX 2 files of firmware H24.02.01.09.71 (14 November 2026,
/// lots/feat-raw-2026-48.md): GRAV of a camera standing upright lies along +y within 3 degrees; on a clip from a car
/// that turns by 90 degrees, CORI turns frame j back onto frame i best with these axes (sum of the grey differences
/// above the horizon over 8 pairs 100.3, against 107.4 to 119.3 for the three other turns about the vertical, 110.8
/// unturned and 161.8 with the MAX's matrix).
const goProMax2ViewToGpmf = Mat3.identity;

/// The rotation from the view frame of the stitch of a DJI Osmo 360 .osv to the body frame of its attitude, row major:
/// bodyFrame([0, 1, 0]), the view of an upright Insta360 (lot a3, the attitude checked against the picture)
const djiViewToBody = Mat3([-1, 0, 0, 0, 1, 0, 0, 0, -1]);

/// The up of the world of the DJI attitude: its z points down along gravity
const djiWorldUp = [0.0, 0.0, -1.0];

/// The orientations a camera wrote for its frames ([CameraMotionTrack.frameOrientations], from the world to the
/// camera), as the input of [stabilizationOfOrientations]: their inverse (from the camera to the world), made unit
/// long, at [CameraMotionTrack.frameTimes]. A frame whose orientation is not a number or far from unit long is left out
/// (the table blends over it). The gravity of a GoPro (GRAV, which points down) goes along; the world of a DJI attitude
/// is level already ([djiWorldUp]). Null when the track has no orientation, or none that can be used.
CameraOrientationTrack? cameraOrientationTrackOf(CameraMotionTrack track) {
  final source = track.frameOrientations;
  if (source == null) {
    return null;
  }
  final frames = track.frameTimes.length;
  final gravity = track.frameGravity;
  final kept = <int>[];
  for (var i = 0; i < frames; i++) {
    final w = source[4 * i];
    final x = source[4 * i + 1];
    final y = source[4 * i + 2];
    final z = source[4 * i + 3];
    final norm = math.sqrt(w * w + x * x + y * y + z * z);
    if (norm.isFinite && norm > 0.5 && norm < 1.5) {
      kept.add(i);
    }
  }
  if (kept.isEmpty) {
    return null;
  }
  if (kept.length < frames) {
    _log.info('Stabilization: ${frames - kept.length} of $frames frames have no orientation, blended over');
  }
  final times = Float64List(kept.length);
  final orientations = Float64List(4 * kept.length);
  final down = gravity == null ? null : Float32List(3 * kept.length);
  for (var j = 0; j < kept.length; j++) {
    final i = kept[j];
    times[j] = track.frameTimes[i];
    final w = source[4 * i];
    final x = source[4 * i + 1];
    final y = source[4 * i + 2];
    final z = source[4 * i + 3];
    final norm = math.sqrt(w * w + x * x + y * y + z * z);
    // The conjugate: from the camera to the world
    orientations[4 * j] = w / norm;
    orientations[4 * j + 1] = -x / norm;
    orientations[4 * j + 2] = -y / norm;
    orientations[4 * j + 3] = -z / norm;
    if (down != null) {
      down.setRange(3 * j, 3 * j + 3, gravity!, 3 * i);
    }
  }
  return switch (track.source) {
    CameraMotionSource.djiAttitude => CameraOrientationTrack(
      label: 'DJI attitude',
      times: times,
      orientations: orientations,
      worldUp: djiWorldUp,
    ),
    CameraMotionSource.goProGpmf => CameraOrientationTrack(
      label: 'GoPro CORI',
      times: times,
      orientations: orientations,
      gravity: down,
    ),
    CameraMotionSource.insta360Imu => CameraOrientationTrack(
      label: 'Insta360 orientation',
      times: times,
      orientations: orientations,
      gravity: down,
    ),
  };
}

/// The rotation from the view frame of the stitch to the body frame of the orientations of [source]: [goProViewToGpmf]
/// or [djiViewToBody]; null for a source that gives raw samples (its view comes from the gravity the stitch uses)
Mat3? viewToBodyOf(CameraMotionSource source) => switch (source) {
  CameraMotionSource.goProGpmf => goProViewToGpmf,
  CameraMotionSource.djiAttitude => djiViewToBody,
  CameraMotionSource.insta360Imu => null,
};

/// The stabilisation table of any motion track: the gyroscope integrated for a track of raw samples (Insta360, see
/// [stabilizationOfMotionTrack] for [downBody]), the orientations the camera wrote for the others (GoPro, DJI: see
/// [cameraOrientationTrackOf] and [stabilizationOfOrientations]), seen from the view of their stitch ([viewToBody],
/// [viewToBodyOf] when null). [frameDurationUs] as in [readInsta360Stabilization]. Null without frames or orientations.
StabilizationTable? stabilizationOfCameraMotion(
  CameraMotionTrack track, {
  List<double>? downBody,
  Mat3? viewToBody,
  double? frameDurationUs,
  StabilizationOptions options = const StabilizationOptions(),
  StabilizationDetails? details,
}) {
  final orientations = cameraOrientationTrackOf(track);
  if (orientations == null) {
    if (track.samples.isEmpty) {
      _log.info('Stabilization: ${track.source.name} has neither samples nor orientations, no table');
      return null;
    }
    return stabilizationOfMotionTrack(
      track,
      downBody: downBody,
      frameDurationUs: frameDurationUs,
      options: options,
      details: details,
    );
  }
  final toBody = viewToBody ?? viewToBodyOf(track.source);
  if (toBody == null) {
    _log.warning('Stabilization: no view to body rotation for ${track.source.name}, no table');
    return null;
  }
  return stabilizationOfOrientations(
    orientations,
    frameTimes: track.frameTimes,
    viewToBody: toBody,
    frameDurationUs: frameDurationUs,
    framesOnVideoTimeline: track.source != CameraMotionSource.insta360Imu,
    fadeInSeconds: track.source == CameraMotionSource.djiAttitude ? options.djiFadeInSeconds : 0,
    options: options,
    details: details,
  );
}

/// The rotation from the view of the stitch to the GPMF axes of the GoPro named [cameraModel] (DVNM), measured
/// against its picture: [goProViewToGpmf] for the MAX ("GoPro Max"), [goProMax2ViewToGpmf] for the MAX 2 ("MAX2");
/// for a file that does not name its camera, by the side of its EAC faces ([face]: 1920 on the MAX 2, the MAX
/// otherwise). Null for any other camera, whose axes were not measured: taken with another camera's matrix, its
/// stabilised video could play rolled by 90 degrees.
Mat3? goProViewToGpmfOf(String? cameraModel, {int? face}) {
  if (cameraModel == null) {
    return face == goProMax2Face ? goProMax2ViewToGpmf : goProViewToGpmf;
  }
  return switch (cameraModel.trim().toLowerCase().replaceAll(' ', '')) {
    'gopromax' => goProViewToGpmf,
    'max2' || 'gopromax2' => goProMax2ViewToGpmf,
    _ => null,
  };
}

/// Side of the EAC faces of the GoPro MAX 2
const goProMax2Face = 1920;

/// Whether the axes of the GPMF of the GoPro named [cameraModel] (DVNM) were measured against its picture
/// ([goProViewToGpmfOf]): the MAX and the MAX 2. A file that does not name its camera counts as measured; the caller
/// checks its faces.
bool goProAxesMeasured(String? cameraModel) => goProViewToGpmfOf(cameraModel) != null;

/// Reads the GPMF track of the GoPro .360 of [fileSize] bytes that [read] reads ([readGoProMotion]) and builds its
/// stabilisation table from CORI and GRAV, the frames on the clock of the video track, seen through the axes of its
/// camera ([goProViewToGpmfOf], [face] the side of its EAC faces when known). Null when the file has no CORI, or when it
/// comes from a GoPro whose axes were not measured.
Future<StabilizationTable?> readGoProStabilization(
  ByteRangeReader read,
  int fileSize, {
  int? face,
  double? frameDurationUs,
  StabilizationOptions options = const StabilizationOptions(),
  StabilizationDetails? details,
}) async {
  final track = await readGoProMotion(read, fileSize);
  if (track == null) {
    return null;
  }
  final viewToGpmf = goProViewToGpmfOf(track.cameraModel, face: face);
  if (viewToGpmf == null) {
    _log.info('Stabilization: the axes of the ${track.cameraModel} were not measured against its picture, no table');
    return null;
  }
  if (track.truncated) {
    _log.warning('Stabilization: the GPMF track was read in part, the last frames hold the last orientation');
  }
  return stabilizationOfCameraMotion(
    track,
    viewToBody: viewToGpmf,
    frameDurationUs: frameDurationUs,
    options: options,
    details: details,
  );
}

/// Reads the attitude of the DJI Osmo 360 .osv of [fileSize] bytes that [read] reads ([readDjiMotion]) and builds its
/// stabilisation table, levelled by the world of the attitude. The fusion of the camera may lean in the first seconds
/// of a ride (20 degrees at 0 s, under 1 degree after 4 s on the sample): the correction fades in over the first
/// [StabilizationOptions.djiFadeInSeconds] (head of this file, step 6). Null when the file has no attitude.
Future<StabilizationTable?> readDjiStabilization(
  ByteRangeReader read,
  int fileSize, {
  double? frameDurationUs,
  StabilizationOptions options = const StabilizationOptions(),
  StabilizationDetails? details,
}) async {
  final track = await readDjiMotion(read, fileSize);
  if (track == null) {
    return null;
  }
  if (track.truncated) {
    _log.warning('Stabilization: the camd box was read in part, the last frames hold the last orientation');
  }
  return stabilizationOfCameraMotion(track, frameDurationUs: frameDurationUs, options: options, details: details);
}

/// Integrates the gyroscope of a motion track, chunk after chunk, into the orientation of the camera at each frame,
/// and the accelerometer into the windows that level it; then builds the table ([finish]). Give it to
/// [readInsta360Motion] as its sink, or feed it a track whose samples were read whole.
class GyroStabilizer implements CameraMotionSampleSink {
  GyroStabilizer({this.downBody, this.frameDurationUs, this.options = const StabilizationOptions()})
    : _windows = _LevelWindows(options.levelWindowSeconds);

  /// The gravity the stitch levels the video with, in the body frame; null takes it from the first samples
  final List<double>? downBody;

  /// Duration of a frame on the timeline of the video, in microseconds; see [readInsta360Stabilization]
  final double? frameDurationUs;

  final StabilizationOptions options;

  final _LevelWindows _windows;

  CameraMotionTrack? _track;
  String _label = 'Gyroscope';

  // The time each frame is taken at, and the orientation there (body to the world of the first sample)
  Float64List _times = Float64List(0);
  Float64List _orientations = Float64List(0);
  int _next = 0;

  // The orientation at the last sample, its time and rate
  double _w = 1;
  double _x = 0;
  double _y = 0;
  double _z = 0;
  double _lastTime = 0;
  double _lastRateX = 0;
  double _lastRateY = 0;
  double _lastRateZ = 0;

  int _samples = 0;
  int _gaps = 0;
  int _outside = 0;

  // Sum of the first accelerometer samples, in the body frame, for the level of the stitch
  double _levelX = 0;
  double _levelY = 0;
  double _levelZ = 0;
  int _levelCount = 0;

  @override
  void begin(CameraMotionTrack track) {
    _track = track;
    _label = '${track.cameraModel ?? track.source.name} gyroscope';
    final frames = track.frameTimes;
    final exposures = track.frameExposures;
    _times = Float64List(frames.length);
    for (var i = 0; i < frames.length; i++) {
      // An exposure the file does not give counts as none
      final exposure = i < exposures.length && exposures[i].isFinite ? exposures[i] : 0.0;
      final time = frames[i] - exposure / 2 + options.gyroOffsetSeconds;
      // A sudden change of exposure must not take a frame before the one before it
      _times[i] = i > 0 && time < _times[i - 1] ? _times[i - 1] : time;
    }
    _orientations = Float64List(4 * frames.length);
  }

  @override
  void add(CameraMotionSamples chunk) {
    final times = chunk.times;
    final rates = chunk.rotationRates;
    final accelerations = chunk.accelerations;
    final frameTimes = _times;
    final orientations = _orientations;
    final frames = frameTimes.length;
    var w = _w;
    var x = _x;
    var y = _y;
    var z = _z;
    for (var k = 0; k < times.length; k++) {
      final time = times[k];
      final rateX = rates[3 * k];
      final rateY = rates[3 * k + 1];
      final rateZ = rates[3 * k + 2];
      if (_samples == 0) {
        // Frames at or before the first sample: its orientation, the identity
        while (_next < frames && frameTimes[_next] <= time) {
          orientations[4 * _next] = 1;
          _outside += frameTimes[_next] < time ? 1 : 0;
          _next++;
        }
      } else {
        final dt = time - _lastTime;
        if (dt > _gapSeconds) {
          _gaps++;
        }
        final meanX = 0.5 * (_lastRateX + rateX);
        final meanY = 0.5 * (_lastRateY + rateY);
        final meanZ = 0.5 * (_lastRateZ + rateZ);
        while (_next < frames && frameTimes[_next] <= time) {
          final h = frameTimes[_next] - _lastTime;
          final step = _exp(meanX * h, meanY * h, meanZ * h);
          final o = 4 * _next;
          orientations[o] = w * step.w - x * step.x - y * step.y - z * step.z;
          orientations[o + 1] = w * step.x + x * step.w + y * step.z - z * step.y;
          orientations[o + 2] = w * step.y - x * step.z + y * step.w + z * step.x;
          orientations[o + 3] = w * step.z + x * step.y - y * step.x + z * step.w;
          _next++;
        }
        final step = _exp(meanX * dt, meanY * dt, meanZ * dt);
        final nw = w * step.w - x * step.x - y * step.y - z * step.z;
        final nx = w * step.x + x * step.w + y * step.z - z * step.y;
        final ny = w * step.y - x * step.z + y * step.w + z * step.x;
        final nz = w * step.z + x * step.y - y * step.x + z * step.w;
        final norm = math.sqrt(nw * nw + nx * nx + ny * ny + nz * nz);
        w = nw / norm;
        x = nx / norm;
        y = ny / norm;
        z = nz / norm;
      }
      final ax = accelerations[3 * k];
      final ay = accelerations[3 * k + 1];
      final az = accelerations[3 * k + 2];
      final up = _rotate(w, x, y, z, ax, ay, az);
      _windows.add(time, up.x, up.y, up.z);
      if (_levelCount < stabilizationLevelSamples) {
        _levelX += ax;
        _levelY += ay;
        _levelZ += az;
        _levelCount++;
      }
      _lastTime = time;
      _lastRateX = rateX;
      _lastRateY = rateY;
      _lastRateZ = rateZ;
      _samples++;
    }
    _w = w;
    _x = x;
    _y = y;
    _z = z;
  }

  /// The table of the frames of the track; null without frames or samples, and null for a track that does not say
  /// which entry is the first frame of the video ([CameraMotionTimeOrigin.firstFrame]): on every file measured the
  /// first frame entry comes 4 to 8 entries before the first frame, so such a table would be 130 to 270 ms late and
  /// add shake. [details], when given, gets the steps.
  StabilizationTable? finish({StabilizationDetails? details}) {
    final track = _track;
    if (track == null || _times.isEmpty || _samples == 0) {
      _log.info(
        'Stabilization: ${track == null
            ? 'no track'
            : _times.isEmpty
            ? 'no frame times'
            : 'no sample'}',
      );
      return null;
    }
    if (track.timeOrigin != CameraMotionTimeOrigin.firstFrame) {
      _log.warning(
        'Stabilization: the ${track.cameraModel ?? 'camera'} does not say which entry is the first frame '
        '(${track.timeOrigin.name}), no table',
      );
      return null;
    }
    // Frames after the last sample hold its orientation
    while (_next < _times.length) {
      final o = 4 * _next;
      _orientations[o] = _w;
      _orientations[o + 1] = _x;
      _orientations[o + 2] = _y;
      _orientations[o + 3] = _z;
      _outside += _times[_next] > _lastTime ? 1 : 0;
      _next++;
    }
    _windows.finish();
    final down = downBody ?? [-_levelX, -_levelY, -_levelZ];
    return _buildTable(
      label: _label,
      orientations: _orientations,
      times: _times,
      presentationTimesUs: _presentationTimes(track.frameTimes, frameDurationUs, onVideoTimeline: false),
      frameTimes: track.frameTimes,
      viewToBody: bodyFrame(down),
      windows: _windows,
      options: options,
      outside: _outside,
      samples: _samples,
      gaps: _gaps,
      details: details,
    );
  }
}

/// The accelerometer turned into the world, averaged over windows of the video clock
class _LevelWindows {
  _LevelWindows(this.seconds);

  final double seconds;

  /// Mean time, mean vector (three values) and span of each window that had samples
  final times = <double>[];
  final means = <double>[];
  final spans = <double>[];

  int? _index;
  double _sumX = 0;
  double _sumY = 0;
  double _sumZ = 0;
  double _sumTime = 0;
  int _count = 0;
  double _first = 0;
  double _last = 0;

  void add(double time, double x, double y, double z) {
    final index = (time / seconds).floor();
    if (index != _index) {
      _close();
      _index = index;
      _first = time;
    }
    _sumX += x;
    _sumY += y;
    _sumZ += z;
    _sumTime += time;
    _count++;
    _last = time;
  }

  void finish() => _close();

  void _close() {
    if (_count > 0) {
      times.add(_sumTime / _count);
      means
        ..add(_sumX / _count)
        ..add(_sumY / _count)
        ..add(_sumZ / _count);
      spans.add(_last - _first);
    }
    _sumX = _sumY = _sumZ = _sumTime = 0;
    _count = 0;
  }
}

// The presentation time of each frame, in microseconds (head of this file, step 7). Frame times [onVideoTimeline]: the
// time on the nearest multiple of the frame duration, or the time itself. On the clock of a camera: i times the frame
// duration, or the frame time less the one of frame 0.
Int64List _presentationTimes(Float64List frameTimes, double? frameDurationUs, {required bool onVideoTimeline}) {
  final times = Int64List(frameTimes.length);
  for (var i = 0; i < frameTimes.length; i++) {
    final double us;
    if (onVideoTimeline) {
      us = frameDurationUs != null
          ? (frameTimes[i] * 1e6 / frameDurationUs).round() * frameDurationUs
          : frameTimes[i] * 1e6;
    } else {
      us = frameDurationUs != null ? i * frameDurationUs : (frameTimes[i] - frameTimes[0]) * 1e6;
    }
    times[i] = us.round();
  }
  return times;
}

/// The table from the orientation of the body at each frame ([orientations], body to a world, four values a frame,
/// taken at [times]); see the head of this file for the steps
StabilizationTable _buildTable({
  required String label,
  required Float64List orientations,
  required Float64List times,
  required Int64List presentationTimesUs,
  required Float64List frameTimes,
  required Mat3 viewToBody,
  required StabilizationOptions options,
  _LevelWindows? windows,
  List<double>? worldUp,
  int outside = 0,
  int samples = 0,
  int gaps = 0,
  double fadeInSeconds = 0,
  StabilizationDetails? details,
}) {
  final count = times.length;
  final b = _quaternionOf(viewToBody);
  // G = R(q_0) B, the view of the first frame into the world of the orientations; its inverse turns that world into
  // the world of the table
  final g = _multiply(_at(orientations, 0), b);
  final gInverse = _conjugate(g);

  // C_i = G^T R(q_i) B
  final camera = Float64List(4 * count);
  for (var i = 0; i < count; i++) {
    camera.setAll(4 * i, _multiply(_multiply(gInverse, _at(orientations, i)), b));
  }

  // The up of each frame, in the world of the table
  final up = Float64List(3 * count);
  var windowsKept = 0;
  if (worldUp != null) {
    final u = _normalized(
      _rotate(gInverse[0], gInverse[1], gInverse[2], gInverse[3], worldUp[0], worldUp[1], worldUp[2]),
    );
    for (var i = 0; i < count; i++) {
      up.setAll(3 * i, [u.x, u.y, u.z]);
    }
  } else {
    final kept = <int>[
      if (windows != null)
        for (var j = 0; j < windows.times.length; j++)
          if (windows.spans[j] >= windows.seconds / 2 &&
              _isLevel(windows.means, j, options.levelMinNorm, options.levelMaxNorm))
            j,
    ];
    windowsKept = kept.length;
    if (kept.isEmpty) {
      for (var i = 0; i < count; i++) {
        up[3 * i + 1] = -1;
      }
    } else {
      final windowTimes = Float64List.fromList([for (final j in kept) windows!.times[j]]);
      final units = Float64List(3 * kept.length);
      for (var n = 0; n < kept.length; n++) {
        final j = kept[n];
        final u = _normalized((x: windows!.means[3 * j], y: windows.means[3 * j + 1], z: windows.means[3 * j + 2]));
        units.setAll(3 * n, [u.x, u.y, u.z]);
      }
      final smoothed = _twoSided(windowTimes, units, 3, options.levelTimeConstant);
      for (var n = 0; n < kept.length; n++) {
        final u = _normalized((x: smoothed[3 * n], y: smoothed[3 * n + 1], z: smoothed[3 * n + 2]));
        smoothed.setAll(3 * n, [u.x, u.y, u.z]);
      }
      var n = 0;
      for (var i = 0; i < count; i++) {
        final time = times[i];
        while (n + 1 < kept.length && windowTimes[n + 1] <= time) {
          n++;
        }
        final Vec3 u;
        if (time <= windowTimes[0] || n + 1 >= kept.length) {
          final at = time <= windowTimes[0] ? 0 : kept.length - 1;
          u = (x: smoothed[3 * at], y: smoothed[3 * at + 1], z: smoothed[3 * at + 2]);
        } else {
          final share = (time - windowTimes[n]) / (windowTimes[n + 1] - windowTimes[n]);
          u = _normalized((
            x: smoothed[3 * n] + share * (smoothed[3 * n + 3] - smoothed[3 * n]),
            y: smoothed[3 * n + 1] + share * (smoothed[3 * n + 4] - smoothed[3 * n + 1]),
            z: smoothed[3 * n + 2] + share * (smoothed[3 * n + 5] - smoothed[3 * n + 2]),
          ));
        }
        final turned = _rotate(gInverse[0], gInverse[1], gInverse[2], gInverse[3], u.x, u.y, u.z);
        up.setAll(3 * i, [turned.x, turned.y, turned.z]);
      }
    }
  }

  // The heading of the camera's view forward, unwrapped
  final heading = Float64List(count);
  var held = 0;
  for (var i = 0; i < count; i++) {
    final u = (x: up[3 * i], y: up[3 * i + 1], z: up[3 * i + 2]);
    final (:forward, :right) = _levelReference(u);
    final c = 4 * i;
    final (w, x, y, z) = (camera[c], camera[c + 1], camera[c + 2], camera[c + 3]);
    // C z, the third column of the rotation
    final fx = 2 * (x * z + w * y);
    final fy = 2 * (y * z - w * x);
    final fz = 1 - 2 * (x * x + y * y);
    final along = fx * u.x + fy * u.y + fz * u.z;
    final hx = fx - along * u.x;
    final hy = fy - along * u.y;
    final hz = fz - along * u.z;
    if (i > 0 && math.sqrt(hx * hx + hy * hy + hz * hz) < _minLevelForward) {
      heading[i] = heading[i - 1];
      held++;
      continue;
    }
    final angle = math.atan2(
      hx * right.x + hy * right.y + hz * right.z,
      hx * forward.x + hy * forward.y + hz * forward.z,
    );
    heading[i] = i == 0 ? angle : heading[i - 1] + _wrapped(angle - heading[i - 1]);
  }
  final maxSpeed = options.headingMaxDegreesPerSecond;
  final smoothedHeading = maxSpeed == null
      ? _twoSided(times, heading, 1, options.headingTimeConstant)
      : _speedCapped(times, _twoSided(times, heading, 1, options.headingTimeConstant), maxSpeed / _degrees);

  // The target, the correction, the numbers of the summary
  final corrections = Float32List(4 * count);
  final target = details != null ? Float64List(4 * count) : null;
  final steps = Float64List(3 * math.max(0, count - 1));
  var correctionSum = 0.0;
  var correctionMax = 0.0;
  var stepSum = 0.0;
  var stepMax = 0.0;
  var viewStepSum = 0.0;
  var levelMax = 0.0;
  var faded = 0;
  List<double>? lastTarget;
  List<double>? lastCorrection;
  for (var i = 0; i < count; i++) {
    final u = (x: up[3 * i], y: up[3 * i + 1], z: up[3 * i + 2]);
    final (:forward, :right) = _levelReference(u);
    final s = smoothedHeading[i];
    final cosine = math.cos(s);
    final sine = math.sin(s);
    final f = (
      x: cosine * forward.x + sine * right.x,
      y: cosine * forward.y + sine * right.y,
      z: cosine * forward.z + sine * right.z,
    );
    final d = (x: -u.x, y: -u.y, z: -u.z);
    final r = _cross(d, f);
    final t = _quaternionOf(Mat3.columns(r, d, f));
    final c = _at(camera, i);
    var k = _multiply(_conjugate(t), c);
    if (k[0] < 0) {
      k = [-k[0], -k[1], -k[2], -k[3]];
    }
    final fade = _fadeIn(frameTimes[i], fadeInSeconds);
    if (fade < 1) {
      k = slerpQuaternion(const [1, 0, 0, 0], k, fade);
      faded++;
    }
    if (lastCorrection != null && _dot(k, lastCorrection) < 0) {
      k = [-k[0], -k[1], -k[2], -k[3]];
    }
    // The view the viewer gets, c k^-1: the target once the correction is whole
    final shown = fade < 1 ? _multiply(c, _conjugate(k)) : t;
    for (var j = 0; j < 4; j++) {
      corrections[4 * i + j] = k[j];
    }
    lastCorrection = k;
    final angle = _angle(k);
    correctionSum += angle;
    correctionMax = math.max(correctionMax, angle);
    levelMax = math.max(levelMax, math.acos(math.max(-1.0, math.min(1.0, -u.y))) * _degrees);
    if (i > 0) {
      final step = _multiply(_conjugate(_at(camera, i - 1)), c);
      final stepAngle = _angle(step);
      stepSum += stepAngle;
      stepMax = math.max(stepMax, stepAngle);
      final vector = _rotationVector(step);
      steps.setAll(3 * (i - 1), [vector.x, vector.y, vector.z]);
      viewStepSum += _angle(_multiply(_conjugate(lastTarget!), shown));
    }
    lastTarget = shown;
    target?.setAll(4 * i, _conjugate(shown));
  }
  if (faded > 0) {
    _log.info('Stabilization: the correction fades in over the first $faded frames, $fadeInSeconds s');
  }

  final summary = StabilizationSummary(
    source: label,
    frames: count,
    meanCorrectionDegrees: correctionSum / count,
    largestCorrectionDegrees: correctionMax,
    headingRangeDegrees: count == 0 ? 0 : (_max(heading) - _min(heading)) * _degrees,
    meanCameraStepDegrees: count > 1 ? stepSum / (count - 1) : 0,
    largestCameraStepDegrees: stepMax,
    meanViewStepDegrees: count > 1 ? viewStepSum / (count - 1) : 0,
    cameraShakeDegrees: _shake(steps, _framesPerSecond(frameTimes)),
    levelWindows: windows?.times.length ?? 0,
    levelWindowsKept: windowsKept,
    largestLevelDegrees: levelMax,
    framesOutsideSamples: outside,
    headingHeldFrames: held,
    samples: samples,
    sampleGaps: gaps,
  );
  if (details != null) {
    final cameraFromWorld = Float64List(4 * count);
    for (var i = 0; i < count; i++) {
      cameraFromWorld.setAll(4 * i, _conjugate(_at(camera, i)));
    }
    details
      ..camera = cameraFromWorld
      ..target = target!
      ..up = up
      ..heading = heading
      ..smoothedHeading = smoothedHeading
      ..times = times
      ..viewToBody = viewToBody;
  }
  final table = StabilizationTable(
    presentationTimesUs: presentationTimesUs,
    corrections: corrections,
    summary: summary,
  );
  _log.info('Stabilization: $summary');
  return table;
}

// The share of the correction a frame at [time] seconds of the video gets: 0 at the first frame to 1 after [seconds],
// along a smoothstep (no jump of the speed of the view at either end); 1 when [seconds] is 0
double _fadeIn(double time, double seconds) {
  if (seconds <= 0 || time >= seconds) {
    return 1;
  }
  final x = math.max(0.0, time / seconds);
  return x * x * (3 - 2 * x);
}

bool _isLevel(List<double> means, int j, double low, double high) {
  final x = means[3 * j];
  final y = means[3 * j + 1];
  final z = means[3 * j + 2];
  final norm = math.sqrt(x * x + y * y + z * z);
  return norm >= low && norm <= high;
}

/// The forward of the world laid level about [up], and the right of it: the axes the heading is measured from
({Vec3 forward, Vec3 right}) _levelReference(Vec3 up) {
  var forward = (x: -up.z * up.x, y: -up.z * up.y, z: 1 - up.z * up.z);
  if (math.sqrt(_dot3(forward, forward)) < 1e-6) {
    // The world forward is the up: the world right laid level instead
    forward = (x: 1 - up.x * up.x, y: -up.x * up.y, z: -up.x * up.z);
  }
  forward = _normalized(forward);
  // Right = down x forward, as in bodyFrame
  return (forward: forward, right: _cross((x: -up.x, y: -up.y, z: -up.z), forward));
}

/// Values smoothed with the two sided exponential of [tau] seconds: at each time, the mean of all the values weighted
/// by exp(-|t - t_j| / tau). A pass forward and one backward, the weights summed the same way: the filter forward then
/// backward, with no pull towards the first or last value at the ends. [dims] values per time.
Float64List _twoSided(Float64List times, Float64List values, int dims, double tau) {
  final count = times.length;
  final forward = Float64List(dims * count);
  final backward = Float64List(dims * count);
  final forwardWeight = Float64List(count);
  final backwardWeight = Float64List(count);
  for (var i = 0; i < count; i++) {
    final decay = i == 0 ? 0.0 : math.exp(-(times[i] - times[i - 1]) / tau);
    forwardWeight[i] = 1 + (i == 0 ? 0 : decay * forwardWeight[i - 1]);
    for (var d = 0; d < dims; d++) {
      forward[dims * i + d] = values[dims * i + d] + (i == 0 ? 0 : decay * forward[dims * (i - 1) + d]);
    }
  }
  for (var i = count - 1; i >= 0; i--) {
    final last = i == count - 1;
    final decay = last ? 0.0 : math.exp(-(times[i + 1] - times[i]) / tau);
    backwardWeight[i] = 1 + (last ? 0 : decay * backwardWeight[i + 1]);
    for (var d = 0; d < dims; d++) {
      backward[dims * i + d] = values[dims * i + d] + (last ? 0 : decay * backward[dims * (i + 1) + d]);
    }
  }
  final result = Float64List(dims * count);
  for (var i = 0; i < count; i++) {
    final weight = forwardWeight[i] + backwardWeight[i] - 1;
    for (var d = 0; d < dims; d++) {
      final at = dims * i + d;
      result[at] = (forward[at] + backward[at] - values[at]) / weight;
    }
  }
  return result;
}

/// [values] (one a time) turning at most [maxPerSecond] a second: each step limited once forward, from the first
/// value, and once backward, from the last, then the mean of the two passes, which keeps the limit (a mean of two
/// limited steps is limited) and centres the lag of a fast turn on it. A step of a gap in [times] may be longer.
Float64List _speedCapped(Float64List times, Float64List values, double maxPerSecond) {
  final count = values.length;
  final forward = Float64List(count);
  final backward = Float64List(count);
  if (count == 0) {
    return forward;
  }
  forward[0] = values[0];
  for (var i = 1; i < count; i++) {
    final limit = maxPerSecond * (times[i] - times[i - 1]).abs();
    forward[i] = forward[i - 1] + (values[i] - forward[i - 1]).clamp(-limit, limit);
  }
  backward[count - 1] = values[count - 1];
  for (var i = count - 2; i >= 0; i--) {
    final limit = maxPerSecond * (times[i + 1] - times[i]).abs();
    backward[i] = backward[i + 1] + (values[i] - backward[i + 1]).clamp(-limit, limit);
  }
  return Float64List.fromList([for (var i = 0; i < count; i++) (forward[i] + backward[i]) / 2]);
}

// Frames a second from the median step of the frame times; 30 with fewer than two frames
double _framesPerSecond(Float64List frameTimes) {
  if (frameTimes.length < 2) {
    return 30;
  }
  final steps = [for (var i = 1; i < frameTimes.length; i++) frameTimes[i] - frameTimes[i - 1]]..sort();
  final median = steps.length.isOdd
      ? steps[steps.length ~/ 2]
      : 0.5 * (steps[steps.length ~/ 2 - 1] + steps[steps.length ~/ 2]);
  return median > 0 ? 1 / median : 30;
}

// The shake above 1 Hz, degrees a frame: the root mean square of the rotation vectors of the frame steps less their
// mean over a second of frames around each (fewer at the ends)
double _shake(Float64List steps, double framesPerSecond) {
  final count = steps.length ~/ 3;
  if (count == 0) {
    return 0;
  }
  final window = math.max(3, framesPerSecond.round());
  final sums = Float64List(3 * (count + 1));
  for (var i = 0; i < count; i++) {
    for (var d = 0; d < 3; d++) {
      sums[3 * (i + 1) + d] = sums[3 * i + d] + steps[3 * i + d];
    }
  }
  var total = 0.0;
  for (var i = 0; i < count; i++) {
    final low = (i - window ~/ 2).clamp(0, count);
    final high = (i - window ~/ 2 + window).clamp(0, count);
    for (var d = 0; d < 3; d++) {
      final mean = (sums[3 * high + d] - sums[3 * low + d]) / (high - low);
      final value = steps[3 * i + d] - mean;
      total += value * value;
    }
  }
  return math.sqrt(total / count) * _degrees;
}

double _max(Float64List values) => values.reduce(math.max);

double _min(Float64List values) => values.reduce(math.min);

// [angle] brought into -pi to pi
double _wrapped(double angle) {
  final wrapped = (angle + math.pi) % (2 * math.pi);
  return wrapped - math.pi;
}

double _dot3(Vec3 a, Vec3 b) => a.x * b.x + a.y * b.y + a.z * b.z;

Vec3 _cross(Vec3 a, Vec3 b) => (x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x);

Vec3 _normalized(Vec3 v) {
  final norm = math.sqrt(_dot3(v, v));
  return norm > 0 ? (x: v.x / norm, y: v.y / norm, z: v.z / norm) : v;
}

// The quaternion of the rotation by the rotation vector (x, y, z): its axis, its length the angle in radians
({double w, double x, double y, double z}) _exp(double x, double y, double z) {
  final angle = math.sqrt(x * x + y * y + z * z);
  // sin(angle / 2) / angle, by its series near 0
  final scale = angle < 1e-6 ? 0.5 - angle * angle / 48 : math.sin(0.5 * angle) / angle;
  return (w: math.cos(0.5 * angle), x: scale * x, y: scale * y, z: scale * z);
}

// The vector (x, y, z) turned by the unit quaternion (w, qx, qy, qz)
Vec3 _rotate(double w, double qx, double qy, double qz, double x, double y, double z) {
  // t = 2 u x v, v' = v + w t + u x t
  final tx = 2 * (qy * z - qz * y);
  final ty = 2 * (qz * x - qx * z);
  final tz = 2 * (qx * y - qy * x);
  return (
    x: x + w * tx + (qy * tz - qz * ty),
    y: y + w * ty + (qz * tx - qx * tz),
    z: z + w * tz + (qx * ty - qy * tx),
  );
}

List<double> _at(Float64List quaternions, int i) => [
  quaternions[4 * i],
  quaternions[4 * i + 1],
  quaternions[4 * i + 2],
  quaternions[4 * i + 3],
];

List<double> _multiply(List<double> a, List<double> b) => [
  a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
  a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
  a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
  a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
];

List<double> _conjugate(List<double> q) => [q[0], -q[1], -q[2], -q[3]];

double _dot(List<double> a, List<double> b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];

// The angle of the rotation of [q], in degrees
double _angle(List<double> q) =>
    2 * math.atan2(math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3]), q[0].abs()) * _degrees;

// The rotation vector of [q], its length the angle in radians, the shorter way
Vec3 _rotationVector(List<double> q) {
  final sign = q[0] < 0 ? -1.0 : 1.0;
  final length = math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
  if (length < 1e-15) {
    return (x: 2 * sign * q[1], y: 2 * sign * q[2], z: 2 * sign * q[3]);
  }
  final scale = sign * 2 * math.atan2(length, q[0].abs()) / length;
  return (x: scale * q[1], y: scale * q[2], z: scale * q[3]);
}

// The unit quaternion of the rotation matrix [m] (Shepperd's method), w at least 0
List<double> _quaternionOf(Mat3 m) {
  final m00 = m.at(0, 0);
  final m11 = m.at(1, 1);
  final m22 = m.at(2, 2);
  final trace = m00 + m11 + m22;
  final List<double> q;
  if (trace > 0) {
    final s = math.sqrt(trace + 1) * 2;
    q = [s / 4, (m.at(2, 1) - m.at(1, 2)) / s, (m.at(0, 2) - m.at(2, 0)) / s, (m.at(1, 0) - m.at(0, 1)) / s];
  } else if (m00 > m11 && m00 > m22) {
    final s = math.sqrt(1 + m00 - m11 - m22) * 2;
    q = [(m.at(2, 1) - m.at(1, 2)) / s, s / 4, (m.at(0, 1) + m.at(1, 0)) / s, (m.at(0, 2) + m.at(2, 0)) / s];
  } else if (m11 > m22) {
    final s = math.sqrt(1 + m11 - m00 - m22) * 2;
    q = [(m.at(0, 2) - m.at(2, 0)) / s, (m.at(0, 1) + m.at(1, 0)) / s, s / 4, (m.at(1, 2) + m.at(2, 1)) / s];
  } else {
    final s = math.sqrt(1 + m22 - m00 - m11) * 2;
    q = [(m.at(1, 0) - m.at(0, 1)) / s, (m.at(0, 2) + m.at(2, 0)) / s, (m.at(1, 2) + m.at(2, 1)) / s, s / 4];
  }
  final norm = math.sqrt(_dot(q, q));
  final sign = q[0] < 0 ? -1.0 : 1.0;
  return [for (final v in q) sign * v / norm];
}
