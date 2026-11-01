// The model COLMAP writes for a splat scene (plan 2026-11-01, sections 2.2 and 3, lot SP4): the files of a sparse/<n>
// folder, cameras.bin, images.bin and points3D.bin, little endian, the names of the images in UTF-8 (COLMAP 4.2.1 keeps
// the layout of COLMAP 3 for these three beside its new rigs.bin and frames.bin; read in the models of the measure of
// 1 November 2026). What the app needs of it:
//  - how many images a model placed, read from the first 8 bytes of its images.bin alone, so that the largest of the
//    models the mapper wrote is chosen without reading them all: the measure saw a sparse/0 of 4 images beside a
//    sparse/1 of 150 for the room (run c4), and a sparse/1 of 26 beside a sparse/0 of 144 for the video of the
//    lighthouse;
//  - the whole model once aligned upright by model_orientation_aligner (+y then points down, as COLMAP and the headset
//    take it): the centres of the cameras, the points, the mean reprojection error COLMAP's model_analyzer gives
//    (0.66 px for the room of the measure), and the floor under the cameras, from which the copy for the headset gets
//    its scale when a place was filmed (SplatV1.placeCameraHeight above it).
// The floor: the lowest layer of the scene under the cameras, the 95th percentile of the heights of the points below the
// median height of the cameras (the 5 % below it are floaters and reflections), when those points are at least
// [ColmapModel.floorMinShare] of all and [ColmapModel.floorMinPoints]; otherwise there is no floor to trust (an object
// seen from below or from its height, the skull of the measure: no point under its cameras), and the scale comes from
// the size of the scene (lot SP3). A plane found in a histogram was tried first on the models of the measure: their
// floors are no peak (the room of Mip-NeRF 360 spreads its points over the whole height below its cameras, its floor
// smeared by a tilt of a few degrees), so the peak fell on the furniture. The rule is not measured against a true floor:
// the copies of the first test T1, in the headset, say whether a room stands at the right height.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// The number of parameters of each camera model of COLMAP 4.2.1, by its id (sensor/models.h)
const colmapCameraParams = {
  0: 3, // SIMPLE_PINHOLE
  1: 4, // PINHOLE
  2: 4, // SIMPLE_RADIAL
  3: 5, // RADIAL
  4: 8, // OPENCV
  5: 8, // OPENCV_FISHEYE
  6: 12, // FULL_OPENCV
  7: 5, // FOV
  8: 4, // SIMPLE_RADIAL_FISHEYE
  9: 5, // RADIAL_FISHEYE
  10: 12, // THIN_PRISM_FISHEYE
  11: 16, // RAD_TAN_THIN_PRISM_FISHEYE
};

/// One camera of a model: its model id, the size of its images, its parameters
class ColmapCamera {
  const ColmapCamera({
    required this.id,
    required this.model,
    required this.width,
    required this.height,
    this.params = const [],
  });

  final int id;
  final int model;
  final int width;
  final int height;
  final List<double> params;
}

/// One image a model placed: from the world to the camera ([qvec] w, x, y, z and [tvec]), and its centre in the world
class ColmapImage {
  ColmapImage({
    required this.id,
    required this.name,
    required this.cameraId,
    required this.qvec,
    required this.tvec,
    this.observations = 0,
  }) : center = colmapCenterOf(qvec, tvec);

  final int id;

  /// Its path under the folder of the images, "/" between folders
  final String name;
  final int cameraId;
  final List<double> qvec;
  final List<double> tvec;

  /// The points of the image that have a point in 3D
  final int observations;

  /// -Rᵀ t: where the camera stands in the world
  final List<double> center;
}

/// One point of a model: where it is, its colour, its mean reprojection error (negative when COLMAP gave none), and how
/// many images see it
class ColmapPoint {
  const ColmapPoint({required this.id, required this.xyz, required this.rgb, required this.error, required this.track});

  final int id;
  final List<double> xyz;
  final List<int> rgb;
  final double error;
  final int track;
}

/// The floor found under the cameras of an upright model: its height ([y], +y down) and the median height of the
/// cameras above it ([cameraHeight], in the units of the model), from the [support] points below the cameras
class ColmapFloor {
  const ColmapFloor({required this.y, required this.cameraHeight, required this.support});

  final double y;
  final double cameraHeight;
  final int support;

  @override
  String toString() => 'ColmapFloor(y: $y, cameraHeight: $cameraHeight, support: $support)';
}

