// The motion of a 360° camera as its file records it, for the stabilisation of the video at playback: the samples of
// its gyroscope and accelerometer, and the time of each frame, all on the clock of the video (time 0 at its first
// frame), and the orientation the camera itself fused for each frame when the file has it. See
// lib/domain/services/raw/insta360_motion.dart for the Insta360 trailer, lib/domain/services/raw/gopro_motion.dart for
// the GPMF track of a GoPro, lib/domain/services/raw/dji_motion.dart for the attitude of the DJI Osmo 360.

import 'dart:typed_data';

/// Where a motion track was read
enum CameraMotionSource {
  /// The IMU record of an Insta360 trailer (record 3), with the time of each frame (record 4)
  insta360Imu,

  /// The GPMF track of a GoPro (MAX, MAX 2, HERO8 and later): one orientation (CORI) and one gravity vector (GRAV) per
  /// frame, in the axes of the GPMF camera frame, not yet the body frame of dual_fisheye_math.dart; no raw samples
  goProGpmf,

  /// The attitude in the per frame records of the camd box of a DJI Osmo 360 .osv file: one orientation per frame,
  /// already in the body frame of dual_fisheye_math.dart, its world levelled (z down); no raw samples
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
    this.cameraModel,
    this.firmware,
    this.rollingShutterMs,
    this.truncated = false,
    this.droppedSamples = 0,
    this.frameOrientations,
    this.frameGravity,
  }) : assert(frameExposures.length == 0 || frameExposures.length == frameTimes.length),
       assert(frameOrientations == null || frameOrientations.length == 4 * frameTimes.length),
       assert(frameGravity == null || frameGravity.length == 3 * frameTimes.length);

  final CameraMotionSource source;

  final CameraMotionTimeOrigin timeOrigin;

  /// The samples of the gyroscope and the accelerometer; empty when the file gives the orientation per frame instead
  final CameraMotionSamples samples;

  /// Time of each frame of the video the file lists, frame 0 first, in seconds from the first frame (so 0 for it when
  /// [timeOrigin] is [CameraMotionTimeOrigin.firstFrame]); empty when the file lists none
  final Float64List frameTimes;

  /// Exposure time of each frame, in seconds; empty when the file does not say, NaN for a frame it says nothing of
  final Float32List frameExposures;

  /// The orientation the camera fused for each entry of [frameTimes], four values a frame (w, x, y, z): the unit
  /// quaternion q from the world to the camera, so that a vector of the world reads q v q^-1 in the axes of the camera,
  /// The orientation the camera fused for each entry of [frameTimes], four values a frame (w, x, y, z): the unit
  /// quaternion q from the world to the camera, so that a vector of the world reads q v q^-1 in the axes of the camera,
  /// and q^-1 turns the camera's vectors into the world. The axes of the camera are those of [source]. For
  /// [CameraMotionSource.goProGpmf] the world is the camera's own reference, not levelled (the GoPro's frame at the
  /// start of the capture): [frameGravity] levels it. For [CameraMotionSource.djiAttitude] the axes are the body frame
  /// of [CameraMotionSamples], and the world's z is down along gravity once the fusion of the camera has settled (see
  /// dji_motion.dart); consecutive quaternions are on the same side (their dot product is not negative). Null when the
  /// file only has raw samples; NaN for a frame the file says nothing of.
  final Float32List? frameOrientations;

  /// The gravity vector the camera wrote for each entry of [frameTimes], three values a frame, unit, in the axes of the
  /// camera ([source]), as the camera wrote it (GoPro GRAV: turned into the world by the inverse of the orientation, it
  /// stays within 1.7 degrees of one direction on the sample measured). Null when the file has none; NaN for a frame
  /// the file says nothing of.
  final Float32List? frameGravity;

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
      'rate ${sampleRate?.toStringAsFixed(1)} Hz, ${frameTimes.length} frames, '
      'orientations: ${frameOrientations != null}, gravity: ${frameGravity != null}, '
      'rolling shutter $rollingShutterMs ms, '
      'truncated: $truncated, dropped: $droppedSamples)';
}
