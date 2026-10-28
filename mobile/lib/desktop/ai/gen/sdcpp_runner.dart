// sd-cli of stable-diffusion.cpp on Vulkan, the generator and the upscaler of the 360° panoramas (lot P2; design-final
// 2026-10-27, sections 4.3 to 4.5; measure M3, phase23/m3-measures-2026-10-27.md, section 9), behind GeneratorBackend and
// UpscaleBackend. One child process per generation or upscale, started by a ProcessRunner (managed_process.dart in the
// app, the fake runner or the compiled fake sd-cli in the tests):
//  - its arguments are frozen: those M3 ran, every option found in sd_cli_help.txt of the pinned build (the sdcpp jobs
//    compare the build with it), the graphics card named by ggml's index (--backend diffusion=Vulkan<n>,vae=Vulkan<n>,
//    te=CPU: the integrated card comes first on a laptop, so sd-cli never chooses), flash attention on (without it the
//    attention goes to the processor and no step ends in 10 minutes), the VAE in tiles, -t the logical processors less
//    two, -v for the line about segments;
//  - its progress is the bar it redraws ("12/20 - 8.65s/it"): the steps of the sampling only, not the loading of the
//    weights nor the tiles of the VAE;
//  - a generation whose graph sd-cli cut into segments ("flux using 27 segments", when the free memory of the card is
//    short) is stopped at once and refused as gpuBusy ("Other apps use the graphics card memory: close games or 3D
//    apps"): with the LoRA applied at run time and the guidance, the image comes out spoilt (M3, section 2, point 2),
//    so it never becomes a file;
//  - a failure is named: gpuOutOfMemory when its output says the memory was short (the texts M3 read), generatorStalled
//    after 180 s without a line, generatorFailed with the end of its error output, cancelled within a second of the
//    flag; the process is killed in every case where it still runs;
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
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

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

/// One run of sd-cli to its end, read as it goes
class _SdCppRun {
  _SdCppRun({
    required this.runner,
    required this.settings,
    required this.arguments,
    required this.workFolder,
    required this.cancel,
    required this.elapsed,
    required this.onLine,
  });

  final ProcessRunner runner;
  final SdCppSettings settings;
  final List<String> arguments;
  final String workFolder;
  final NativeCancelFlag cancel;
  final Duration Function() elapsed;

  /// Each line of either output; returns a failure to stop the run with, or null to go on
  final BackendException? Function(String line) onLine;

  final _errorTail = <String>[];
  final _outputTail = <String>[];
  var _outOfMemory = false;
  BackendException? _stop;

  /// The end of the error output, or of the output when the error output said nothing
  String get tail => (_errorTail.isNotEmpty ? _errorTail : _outputTail).join('\n');

  void _remember(List<String> tail, String line) {
    if (line.trim().isEmpty || sdCppBarOf(line) != null || line.contains('MB/s')) {
      return;
    }
    tail.add(line);
    if (tail.length > sdCppErrorTailLines) {
      tail.removeAt(0);
    }
  }

  Future<void> run() async {
    if (cancel.isCancelled) {
      throw const BackendException(ImmersiveErrorCode.cancelled, 'Cancelled before sd-cli started');
    }
    final RunningProcess process;
    try {
      process = await runner.start(
        ProcessLaunch(
          executable: settings.sdCli,
          arguments: arguments,
          workingDirectory: workFolder,
          environment: settings.environment,
        ),
      );
    } on ProcessException catch (error) {
      throw BackendException(ImmersiveErrorCode.generatorFailed, 'sd-cli could not start: ${error.message}');
    }
    var lastLine = elapsed();
    void stop(BackendException reason) {
      if (_stop == null) {
        _stop = reason;
        process.kill();
      }
    }

    void read(String line, {required bool isError}) {
      // Once stopped, what was still in the pipes says nothing more: no progress after a refusal
      if (_stop != null) {
        return;
      }
      lastLine = elapsed();
      _remember(isError ? _errorTail : _outputTail, line);
      if (sdCppOutOfMemoryTexts.any(line.contains)) {
        _outOfMemory = true;
      }
      final failure = onLine(line);
      if (failure != null) {
        stop(failure);
      }
    }

    final outputs = [
      process.stdoutLines.listen((line) => read(line, isError: false)).asFuture<void>(),
      process.stderrLines.listen((line) => read(line, isError: true)).asFuture<void>(),
    ];
    final watch = Timer.periodic(settings.pollInterval, (_) {
      if (cancel.isCancelled) {
        stop(const BackendException(ImmersiveErrorCode.cancelled, 'Cancelled'));
      } else if (elapsed() - lastLine > settings.stallTimeout) {
        stop(
          BackendException(
            ImmersiveErrorCode.generatorStalled,
            'sd-cli wrote nothing for ${settings.stallTimeout.inSeconds} s and was stopped',
          ),
        );
      }
    });
    final int code;
    try {
      code = await process.exitCode;
      await Future.wait(outputs).timeout(const Duration(seconds: 5), onTimeout: () => const []);
    } finally {
      watch.cancel();
    }
    final stopped = _stop;
    if (stopped != null) {
      throw stopped;
    }
    if (code != 0) {
      throw _outOfMemory
          ? BackendException(ImmersiveErrorCode.gpuOutOfMemory, tail)
          : BackendException(ImmersiveErrorCode.generatorFailed, 'sd-cli ended with $code: $tail');
    }
  }
}

Duration Function() _stopwatch() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}

/// The generator of a panorama: klein base 4B with the 360 ERP LoRA, through sd-cli
class SdCppGenerator implements GeneratorBackend {
  SdCppGenerator({
    required this.runner,
    required this.settings,
    required this.generatorSha256,
    required this.loraSha256,
    Duration Function()? elapsed,
    this.checkImages = true,
  }) : _elapsed = elapsed ?? _stopwatch();

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
    await _SdCppRun(
      runner: runner,
      settings: settings,
      arguments: argumentsOf(request),
      workFolder: request.workFolder,
      cancel: cancel,
      elapsed: _elapsed,
      onLine: (line) {
        final segments = sdCppSegmentsOf(line);
        if (segments != null && segments > 1) {
          return BackendException(
            ImmersiveErrorCode.gpuBusy,
            'sd-cli cut the generator into $segments segments, the memory of the graphics card being short: the image '
            'would be spoilt (close games or 3D apps and retry)',
          );
        }
        if (line.contains('generating image')) {
          sampling = true;
          return null;
        }
        final bar = sampling && done < request.steps ? sdCppBarOf(line) : null;
        if (bar != null && bar.steps == request.steps && bar.step > done) {
          done = bar.step;
          onProgress?.call(bar);
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
    final path = request.outputPath;
    final control = request.controlPath;
    final GeneratedImageReport report;
    try {
      report = await Isolate.run(() => checkGeneratedFile(path, controlPath: control));
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

/// The upscale of a panorama: Real-ESRGAN x4plus through sd-cli
class SdCppUpscaler implements UpscaleBackend {
  SdCppUpscaler({required this.runner, required this.settings, required this.modelSha256, Duration Function()? elapsed})
    : _elapsed = elapsed ?? _stopwatch();

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
    await _SdCppRun(
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
