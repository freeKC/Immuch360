// The model of COLMAP read by the app (lib/desktop/ai/splat/colmap_model.dart, lot SP4), on models written as COLMAP
// 4.2.1 writes them by the writer of the fakes (test/desktop/ai/fakes/fake_colmap_model.dart): the count of an
// images.bin from its first bytes, the largest of several models, the cameras, the names in UTF-8, the centres, the
// mean reprojection error, a file cut short, and the floor under the cameras of a synthetic room. The same reader on
// the models of the measure of 1 November gave what model_analyzer gave (150 images, 29 818 points, 0.662430 px for
// the room; 144, 11 296, 0.623272 px for the video): lot SP4, report.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/splat/colmap_model.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_colmap_model.dart';

const _camera = FakeColmapCamera(id: 1, width: 1600, height: 1200, params: [1920, 800, 600, 0.01]);

/// [count] images on a circle of 1.3 m around the origin, at the height 0, named in [folder]
FakeColmapModel _circle(int count, {String folder = 'cam0', List<FakeColmapPoint>? points}) {
  final model = FakeColmapModel.circle(
    names: [for (var k = 1; k <= count; k++) '$folder/${'$k'.padLeft(6, '0')}.jpg'],
    ids: [for (var k = 1; k <= count; k++) k],
    cameras: const [_camera],
    cameraOf: (_) => 1,
  );
  return points == null ? model : FakeColmapModel(cameras: model.cameras, images: model.images, points: points);
}

/// [count] points at the height [y] (+y down), spread over a square of [side] metres
List<FakeColmapPoint> _layer(int count, double y, {double side = 4, int firstId = 1, int seed = 1}) {
  final random = math.Random(seed);
  return [
    for (var k = 0; k < count; k++)
      FakeColmapPoint(
        id: firstId + k,
        xyz: [
          random.nextDouble() * side - side / 2,
          y + random.nextDouble() * 0.02 - 0.01,
          random.nextDouble() * side - side / 2,
        ],
        rgb: const [128, 128, 128],
        track: const [(1, 0), (2, 0)],
      ),
  ];
}

