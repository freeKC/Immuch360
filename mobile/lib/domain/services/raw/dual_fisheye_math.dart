// The geometry of a dual fisheye camera (Insta360 .insp photos and .insv videos): from a direction of the sphere to a
// pixel of each lens, as docs/16-dual-fisheye-spec.md (section 3) sets it out. The lens pose follows the convention
// GyroView (MIT) measured against Insta360 Studio, and the Mei projection the V3 calibration strings of the cameras;
// a prototype built on the same steps matches Studio's own export of X3 photos within about a degree of yaw.
//
// Frames: the view looks along +z with x to the right and y down, the centre of an equirect picture straight ahead.
// The body of the camera has x to the right, y down and z along the optical axis of lens 0 (the left half of a frame).
//
// Pure Dart: the Dart pre-warp of the photos and the tests use it, and the shaders of the native players follow the
// same steps.

import 'dart:math' as math;

import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';

/// A direction, or a point, in 3D
typedef Vec3 = ({double x, double y, double z});

/// A pixel position
typedef Pixel = ({double x, double y});

/// What one lens gives to an output pixel: the lens, where to read it in the frame (frame pixels, lens 1 in the right
/// half), and its share of the pixel (the shares of a pixel add up to 1)
typedef LensSample = ({int lens, double x, double y, double weight});

/// A 3 x 3 matrix, row after row
class Mat3 {
  const Mat3(this.values);

  /// The matrix whose columns are [a], [b] and [c]
  factory Mat3.columns(Vec3 a, Vec3 b, Vec3 c) => Mat3([a.x, b.x, c.x, a.y, b.y, c.y, a.z, b.z, c.z]);

  static const identity = Mat3([1, 0, 0, 0, 1, 0, 0, 0, 1]);

  final List<double> values;

  double at(int row, int column) => values[row * 3 + column];

  Mat3 operator *(Mat3 other) => Mat3([
    for (var row = 0; row < 3; row++)
      for (var column = 0; column < 3; column++)
        at(row, 0) * other.at(0, column) + at(row, 1) * other.at(1, column) + at(row, 2) * other.at(2, column),
  ]);

  Vec3 apply(Vec3 v) => (
    x: values[0] * v.x + values[1] * v.y + values[2] * v.z,
    y: values[3] * v.x + values[4] * v.y + values[5] * v.z,
    z: values[6] * v.x + values[7] * v.y + values[8] * v.z,
  );

  Mat3 get transposed => Mat3([
    for (var column = 0; column < 3; column++) ...[at(0, column), at(1, column), at(2, column)],
  ]);

  @override
  String toString() => 'Mat3($values)';
}

const _degree = math.pi / 180;

/// Largest angle off the optical axis, in degrees, a lens is read at: the image circle of the X3 ends about there (the
/// Mei model of a real X3 puts 100 degrees 2886 canvas pixels off centre, in a half square of 2976)
const dualFisheyeMaxTheta = 100.0;

/// The blend of the two lenses runs between these angles off axis, in degrees: one lens alone up to 85, the other alone
/// past 95
const dualFisheyeBlendStart = 85.0;
const dualFisheyeBlendEnd = 95.0;

/// Rotation about the x axis by [radians]
Mat3 rotationX(double radians) {
  final c = math.cos(radians);
  final s = math.sin(radians);
  return Mat3([1, 0, 0, 0, c, -s, 0, s, c]);
}

/// Rotation about the y axis by [radians]
Mat3 rotationY(double radians) {
  final c = math.cos(radians);
  final s = math.sin(radians);
  return Mat3([c, 0, s, 0, 1, 0, -s, 0, c]);
}

/// Rotation about the z axis by [radians]
Mat3 rotationZ(double radians) {
  final c = math.cos(radians);
  final s = math.sin(radians);
  return Mat3([c, -s, 0, s, c, 0, 0, 0, 1]);
}

double _dot(Vec3 a, Vec3 b) => a.x * b.x + a.y * b.y + a.z * b.z;

Vec3 _cross(Vec3 a, Vec3 b) => (x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x);

// [a] minus [b] times [factor]
Vec3 _minusScaled(Vec3 a, Vec3 b, double factor) =>
    (x: a.x - b.x * factor, y: a.y - b.y * factor, z: a.z - b.z * factor);

// [v] made unit long, null when it is too short to have a direction
Vec3? _normalized(Vec3 v) {
  final length = math.sqrt(_dot(v, v));
  if (!length.isFinite || length < 1e-9) {
    return null;
  }
  return (x: v.x / length, y: v.y / length, z: v.z / length);
}

