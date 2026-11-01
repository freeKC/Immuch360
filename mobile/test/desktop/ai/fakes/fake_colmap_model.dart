// The files a COLMAP model is made of, as COLMAP 4.2.1 writes them in a sparse/<n> folder (cameras.bin, images.bin,
// points3D.bin, little endian, the names of the images in UTF-8; read in the models of the measure of 1 November 2026,
// which keep this layout of COLMAP 3 beside their new rigs.bin and frames.bin), for the fake COLMAP and the fake Brush
// of the splat scenes (lot SP0), and read back by their tests. Pure Dart, with no Flutter: compiled into the fakes by
// `dart compile exe`. The model of the app itself is read by its own code (lot SP4), never by this one.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// SIMPLE_RADIAL, the model COLMAP gives a camera it knows nothing of: f, cx, cy, k
const fakeColmapSimpleRadial = 2;

/// One camera of a model
class FakeColmapCamera {
  const FakeColmapCamera({required this.id, required this.width, required this.height, required this.params});

  final int id;
  final int width;
  final int height;

  /// f, cx, cy, k of SIMPLE_RADIAL
  final List<double> params;
}

/// One image registered in a model: the world to the camera, as COLMAP writes it, and its points
class FakeColmapImage {
  const FakeColmapImage({
    required this.id,
    required this.name,
    required this.cameraId,
    required this.qvec,
    required this.tvec,
    this.points = const [],
  });

  final int id;

  /// Its path under the folder of the images, "/" between folders: "cam0/0001.jpg"
  final String name;
  final int cameraId;

  /// w, x, y, z
  final List<double> qvec;
  final List<double> tvec;

  /// x, y of each point of the image in pixels, with the id of its point in 3D (-1 for none)
  final List<(double, double, int)> points;
}

/// One point of a model, with the images that see it (image id, index of the point in that image)
class FakeColmapPoint {
  const FakeColmapPoint({required this.id, required this.xyz, required this.rgb, required this.track});

  final int id;
  final List<double> xyz;
  final List<int> rgb;
  final List<(int, int)> track;
}

/// A whole model
class FakeColmapModel {
  const FakeColmapModel({required this.cameras, required this.images, required this.points});

  final List<FakeColmapCamera> cameras;
  final List<FakeColmapImage> images;
  final List<FakeColmapPoint> points;

  /// The model of [names] (their image ids in [ids]) placed on a circle around the origin, looking at it, each with
  /// [cameraOf] its camera, and [pointsPerImage] points of a box of 4 x 2.4 x 4 m seen by it and the image after it
  factory FakeColmapModel.circle({
    required List<String> names,
    required List<int> ids,
    required List<FakeColmapCamera> cameras,
    required int Function(String name) cameraOf,
    int pointsPerImage = 12,
  }) {
    final random = math.Random(names.length * 7919 + ids.fold<int>(0, (sum, id) => sum + id));
    final images = <FakeColmapImage>[];
    final points = <FakeColmapPoint>[];
    final observations = <int, List<(double, double, int)>>{for (final id in ids) id: []};
    for (var k = 0; k < ids.length; k++) {
      for (var j = 0; j < pointsPerImage; j++) {
        final id = points.length + 1;
        final seenBy = [ids[k], if (ids.length > 1) ids[(k + 1) % ids.length]];
        final track = <(int, int)>[];
        for (final image in seenBy) {
          final list = observations[image]!;
          track.add((image, list.length));
          list.add((random.nextDouble() * 1000, random.nextDouble() * 700, id));
        }
        points.add(
          FakeColmapPoint(
            id: id,
            xyz: [random.nextDouble() * 4 - 2, random.nextDouble() * 2.4 - 1.2, random.nextDouble() * 4 - 2],
            rgb: [random.nextInt(256), random.nextInt(256), random.nextInt(256)],
            track: track,
          ),
        );
      }
    }
    for (var k = 0; k < ids.length; k++) {
      final angle = 2 * math.pi * k / ids.length;
      // A turn about the vertical: the camera at 1.3 m from the origin, looking at it
      final half = (angle + math.pi / 2) / 2;
      images.add(
        FakeColmapImage(
          id: ids[k],
          name: names[k],
          cameraId: cameraOf(names[k]),
          qvec: [math.cos(half), 0, math.sin(half), 0],
          tvec: [0, 0, 1.3],
          points: observations[ids[k]]!,
        ),
      );
    }
    return FakeColmapModel(cameras: cameras, images: images, points: points);
  }

