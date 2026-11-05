// sd-cli of stable-diffusion.cpp on Vulkan, the generator and the upscaler of the 360° panoramas (lot P2; design-final
// 2026-10-27, sections 4.3 to 4.5; measure M3, phase23/m3-measures-2026-10-27.md, section 9), behind GeneratorBackend and
// UpscaleBackend. One child process per generation or upscale, started by a ProcessRunner (managed_process.dart in the
// app, the fake runner or the compiled fake sd-cli in the tests):
//  - its arguments are frozen: those M3 ran, every option found in sd_cli_help.txt of the pinned build (the sdcpp jobs
//    compare the build with it), the graphics card named by ggml's index (--backend diffusion=Vulkan<n>,vae=Vulkan<n>,
//    te=CPU: the integrated card comes first on a laptop, so sd-cli never chooses), flash attention on (without it the
//    attention goes to the processor and no step ends in 10 minutes), the VAE in tiles, -t the logical processors less
//    two, -v for the line about segments; and on a card with less memory free, the reference capped at 1280 x 640
//    (--ref-image-args vae_input_max_pixels=819200, measured on 4 November 2026: 4 676 MiB on the card instead of
//    5 388, see gpu_budget.dart);
//  - its progress is the bar it redraws ("12/20 - 8.65s/it"): the steps of the sampling only, not the loading of the
//    weights nor the tiles of the VAE;
//  - a generation whose graph sd-cli cuts into segments ("flux using 27 segments", when the memory it may use on the
//    card is short) goes on: at the 1536 x 768 of the app the cut gives the same bytes as one segment, slower (measure
//    of 5 November 2026, ai-gpu-budget-2026-11-05/measure.md, section 4: 294 s instead of 202 with 5.5 GiB free, about
//    8 min near the floor of 3.1 GiB; M3 saw spoilt images in segments at 1792 x 896 and 2048 x 1024 only). Each step
//    it reports then carries the number of segments (GeneratorProgress.segments), which the panel says, and the log
//    keeps it with the free memory and the budget sd-cli read on the card (the lines of its auto-fit plan);
//  - a failure is named: gpuOutOfMemory when its output says the memory was short (the texts M3 read), generatorStalled
//    after 180 s without a line, generatorFailed with the end of its error output, cancelled within a second of the
//    flag; the process is killed in every case where it still runs (the run of a program, its watch of the silence
//    and of the flag, is SidecarRun of process/sidecar_run.dart since lot SP4, shared with COLMAP and Brush);
//  - the image it wrote is checked (image_checks.dart, in an isolate of its own): its size, not grey, no pure green
//    left outside the photo; a refused image, or a file that does not decode, is deleted and outputRejected (the
//    engine of P3 makes it once more, then gives up).

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/gen/image_checks.dart';
import 'package:immich_mobile/desktop/ai/process/sidecar_run.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('SdCpp');

/// The program of the engine in its folder (`engines/<id>/` of the AI components)
String sdCliIn(String folder, {bool? windows}) =>
    p.join(folder, (windows ?? Platform.isWindows) ? 'sd-cli.exe' : 'sd-cli');

/// The files sd-cli reads: the transformer, the VAE, the text encoder, the LoRA and the upscaler
class SdCppModels {
  const SdCppModels({
    required this.diffusionModel,
    required this.vae,
    required this.textEncoder,
    required this.lora,
    required this.upscaler,
  });

  final String diffusionModel;
  final String vae;
  final String textEncoder;

  /// The LoRA file: sd-cli finds it in its folder (--lora-model-dir) by the name the prompt gives (<lora:NAME:0.9>)
  final String lora;
  final String upscaler;

  String get loraFolder => p.dirname(lora);
  String get loraName => p.basenameWithoutExtension(lora);
}

/// How sd-cli ran: the program, the models, the graphics card, the threads, and the watchdogs
class SdCppSettings {
  SdCppSettings({
    required this.sdCli,
    required this.models,
    required this.device,
    int? threads,
    this.stallTimeout = const Duration(seconds: 180),
    this.pollInterval = const Duration(milliseconds: 200),
    this.environment = const {},
  }) : threads = threads ?? math.max(1, Platform.numberOfProcessors - 2),
       assert(RegExp(r'^Vulkan\d+$').hasMatch(device), 'A Vulkan device of ggml, Vulkan0, Vulkan1...');