/// The roll of a lens as the body to lens rotation takes it. The calibration strings give it mirrored about the nearest
/// quarter turn: the sensors of the X3 are mounted sideways (a roll near 90 degrees), and GyroView measured against
/// Studio, on the X3, X5 and X6, that the roll as written turns the picture the wrong way.
double mirroredRoll(double rollDegrees) => 2 * (rollDegrees / 90).round() * 90 - rollDegrees;

/// The rotation from the body frame to the frame of lens [index] (0 or 1), whose z is its optical axis and whose x and
/// y follow the columns and the rows of its square: Rz(mirrored roll) Rx(180 degrees for lens 1) Rx(pitch) Ry(yaw).
/// Lens 1 looks the other way, turned about x.
Mat3 lensPose(DualFisheyeLens lens, int index) =>
    rotationZ(mirroredRoll(lens.roll) * _degree) *
    rotationX(180.0 * index * _degree) *
    rotationX(lens.pitch * _degree) *
    rotationY(lens.yaw * _degree);

/// The direction of gravity in the body frame from the mean of the accelerometer of an Insta360 camera, in any unit (at
/// rest it measures the reaction to gravity, which points up). The IMU of the X3, and of the X4 Air, X5 and X6 as
/// GyroView measured them, has body x = IMU x, body y = IMU z and body z = -IMU y. Without a usable [accelerometer]
/// the camera is taken as upright, gravity along body +x: the lenses face the horizon, sideways.
List<double> downBodyFromAccelerometer(List<double>? accelerometer) {
  final a = accelerometer != null && accelerometer.length >= 3
      ? _normalized((x: accelerometer[0], y: accelerometer[1], z: accelerometer[2]))
      : null;
  if (a == null) {
    return const [1.0, 0.0, 0.0];
  }
  // Gravity is opposite to what the accelerometer measures
  return [-a.x, -a.z, a.y];
}

/// The rotation from the view to the body frame, levelled by [downBody] (the direction of gravity in the body frame):
/// its columns are the right, down and forward axes of the view in the body frame. Forward is the axis of lens 1 (body
/// -z) laid level, where Insta360 Studio opens a picture.
Mat3 bodyFrame(List<double> downBody) {
  final down =
      (downBody.length >= 3 ? _normalized((x: downBody[0], y: downBody[1], z: downBody[2])) : null) ??
      (x: 1.0, y: 0.0, z: 0.0);
  const lens1Axis = (x: 0.0, y: 0.0, z: -1.0);
  const bodyX = (x: 1.0, y: 0.0, z: 0.0);
  // Lens 1 pointing straight up or down has no level direction: any level direction will do then, body x is one
  final forward =
      _normalized(_minusScaled(lens1Axis, down, _dot(lens1Axis, down))) ??
      _normalized(_minusScaled(bodyX, down, _dot(bodyX, down)))!;
  return Mat3.columns(_cross(down, forward), down, forward);
}

/// The rotations from the view to the frame of each lens of [calibration], levelled by its gravity: what a shader needs
/// with the lenses' intrinsics
List<Mat3> viewToLens(DualFisheyeCalibration calibration) {
  final body = bodyFrame(calibration.downBody);
  return [for (var i = 0; i < calibration.lenses.length; i++) lensPose(calibration.lenses[i], i) * body];
}

/// The longitude and the latitude, in radians, of the centre of pixel ([i], [j]) of an equirect picture of [width] x
/// [height] pixels: longitude 0 in the middle column, latitude pi/2 at the top
({double lon, double lat}) equirectAngles(int i, int j, int width, int height) =>
    (lon: ((i + 0.5) / width * 2 - 1) * math.pi, lat: math.pi / 2 - (j + 0.5) / height * math.pi);

/// The view direction of longitude [lon] and latitude [lat], in radians
Vec3 viewDirection(double lon, double lat) =>
    (x: math.cos(lat) * math.sin(lon), y: -math.sin(lat), z: math.cos(lat) * math.cos(lon));

/// The view direction of the centre of pixel ([i], [j]) of an equirect picture of [width] x [height] pixels
Vec3 directionForEquirect(int i, int j, int width, int height) {
  final (:lon, :lat) = equirectAngles(i, j, width, height);
  return viewDirection(lon, lat);
}

/// The angle, in degrees, between the unit direction [d] of a lens frame and the optical axis of the lens
double offAxisDegrees(Vec3 d) => math.acos(d.z.clamp(-1.0, 1.0)) / _degree;

