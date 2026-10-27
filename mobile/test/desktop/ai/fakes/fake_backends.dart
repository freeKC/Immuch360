// The seams of the engines of phases 2 and 3 without a model (lib/desktop/ai/engine/backends.dart), for the tests of
// the scene engine (S1), the panorama engine (P3) and the queue: a geometry of known planes, a filling that paints the
// holes with the mean of what is known, a generator that writes a real PNG and can fail every named way (grey image,
// green left, out of memory, silence, error), an upscale by nearest neighbour, and a scene backend that gives the
// meshes of tiny_scene3D.jpg. Each counts its calls and fails on demand.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// Pure Dart, already in the lock through maplibre_gl, as in lib/desktop/library/local_image_codec.dart
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

import 'fake_scene_engine.dart' show FakeSceneTail;

/// The points [FakeGeometryBackend] gives
enum FakeGeometryShape {
  /// A wall facing the camera at 2 m (z, up to the shift, 2 everywhere)
  wall,

  /// The left half at 1 m, the right half at 4 m: one long break down the middle
  step,

  /// A floor seen from standing: 1 m on the bottom row to 10 m on the top one
  floor,

  /// The wall, with the top quarter without depth (the sky)
  sky,
}

class FakeGeometryBackend implements GeometryBackend {
  FakeGeometryBackend({
    this.shape = FakeGeometryShape.wall,
    this.inputLongSide = SceneV1.mapLongSide,
    this.modelSha256 = '3333333333333333333333333333333333333333333333333333333333333333',
    this.focal = 1.0,
    this.metricScale = 1.0,
    this.failure,
  });

  final FakeGeometryShape shape;

  @override
  final int inputLongSide;

  @override
  final String modelSha256;

  /// The focal length the points are made with, in the units of MoGe (the half diagonal is 1)
  final double focal;
  final double metricScale;

  /// Thrown by [estimate] when set
  final BackendException? failure;
  int calls = 0;
  bool closed = false;

  @override
  GeometryMaps estimate(Float32List nchw, {required int width, required int height}) {
    calls++;
    final failed = failure;
    if (failed != null) {
      throw failed;
    }
    if (nchw.length != 3 * width * height) {
      throw BackendException(ImmersiveErrorCode.modelFailed, 'An input of ${nchw.length} values for $width x $height');
    }
    final points = Float32List(3 * width * height);
    final mask = Float32List(width * height);
    final aspect = width / height;
    final spanX = aspect / _hypot(aspect);
    final spanY = 1 / _hypot(aspect);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final u = (2 * (x + 0.5) / width - 1) * spanX;
        final v = (2 * (y + 0.5) / height - 1) * spanY;
        final z = switch (shape) {
          FakeGeometryShape.wall || FakeGeometryShape.sky => 2.0,
          FakeGeometryShape.step => x < width / 2 ? 1.0 : 4.0,
          FakeGeometryShape.floor => 10.0 - 9.0 * y / (height - 1),
        };
        final at = y * width + x;
        points[3 * at] = u * z / focal;
        points[3 * at + 1] = v * z / focal;
        points[3 * at + 2] = z;
        mask[at] = shape == FakeGeometryShape.sky && y < height / 4 ? 0 : 1;
      }
    }
    return GeometryMaps(width: width, height: height, points: points, mask: mask, metricScale: metricScale);
  }

  @override
  void close() => closed = true;
}

double _hypot(double aspect) => math.sqrt(1 + aspect * aspect);

class FakeInpaintBackend implements InpaintBackend {
  FakeInpaintBackend({
    this.regionMax = SceneV1.inpaintRegionMax,
    this.modelSha256 = '4444444444444444444444444444444444444444444444444444444444444444',
    this.failure,
  });

  @override
  final int regionMax;

  @override
  final String modelSha256;
  final BackendException? failure;

  /// Every region filled, in order
  final regions = <InpaintRegion>[];
  bool closed = false;

  @override
  Uint8List fill(InpaintRegion region) {
    regions.add(region);
    final failed = failure;
    if (failed != null) {
      throw failed;
    }
    if (region.width > regionMax || region.height > regionMax) {
      throw BackendException(ImmersiveErrorCode.modelFailed, 'A region of ${region.width} x ${region.height}');
    }
    final sums = [0, 0, 0];
    var known = 0;
    for (var i = 0; i < region.mask.length; i++) {
      if (region.mask[i] == 255) {
        known++;
        for (var c = 0; c < 3; c++) {
          sums[c] += region.rgb[3 * i + c];
        }
      }
    }
    final mean = [for (final sum in sums) known == 0 ? 0 : sum ~/ known];
    final out = Uint8List.fromList(region.rgb);
    for (var i = 0; i < region.mask.length; i++) {
      if (region.mask[i] != 255) {
        out.setRange(3 * i, 3 * i + 3, mean);
      }
    }
    return out;
  }

  @override
  void close() => closed = true;
}

/// How [FakeGeneratorBackend] ends a generation
enum FakeGeneration {
  /// A panorama: the control frame with its green painted over by a gradient
  good,

  /// A grey image (the out of memory at decoding that ended "with success", issue 1220 of stable-diffusion.cpp)
  grey,

  /// The control frame as it came: all its green left
  green,

  /// The generator runs out of memory: gpuOutOfMemory
  outOfMemory,

