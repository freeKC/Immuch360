// MoGe-2 ViT-S through ONNX Runtime, behind GeometryBackend (design-final 2026-10-27, sections 2.2 and 2.3, step 2;
// measure M2; lot S1). The model is our export of the MIT weights (moge_2_vits_normal_immuch360.onnx, the catalogue's
// mogeGeometryComponent): image float32 [1, 3, height, width] in [0, 1] and num_tokens int64 of shape [] in; points
// float32 [1, height, width, 3] (up to the shift of their depth), normal, mask float32 [1, height, width] (a sigmoid)
// and scale float32 [1] (the metric scale) out. The network normalises the image itself and gives its maps at the size
// of the input. M2 chose 2 500 tokens and a session without the arena of ONNX Runtime (1.35 GB at the peak instead of
// 2.25, for the same time).
//
// The session comes from [session] (the worker keeps it between jobs, ai_worker.dart) and every run takes the
// RunOptions of the job ([options]), through which the root isolate stops a run in progress: OrtRunStopped becomes
// BackendException(cancelled). Any other failure, with the message of ONNX Runtime, is modelFailed. A model whose
// names, types or ranks are not those of our export is refused before its first run.

import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The tokens MoGe-2 ViT-S runs with (measure M2: 2 500, the top of the range MoGe suggests)
const mogeTokens = 2500;

/// Why a model is not MoGe-2 as we export it, null when it is
String? mogeRefusalOf(List<OrtTensorSpec> inputs, List<OrtTensorSpec> outputs) {
  OrtTensorSpec? named(List<OrtTensorSpec> specs, String name) => specs.where((spec) => spec.name == name).firstOrNull;
  final image = named(inputs, 'image');
  final tokens = named(inputs, 'num_tokens');
  final points = named(outputs, 'points');
  final mask = named(outputs, 'mask');
  final scale = named(outputs, 'scale');
  if (image == null || tokens == null || points == null || mask == null || scale == null) {
    return 'Not MoGe-2: inputs $inputs, outputs $outputs';
  }
  bool free(int dimension, int wanted) => dimension == -1 || dimension == wanted;
  if (image.type != OrtElementType.float32 || image.shape.length != 4 || !free(image.shape[1], 3)) {
    return 'The input $image of MoGe-2 is not a float32 image [batch, 3, height, width]';
  }
  if (tokens.type != OrtElementType.int64 || tokens.shape.isNotEmpty) {
    return 'The input $tokens of MoGe-2 is not one int64';
  }
  if (points.type != OrtElementType.float32 || points.shape.length != 4 || !free(points.shape[3], 3)) {
    return 'The output $points of MoGe-2 is not float32 [batch, height, width, 3]';
  }
  if (mask.type != OrtElementType.float32 || mask.shape.length != 3) {
    return 'The output $mask of MoGe-2 is not float32 [batch, height, width]';
  }
  if (scale.type != OrtElementType.float32 || scale.shape.length != 1) {
    return 'The output $scale of MoGe-2 is not float32 [batch]';
  }
  return null;
}

/// MoGe-2 ViT-S on ONNX Runtime
class OrtMogeGeometry implements GeometryBackend {
  OrtMogeGeometry({required this.session, required this.modelSha256, this.options, this.tokens = mogeTokens});

  /// The session of the model, opened at the first call (and checked by [mogeRefusalOf])
  final OrtSession Function() session;

  /// The options of the runs of the job, null to run without
  final OrtRunOptions? Function()? options;

  @override
  final String modelSha256;
  final int tokens;

  @override
  int get inputLongSide => SceneV1.mapLongSide;

  @override
  GeometryMaps estimate(Float32List nchw, {required int width, required int height}) {
    if (nchw.length != 3 * width * height) {
      throw ArgumentError('The input is [1, 3, $height, $width]: ${nchw.length} values');
    }
    final Map<String, OrtTensor> out;
    try {
      out = session().runNamed(
        {
          'image': OrtTensor([1, 3, height, width], nchw),
          'num_tokens': OrtTensor.int64Scalar(tokens),
        },
        outputs: const ['points', 'mask', 'scale'],
        options: options?.call(),
      );
    } on OrtRunStopped catch (error) {
      throw BackendException(ImmersiveErrorCode.cancelled, error.message);
    } on OrtException catch (error) {
      throw BackendException(ImmersiveErrorCode.modelFailed, error.message);
    }
    final points = out['points']!;
    final mask = out['mask']!;
    final scale = out['scale']!;
    if (!_same(points.shape, [1, height, width, 3]) ||
        !_same(mask.shape, [1, height, width]) ||
        scale.elementCount < 1) {
      throw BackendException(
        ImmersiveErrorCode.modelFailed,
        'MoGe-2 gave points ${points.shape}, mask ${mask.shape} and scale ${scale.shape} for an image of '
        '$width x $height',
      );
    }
    final metric = scale.values.first;
    if (!metric.isFinite || metric <= 0) {
      throw BackendException(ImmersiveErrorCode.modelFailed, 'MoGe-2 gave the metric scale $metric');
    }
    return GeometryMaps(width: width, height: height, points: points.values, mask: mask.values, metricScale: metric);
  }

  @override
  void close() {}
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