/// Where the unit direction [d], in the frame of [lens], lands on the calibration canvas with the unified camera model of
/// Mei (V3 calibration strings): the direction is projected from a point [DualFisheyeLens.xi] behind the centre of the
/// unit sphere, then goes through a radial (k1 to k3) and a tangential (p1, p2) distortion. Null past
/// [dualFisheyeMaxTheta] off axis, or for a lens without the Mei intrinsics.
Pixel? meiProject(DualFisheyeLens lens, Vec3 d) {
  final xi = lens.xi;
  final fx = lens.fx;
  final fy = lens.fy;
  if (xi == null || fx == null || fy == null || offAxisDegrees(d) >= dualFisheyeMaxTheta) {
    return null;
  }
  final depth = d.z + xi;
  if (depth <= 1e-6) {
    return null;
  }
  final mx = d.x / depth;
  final my = d.y / depth;
  final r2 = mx * mx + my * my;
  final radial = 1 + r2 * (lens.k1 + r2 * (lens.k2 + r2 * lens.k3));
  final dx = radial * mx + 2 * lens.p1 * mx * my + lens.p2 * (r2 + 2 * mx * mx);
  final dy = radial * my + lens.p1 * (r2 + 2 * my * my) + 2 * lens.p2 * mx * my;
  return (x: fx * dx + lens.cx, y: fy * dy + lens.cy);
}

/// Where the unit direction [d], in the frame of [lens], lands on the calibration canvas with an equidistant fisheye (V1
/// calibration strings): the distance to the centre grows with the angle off axis, [DualFisheyeLens.radius] at 100
/// degrees (where the V1 radius sits on the X3). Null past [dualFisheyeMaxTheta] off axis, or without a radius.
Pixel? equidistantProject(DualFisheyeLens lens, Vec3 d) {
  final radius = lens.radius;
  final theta = offAxisDegrees(d);
  if (radius == null || theta >= dualFisheyeMaxTheta) {
    return null;
  }
  final planar = math.sqrt(d.x * d.x + d.y * d.y);
  if (planar < 1e-12) {
    return (x: lens.cx, y: lens.cy);
  }
  final r = radius * theta / dualFisheyeMaxTheta;
  return (x: lens.cx + r * d.x / planar, y: lens.cy + r * d.y / planar);
}

/// Where [d] lands on the canvas for a lens of the [model]
Pixel? projectLens(DualFisheyeModel model, DualFisheyeLens lens, Vec3 d) => switch (model) {
  DualFisheyeModel.mei => meiProject(lens, d),
  DualFisheyeModel.equidistant => equidistantProject(lens, d),
};

