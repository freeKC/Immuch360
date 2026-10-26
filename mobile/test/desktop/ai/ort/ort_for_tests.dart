// The real ONNX Runtime of the tests that need one (ort_session_test, ort_depth_backend_test, ort_real_model_test):
// the library of an official release archive, named by IMMUCH360_ORT_LIB, one version per run since a process keeps
// the first ONNX Runtime it loads. Without it those tests are skipped with this reason; a name that leads to no file
// fails them, so that a run of the CI that looks for a library in the wrong place cannot pass by skipping them all. The
// desktop workflow downloads the archives by their SHA-256: 1.31.0 and 1.23.2 on Linux (the job test), 1.31.0 on
// Windows (the job windows).
//
//   Linux:   tar -xzf onnxruntime-linux-x64-1.31.0.tgz
//            IMMUCH360_ORT_LIB=$PWD/onnxruntime-linux-x64-1.31.0/lib/libonnxruntime.so.1.31.0 flutter test test/desktop/ai/ort
//   Windows: IMMUCH360_ORT_LIB=C:\ort\onnxruntime-win-x64-1.31.0\lib\onnxruntime.dll flutter test test/desktop/ai/ort
//   macOS:   IMMUCH360_ORT_LIB=$PWD/onnxruntime-osx-arm64-1.31.0/lib/libonnxruntime.1.31.0.dylib (1.23.2 x86_64 on
//            an Intel Mac)
//
// The tiny model (test/fixtures/ai_immersive/tiny_depth.onnx, made by .github/desktop/ai/make_tiny_depth_model.py)
// stands for Depth Anything V2 Small: the same input and output names and ranks, one 3 x 3 convolution inside, whose
// output this file computes exactly for inputs made of multiples of 1/32.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// The ONNX Runtime library to load, or why the tests that need one are skipped
typedef OrtForTests = ({String? library, String? skip});

/// The library [environment] (the process's by default) names in IMMUCH360_ORT_LIB. Throws [StateError] when it names
/// no file: called by main, that fails the whole test file.
OrtForTests ortForTests([Map<String, String>? environment]) {
  final given = (environment ?? Platform.environment)['IMMUCH360_ORT_LIB'];
  if (given == null || given.isEmpty) {
    return (
      library: null,
      skip: 'no ONNX Runtime: set IMMUCH360_ORT_LIB to the library of an official archive (see ort_for_tests.dart)',
    );
  }
  if (!File(given).existsSync()) {
    throw StateError('IMMUCH360_ORT_LIB names no file: $given');
  }
  return (library: p.absolute(given), skip: null);
}

/// The tiny depth model, as an absolute path
String tinyDepthModelPath() => p.absolute('test/fixtures/ai_immersive/tiny_depth.onnx');

/// tiny_depth_expected.json: the weights of the model, a sample input and its output
class TinyDepthModel {
  TinyDepthModel._(
    this.inputName,
    this.outputName,
    this.weights,
    this.bias,
    this.sampleShape,
    this.sample,
    this.expectedShape,
    this.expected,
  );

  factory TinyDepthModel.load() {
    final json =
        jsonDecode(File('test/fixtures/ai_immersive/tiny_depth_expected.json').readAsStringSync())
            as Map<String, dynamic>;
    List<double> flat(Object? nested) =>
        nested is List ? [for (final item in nested) ...flat(item)] : [(nested! as num).toDouble()];
    return TinyDepthModel._(
      json['input'] as String,
      json['output'] as String,
      flat(json['weights']),
      (json['bias'] as num).toDouble(),
      (json['sampleShape'] as List).cast<int>(),
      Float32List.fromList(flat(json['sampleInput'])),
      (json['expectedShape'] as List).cast<int>(),
      Float32List.fromList(flat(json['expectedOutput'])),
    );
  }

  final String inputName;
  final String outputName;

  /// weight[channel][row][column], flattened
  final List<double> weights;
  final double bias;
  final List<int> sampleShape;
  final Float32List sample;
  final List<int> expectedShape;
  final Float32List expected;

  /// An input of [height] x [width] made of multiples of 1/32 below 2, so that float32 computes the model exactly
  static Float32List exactInput(int width, int height) {
    final values = Float32List(3 * width * height);
    for (var c = 0; c < 3; c++) {
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          values[(c * height + y) * width + x] = ((20 * c + 5 * y + x) % 64) / 32;
        }
      }
    }
    return values;
  }

  /// What the model gives for [input] of [height] x [width]: the convolution padded by one, plus the bias
  Float32List outputFor(Float32List input, int width, int height) {
    final output = Float32List(width * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var total = bias;
        for (var c = 0; c < 3; c++) {
          for (var ky = 0; ky < 3; ky++) {
            for (var kx = 0; kx < 3; kx++) {
              final yy = y + ky - 1;
              final xx = x + kx - 1;
              if (yy >= 0 && yy < height && xx >= 0 && xx < width) {
                total += weights[(c * 3 + ky) * 3 + kx] * input[(c * height + yy) * width + xx];
              }
            }
          }
        }
        output[y * width + x] = total;
      }
    }
    return output;
  }
}
