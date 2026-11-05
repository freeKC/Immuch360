// What the player needs to stabilise a 360° video with the motion track of its camera: one rotation per frame, keyed
// on the presentation time of the frame, and the inputs of the cameras that write their own orientation. See
// lib/domain/services/raw/stabilization.dart for how the table is built.
//
// Frames: the view frame of the stitch (dual_fisheye_math.dart), x to the right, y down, z forward, levelled by the
// gravity the stitch uses. A quaternion is (w, x, y, z), Hamilton product, a rotation acting on the vectors.

import 'dart:math' as math;
import 'dart:typed_data';

/// The rotation that stabilises each frame of a video. A point of the sphere of the stitched frame at direction d (view
/// frame) is shown at direction k d, k the correction of the frame: the viewer then sees the world as the target view
/// (level, the heading of the camera smoothed) would see it, whatever the camera did.
///
/// Written with the orientations from the world (the levelled view of the first frame) to the view, the way GoPro
/// writes CORI: k = target x camera^-1, so that k x camera = target.
class StabilizationTable {
  StabilizationTable({required this.presentationTimesUs, required this.corrections, required this.summary})
    : assert(corrections.length == 4 * presentationTimesUs.length);

  /// Presentation time of each frame on the timeline of the video, in microseconds, frame 0 first; they rise
  final Int64List presentationTimesUs;

  /// The correction of each frame, four values a frame (w, x, y, z), 16 bytes; neighbours on the same side (positive
  /// dot product), so that a lookup between two frames can blend them
  final Float32List corrections;

  final StabilizationSummary summary;

  int get length => presentationTimesUs.length;

  bool get isEmpty => presentationTimesUs.isEmpty;

  /// The correction at [timeUs] of the timeline: the one of the frame at that time, blended (slerp) between the two
  /// frames around it, the first or the last one outside them. Identity for an empty table.
  List<double> correctionAt(int timeUs) {
    final times = presentationTimesUs;
    if (times.isEmpty) {
      return const [1, 0, 0, 0];
    }
    if (timeUs <= times.first) {
      return _quaternion(0);
    }
    if (timeUs >= times.last) {
      return _quaternion(times.length - 1);
    }
    // The last frame at or before timeUs
    var low = 0;
    var high = times.length - 1;
    while (high - low > 1) {
      final middle = (low + high) >> 1;
      if (times[middle] <= timeUs) {
        low = middle;
      } else {
        high = middle;
      }
    }
    final span = times[high] - times[low];
    final share = span <= 0 ? 0.0 : (timeUs - times[low]) / span;
    return slerpQuaternion(_quaternion(low), _quaternion(high), share);
  }

  List<double> _quaternion(int frame) => [for (var i = 0; i < 4; i++) corrections[4 * frame + i]];

  @override
  String toString() => 'StabilizationTable($length frames, $summary)';
}

/// What a stabilisation table did, for the logs
class StabilizationSummary {
  const StabilizationSummary({
    required this.source,
    required this.frames,
    this.meanCorrectionDegrees = 0,
    this.largestCorrectionDegrees = 0,
    this.headingRangeDegrees = 0,
    this.meanCameraStepDegrees = 0,
    this.largestCameraStepDegrees = 0,
    this.meanViewStepDegrees = 0,
    this.cameraShakeDegrees = 0,
    this.levelWindows = 0,
    this.levelWindowsKept = 0,
    this.largestLevelDegrees = 0,
    this.framesOutsideSamples = 0,
    this.headingHeldFrames = 0,
    this.samples = 0,
    this.sampleGaps = 0,
  });

  /// Where the orientation came from: "Insta360 gyroscope", "GoPro CORI"
  final String source;

  final int frames;

  /// Mean and largest angle of the corrections
  final double meanCorrectionDegrees;
  final double largestCorrectionDegrees;

  /// The heading of the camera, unwrapped: its largest less its smallest value
  final double headingRangeDegrees;

  /// The rotation of the camera from one frame to the next: mean and largest
  final double meanCameraStepDegrees;
  final double largestCameraStepDegrees;

