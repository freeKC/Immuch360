// A small program that runs one generation of a 360° panorama through the runner and the launcher of the app (lot P2:
// sdcpp_runner.dart, managed_process.dart), with no Flutter: compiled by `dart compile exe` in the windows job of the
// desktop workflow (artifact Immuch360-AI-tools-windows-x64, with the fake sd-cli), it is the essay of the lot on a PC
// with a graphics card while Flutter 3.47.2 is not installed there (decision D9 of FreeKC). It prints one JSON line per
// event, with the milliseconds since its start:
//   started   the id and path of sd-cli
//   step      a step of the sampling, its pace and the time left
//   cancel    the flag raised, at --cancel-at STEP
//   ended     how the generation ended: done, or the code of its failure and its message
//   gone      whether sd-cli still runs at its id after the end (it must not)
//   upscale   with --upscale, the image wrapped by 32 columns on each side and upscaled x4, as measure M3 did
// The test of the job object is outside: kill this program (taskkill /F) while sd-cli runs, then look for sd-cli.
//
//   sdcpp_probe --sd-cli FILE --models DIR --control PNG --out DIR [--device Vulkan1] [--steps 20] [--seed 1002]
//               [--cancel-at STEP] [--upscale] [--threads N] [--prompt TEXT]
// The models are found in DIR by the names M3 used, each replaceable by --diffusion-model, --vae, --llm, --lora and
// --upscaler.

import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

final _clock = Stopwatch()..start();

void _event(String name, [Map<String, Object?> values = const {}]) =>
    stdout.writeln(jsonEncode({'event': name, 'ms': _clock.elapsedMilliseconds, ...values}));

/// The fixed prompt of the LoRA's card, as M3 ran it (the engine of P3 holds the one the app uses)
const _prompt =
    'Fill the green spaces according to the image. Outpaint as a seamless 360 equirectangular panorama (2:1). Keep '
    'the horizon level. Match left and right edges.';

/// Announces the programs it starts
class _Announcing implements ProcessRunner {
  _Announcing(this.inner);

  final ProcessRunner inner;
  final pids = <int>[];

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async {
    final process = await inner.start(launch);
    pids.add(process.pid);
    _event('started', {'pid': process.pid, 'executable': launch.executable});
    return process;
  }
}

Future<void> main(List<String> arguments) async {
  final options = <String, String>{};
  final flags = <String>{};
  for (var i = 0; i < arguments.length; i++) {
    final name = arguments[i];
    if (!name.startsWith('--')) {
      continue;
    }
    if (name == '--upscale') {
      flags.add('upscale');
    } else if (i + 1 < arguments.length) {
      options[name.substring(2)] = arguments[++i];
    }
  }
  // Absolute: sd-cli runs in the output folder
  String need(String name) => p.absolute(options[name] ?? (throw ArgumentError('--$name is missing')));
  final models = p.absolute(options['models'] ?? '.');
  String model(String option, String name) => p.absolute(options[option] ?? p.join(models, name));

  final out = Directory(need('out'))..createSync(recursive: true);
  final launcher = options['launcher'];
  final runner = _Announcing(ManagedProcessRunner.open(linuxLauncher: launcher == null ? null : p.absolute(launcher)));
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
  final steps = int.parse(options['steps'] ?? '${PanoV1.steps}');
  final cancelAt = options['cancel-at'] == null ? null : int.parse(options['cancel-at']!);
  final generated = p.join(out.path, 'generated.png');
  final cancel = NativeCancelFlag();
  final generator = SdCppGenerator(runner: runner, settings: settings, generatorSha256: '', loraSha256: '');
  final request = GeneratorRequest(
    controlPath: need('control'),
    outputPath: generated,
    workFolder: out.path,
    prompt: options['prompt'] ?? _prompt,
    seed: int.parse(options['seed'] ?? '1002'),
    steps: steps,
  );
  _event('arguments', {'arguments': generator.argumentsOf(request)});
  int? cancelledAt;
  try {
    await generator.generate(
      request,
      cancel: cancel,
      onProgress: (progress) {
        _event('step', {
          'step': progress.step,
          'steps': progress.steps,
          'secondsPerStep': progress.secondsPerStep,
          'remainingSeconds': progress.remaining?.inSeconds,
        });
        if (cancelAt != null && progress.step >= cancelAt && cancelledAt == null) {
          cancelledAt = _clock.elapsedMilliseconds;
          cancel.cancel();
          _event('cancel');
        }
      },
    );
    _event('ended', {'result': 'done', 'image': generated});
  } on BackendException catch (error) {
    _event('ended', {
      'result': error.code.name,
      'message': error.message,
      if (cancelledAt != null) 'afterCancelMs': _clock.elapsedMilliseconds - cancelledAt!,
    });
  }
  for (final pid in runner.pids) {
    _event('gone', {'pid': pid, 'gone': processImageOf(pid) == null});
  }
  if (flags.contains('upscale') && File(generated).existsSync()) {
    final image = img.decodePng(File(generated).readAsBytesSync())!;
    const pad = PanoV1.upscalePadding;
    final wrapped = img.Image(width: image.width + 2 * pad, height: image.height);
    img.compositeImage(wrapped, image, dstX: pad);
    img.compositeImage(wrapped, image, dstX: pad + image.width, srcX: 0, srcW: pad);
    img.compositeImage(wrapped, image, dstX: 0, srcX: image.width - pad, srcW: pad);
    final input = p.join(out.path, 'wrapped.png');
    File(input).writeAsBytesSync(img.encodePng(wrapped));
    final started = _clock.elapsedMilliseconds;
    try {
      await SdCppUpscaler(runner: runner, settings: settings, modelSha256: '').upscale(
        UpscaleRequest(inputPath: input, outputPath: p.join(out.path, 'upscaled.png'), workFolder: out.path),
        cancel: cancel,
      );
      _event('upscale', {'result': 'done', 'seconds': (_clock.elapsedMilliseconds - started) / 1000});
    } on BackendException catch (error) {
      _event('upscale', {'result': error.code.name, 'message': error.message});
    }
  }
  cancel.free();
}
