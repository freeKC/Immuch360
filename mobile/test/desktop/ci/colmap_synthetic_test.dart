// Runs .github/desktop/ai/colmap_synthetic.py, the synthetic set the colmap jobs pose with the archive they built (lot
// SP1 of the splat maker): the views are the same bytes from one run to the next, and the comparison of a model with the
// true poses passes a model that differs from them by a similarity only, and fails on a missing view, a wrong rotation,
// a wrong centre or a single camera.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

const _script = 'ai/colmap_synthetic.py';

typedef _Matrix = List<List<double>>;

_Matrix _multiply(_Matrix a, _Matrix b) => [
  for (var i = 0; i < 3; i++)
    [
      for (var j = 0; j < 3; j++) [for (var k = 0; k < 3; k++) a[i][k] * b[k][j]].reduce((x, y) => x + y),
    ],
];

_Matrix _transpose(_Matrix a) => [
  for (var i = 0; i < 3; i++) [for (var j = 0; j < 3; j++) a[j][i]],
];

List<double> _apply(_Matrix m, List<double> v) => [
  for (var i = 0; i < 3; i++) m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2],
];

_Matrix _rotationY(double degrees) {
  final r = degrees * math.pi / 180;
  return [
    [math.cos(r), 0, math.sin(r)],
    [0, 1, 0],
    [-math.sin(r), 0, math.cos(r)],
  ];
}

/// The quaternion (w, x, y, z) of a rotation matrix
List<double> _quaternion(_Matrix m) {
  final trace = m[0][0] + m[1][1] + m[2][2];
  if (trace > 0) {
    final s = math.sqrt(trace + 1) * 2;
    return [s / 4, (m[2][1] - m[1][2]) / s, (m[0][2] - m[2][0]) / s, (m[1][0] - m[0][1]) / s];
  }
  if (m[0][0] > m[1][1] && m[0][0] > m[2][2]) {
    final s = math.sqrt(1 + m[0][0] - m[1][1] - m[2][2]) * 2;
    return [(m[2][1] - m[1][2]) / s, s / 4, (m[0][1] + m[1][0]) / s, (m[0][2] + m[2][0]) / s];
  }
  if (m[1][1] > m[2][2]) {
    final s = math.sqrt(1 + m[1][1] - m[0][0] - m[2][2]) * 2;
    return [(m[0][2] - m[2][0]) / s, (m[0][1] + m[1][0]) / s, s / 4, (m[1][2] + m[2][1]) / s];
  }
  final s = math.sqrt(1 + m[2][2] - m[0][0] - m[1][1]) * 2;
  return [(m[1][0] - m[0][1]) / s, (m[0][2] + m[2][0]) / s, (m[1][2] + m[2][1]) / s, s / 4];
}

/// A text model of COLMAP made from the true poses, in a world moved by a similarity (scale, rotation about y,
/// translation), as a mapper gives them: [skip] is left out, [turn] turns one camera by some degrees, [shift] moves
/// one centre by some metres, [cameras] is the number of camera lines
void _writeModel(
  Directory folder,
  Map<String, dynamic> truth, {
  String? skip,
  (String, double)? turn,
  (String, double)? shift,
  int cameras = 2,
}) {
  const scale = 0.37;
  final q = _rotationY(70);
  const move = [1.5, -0.4, 2.0];
  final lines = ['# Image list with two lines of data per image:', '# Number of images: ${truth.length}'];
  var id = 1;
  for (final entry in truth.entries) {
    if (entry.key == skip) {
      continue;
    }
    final pose = entry.value as Map<String, dynamic>;
    var rotation = [
      for (final row in pose['rotation'] as List<dynamic>)
        [for (final x in row as List<dynamic>) (x as num).toDouble()],
    ];
    var centre = [for (final x in pose['centre'] as List<dynamic>) (x as num).toDouble()];
    if (turn != null && turn.$1 == entry.key) {
      rotation = _multiply(_rotationY(turn.$2), rotation);
    }
    if (shift != null && shift.$1 == entry.key) {
      centre = [centre[0] + shift.$2, centre[1], centre[2]];
    }
    // The world of the model: X' = scale * Q * X + move; the camera keeps its view, R' = R Q^T, C' = scale Q C + move
    final moved = _multiply(rotation, _transpose(q));
    final movedCentre = [for (final (i, x) in _apply(q, centre).indexed) scale * x + move[i]];
    final translation = [for (final x in _apply(moved, movedCentre)) -x];
    final camera = pose['camera'] == 'a' || cameras == 1 ? 1 : 2;
    lines
      ..add([id, ..._quaternion(moved), ...translation, camera, entry.key].join(' '))
      ..add('12.5 30.25 -1 40.0 50.5 7');
    id++;
  }
  File(p.join(folder.path, 'images.txt')).writeAsStringSync('${lines.join('\n')}\n');
  File(p.join(folder.path, 'cameras.txt')).writeAsStringSync(
    '# Camera list with one line of data per camera:\n'
    '${[for (var c = 1; c <= cameras; c++) '$c SIMPLE_RADIAL 96 72 84.0 48 36 0.0'].join('\n')}\n',
  );
}

