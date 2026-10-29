// The depth model behind one interface (design-final 2026-10-26, section 2.7): ONNX Runtime by FFI on the processor in
// phase 1 (lot A4a), a GPU later (lot A10), and FakeDepthBackend in the tests, which gives a gradient, a step or a
// constant without any native library. The call is synchronous: the heavy body of a job runs as one synchronous event
// of the worker isolate, so the thread never changes on the way and the cancel flag is read without waiting.

import 'dart:typed_data';

/// A depth map: relative disparity (larger is nearer), [height] rows of [width] values
class DepthMap {
  DepthMap(this.width, this.height, this.values)
    : assert(values.length == width * height, 'A map of $width x $height has ${width * height} values');

  final int width;
  final int height;
  final Float32List values;

  double at(int x, int y) => values[y * width + x];
}

/// Thrown when the model cannot be loaded or run; the job then fails with modelFailed and this message
class DepthBackendException implements Exception {
  const DepthBackendException(this.message);

  final String message;

  @override
  String toString() => 'DepthBackendException: $message';
}

/// Estimates the depth of a photo already prepared for the model
abstract interface class DepthBackend {
  /// The input the model takes: 686 x 518 for Depth Anything V2 Small on every system (depthModelInputWidth and
  /// depthModelInputHeight)
  int get inputWidth;
  int get inputHeight;

  /// The SHA-256 of the model file, written as DepthModelSha256
  String get modelSha256;

  /// The depth of [nchw], the photo as [1, 3, inputHeight, inputWidth] float32 normalised with the means and standard
  /// deviations of ImageNet. The map has the size the model gives (its output [1, inputHeight, inputWidth]).
  /// Throws [DepthBackendException].
  DepthMap estimate(Float32List nchw);

  /// Frees the session; [estimate] loads it again when called after
  void close();
}