void main() {
  late Directory folder;

  setUp(() => folder = Directory.systemTemp.createTempSync('colmap-model-'));
  tearDown(() => folder.deleteSync(recursive: true));

  Directory at(String name) => Directory(p.join(folder.path, name));

  test('reads the cameras, the images with their names in UTF-8 and their centres, and the points', () {
    final written = FakeColmapModel.circle(
      names: ['Łódź/000001.jpg', 'Łódź/000002.jpg', 'été/000003.jpg', 'été/000004.jpg'],
      ids: [1, 2, 3, 4],
      cameras: const [
        _camera,
        FakeColmapCamera(id: 2, width: 800, height: 600, params: [960, 400, 300, 0]),
      ],
      cameraOf: (name) => name.startsWith('été') ? 2 : 1,
    )..writeTo(at('0'));
    final model = ColmapModel.read(at('0'));
    expect(model.cameras.keys, [1, 2]);
    expect((model.cameras[1]!.model, model.cameras[1]!.width, model.cameras[1]!.height), (2, 1600, 1200));
    expect(model.cameras[1]!.params, [1920, 800, 600, 0.01]);
    expect(model.images.map((image) => image.name), [
      'Łódź/000001.jpg',
      'Łódź/000002.jpg',
      'été/000003.jpg',
      'été/000004.jpg',
    ]);
    expect(model.images.map((image) => image.cameraId), [1, 1, 2, 2]);
    for (final image in model.images) {
      final c = image.center;
      // The writer puts each camera 1.3 m from the origin, at the height 0
      expect(math.sqrt(c[0] * c[0] + c[2] * c[2]), closeTo(1.3, 1e-9));
      expect(c[1], closeTo(0, 1e-9));
    }
    expect(model.points, hasLength(written.points.length));
    expect(model.points.first.xyz, written.points.first.xyz);
    expect(model.points.first.rgb, written.points.first.rgb);
    expect(model.points.first.track, 2);
    expect(model.images.first.observations, written.images.first.points.length);
    expect(model.meanReprojectionError, closeTo(0.66, 1e-12));
    expect(colmapPlacedIn(at('0')), 4);
  });

  test('the count of a model is the first 8 bytes of its images.bin; none without, or with fewer bytes', () {
    _circle(150).writeTo(at('0'));
    final head = File(p.join(at('0').path, 'images.bin')).readAsBytesSync().sublist(0, 8);
    File(p.join((at('1')..createSync()).path, 'images.bin')).writeAsBytesSync(head);
    File(p.join((at('2')..createSync()).path, 'images.bin')).writeAsBytesSync(head.sublist(0, 4));
    expect(colmapPlacedIn(at('0')), 150);
    expect(colmapPlacedIn(at('1')), 150);
    expect(colmapPlacedIn(at('2')), isNull);
    expect(colmapPlacedIn(at('3')), isNull);
  });

  test('the largest model of the mapper: the most images, the first of two equal ones; none in an empty folder', () {
    final sparse = at('sparse')..createSync();
    expect(largestColmapModel(sparse), isNull);
    expect(largestColmapModel(at('nothing')), isNull);
    _circle(4).writeTo(Directory(p.join(sparse.path, '0')));
    _circle(12).writeTo(Directory(p.join(sparse.path, '1')));
    _circle(12).writeTo(Directory(p.join(sparse.path, '2')));
    // Not a model of the mapper
    _circle(40).writeTo(Directory(p.join(sparse.path, 'aligned')));
    final largest = largestColmapModel(sparse)!;
    expect(p.basename(largest.folder.path), '1');
    expect(largest.placed, 12);
    // The video of the measure: 144 images in sparse/0, 26 in sparse/1
    final video = at('video')..createSync();
    _circle(144).writeTo(Directory(p.join(video.path, '0')));
    _circle(26).writeTo(Directory(p.join(video.path, '1')));
    expect(p.basename(largestColmapModel(video)!.folder.path), '0');
    // sparse/10 comes after sparse/9, not after sparse/1
    final many = at('many')..createSync();
    _circle(30).writeTo(Directory(p.join(many.path, '9')));
    _circle(30).writeTo(Directory(p.join(many.path, '10')));
    expect(p.basename(largestColmapModel(many)!.folder.path), '9');
  });

  test('a missing file, a file cut short or an unknown camera model does not read', () {
    _circle(6).writeTo(at('0'));
    File(p.join(at('0').path, 'points3D.bin')).deleteSync();
    expect(() => ColmapModel.read(at('0')), throwsFormatException);
    _circle(6).writeTo(at('1'));
    final images = File(p.join(at('1').path, 'images.bin'));
    images.writeAsBytesSync(images.readAsBytesSync().sublist(0, 200));
    expect(() => ColmapModel.read(at('1')), throwsFormatException);
    _circle(6).writeTo(at('2'));
    final cameras = File(p.join(at('2').path, 'cameras.bin'));
    final bytes = cameras.readAsBytesSync();
    bytes[12] = 42;
    cameras.writeAsBytesSync(bytes);
    expect(() => ColmapModel.read(at('2')), throwsFormatException);
  });

  test('the floor of a room: the lowest layer under the cameras, its floaters left out', () {
    // Cameras at the height 0, a floor 1.5 m below them, a table at 0.75, the ceiling 1.2 m above, a few floaters under
    // the floor
    final points = [
      ..._layer(600, 1.5, side: 5),
      ..._layer(150, 0.75, side: 1, firstId: 1000, seed: 2),
      ..._layer(400, -1.2, side: 5, firstId: 2000, seed: 3),
      ..._layer(8, 2.6, side: 5, firstId: 3000, seed: 4),
    ];
    _circle(40, points: points).writeTo(at('0'));
    final floor = ColmapModel.read(at('0')).floor()!;
    expect(floor.y, closeTo(1.5, 0.011));
    expect(floor.cameraHeight, closeTo(1.5, 0.011));
    expect(floor.support, 758);
  });

  test('no floor without points under the cameras, or with too few of them', () {
    // An object seen from below: every point above the cameras
    _circle(30, points: _layer(500, -0.8)).writeTo(at('0'));
    expect(ColmapModel.read(at('0')).floor(), isNull);
    // Under a tenth of the points below
    _circle(30, points: [..._layer(500, -0.8), ..._layer(40, 1.2, firstId: 1000)]).writeTo(at('1'));
    expect(ColmapModel.read(at('1')).floor(), isNull);
    // Fewer than 30 below, whatever their share
    _circle(30, points: [..._layer(20, -0.8), ..._layer(29, 1.2, firstId: 1000)]).writeTo(at('2'));
    expect(ColmapModel.read(at('2')).floor(), isNull);
    _circle(30, points: [..._layer(20, -0.8), ..._layer(30, 1.2, firstId: 1000)]).writeTo(at('3'));
    expect(ColmapModel.read(at('3')).floor()!.y, closeTo(1.2, 0.011));
  });

  test('the centre of a camera is -Rᵀ t', () {
    // Turned a quarter about the vertical, the origin 2 m in front of it along its own z: it stands at x = 2
    const half = math.pi / 4;
    final c = colmapCenterOf([math.cos(half), 0, math.sin(half), 0], [0, 0, 2]);
    expect(c[0], closeTo(2, 1e-12));
    expect(c[1], closeTo(0, 1e-12));
    expect(c[2], closeTo(0, 1e-12));
    // The quaternion need not be of length 1
    final scaled = colmapCenterOf([2 * math.cos(half), 0, 2 * math.sin(half), 0], [0, 0, 2]);
    expect(scaled[0], closeTo(2, 1e-12));
  });
}