  final String sdCli;
  final SdCppModels models;

  /// The graphics card by ggml's name for it, "Vulkan1" (ggml lists the Vulkan devices in the order of the probe)
  final String device;

  /// -t: the logical processors less two, at least one
  final int threads;

  /// Stopped and named generatorStalled after this long without a line on either output
  final Duration stallTimeout;

  /// How often the cancel flag and the silence are looked at
  final Duration pollInterval;

  /// Added to the environment of the app for sd-cli
  final Map<String, String> environment;
}

/// The texts of a failure that means the memory of the graphics card was short (M3, section 5: the model manager of
/// sd-cli refuses before it allocates; the two others from Vulkan, by prudence, never seen in M3)
const sdCppOutOfMemoryTexts = [
  'cannot make enough memory available',
  'failed during weight preparation',
  'ErrorOutOfDeviceMemory',
  'Failed to allocate',
];

/// The most lines of the error output a failure carries in its message
const sdCppErrorTailLines = 20;

final _bar = RegExp(r'\|\s*(\d+)/(\d+)\s*-\s*([\d.]+)\s*(s/it|it/s)');
final _segments = RegExp(r'\bflux (?:using (\d+) segments|compute buffer size:.*\(peak across (\d+) segments\))');

/// A step of a bar of sd-cli: done, of how many, and the seconds of the step, or null when [line] is no such bar
GeneratorProgress? sdCppBarOf(String line) {
  final match = _bar.firstMatch(line);
  if (match == null) {
    return null;
  }
  final value = double.parse(match.group(3)!);
  final seconds = match.group(4) == 's/it' ? value : (value == 0 ? null : 1 / value);
  return GeneratorProgress(int.parse(match.group(1)!), int.parse(match.group(2)!), secondsPerStep: seconds);
}

/// The number of segments a line says the transformer's graph was cut into, null when it says nothing of it
int? sdCppSegmentsOf(String line) {
  final match = _segments.firstMatch(line);
  return match == null ? null : int.parse(match.group(1) ?? match.group(2)!);
}

const _mib = 1024 * 1024;

/// "[I]     Vulkan1      NVIDIA GeForce RTX 4060 Laptop GPU free   7188 MiB, budget   3072 MiB --- backend_fit.cpp:328",
/// a card of the auto-fit plan sd-cli writes before it loads its weights (the last "free" of the line: the name of a
/// card holds no figure in MiB)
final _plan = RegExp(r'^\[I\]\s+(Vulkan\d+)\s.*\bfree\s+(\d+) MiB, budget\s+(\d+) MiB');

/// What sd-cli read of the memory of the card [device] ("Vulkan1"), from the line of its auto-fit plan for that card:
/// the bytes free and the budget it plans with (the free memory less its reserve of 512 MiB, or the one --max-vram
/// gives); null for any other line
({int free, int budget})? sdCppCardMemoryOf(String line, String device) {
  final match = _plan.firstMatch(line);
  if (match == null || match.group(1) != device) {
    return null;
  }
  return (free: int.parse(match.group(2)!) * _mib, budget: int.parse(match.group(3)!) * _mib);
}

String _decimal(double value) => value.toString();

/// The arguments of one generation, frozen (M3, section 9, point 4)
List<String> sdCppGenerationArguments(SdCppSettings settings, GeneratorRequest request) {
  final models = settings.models;
  return [
    '--diffusion-model',
    models.diffusionModel,
    '--vae',
    models.vae,
    '--llm',
    models.textEncoder,
    '--lora-model-dir',
    models.loraFolder,
    '--backend',
    'diffusion=${settings.device},vae=${settings.device},te=CPU',
    '--flash-attn',
    'on',
    '--vae-tiling',
    '-r',
    request.controlPath,
    if (request.referenceMaxPixels case final pixels?) ...['--ref-image-args', 'vae_input_max_pixels=$pixels'],
    '-W',
    '${request.width}',
    '-H',
    '${request.height}',
    '--steps',
    '${request.steps}',
    '--cfg-scale',
    _decimal(request.guidance),
    '--sampling-method',
    'euler',
    '-s',
    '${request.seed}',
    '-p',
    '${request.prompt}<lora:${models.loraName}:${_decimal(request.loraStrength)}>',
    '-n',
    PanoV1.negativePrompt,
    '-t',
    '${settings.threads}',
    '-v',
    '-o',
    request.outputPath,
  ];
}