  /// Writes cameras.bin, images.bin and points3D.bin into [folder], made first unless [create] is false (the aligner of
  /// the fake COLMAP, which refuses a folder that is not there)
  void writeTo(Directory folder, {bool create = true}) {
    if (create) {
      folder.createSync(recursive: true);
    }
    final cameraBytes = BytesBuilder()..add(_u64(cameras.length));
    for (final camera in cameras) {
      cameraBytes
        ..add(_u32(camera.id))
        ..add(_i32(fakeColmapSimpleRadial))
        ..add(_u64(camera.width))
        ..add(_u64(camera.height));
      for (final value in camera.params) {
        cameraBytes.add(_f64(value));
      }
    }
    File('${folder.path}/cameras.bin').writeAsBytesSync(cameraBytes.takeBytes());
    final imageBytes = BytesBuilder()..add(_u64(images.length));
    for (final image in images) {
      imageBytes.add(_u32(image.id));
      for (final value in [...image.qvec, ...image.tvec]) {
        imageBytes.add(_f64(value));
      }
      imageBytes
        ..add(_u32(image.cameraId))
        ..add([...utf8.encode(image.name), 0])
        ..add(_u64(image.points.length));
      for (final (x, y, point) in image.points) {
        imageBytes
          ..add(_f64(x))
          ..add(_f64(y))
          ..add(_i64(point));
      }
    }
    File('${folder.path}/images.bin').writeAsBytesSync(imageBytes.takeBytes());
    final pointBytes = BytesBuilder()..add(_u64(points.length));
    for (final point in points) {
      pointBytes.add(_u64(point.id));
      for (final value in point.xyz) {
        pointBytes.add(_f64(value));
      }
      pointBytes
        ..add(point.rgb)
        ..add(_f64(0.66))
        ..add(_u64(point.track.length));
      for (final (image, index) in point.track) {
        pointBytes
          ..add(_u32(image))
          ..add(_u32(index));
      }
    }
    File('${folder.path}/points3D.bin').writeAsBytesSync(pointBytes.takeBytes());
  }

  /// The model in [folder], null when its three files are not all there
  static FakeColmapModel? readFrom(Directory folder) {
    final files = [
      for (final name in ['cameras.bin', 'images.bin', 'points3D.bin']) File('${folder.path}/$name'),
    ];
    if (files.any((file) => !file.existsSync())) {
      return null;
    }
    final cameras = <FakeColmapCamera>[];
    final c = _Reader(files[0].readAsBytesSync());
    for (var n = c.u64(); n > 0; n--) {
      final id = c.u32();
      final model = c.i32();
      final width = c.u64();
      final height = c.u64();
      final count = model == fakeColmapSimpleRadial ? 4 : _paramCounts[model] ?? 0;
      cameras.add(
        FakeColmapCamera(id: id, width: width, height: height, params: [for (var k = 0; k < count; k++) c.f64()]),
      );
    }
    final images = <FakeColmapImage>[];
    final r = _Reader(files[1].readAsBytesSync());
    for (var n = r.u64(); n > 0; n--) {
      final id = r.u32();
      final qvec = [for (var k = 0; k < 4; k++) r.f64()];
      final tvec = [for (var k = 0; k < 3; k++) r.f64()];
      final camera = r.u32();
      final name = r.text();
      final points = [for (var k = r.u64(); k > 0; k--) (r.f64(), r.f64(), r.i64())];
      images.add(FakeColmapImage(id: id, name: name, cameraId: camera, qvec: qvec, tvec: tvec, points: points));
    }
    final points = <FakeColmapPoint>[];
    final p = _Reader(files[2].readAsBytesSync());
    for (var n = p.u64(); n > 0; n--) {
      final id = p.u64();
      final xyz = [p.f64(), p.f64(), p.f64()];
      final rgb = [p.u8(), p.u8(), p.u8()];
      p.f64();
      final track = [for (var k = p.u64(); k > 0; k--) (p.u32(), p.u32())];
      points.add(FakeColmapPoint(id: id, xyz: xyz, rgb: rgb, track: track));
    }
    return FakeColmapModel(cameras: cameras, images: images, points: points);
  }
}

/// The parameters of the other camera models of COLMAP, by their id
const _paramCounts = {0: 3, 1: 4, 3: 5, 4: 8, 5: 8, 6: 12, 7: 5, 8: 4, 9: 5, 10: 12};

Uint8List _u32(int value) => Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);

Uint8List _i32(int value) => Uint8List(4)..buffer.asByteData().setInt32(0, value, Endian.little);

Uint8List _u64(int value) => Uint8List(8)..buffer.asByteData().setUint64(0, value, Endian.little);

Uint8List _i64(int value) => Uint8List(8)..buffer.asByteData().setInt64(0, value, Endian.little);

Uint8List _f64(double value) => Uint8List(8)..buffer.asByteData().setFloat64(0, value, Endian.little);

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

  String text() {
    final end = _bytes.indexOf(0, _at);
    final value = utf8.decode(_bytes.sublist(_at, end));
    _at = end + 1;
    return value;
  }
}
