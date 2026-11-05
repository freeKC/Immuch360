// The motion of a 360° camera as its file records it, for the stabilisation of the video at playback: the samples of
// its gyroscope and accelerometer, or its own orientation per frame, and the time of each frame, all on the clock of the
// video (time 0 at its first frame). See lib/domain/services/raw/insta360_motion.dart for the Insta360 trailer and
// lib/domain/services/raw/dji_motion.dart for the attitude of the DJI Osmo 360.

import 'dart:typed_data';

/// Where a motion track was read
enum CameraMotionSource {
  /// The IMU record of an Insta360 trailer (record 3), with the time of each frame (record 4)
  insta360Imu,

  /// The attitude the DJI Osmo 360 writes in the per frame records of the camd box of its .osv files: an orientation
  /// per frame, no gyroscope samples
  djiAttitude,
}

/// What time 0 of a motion track is
enum CameraMotionTimeOrigin {
  /// The first frame of the video, as the file names it (field 24 of an Insta360 trailer)
  firstFrame,

  /// The first frame entry of the file, without a field to say it is the first frame of the video: the camera may have
  /// listed a few frames before it
  firstFrameEntry,

  /// The first sample, without any frame time: the samples and the frames may be off by a fraction of a second
  firstSample,
}

/// Samples of the gyroscope and the accelerometer of a camera, in the frame of its body (x to the right, y down, z
/// along the optical axis of lens 0, the frame of dual_fisheye_math.dart), each at its time from the first frame of the
/// video. Times rise strictly.
class CameraMotionSamples {
  CameraMotionSamples({required this.times, required this.rotationRates, required this.accelerations})
    : assert(rotationRates.length == 3 * times.length && accelerations.length == 3 * times.length);

  /// An empty run of samples
  factory CameraMotionSamples.empty() =>
      CameraMotionSamples(times: Float64List(0), rotationRates: Float32List(0), accelerations: Float32List(0));

  /// Time of each sample, in seconds from the first frame of the video (negative before it)
  final Float64List times;

  /// Angular rate of each sample about the body x, y and z axes, in radians per second, three values per sample
  final Float32List rotationRates;

  /// What the accelerometer measured for each sample along the body x, y and z axes, in g, three values per sample: at
  /// rest the reaction to gravity, pointing up
  final Float32List accelerations;

  int get length => times.length;

  bool get isEmpty => times.isEmpty;

  @override
  String toString() => 'CameraMotionSamples($length samples${isEmpty ? '' : ', ${times.first} s to ${times.last} s'})';
}

/// The motion a camera recorded in a video file, and the time of each of its frames on the same clock
class CameraMotionTrack {
  const CameraMotionTrack({
    required this.source,
    required this.timeOrigin,
    required this.samples,
    required this.frameTimes,
    required this.frameExposures,
    this.frameOrientations,
    this.cameraModel,
    this.firmware,
    this.rollingShutterMs,
    this.truncated = false,
    this.droppedSamples = 0,
  }) : assert(frameExposures.isEmpty || frameExposures.length == frameTimes.length),
       assert(frameOrientations == null || frameOrientations.length == 4 * frameTimes.length);

  final CameraMotionSource source;

  final CameraMotionTimeOrigin timeOrigin;

  /// The samples of the gyroscope and the accelerometer; empty for a camera that gives its orientation instead
  /// ([frameOrientations])
  final CameraMotionSamples samples;

  /// Time of each frame of the video the file lists, frame 0 first, in seconds from the first frame (so 0 for it when
  /// [timeOrigin] is [CameraMotionTimeOrigin.firstFrame]); empty when the file lists none
  final Float64List frameTimes;

  /// Exposure time of each frame, in seconds; empty when the file does not give it
  final Float32List frameExposures;

  /// Orientation of the camera at each frame of [frameTimes], as the camera fused it: four values a frame, the unit
  /// quaternion w, x, y, z of the rotation from the body frame (that of [CameraMotionSamples]) to a world frame fixed in
  /// space, so a direction v of the body at that frame is R(q) v in the world. Consecutive quaternions are on the same
  /// side (their dot product is not negative). Null when the camera gives no orientation (the gyroscope samples are
  /// then to be integrated). For [CameraMotionSource.djiAttitude] the world has z down along gravity, once the
  /// camera's fusion has settled; each orientation is the one the picture of its frame was taken at (see dji_motion.dart)
  final Float32List? frameOrientations;

  /// Name of the camera, "Insta360 X4"
  final String? cameraModel;

  /// Firmware of the camera
  final String? firmware;

  /// Time the sensor takes to read one frame out, in milliseconds
  final double? rollingShutterMs;

  /// Whether the file has more samples than were read
  final bool truncated;

  /// Samples left out because their time did not rise past the one before
  final int droppedSamples;

  /// Mean number of samples per second, null with fewer than two samples
  double? get sampleRate {
    final times = samples.times;
    if (times.length < 2 || times.last <= times.first) {
      return null;
    }
    return (times.length - 1) / (times.last - times.first);
  }

  @override
  String toString() =>
      'CameraMotionTrack(${source.name}, $cameraModel $firmware, origin ${timeOrigin.name}, $samples, '
      'rate ${sampleRate?.toStringAsFixed(1)} Hz, ${frameTimes.length} frames'
      '${frameOrientations == null ? '' : ' with orientations'}, rolling shutter $rollingShutterMs ms, '
      'truncated: $truncated, dropped: $droppedSamples)';
}