/// The centre of a camera from its pose, the world to the camera: -Rᵀ t, R the rotation of the quaternion [q] (w, x,
/// y, z)
List<double> colmapCenterOf(List<double> q, List<double> t) {
  final norm = math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
  final w = q[0] / norm;
  final x = q[1] / norm;
  final y = q[2] / norm;
  final z = q[3] / norm;
  final r = [
    [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
    [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
    [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
  ];
  return [for (var j = 0; j < 3; j++) -(r[0][j] * t[0] + r[1][j] * t[1] + r[2][j] * t[2])];
}

/// The number of images the model in [folder] placed, read from the first 8 bytes of its images.bin; null when it has
/// none or a shorter one
int? colmapPlacedIn(Directory folder) {
  final file = File(p.join(folder.path, 'images.bin'));
  try {
    final handle = file.openSync();
    try {
      final head = handle.readSync(8);
      return head.length < 8 ? null : ByteData.sublistView(head).getUint64(0, Endian.little);
    } finally {
      handle.closeSync();
    }
  } on FileSystemException {
    return null;
  }
}

/// The model of [sparse] (the output folder of the mapper, models in 0, 1...) that placed the most images, the first
/// one when two placed as many; null when there is none
({Directory folder, int placed})? largestColmapModel(Directory sparse) {
  if (!sparse.existsSync()) {
    return null;
  }
  final models = [
    for (final entry in sparse.listSync())
      if (entry is Directory && RegExp(r'^\d+$').hasMatch(p.basename(entry.path))) entry,
  ]..sort((a, b) => int.parse(p.basename(a.path)).compareTo(int.parse(p.basename(b.path))));
  ({Directory folder, int placed})? best;
  for (final folder in models) {
    final placed = colmapPlacedIn(folder);
    if (placed != null && placed > 0 && (best == null || placed > best.placed)) {
      best = (folder: folder, placed: placed);
    }
  }
  return best;
}

/// A whole model (see the top of this file)
class ColmapModel {
  const ColmapModel({required this.cameras, required this.images, required this.points});

  final Map<int, ColmapCamera> cameras;
  final List<ColmapImage> images;
  final List<ColmapPoint> points;

  /// The floor needs this share of the points, and this many, below the median height of the cameras
  static const floorMinShare = 0.1;
  static const floorMinPoints = 30;

  /// The percentile of the heights of the points below the cameras taken as the floor
  static const floorPercentile = 0.95;

  /// Reads the model in [folder]; throws a FormatException when a file is missing or does not read
  static ColmapModel read(Directory folder) {
    Uint8List bytes(String name) {
      final file = File(p.join(folder.path, name));
      if (!file.existsSync()) {
        throw FormatException('No $name in ${folder.path}');
      }
      return file.readAsBytesSync();
    }

    final cameras = <int, ColmapCamera>{};
    final images = <ColmapImage>[];
    final points = <ColmapPoint>[];
    try {
      final c = _Reader(bytes('cameras.bin'));
      for (var n = c.u64(); n > 0; n--) {
        final id = c.u32();
        final model = c.i32();
        final width = c.u64();
        final height = c.u64();
        final count = colmapCameraParams[model];
        if (count == null) {
          throw FormatException('Camera $id has the unknown model $model');
        }
        cameras[id] = ColmapCamera(
          id: id,
          model: model,
          width: width,
          height: height,
          params: [for (var k = 0; k < count; k++) c.f64()],
        );
      }
      final r = _Reader(bytes('images.bin'));
      for (var n = r.u64(); n > 0; n--) {
        final id = r.u32();
        final qvec = [for (var k = 0; k < 4; k++) r.f64()];
        final tvec = [for (var k = 0; k < 3; k++) r.f64()];
        final camera = r.u32();
        final name = r.text();
        var observations = 0;
        for (var k = r.u64(); k > 0; k--) {
          r.skip(16);
          if (r.i64() >= 0) {
            observations++;
          }
        }
        images.add(
          ColmapImage(id: id, name: name, cameraId: camera, qvec: qvec, tvec: tvec, observations: observations),
        );
      }
      final q = _Reader(bytes('points3D.bin'));
      for (var n = q.u64(); n > 0; n--) {
        final id = q.u64();
        final xyz = [q.f64(), q.f64(), q.f64()];
        final rgb = [q.u8(), q.u8(), q.u8()];
        final error = q.f64();
        final track = q.u64();
        q.skip(8 * track);
        points.add(ColmapPoint(id: id, xyz: xyz, rgb: rgb, error: error, track: track));
      }
    } on RangeError {
      throw FormatException('A file of the model in ${folder.path} is cut short');
    }
    return ColmapModel(cameras: cameras, images: images, points: points);
  }

  /// The mean of the reprojection errors of the points, as model_analyzer gives it; null without points
  double? get meanReprojectionError {
    var sum = 0.0;
    var count = 0;
    for (final point in points) {
      if (point.error >= 0) {
        sum += point.error;
        count++;
      }
    }
    return count == 0 ? null : sum / count;
  }

  /// The floor under the cameras, the model being upright (+y down); null when there is none to trust (see the top of
  /// this file)
  ColmapFloor? floor() {
    if (images.isEmpty || points.isEmpty) {
      return null;
    }
    final cameraY = _median([for (final image in images) image.center[1]]);
    final below = [
      for (final point in points)
        if (point.xyz[1] > cameraY) point.xyz[1],
    ]..sort();
    if (below.length < floorMinPoints || below.length < points.length * floorMinShare) {
      return null;
    }
    final floorY = below[((below.length - 1) * floorPercentile).round()];
    return ColmapFloor(y: floorY, cameraHeight: floorY - cameraY, support: below.length);
  }
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

class _Reader {
  _Reader(Uint8List bytes) : _data = ByteData.sublistView(bytes), _bytes = bytes;

  final ByteData _data;
  final Uint8List _bytes;
  var _at = 0;

  int u8() => _data.getUint8(_at++);

  int u32() => _data.getUint32((_at += 4) - 4, Endian.little);

  int i32() => _data.getInt32((_at += 4) - 4, Endian.little);

  int u64() => _data.getUint64((_at += 8) - 8, Endian.little);

  int i64() => _data.getInt64((_at += 8) - 8, Endian.little);

  double f64() => _data.getFloat64((_at += 8) - 8, Endian.little);

  void skip(int count) {
    if (_at + count > _bytes.length) {
      throw RangeError('Past the end');
    }
    _at += count;
  }

  String text() {
    final end = _bytes.indexOf(0, _at);
    if (end < 0) {
      throw RangeError('No end to the name');
    }
    final value = utf8.decode(_bytes.sublist(_at, end), allowMalformed: true);
    _at = end + 1;
    return value;
  }
}
