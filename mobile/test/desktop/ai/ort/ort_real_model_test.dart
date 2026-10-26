// The real model on the real ONNX Runtime, on a few photos (lot A4a): run by hand on a build host, never in the CI,
// which downloads no model. One library per run (see ort_for_tests.dart), so the parity of two versions takes two runs
// sharing a folder of maps: the first writes them, the second compares with them.
//
//   IMMUCH360_ORT_LIB    the library (1.31.0, then 1.23.2: the proof that Intel Macs read the model)
//   IMMUCH360_AI_MODEL   Depth Anything V2 Small in ONNX (model.onnx of onnx-community, 99 060 839 bytes)
//   IMMUCH360_AI_PHOTOS  a folder of JPEG photos
//   IMMUCH360_ORT_MAPS   a folder for the maps: written when absent, compared when present (largest difference,
//                        relative to the range of the map, at most 1e-4)
//
// The photo is stretched to 686 x 518 by package:image and normalised with the means and deviations of ImageNet: a
// stand-in for the chain of lot A4b, enough to compare two versions of ONNX Runtime on real content.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/ort/ort_depth_backend.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

import 'ort_for_tests.dart';

Float32List _nchw(img.Image photo) {
  final resized = img.copyResize(
    photo,
    width: depthModelInputWidth,
    height: depthModelInputHeight,
    interpolation: img.Interpolation.average,
  );
  const mean = [0.485, 0.456, 0.406];
  const deviation = [0.229, 0.224, 0.225];
  const plane = depthModelInputWidth * depthModelInputHeight;
  final values = Float32List(3 * plane);
  for (var y = 0; y < depthModelInputHeight; y++) {
    for (var x = 0; x < depthModelInputWidth; x++) {
      final pixel = resized.getPixel(x, y);
      final rgb = [pixel.rNormalized, pixel.gNormalized, pixel.bNormalized];
      for (var c = 0; c < 3; c++) {
        values[c * plane + y * depthModelInputWidth + x] = (rgb[c] - mean[c]) / deviation[c];
      }
    }
  }
  return values;
}

void main() {
  final ort = ortForTests();
  final model = Platform.environment['IMMUCH360_AI_MODEL'];
  final photos = Platform.environment['IMMUCH360_AI_PHOTOS'];
  final maps = Platform.environment['IMMUCH360_ORT_MAPS'];
  final skip =
      ort.skip ??
      (model == null || photos == null ? 'set IMMUCH360_AI_MODEL and IMMUCH360_AI_PHOTOS (see this file)' : null);

  test(
    'the real model gives the same maps on every version of ONNX Runtime',
    () {
      final backend = OrtDepthBackend(libraryPath: ort.library!, modelPath: model!);
      addTearDown(backend.close);
      final opening = Stopwatch()..start();
      backend.open();
      // ignore: avoid_print
      print('ONNX Runtime ${backend.runtimeVersion}: session opened in ${opening.elapsedMilliseconds} ms');
      final files =
          Directory(photos!)
              .listSync()
              .whereType<File>()
              .where((f) => RegExp(r'\.jpe?g$', caseSensitive: false).hasMatch(f.path))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      expect(files, isNotEmpty);
      for (final file in files) {
        final photo = img.decodeJpg(file.readAsBytesSync())!;
        final input = _nchw(photo);
        final pass = Stopwatch()..start();
        final map = backend.estimate(input);
        final elapsed = pass.elapsedMilliseconds;
        expect(map.width, depthModelInputWidth);
        expect(map.height, depthModelInputHeight);
        var low = double.infinity;
        var high = -double.infinity;
        for (final value in map.values) {
          expect(value.isFinite, isTrue);
          low = math.min(low, value);
          high = math.max(high, value);
        }
        expect(high, greaterThan(low));
        var line =
            '${p.basename(file.path)} ${photo.width} x ${photo.height}: depth in $elapsed ms, from $low to $high';
        if (maps != null) {
          final saved = File(p.join(maps, '${p.basenameWithoutExtension(file.path)}.f32'));
          if (saved.existsSync()) {
            final reference = saved.readAsBytesSync().buffer.asFloat32List();
            expect(reference.length, map.values.length);
            var largest = 0.0;
            for (var i = 0; i < reference.length; i++) {
              largest = math.max(largest, (reference[i] - map.values[i]).abs());
            }
            final relative = largest / (high - low);
            line += ', largest difference with ${saved.path} $largest ($relative of the range)';
            expect(relative, lessThanOrEqualTo(1e-4), reason: line);
          } else {
            Directory(maps).createSync(recursive: true);
            saved.writeAsBytesSync(map.values.buffer.asUint8List(map.values.offsetInBytes, map.values.lengthInBytes));
            line += ', written to ${saved.path}';
          }
        }
        // ignore: avoid_print
        print(line);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
