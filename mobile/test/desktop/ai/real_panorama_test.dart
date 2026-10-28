// The engine of the 360° panoramas on the real models, a real graphics card and real photos (lot P3, design-final
// 2026-10-27, section 10.2), by hand only, never in the CI, which has neither the models nor a card: sd-cli of our
// archive, FLUX.2 klein base 4B Q4_0, Qwen3, the VAE, the LoRA of nomadoor and Real-ESRGAN in IMMUCH360_PANO_MODELS
// (the names M3 used), MoGe-2 and MI-GAN on ONNX Runtime, the engine of the app on every photo of IMMUCH360_AI_PHOTOS.
// Each panorama is read back: 6144 x 3072, our XMP with GPano, Origin GeneratedContent and the IPTC, the region and the
// coverage; the originals are compared byte for byte after the run. The panoramas and a summary with the time of each
// step go to IMMUCH360_AI_WORK, to be looked at in the headset and compared with the measure M3.
//
//   IMMUCH360_SD_CLI        sd-cli (sd-cli.exe) of the archive of the engine
//   IMMUCH360_SD_DEVICE     the card by ggml's name for it, Vulkan1 on the laptop of the owner (Vulkan0 by default)
//   IMMUCH360_PANO_MODELS   the folder of the transformer, the VAE, the text encoder, the LoRA and the upscaler
//   IMMUCH360_ORT_LIB       the library of ONNX Runtime
//   IMMUCH360_AI_MOGE       moge_2_vits_normal_immuch360.onnx, checked by its SHA-256 against the catalogue
//   IMMUCH360_AI_MIGAN      migan_pipeline_v2.onnx, the same
//   IMMUCH360_AI_PHOTOS     a folder of JPEG photos
//   IMMUCH360_AI_WORK       a folder for the panoramas and the summary
//
// On this PC, without Flutter 3.47.2 (decision D9), the same chain runs through test/desktop/ai/tools/panorama_probe.dart
// compiled by the CI.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/panorama/panorama_engine.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final environment = Platform.environment;
  final sdCli = environment['IMMUCH360_SD_CLI'];
  final models = environment['IMMUCH360_PANO_MODELS'];
  final library = environment['IMMUCH360_ORT_LIB'];
  final moge = environment['IMMUCH360_AI_MOGE'];
  final migan = environment['IMMUCH360_AI_MIGAN'];
  final photos = environment['IMMUCH360_AI_PHOTOS'];
  final work = environment['IMMUCH360_AI_WORK'];
  final missing = [
    if (sdCli == null) 'IMMUCH360_SD_CLI',
    if (models == null) 'IMMUCH360_PANO_MODELS',
    if (library == null) 'IMMUCH360_ORT_LIB',
    if (moge == null) 'IMMUCH360_AI_MOGE',
    if (migan == null) 'IMMUCH360_AI_MIGAN',
    if (photos == null) 'IMMUCH360_AI_PHOTOS',
    if (work == null) 'IMMUCH360_AI_WORK',
  ];
  final skip = missing.isEmpty ? null : 'by hand: set ${missing.join(', ')}';

  test(
    'a panorama of every photo, read back, its originals untouched',
    () async {
      for (final (path, component) in [(moge!, mogeGeometryComponent), (migan!, miganInpaintComponent)]) {
        final sum = sha256.convert(File(path).readAsBytesSync()).toString();
        expect(sum, component.sha256, reason: '$path is not ${component.id}');
      }
      final out = Directory(p.join(work!, 'panoramas'))..createSync(recursive: true);
      final originals =
          Directory(photos!)
              .listSync()
              .whereType<File>()
              .where((file) => const {'.jpg', '.jpeg'}.contains(p.extension(file.path).toLowerCase()))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      expect(originals, isNotEmpty);
      final before = {for (final file in originals) file.path: sha256.convert(file.readAsBytesSync()).toString()};

      final session = AiProcessSession();
      final runner = session.runner(
        linuxLauncher: Platform.isLinux ? p.join(p.dirname(sdCli!), linuxLauncherName) : null,
      );
      final settings = SdCppSettings(
        sdCli: sdCli!,
        models: SdCppModels(
          diffusionModel: p.join(models!, 'flux-2-klein-base-4b-Q4_0.gguf'),
          vae: p.join(models, 'flux2-klein-base-4b-vae.safetensors'),
          textEncoder: p.join(models, 'Qwen3-4B-Q4_K_M.gguf'),
          lora: p.join(models, 'flux-2-klein-4B-360-erp-outpaint-lora_V1.safetensors'),
          upscaler: p.join(models, 'RealESRGAN_x4plus.pth'),
        ),
        device: environment['IMMUCH360_SD_DEVICE'] ?? 'Vulkan0',
      );
      final engine = PanoramaEngine(
        generator: SdCppGenerator(
          runner: runner,
          settings: settings,
          generatorSha256: fluxTransformerComponent.sha256!,
          loraSha256: panoramaLoraComponent.sha256!,
        ),
        upscaler: SdCppUpscaler(runner: runner, settings: settings, modelSha256: upscalerComponent.sha256!),
        models: OrtPanoramaModelsSpec(
          libraryPath: library!,
          miganPath: migan,
          inpaintSha256: miganInpaintComponent.sha256!,
          mogePath: moge,
          mogeSha256: mogeGeometryComponent.sha256!,
        ),
        folders: session.folders,
      );
      addTearDown(engine.dispose);

      final summary = <Map<String, Object?>>[];
      for (final (index, original) in originals.indexed) {
        final bytes = original.readAsBytesSync();
        final name = p.basenameWithoutExtension(original.path);
        final target = p.join(out.path, '${name}_360.jpg');
        final cancel = NativeCancelFlag();
        final result = await engine.run(
          PanoramaJob(
            id: 'real-$name',
            source: ImmersiveSource(
              name: p.basename(original.path),
              size: bytes.length,
              sha1: base64.encode(sha1.convert(bytes).bytes),
              path: original.path,
            ),
            partPath: '$target.part',
            derivativeId: 'urn:uuid:real-$index',
            creatorTool: 'Immuch360 Desktop (real panorama test)',
            created: DateTime.now().toIso8601String(),
            generator: fluxTransformerComponent.id,
            steps: PanoV1.steps,
            seed: 1001 + index,
          ),
          cancel: cancel,
        );
        cancel.free();
        expect(result.isDone, isTrue, reason: '$name: ${result.error} ${result.message}');
        File('$target.part').renameSync(target);
        final written = File(target).readAsBytesSync();
        final xmp = ImmersiveXmp.findIn(written)! as PanoramaXmp;
        expect((xmp.width, xmp.height), (PanoV1.outputWidth, PanoV1.outputHeight));
        expect(xmp.origin, ImmersiveOrigin.generatedContent);
        expect(xmp.digitalSourceType, iptcCompositeWithTrainedAlgorithmicMedia);
        final decoded = const DartSbsCodec().decodeJpeg(written);
        expect((decoded.width, decoded.height), (PanoV1.outputWidth, PanoV1.outputHeight));
        summary.add({
          'photo': p.basename(original.path),
          'panorama': p.basename(target),
          'hfov': xmp.region?.hfov,
          'coverage': xmp.sourceCoverage,
          'seed': xmp.seed,
          'flags': [for (final flag in result.qualityFlags) flag.xmp],
          'seconds': {
            for (final MapEntry(key: stage, value: time) in result.stageTimes.entries)
              stage.name: time.inMilliseconds / 1000,
          },
        });
      }
      File(p.join(work, 'summary.json')).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(summary));
      for (final file in originals) {
        expect(sha256.convert(file.readAsBytesSync()).toString(), before[file.path], reason: 'original untouched');
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(hours: 2)),
  );
}
