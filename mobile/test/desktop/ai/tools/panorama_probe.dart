// A small program that makes 360° panoramas of photos through the engine of the app (lot P3: panorama_engine.dart, with
// the runner and the launcher of lot P2, MoGe-2 and MI-GAN on ONNX Runtime), with no Flutter: compiled by
// `dart compile exe` in the windows job of the desktop workflow (artifact Immuch360-AI-tools-windows-x64, beside the
// fake sd-cli and the probe of a generation), it is the essay of the lot on a PC with a graphics card while Flutter
// 3.47.2 is not installed there (decision D9 of FreeKC). The JPEG codec is the Dart one: the native codec of the app
// is built by its build hook, which this program does not run. It prints one JSON line per event, with the
// milliseconds since its start:
//   photo     the photo started, its size in bytes
//   stage     a step of the engine entered, its share of the job in thousandths
//   step      a step of the generation, its pace and the time left
//   cancel    the flag raised, at --cancel-at STEP
//   done      the panorama written: its file, size, seed, coverage, flags and the time of each step
//   failed    the code of the failure and its message
//
//   panorama_probe --sd-cli FILE --models DIR --ort LIBRARY --moge FILE --migan FILE --out DIR PHOTO...
//                  [--device Vulkan1] [--steps 20] [--seed 1002] [--threads N] [--cancel-at STEP]
// The models are found in DIR by the names M3 used, each replaceable by --diffusion-model, --vae, --llm, --lora and
// --upscaler. Each photo gives <out>/<name>_360.jpg.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/panorama/panorama_engine.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

final _clock = Stopwatch()..start();

void _event(String name, [Map<String, Object?> values = const {}]) =>
    stdout.writeln(jsonEncode({'event': name, 'ms': _clock.elapsedMilliseconds, ...values}));

Future<void> main(List<String> arguments) async {
  final options = <String, String>{};
  final photos = <String>[];
  for (var i = 0; i < arguments.length; i++) {
    final name = arguments[i];
    if (name.startsWith('--') && i + 1 < arguments.length) {
      options[name.substring(2)] = arguments[++i];
    } else {
      photos.add(name);
    }
  }
  String need(String name) => p.absolute(options[name] ?? (throw ArgumentError('--$name is missing')));
  final models = p.absolute(options['models'] ?? '.');
  String model(String option, String name) => p.absolute(options[option] ?? p.join(models, name));
  final out = Directory(need('out'))..createSync(recursive: true);

  final session = AiProcessSession();
  final runner = session.runner(linuxLauncher: options['launcher'] == null ? null : p.absolute(options['launcher']!));
  final settings = SdCppSettings(
    sdCli: need('sd-cli'),
    models: SdCppModels(
      diffusionModel: model('diffusion-model', 'flux-2-klein-base-4b-Q4_0.gguf'),
      vae: model('vae', 'flux2-klein-base-4b-vae.safetensors'),
      textEncoder: model('llm', 'Qwen3-4B-Q4_K_M.gguf'),
      lora: model('lora', 'flux-2-klein-4B-360-erp-outpaint-lora_V1.safetensors'),
      upscaler: model('upscaler', 'RealESRGAN_x4plus.pth'),
    ),
    device: options['device'] ?? 'Vulkan1',
    threads: options['threads'] == null ? null : int.parse(options['threads']!),
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
      libraryPath: need('ort'),
      miganPath: need('migan'),
      inpaintSha256: miganInpaintComponent.sha256!,
      mogePath: need('moge'),
      mogeSha256: mogeGeometryComponent.sha256!,
    ),
    folders: session.folders,
  );
  final steps = int.parse(options['steps'] ?? '${PanoV1.steps}');
  final seed = int.parse(options['seed'] ?? '1002');
  final cancelAt = options['cancel-at'] == null ? null : int.parse(options['cancel-at']!);

  for (final (index, photo) in photos.indexed) {
    final file = File(photo);
    final bytes = file.readAsBytesSync();
    final name = p.basenameWithoutExtension(photo);
    final target = p.join(out.path, '${name}_360.jpg');
    final part = '$target.part';
    _event('photo', {'photo': photo, 'bytes': bytes.length});
    final cancel = NativeCancelFlag();
    final job = PanoramaJob(
      id: 'probe-$index-$name',
      source: ImmersiveSource(
        name: p.basename(photo),
        size: bytes.length,
        sha1: base64.encode(crypto.sha1.convert(bytes).bytes),
        path: file.absolute.path,
      ),
      partPath: part,
      derivativeId: 'urn:uuid:probe-$index',
      creatorTool: 'Immuch360 panorama probe',
      created: DateTime.now().toIso8601String(),
      generator: fluxTransformerComponent.id,
      steps: steps,
      seed: seed + index,
    );
    var stage = '';
    final result = await engine.run(
      job,
      cancel: cancel,
      onProgress: (progress) {
        if (progress.stage.name != stage) {
          stage = progress.stage.name;
          _event('stage', {'stage': stage, 'perMille': progress.perMille});
        }
        if (progress.stage == ImmersiveStage.generating && progress.step != null) {
          _event('step', {
            'step': progress.step,
            'steps': progress.steps,
            'remainingSeconds': progress.remaining?.inSeconds,
          });
          if (cancelAt != null && progress.step! >= cancelAt && !cancel.isCancelled) {
            cancel.cancel();
            _event('cancel');
          }
        }
      },
    );
    cancel.free();
    final times = {
      for (final MapEntry(key: stage, value: time) in result.stageTimes.entries)
        stage.name: (time.inMilliseconds / 1000 * 10).round() / 10,
    };
    if (result.isDone) {
      File(part).renameSync(target);
      final details = result.details! as PanoramaResultDetails;
      _event('done', {
        'file': target,
        'bytes': result.bytesWritten,
        'width': details.width,
        'height': details.height,
        'seed': details.seed,
        'coverage': (details.sourceCoverage * 10000).round() / 10000,
        'flags': [for (final flag in result.qualityFlags) flag.xmp],
        'seconds': times,
        'total': (times.values.fold<double>(0, (sum, time) => sum + time) * 10).round() / 10,
      });
    } else {
      if (File(part).existsSync()) {
        File(part).deleteSync();
      }
      final message = result.message ?? '';
      _event('failed', {
        'code': result.error?.name,
        'message': message.substring(0, math.min(message.length, 2000)),
        'seconds': times,
      });
    }
  }
  await engine.dispose();
}