  /// The generator says nothing more: generatorStalled once the test lets the silence end
  silence,

  /// The generator exits with an error: generatorFailed
  error,
}

class FakeGeneratorBackend implements GeneratorBackend {
  FakeGeneratorBackend({
    this.outcome = FakeGeneration.good,
    this.generatorSha256 = '1111111111111111111111111111111111111111111111111111111111111111',
    this.loraSha256 = '2222222222222222222222222222222222222222222222222222222222222222',
    this.secondsPerStep = 12.0,
  });

  final FakeGeneration outcome;

  @override
  final String generatorSha256;

  @override
  final String loraSha256;
  final double secondsPerStep;

  /// Every request, in order
  final requests = <GeneratorRequest>[];

  /// Ends the silence of a [FakeGeneration.silence] generation, as the watchdog of 180 s would
  final _silence = Completer<void>();
  void endSilence() {
    if (!_silence.isCompleted) {
      _silence.complete();
    }
  }

  @override
  Future<void> generate(
    GeneratorRequest request, {
    required NativeCancelFlag cancel,
    void Function(GeneratorProgress progress)? onProgress,
  }) async {
    requests.add(request);
    for (var step = 1; step <= request.steps; step++) {
      await Future<void>.delayed(Duration.zero);
      if (cancel.isCancelled) {
        throw const BackendException(ImmersiveErrorCode.cancelled, 'Stopped');
      }
      if (outcome == FakeGeneration.outOfMemory && step == 2) {
        throw const BackendException(
          ImmersiveErrorCode.gpuOutOfMemory,
          'ggml_vulkan: Device memory allocation of size 1073741824 failed',
        );
      }
      if (outcome == FakeGeneration.silence && step == 2) {
        await _silence.future;
        throw const BackendException(ImmersiveErrorCode.generatorStalled, 'No line for 180 s');
      }
      onProgress?.call(GeneratorProgress(step, request.steps, secondsPerStep: secondsPerStep));
    }
    if (outcome == FakeGeneration.error) {
      throw const BackendException(ImmersiveErrorCode.generatorFailed, 'exit code 1: [ERROR] load model failed');
    }
    final control = img.decodeImage(await File(request.controlPath).readAsBytes());
    final out = img.Image(width: request.width, height: request.height);
    for (var y = 0; y < request.height; y++) {
      for (var x = 0; x < request.width; x++) {
        final pixel = control?.getPixelSafe(
          x * (control.width) ~/ request.width,
          y * (control.height) ~/ request.height,
        );
        final isGreen = pixel != null && pixel.r == 0 && pixel.g == 255 && pixel.b == 0;
        switch (outcome) {
          case FakeGeneration.grey:
            out.setPixelRgb(x, y, 128, 128, 128);
          case FakeGeneration.green:
            out.setPixelRgb(x, y, pixel?.r.toInt() ?? 0, pixel?.g.toInt() ?? 255, pixel?.b.toInt() ?? 0);
          default:
            if (isGreen || pixel == null) {
              out.setPixelRgb(x, y, (x * 255) ~/ request.width, (y * 255) ~/ request.height, 120);
            } else {
              out.setPixelRgb(x, y, pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt());
            }
        }
      }
    }
    await File(request.outputPath).writeAsBytes(img.encodePng(out), flush: true);
  }
}

class FakeUpscaleBackend implements UpscaleBackend {
  FakeUpscaleBackend({this.modelSha256 = '5555555555555555555555555555555555555555555555555555555555555555'});

  @override
  final String modelSha256;
  final requests = <UpscaleRequest>[];

  @override
  Future<void> upscale(
    UpscaleRequest request, {
    required NativeCancelFlag cancel,
    void Function(GeneratorProgress progress)? onProgress,
  }) async {
    requests.add(request);
    if (cancel.isCancelled) {
      throw const BackendException(ImmersiveErrorCode.cancelled, 'Stopped');
    }
    final input = img.decodeImage(await File(request.inputPath).readAsBytes())!;
    final out = img.copyResize(
      input,
      width: input.width * request.scale,
      height: input.height * request.scale,
      interpolation: img.Interpolation.nearest,
    );
    onProgress?.call(const GeneratorProgress(1, 1));
    await File(request.outputPath).writeAsBytes(img.encodePng(out), flush: true);
  }
}

/// A scene backend that gives the two layers of tiny_scene3D.jpg, whatever the photos
class FakeSceneBackend implements SceneBackend {
  FakeSceneBackend({this.modelSha256 = '6666666666666666666666666666666666666666666666666666666666666666'});

  @override
  final String modelSha256;
  final calls = <List<ImmersiveSource>>[];

  @override
  Future<SceneLayers> reconstruct(List<ImmersiveSource> photos, {required NativeCancelFlag cancel}) async {
    calls.add(photos);
    final scene = FakeSceneTail.fixture.xmp;
    return SceneLayers(
      meshes: [
        SceneMeshData(
          positions: Float32List.fromList([0, 0, -2, 1, 0, -2, 0, 1, -2]),
          uvs: Float32List.fromList([0, 1, 1, 1, 0, 0]),
          indices: Uint32List.fromList([0, 1, 2]),
          texture: 0,
        ),
      ],
      textures: [Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8)))],
      safe: scene.safe!,
      scale: 1.0,
      fieldOfView: scene.fieldOfView!,
      hiddenFraction: 0,
    );
  }
}