/// The arguments of one upscale by Real-ESRGAN x4plus on the same card
List<String> sdCppUpscaleArguments(SdCppSettings settings, UpscaleRequest request) => [
  '-M',
  'upscale',
  '-i',
  request.inputPath,
  '--upscale-model',
  settings.models.upscaler,
  '--backend',
  settings.device,
  '-t',
  '${settings.threads}',
  '-v',
  '-o',
  request.outputPath,
];

/// sd-cli to its run (process/sidecar_run.dart): its failures, the texts of a memory too short, and the end of its
/// output without its bars
const sdCppProgram = SidecarProgram(
  name: 'sd-cli',
  failed: ImmersiveErrorCode.generatorFailed,
  stalled: ImmersiveErrorCode.generatorStalled,
  outOfMemoryTexts: sdCppOutOfMemoryTexts,
  tailLines: sdCppErrorTailLines,
  inTail: _inSdCppTail,
);

bool _inSdCppTail(String line) => sdCppBarOf(line) == null && !line.contains('MB/s');

/// One run of sd-cli to its end, read as it goes
SidecarRun _sdCppRun({
  required ProcessRunner runner,
  required SdCppSettings settings,
  required List<String> arguments,
  required String workFolder,
  required NativeCancelFlag cancel,
  required Duration Function() elapsed,
  required BackendException? Function(String line) onLine,
}) => SidecarRun(
  runner: runner,
  program: sdCppProgram,
  launch: ProcessLaunch(
    executable: settings.sdCli,
    arguments: arguments,
    workingDirectory: workFolder,
    environment: settings.environment,
  ),
  cancel: cancel,
  elapsed: elapsed,
  stallTimeout: settings.stallTimeout,
  pollInterval: settings.pollInterval,
  onLine: (line, {required isError}) => onLine(line),
);

/// The generator of a panorama: klein base 4B with the 360 ERP LoRA, through sd-cli
class SdCppGenerator implements GeneratorBackend {
  SdCppGenerator({
    required this.runner,
    required this.settings,
    required this.generatorSha256,
    required this.loraSha256,
    Duration Function()? elapsed,
    this.checkImages = true,
  }) : _elapsed = elapsed ?? sidecarStopwatch();

  final ProcessRunner runner;
  final SdCppSettings settings;
  final Duration Function() _elapsed;

  /// Whether the image is checked once written (the tests of the process alone leave it out)
  final bool checkImages;

  @override
  final String generatorSha256;

  @override
  final String loraSha256;

  /// The arguments of [request], as sd-cli gets them
  List<String> argumentsOf(GeneratorRequest request) => sdCppGenerationArguments(settings, request);