/// 0 below [edge0], 1 above [edge1], a smooth S between
double smoothstep(double edge0, double edge1, double x) {
  final t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// How much a lens counts for a direction [thetaDegrees] off its axis, before the weights of the two lenses are made to
/// add up to 1: 1 up to 85 degrees, 0.5 at 90 (the middle of the seam), 0 from 95
double blendWeight(double thetaDegrees) => 1 - smoothstep(dualFisheyeBlendStart, dualFisheyeBlendEnd, thetaDegrees);

/// The ratio of a frame pixel to a canvas pixel, for a frame [frameHeight] pixels high (one square per lens): the
/// calibration covers the whole square of the canvas, not the crop window of the sensor
double canvasToFrameScale(DualFisheyeCalibration calibration, int frameHeight) =>
    frameHeight / calibration.canvasSquare;

/// Samples a frame of [frameWidth] x [frameHeight] pixels drawn with [calibration], for one direction after another
class DualFisheyeSampler {
  DualFisheyeSampler(this.calibration, {required this.frameWidth, required this.frameHeight})
    : _viewToLens = viewToLens(calibration),
      _scale = canvasToFrameScale(calibration, frameHeight);

  final DualFisheyeCalibration calibration;
  final int frameWidth;
  final int frameHeight;
  final List<Mat3> _viewToLens;
  final double _scale;

  /// What each lens gives to the direction of longitude [lon] and latitude [lat] (radians): lens i is read only inside
  /// its own square of the frame and less than [dualFisheyeMaxTheta] off axis, with the weight of [blendWeight]; the
  /// weights are made to add up to 1. Where no lens has weight (both past 95 degrees, or the other one off its square),
  /// the lens closer to its axis is taken alone. Empty when no lens sees the direction.
  List<LensSample> sample(double lon, double lat) {
    final v = viewDirection(lon, lat);
    final square = frameHeight.toDouble();
    final found = <({LensSample sample, double theta})>[];
    for (var i = 0; i < _viewToLens.length; i++) {
      final d = _viewToLens[i].apply(v);
      final canvas = projectLens(calibration.model, calibration.lenses[i], d);
      if (canvas == null) {
        continue;
      }
      final x = canvas.x * _scale;
      final y = canvas.y * _scale;
      if (x < i * square || x >= math.min((i + 1) * square, frameWidth.toDouble()) || y < 0 || y >= square) {
        continue;
      }
      final theta = offAxisDegrees(d);
      found.add((sample: (lens: i, x: x, y: y, weight: blendWeight(theta)), theta: theta));
    }
    final total = found.fold(0.0, (sum, entry) => sum + entry.sample.weight);
    // A lens past 95 degrees adds nothing to the pixel: it is left out rather than read for nothing
    if (total > 0) {
      return [
        for (final (:sample, theta: _) in found)
          if (sample.weight > 0) (lens: sample.lens, x: sample.x, y: sample.y, weight: sample.weight / total),
      ];
    }
    if (found.isEmpty) {
      return const [];
    }
    final closest = found.reduce((a, b) => b.theta < a.theta ? b : a).sample;
    return [(lens: closest.lens, x: closest.x, y: closest.y, weight: 1.0)];
  }
}

/// What each lens of [calibration] gives to the direction of longitude [lon] and latitude [lat] (radians), in a frame of
/// [frameWidth] x [frameHeight] pixels; see [DualFisheyeSampler.sample], which saves the rotations for many directions
List<LensSample> samplePixel(
  DualFisheyeCalibration calibration,
  int frameWidth,
  int frameHeight,
  double lon,
  double lat,
) => DualFisheyeSampler(calibration, frameWidth: frameWidth, frameHeight: frameHeight).sample(lon, lat);

/// Nominal values of an Insta360 X3, for a frame whose squares have [frameSquare] pixels a side: what a file without a
/// calibration of its own is drawn with when its camera was never seen. Mean values of real X3 units scaled to the
/// square (focal 0.777 of the side), both lenses centred in their square, sensors sideways (roll 90), camera upright.
/// The seams may be off by a few pixels.
DualFisheyeCalibration nominalX3(int frameSquare) {
  final side = frameSquare.toDouble();
  DualFisheyeLens lens(int index) => DualFisheyeLens(
    cx: side / 2 + index * side,
    cy: side / 2,
    yaw: 0,
    pitch: 0,
    roll: 90,
    xi: 1.948,
    fx: 0.777 * side,
    fy: 0.777 * side,
    k1: 0.39,
    k2: 1.28,
    k3: -3.94,
  );
  return DualFisheyeCalibration(
    model: DualFisheyeModel.mei,
    lenses: [lens(0), lens(1)],
    canvasSquare: side,
    source: DualFisheyeSource.nominal,
  );
}

/// [calibration] in the pixels of a frame whose squares have [frameSquare] pixels a side rather than in canvas pixels:
/// for a renderer that reads frame pixels straight. Angles and distortion do not change.
DualFisheyeCalibration calibrationForFrame(DualFisheyeCalibration calibration, int frameSquare) {
  final scale = frameSquare / calibration.canvasSquare;
  double? scaled(double? value) => value == null ? null : value * scale;
  return calibration.copyWith(
    canvasSquare: frameSquare.toDouble(),
    lenses: [
      for (final lens in calibration.lenses)
        DualFisheyeLens(
          cx: lens.cx * scale,
          cy: lens.cy * scale,
          yaw: lens.yaw,
          pitch: lens.pitch,
          roll: lens.roll,
          xi: lens.xi,
          fx: scaled(lens.fx),
          fy: scaled(lens.fy),
          k1: lens.k1,
          k2: lens.k2,
          k3: lens.k3,
          p1: lens.p1,
          p2: lens.p2,
          radius: scaled(lens.radius),
        ),
    ],
  );
}

extension DualFisheyeCalibrationCopy on DualFisheyeCalibration {
  /// This calibration with the given values replaced
  DualFisheyeCalibration copyWith({
    DualFisheyeModel? model,
    List<DualFisheyeLens>? lenses,
    double? canvasSquare,
    List<double>? downBody,
    String? serial,
    String? cameraModel,
    DualFisheyeSource? source,
  }) => DualFisheyeCalibration(
    model: model ?? this.model,
    lenses: lenses ?? this.lenses,
    canvasSquare: canvasSquare ?? this.canvasSquare,
    downBody: downBody ?? this.downBody,
    serial: serial ?? this.serial,
    cameraModel: cameraModel ?? this.cameraModel,
    source: source ?? this.source,
  );
}
