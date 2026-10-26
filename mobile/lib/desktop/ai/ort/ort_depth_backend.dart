// Depth Anything V2 Small through ONNX Runtime on the processor, behind DepthBackend (design-final 2026-10-26 sections
// 2.1 and 2.7, lot A4a). The library and the model are files of the AI components (lot A3a); the session opens on the
// first estimate, or on open() when the hardware gate wants to know whether the library loads, and close() gives its
// memory back (the worker of lot A4b closes it after two minutes without work). The model must take one float32
// image [1, 3, height, width] and give a float32 map whose leading dimensions are 1; any failure, with ONNX Runtime's
// message, becomes a DepthBackendException, so that the job ends with modelFailed and that message.

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

class OrtDepthBackend implements DepthBackend {
  OrtDepthBackend({
    required this.libraryPath,
    required this.modelPath,
    this.modelSha256 = depthModelOnnxSha256,
    this.inputWidth = depthModelInputWidth,
    this.inputHeight = depthModelInputHeight,
    this.settings,
  });

  /// The ONNX Runtime library (onnxruntime.dll, libonnxruntime.so.1.31.0, libonnxruntime.1.31.0.dylib...)
  final String libraryPath;

  /// The model file, Depth Anything V2 Small in ONNX
  final String modelPath;

  @override
  final String modelSha256;

  @override
  final int inputWidth;

  @override
  final int inputHeight;

  /// The use of the processor, the design's ([OrtSessionSettings.forThisComputer]) when null
  final OrtSessionSettings? settings;

  OrtSession? _session;

  /// Whether a session is open (between the first estimate or [open] and [close])
  bool get isOpen => _session != null;

  /// The version of ONNX Runtime the session runs on, null before the session opens
  String? get runtimeVersion => _session?.runtime.version;

  /// Loads the library and the model now rather than at the first estimate. Throws [DepthBackendException] with the
  /// reason (the library is missing or refused, the model unreadable or not a depth model).
  void open() => _session ??= _openSession();

  @override
  DepthMap estimate(Float32List nchw) {
    if (nchw.length != 3 * inputWidth * inputHeight) {
      throw ArgumentError('The input is [1, 3, $inputHeight, $inputWidth]: ${nchw.length} values');
    }
    final session = _session ??= _openSession();
    final OrtTensor output;
    try {
      output = session.run(nchw, [1, 3, inputHeight, inputWidth]);
    } on OrtException catch (error) {
      throw DepthBackendException(error.message);
    }
    final shape = output.shape;
    if (shape.length < 2 || shape.take(shape.length - 2).any((dimension) => dimension != 1)) {
      throw DepthBackendException('The model gave a map of shape $shape, not [1, height, width]');
    }
    return DepthMap(shape[shape.length - 1], shape[shape.length - 2], output.values);
  }

  @override
  void close() {
    _session?.close();
    _session = null;
  }

  OrtSession _openSession() {
    final OrtSession session;
    try {
      session = OrtRuntime.load(libraryPath).openSession(modelPath, settings: settings);
    } on OrtException catch (error) {
      throw DepthBackendException(error.message);
    }
    final refusal = refusalOf(session.inputs, session.outputs);
    if (refusal != null) {
      session.close();
      throw DepthBackendException(refusal);
    }
    return session;
  }

  /// Why a model of these [inputs] and [outputs] is not a depth model this backend can feed, null when it is
  @visibleForTesting
  String? refusalOf(List<OrtTensorSpec> inputs, List<OrtTensorSpec> outputs) {
    if (inputs.length != 1 || outputs.isEmpty) {
      return '$modelPath has ${inputs.length} inputs and ${outputs.length} outputs: a depth model takes one image and '
          'gives one map';
    }
    final input = inputs.single;
    final shape = input.shape;
    bool fits(int dimension, int wanted) => dimension == -1 || dimension == wanted;
    if (!input.isFloat ||
        shape.length != 4 ||
        !fits(shape[0], 1) ||
        !fits(shape[1], 3) ||
        !fits(shape[2], inputHeight) ||
        !fits(shape[3], inputWidth)) {
      return 'The input $input of $modelPath does not take a float32 image [1, 3, $inputHeight, $inputWidth]';
    }
    if (!outputs.first.isFloat) {
      return 'The output ${outputs.first} of $modelPath is not float32';
    }
    return null;
  }
}