void main() {
  final folders = <Directory>[];

  Directory temporary() {
    final folder = Directory.systemTemp.createTempSync('immuch360_synthetic_');
    folders.add(folder);
    return folder;
  }

  tearDown(() {
    for (final folder in folders) {
      if (folder.existsSync()) {
        folder.deleteSync(recursive: true);
      }
    }
    folders.clear();
  });

  ScriptRun synthetic(List<String> arguments) => runCiScript(_script, arguments);

  /// A small set (8 views of 96 x 72), quick enough for the suite
  Directory render() {
    final folder = temporary();
    final run = synthetic(['render', '--out', folder.path, '--views', '8', '--width', '96', '--height', '72']);
    expect(run.exitCode, 0, reason: '$run');
    return folder;
  }

  Map<String, dynamic> truthOf(Directory set) =>
      (jsonDecode(File(p.join(set.path, 'poses.json')).readAsStringSync()) as Map<String, dynamic>)['images']
          as Map<String, dynamic>;

  group('colmap_synthetic.py', () {
    test('renders the views as 8 bit grey PNG files in two folders, the same bytes twice, with their poses', () {
      final first = render();
      final second = render();
      final truth = truthOf(first);
      expect(truth.keys, hasLength(8));
      expect(truth.keys.where((name) => name.startsWith('a/')), hasLength(4));
      expect(truth.keys.where((name) => name.startsWith('b/')), hasLength(4));
      expect({for (final pose in truth.values) (pose as Map<String, dynamic>)['focal']}, {84.0, 96.0});
      for (final name in truth.keys) {
        final bytes = File(p.joinAll([first.path, 'images', ...name.split('/')])).readAsBytesSync();
        expect(bytes.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        // IHDR: 96 x 72, 8 bits, grey
        expect(bytes.sublist(16, 26), [0, 0, 0, 96, 0, 0, 0, 72, 8, 0]);
        final again = File(p.joinAll([second.path, 'images', ...name.split('/')])).readAsBytesSync();
        expect(sha256.convert(again), sha256.convert(bytes), reason: name);
        // A view is not flat: the textures give SIFT something to find
        expect(bytes.toSet().length, greaterThan(64), reason: name);
      }
    });

    test('compare passes a model that differs from the truth by a similarity only', () {
      final set = render();
      final model = Directory(p.join(set.path, 'model'))..createSync();
      _writeModel(model, truthOf(set));
      final run = synthetic(['compare', '--set', set.path, '--model', model.path]);
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('8 of 8 views placed, 2 camera(s)'));
      expect(run.output, contains('(scale 2.7027)'));
    });

    test('compare fails on a missing view, a turned camera, a moved centre or a single camera', () {
      final set = render();
      final truth = truthOf(set);
      final name = truth.keys.elementAt(3);
      for (final (writer, message) in [
        ((Directory d) => _writeModel(d, truth, skip: name), '1 of 8 views not placed: $name'),
        ((Directory d) => _writeModel(d, truth, turn: (name, 2.0)), '$name: rotation 2.0'),
        ((Directory d) => _writeModel(d, truth, shift: (name, 0.5)), '$name: centre'),
        ((Directory d) => _writeModel(d, truth, cameras: 1), '1 camera(s) in the model, 2 folders of views'),
      ]) {
        final model = temporary();
        writer(model);
        final run = synthetic(['compare', '--set', set.path, '--model', model.path]);
        expect(run.exitCode, 1, reason: '$message: $run');
        expect(run.output, contains(message));
      }
    });
  }, skip: skipCiScripts);
}