  /// The rotation of the target view from one frame to the next, mean: what the viewer still sees turn
  final double meanViewStepDegrees;

  /// Shake of the camera above 1 Hz, degrees a frame: root mean square of its frame to frame rotation less the mean of
  /// that rotation over a second around it
  final double cameraShakeDegrees;

  /// Windows of the accelerometer (or of the gravity a camera gives) read, and kept for the level
  final int levelWindows;
  final int levelWindowsKept;

  /// Largest angle between the up the table levels with and the level of the stitch
  final double largestLevelDegrees;

  /// Frames taken outside the samples of the motion track, held at the first or the last orientation
  final int framesOutsideSamples;

  /// Frames whose view looked within 6 degrees of straight up or down, where the heading kept its value
  final int headingHeldFrames;

  /// Samples of the gyroscope integrated, and steps between two of them longer than 20 ms
  final int samples;
  final int sampleGaps;

  @override
  String toString() {
    String deg(double value) => value.toStringAsFixed(2);
    return '$source: $frames frames, correction mean ${deg(meanCorrectionDegrees)}° largest '
        '${deg(largestCorrectionDegrees)}°, camera step mean ${deg(meanCameraStepDegrees)}° largest '
        '${deg(largestCameraStepDegrees)}°, shake ${deg(cameraShakeDegrees)}°/frame, view step '
        '${deg(meanViewStepDegrees)}°, heading range ${deg(headingRangeDegrees)}°, level windows '
        '$levelWindowsKept/$levelWindows (largest ${deg(largestLevelDegrees)}°), held $headingHeldFrames, outside '
        '$framesOutsideSamples${samples > 0 ? ', $samples samples, $sampleGaps gaps' : ''}';
  }
}

/// The orientation a camera writes itself, at its own times: the input for the cameras that fuse their sensors
/// (GoPro CORI and GRAV, DJI attitude), turned into a stabilisation table by stabilizationOfOrientations.
class CameraOrientationTrack {
  CameraOrientationTrack({
    required this.label,
    required this.times,
    required this.orientations,
    this.gravity,
    this.worldUp,
  }) : assert(orientations.length == 4 * times.length),
       assert(gravity == null || gravity.length == 3 * times.length),
       assert(worldUp == null || worldUp.length == 3);

  /// What the orientation is, for the logs: "GoPro CORI"
  final String label;

  /// Time of each orientation, in seconds on the clock of the frame times given with the track; they rise
  final Float64List times;

  /// The rotation from the body frame of the camera to a world frame, at each time, four values each (w, x, y, z).
  /// The world frame is the camera's own: fixed, but not necessarily level.
  final Float64List orientations;

  /// The direction of gravity (down) in the body frame at each time, three values each, any length; null when the
  /// camera gives none
  final Float32List? gravity;

  /// The up direction of the world frame of [orientations], when the camera's attitude is levelled itself (DJI); it
  /// then levels the table, and [gravity] is not read
  final List<double>? worldUp;

  int get length => times.length;

  @override
  String toString() =>
      'CameraOrientationTrack($label, $length orientations${length == 0 ? '' : ', ${times.first} s to ${times.last} s'}'
      '${gravity != null ? ', gravity' : ''}${worldUp != null ? ', world up $worldUp' : ''})';
}

/// The rotation blended between [a] and [b] (w, x, y, z), at [share] (0 at a, 1 at b), along the shorter arc
List<double> slerpQuaternion(List<double> a, List<double> b, double share) {
  var dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
  final sign = dot < 0 ? -1.0 : 1.0;
  dot *= sign;
  double wa;
  double wb;
  if (dot > 1 - 1e-10) {
    // Within about 1e-5 radian: a straight blend is as good
    wa = 1 - share;
    wb = share;
  } else {
    final angle = math.acos(math.min(1.0, dot));
    final sin = math.sin(angle);
    wa = math.sin((1 - share) * angle) / sin;
    wb = math.sin(share * angle) / sin;
  }
  wb *= sign;
  final q = [for (var i = 0; i < 4; i++) wa * a[i] + wb * b[i]];
  final norm = math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
  return [for (final v in q) v / norm];
}
