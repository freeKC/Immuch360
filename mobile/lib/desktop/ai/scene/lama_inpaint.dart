// LaMa through ONNX Runtime, behind InpaintBackend: what fills the hidden bands of a scene (design-final 2026-10-27,
// section 2.3, step 9, and the decision of the measure M2: LaMa leaves no ghost of the near layer where MI-GAN does,
// at every width of band; lot S1). The model is lama_fp32.onnx of Carve/LaMa-ONNX (the catalogue's
// lamaInpaintComponent): image float32 [1, 3, 512, 512] in [0, 1] and mask float32 [1, 1, 512, 512], 1 on the holes,
// in; output float32 [1, 3, 512, 512] in [0, 255] out. It masks the holes itself and gives the known pixels back.
//
// A region is a window of the map of 512 x 512 at most; a smaller one (the map of a 3:1 panorama is 341 values high)
// is padded to 512 on its right and bottom by reflection, its mask with it, as the evaluation code of LaMa pads both
// (pad_img_to_modulo in saicinpainting/evaluation/data.py): the reflection of a hole is a hole, so that LaMa never
// takes the near layer a hole still shows for the context of its filling. M2 measured with the padding all known; the
// two differ only for a map under 512 on a side, near a hole on its edge. Only the holes of the region are taken from
// the output, rounded to the nearest level. The session and the options of the runs come as for MoGe
// (moge_geometry.dart): a stopped run is BackendException(cancelled), any other failure modelFailed.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// Why a model is not LaMa as lama_fp32.onnx is, null when it is
String? lamaRefusalOf(List<OrtTensorSpec> inputs, List<OrtTensorSpec> outputs) {
  OrtTensorSpec? named(List<OrtTensorSpec> specs, String name) => specs.where((spec) => spec.name == name).firstOrNull;
  final image = named(inputs, 'image');
  final mask = named(inputs, 'mask');
  final output = named(outputs, 'output');
  if (image == null || mask == null || output == null) {
    return 'Not LaMa: inputs $inputs, outputs $outputs';
  }
  bool fits(OrtTensorSpec spec, int channels) =>
      spec.type == OrtElementType.float32 &&
      spec.shape.length == 4 &&
      (spec.shape[1] == -1 || spec.shape[1] == channels) &&
      spec.shape.skip(2).every((side) => side == -1 || side == SceneV1.inpaintRegionMax);
  if (!fits(image, 3) || !fits(mask, 1) || !fits(output, 3)) {
    return 'LaMa takes float32 [1, 3, 512, 512] and [1, 1, 512, 512]: inputs $inputs, outputs $outputs';
  }
  return null;
}

/// The index of [i] in a line of [length] values extended by reflection (NumPy's "reflect": the edge not repeated)
int reflectIndex(int i, int length) {
  if (length == 1) {
    return 0;
  }
  final period = 2 * (length - 1);
  final folded = i % period;
  return folded < length ? folded : period - folded;
}

/// The input of LaMa for [region]: the image float32 [1, 3, 512, 512] in [0, 1] and the mask float32 [1, 1, 512, 512],
/// 1 on the holes, the region padded to 512 on its right and bottom by reflection ([reflectIndex]), its mask with it
(Float32List, Float32List) lamaInputOf(InpaintRegion region) {
  const side = SceneV1.inpaintRegionMax;
  const plane = side * side;
  final image = Float32List(3 * plane);
  final mask = Float32List(plane);
  for (var y = 0; y < side; y++) {
    final sy = reflectIndex(y, region.height);
    for (var x = 0; x < side; x++) {
      final sx = reflectIndex(x, region.width);
      final from = sy * region.width + sx;
      final at = y * side + x;
      for (var c = 0; c < 3; c++) {
        image[c * plane + at] = region.rgb[3 * from + c] / 255;
      }
      // The reflection of a hole is a hole: what it shows is the near layer, not context
      mask[at] = region.mask[from] == 0 ? 1 : 0;
    }
  }
  return (image, mask);
}

/// LaMa on ONNX Runtime
class OrtLamaInpaint implements InpaintBackend {
  OrtLamaInpaint({required this.session, required this.modelSha256, this.options});

  final OrtSession Function() session;
  final OrtRunOptions? Function()? options;

  @override
  final String modelSha256;

  @override
  int get regionMax => SceneV1.inpaintRegionMax;

  @override
  Uint8List fill(InpaintRegion region) {
    const side = SceneV1.inpaintRegionMax;
    if (region.width > side || region.height > side) {
      throw BackendException(ImmersiveErrorCode.modelFailed, 'A region of ${region.width} x ${region.height}');
    }
    const plane = side * side;
    final (image, mask) = lamaInputOf(region);
    final OrtTensor output;
    try {
      output = session().runNamed(
        {
          'image': OrtTensor(const [1, 3, side, side], image),
          'mask': OrtTensor(const [1, 1, side, side], mask),
        },
        outputs: const ['output'],
        options: options?.call(),
      )['output']!;
    } on OrtRunStopped catch (error) {
      throw BackendException(ImmersiveErrorCode.cancelled, error.message);
    } on OrtException catch (error) {
      throw BackendException(ImmersiveErrorCode.modelFailed, error.message);
    }
    if (output.elementCount != 3 * plane) {
      throw BackendException(ImmersiveErrorCode.modelFailed, 'LaMa gave an output of shape ${output.shape}');
    }
    final values = output.values;
    final out = Uint8List.fromList(region.rgb);
    for (var y = 0; y < region.height; y++) {
      for (var x = 0; x < region.width; x++) {
        final at = y * region.width + x;
        if (region.mask[at] != 0) {
          continue;
        }
        for (var c = 0; c < 3; c++) {
          final value = values[c * plane + y * side + x];
          out[3 * at + c] = value.isNaN ? 0 : math.min(255, math.max(0, (value + 0.5).floor()));
        }
      }
    }
    return out;
  }

  @override
  void close() {}
}
