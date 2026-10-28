// The MI-GAN pipeline through ONNX Runtime, behind InpaintBackend (design-final 2026-10-27, sections 2.3 and 4.3;
// lot S1). The measure M2 gave the bands of a scene to LaMa (lama_inpaint.dart): MI-GAN leaves blurred ghosts of the
// near layer there. It stays for the seam of a generated panorama (lot P3), which takes it from here. The model is
// migan_pipeline_v2.onnx (the catalogue's miganInpaintComponent): image uint8 [1, 3, height, width] and mask uint8
// [1, 1, height, width], 255 where the pixel is known, 0 on a hole, in; result uint8 [1, 3, height, width] out. The
// pipeline crops around the mask, brings it to 512 and pastes it back.
//
// M2 saw the pixels under a hole leak into the first three pixels of its fill (the pipeline blends with a dilated,
// blurred mask): for the bands of a scene every hole is painted first with the mean colour of the known pixels, so that
// nothing of what the hole hides comes through. The seam of a panorama hides nothing but the seam: its holes keep their
// pixels (paintHoles false), so that the blend at the edge of the band meets the panorama around it rather than a line
// of that mean colour (lot P3). Only the holes are taken from the result.

import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// Why a model is not the MI-GAN pipeline, null when it is
String? miganRefusalOf(List<OrtTensorSpec> inputs, List<OrtTensorSpec> outputs) {
  OrtTensorSpec? named(List<OrtTensorSpec> specs, String name) => specs.where((spec) => spec.name == name).firstOrNull;
  final image = named(inputs, 'image');
  final mask = named(inputs, 'mask');
  final result = named(outputs, 'result');
  bool bytes(OrtTensorSpec? spec) => spec != null && spec.type == OrtElementType.uint8 && spec.shape.length == 4;
  if (!bytes(image) || !bytes(mask) || !bytes(result)) {
    return 'Not the MI-GAN pipeline (image and mask uint8 in, result uint8 out): inputs $inputs, outputs $outputs';
  }
  return null;
}

/// The image and the mask MI-GAN takes for [region]: the image as planes of one colour (all red, then green, then
/// blue), the mask 255 where the pixel is known and 0 on a hole; the holes painted with the mean colour of the known
/// pixels when [paintHoles], their own pixels otherwise (see the top of this file)
(Uint8List, Uint8List) miganInputsOf(InpaintRegion region, {bool paintHoles = true}) {
  final plane = region.width * region.height;
  final sums = [0, 0, 0];
  var known = 0;
  for (var i = 0; i < plane; i++) {
    if (region.mask[i] != 0) {
      known++;
      for (var c = 0; c < 3; c++) {
        sums[c] += region.rgb[3 * i + c];
      }
    }
  }
  final mean = [for (final sum in sums) known == 0 ? 128 : (sum + known ~/ 2) ~/ known];
  final image = Uint8List(3 * plane);
  final mask = Uint8List(plane);
  for (var i = 0; i < plane; i++) {
    final hole = region.mask[i] == 0;
    mask[i] = hole ? 0 : 255;
    for (var c = 0; c < 3; c++) {
      image[c * plane + i] = hole && paintHoles ? mean[c] : region.rgb[3 * i + c];
    }
  }
  return (image, mask);
}

/// The MI-GAN pipeline on ONNX Runtime
class OrtMiganInpaint implements InpaintBackend {
  OrtMiganInpaint({required this.session, required this.modelSha256, this.options, this.paintHoles = true});

  final OrtSession Function() session;
  final OrtRunOptions? Function()? options;

  /// Whether the holes are painted with the mean colour of the known pixels before the run: true for the bands of a
  /// scene, false for the seam of a panorama
  final bool paintHoles;

  @override
  final String modelSha256;

  @override
  int get regionMax => SceneV1.inpaintRegionMax;

  @override
  Uint8List fill(InpaintRegion region) {
    final width = region.width;
    final height = region.height;
    final plane = width * height;
    final (image, mask) = miganInputsOf(region, paintHoles: paintHoles);
    final OrtTensor result;
    try {
      result = session().runNamed(
        {
          'image': OrtTensor.uint8([1, 3, height, width], image),
          'mask': OrtTensor.uint8([1, 1, height, width], mask),
        },
        outputs: const ['result'],
        options: options?.call(),
      )['result']!;
    } on OrtRunStopped catch (error) {
      throw BackendException(ImmersiveErrorCode.cancelled, error.message);
    } on OrtException catch (error) {
      throw BackendException(ImmersiveErrorCode.modelFailed, error.message);
    }
    if (result.elementCount != 3 * plane || result.type != OrtElementType.uint8) {
      throw BackendException(ImmersiveErrorCode.modelFailed, 'MI-GAN gave a result of shape ${result.shape}');
    }
    final values = result.bytes;
    final out = Uint8List.fromList(region.rgb);
    for (var i = 0; i < plane; i++) {
      if (region.mask[i] == 0) {
        for (var c = 0; c < 3; c++) {
          out[3 * i + c] = values[c * plane + i];
        }
      }
    }
    return out;
  }

  @override
  void close() {}
}
