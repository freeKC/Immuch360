// A depth model without ONNX Runtime, for the tests of the chain and of the engine: it gives a known map (a gradient,
// a step or a constant), counts its calls, and fails on demand.

import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The map [FakeDepthBackend] gives
enum FakeDepthShape {
  /// Nearer towards the bottom, as a ground seen from standing: 1 on the top row to 10 on the bottom one
  gradient,

  /// The left half far (1), the right half near (10)
  step,

  /// 5 everywhere: no relief at all
  constant,
}

class FakeDepthBackend implements DepthBackend {
  FakeDepthBackend({
    this.shape = FakeDepthShape.gradient,
    this.inputWidth = depthModelInputWidth,
    this.inputHeight = depthModelInputHeight,
    this.modelSha256 = depthModelOnnxSha256,
    this.failure,
  });

  final FakeDepthShape shape;

  @override
  final int inputWidth;

  @override
  final int inputHeight;

  @override
  final String modelSha256;

  /// When set, [estimate] throws a DepthBackendException with this message
  String? failure;

  /// How many times [estimate] ran, and whether [close] was called after the last one
  int calls = 0;
  bool closed = false;

  @override
  DepthMap estimate(Float32List nchw) {
    if (nchw.length != 3 * inputWidth * inputHeight) {
      throw ArgumentError('The input is [1, 3, $inputHeight, $inputWidth]: ${nchw.length} values');
    }
    calls++;
    closed = false;
    final message = failure;
    if (message != null) {
      throw DepthBackendException(message);
    }
    final values = Float32List(inputWidth * inputHeight);
    for (var y = 0; y < inputHeight; y++) {
      for (var x = 0; x < inputWidth; x++) {
        values[y * inputWidth + x] = switch (shape) {
          FakeDepthShape.gradient => inputHeight == 1 ? 1.0 : 1.0 + 9.0 * y / (inputHeight - 1),
          FakeDepthShape.step => x < inputWidth ~/ 2 ? 1.0 : 10.0,
          FakeDepthShape.constant => 5.0,
        };
      }
    }
    return DepthMap(inputWidth, inputHeight, values);
  }

  @override
  void close() => closed = true;
}