  @override
  Future<void> generate(
    GeneratorRequest request, {
    required NativeCancelFlag cancel,
    void Function(GeneratorProgress progress)? onProgress,
  }) async {
    final output = File(request.outputPath);
    if (output.existsSync()) {
      output.deleteSync();
    }
    var sampling = false;
    var done = 0;
    var segments = 1;
    ({int free, int budget})? read;
    String said() => read == null
        ? 'what it read of the card unknown'
        : '${read!.free ~/ _mib} MiB free read on ${settings.device}, budget ${read!.budget ~/ _mib} MiB';
    await _sdCppRun(
      runner: runner,
      settings: settings,
      arguments: argumentsOf(request),
      workFolder: request.workFolder,
      cancel: cancel,
      elapsed: _elapsed,
      onLine: (line) {
        final plan = sdCppCardMemoryOf(line, settings.device);
        if (plan != null) {
          read = plan;
          _log.info(
            'sd-cli read ${plan.free ~/ _mib} MiB free on ${settings.device}, budget ${plan.budget ~/ _mib} MiB',
          );
          return null;
        }
        // The graph cut into segments: the run goes on, slower, the same image (see the top of this file)
        final cut = sdCppSegmentsOf(line);
        if (cut != null) {
          if (cut != segments) {
            segments = cut;
            _log.info('sd-cli runs the generator in $cut segments (${said()}): slower, the same image');
          }
          return null;
        }
        if (line.contains('generating image')) {
          sampling = true;
          return null;
        }
        final bar = sampling && done < request.steps ? sdCppBarOf(line) : null;
        if (bar != null && bar.steps == request.steps && bar.step > done) {
          done = bar.step;
          onProgress?.call(
            GeneratorProgress(
              bar.step,
              bar.steps,
              secondsPerStep: bar.secondsPerStep,
              segments: segments > 1 ? segments : null,
            ),
          );
        }
        return null;
      },
    ).run();
    if (!output.existsSync()) {
      throw const BackendException(ImmersiveErrorCode.generatorFailed, 'sd-cli ended without writing its image');
    }
    if (!checkImages) {
      return;
    }
    final GeneratedImageReport report;
    try {
      report = await checkGeneratedFileInIsolate(request.outputPath, controlPath: request.controlPath);
    } catch (error) {
      // No image, or one the decoder gives up on (a PNG cut short): refused as any other, never left behind
      if (output.existsSync()) {
        output.deleteSync();
      }
      final why = error is FormatException ? error.message : '$error';
      throw BackendException(ImmersiveErrorCode.outputRejected, 'sd-cli wrote no readable image: $why');
    }
    final problem = report.problemFor(request.width, request.height);
    if (problem != null) {
      output.deleteSync();
      throw BackendException(ImmersiveErrorCode.outputRejected, 'The generated image was refused: $problem');
    }
  }
}

/// [checkGeneratedFile] in an isolate of its own, from a closure built apart from the generation so that it holds the
/// two paths only: one built inside [SdCppGenerator.generate] would carry the context of its progress callback, which
/// reaches the queue, its settings store and their futures, which no isolate can take (found by V3 on the PC: every
/// panorama of the app was refused so)
Future<GeneratedImageReport> checkGeneratedFileInIsolate(String path, {String? controlPath}) =>
    Isolate.run(() => checkGeneratedFile(path, controlPath: controlPath));

/// The upscale of a panorama: Real-ESRGAN x4plus through sd-cli
class SdCppUpscaler implements UpscaleBackend {
  SdCppUpscaler({required this.runner, required this.settings, required this.modelSha256, Duration Function()? elapsed})
    : _elapsed = elapsed ?? sidecarStopwatch();

  final ProcessRunner runner;
  final SdCppSettings settings;
  final Duration Function() _elapsed;

  @override
  final String modelSha256;

  List<String> argumentsOf(UpscaleRequest request) => sdCppUpscaleArguments(settings, request);

  @override
  Future<void> upscale(
    UpscaleRequest request, {
    required NativeCancelFlag cancel,
    void Function(GeneratorProgress progress)? onProgress,
  }) async {
    final input = pngFileSize(request.inputPath);
    if (input == null) {
      throw BackendException(ImmersiveErrorCode.generatorFailed, 'No PNG to upscale at ${request.inputPath}');
    }
    final output = File(request.outputPath);
    if (output.existsSync()) {
      output.deleteSync();
    }
    var tiling = false;
    var done = 0;
    await _sdCppRun(
      runner: runner,
      settings: settings,
      arguments: argumentsOf(request),
      workFolder: request.workFolder,
      cancel: cancel,
      elapsed: _elapsed,
      onLine: (line) {
        if (line.contains('upscaling from')) {
          tiling = true;
          return null;
        }
        final bar = tiling ? sdCppBarOf(line) : null;
        if (bar != null && bar.step > done) {
          done = bar.step;
          onProgress?.call(bar);
        }
        return null;
      },
    ).run();
    final size = pngFileSize(request.outputPath);
    final expected = (input.$1 * request.scale, input.$2 * request.scale);
    if (size != expected) {
      if (output.existsSync()) {
        output.deleteSync();
      }
      throw BackendException(
        ImmersiveErrorCode.outputRejected,
        size == null
            ? 'sd-cli ended without writing the upscaled image'
            : 'The upscaled image is ${size.$1} x ${size.$2}, not ${expected.$1} x ${expected.$2}',
      );
    }
  }
}
