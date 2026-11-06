// A fake sd-cli, compiled into a real program by `dart compile exe` (the test and windows jobs of the desktop workflow,
// or by hand) and given to the tests by IMMUCH360_FAKE_SD_CLI, so that the runner of lot P2 (sdcpp_runner.dart) and the
// launcher (managed_process.dart) are tested against a real child process, with no model and no graphics card. Its lines
// are those of the real sd-cli as M3 read them (phase23/m3-measures-2026-10-27.md): the bars it redraws with \r and
// ends with an escape, its verbose lines, the texts of a memory too short. It takes the arguments of a generation
// (-o, -W, -H, --steps, -s) or of an upscale (-M upscale, -i, -o), and IMMUCH360_FAKE_SD_CLI_MODE says what it does:
//   ok        the steps, then a PNG of the size asked, varied (the default)
//   grey      the steps, then a uniform grey PNG
//   green     the steps, then a PNG still pure green over most of it
//   segments  "flux using 27 segments" before the steps, as when the memory of the card is short, then as ok (the
//             graph cut gives the same image, slower: measure of 5 November 2026)
//   recover   as segments, with the model manager's line of a shortfall sd-cli recovers from at each of the first
//             steps (run F_full_2700 of the measure: four such lines, then its image)
//   oom       the texts of the model manager of sd-cli when the memory is short, then exit 1
//   fail      an error on the error output, then exit 1
//   silent    the lines up to the sampling, then nothing until killed
//   slow      as ok with steps of half a second (IMMUCH360_FAKE_SD_CLI_STEP_MS sets the step otherwise, 5 ms)
// Before it loads its weights it writes the auto-fit plan of its one card, Vulkan0, as the pinned build does: the free
// memory IMMUCH360_FAKE_SD_CLI_FREE_MIB says (7188 by default, the RTX 4060 Laptop of the measure) and the budget as
// the pinned build makes it (backend_fit.cpp 152-157): a positive --max-vram in GiB capped at that free memory, with no
// reserve; a negative one less than that free memory; without it (or 0), the free memory less the reserve of 512 MiB.
// It writes its process id to the file IMMUCH360_FAKE_SD_CLI_PID names, when it does.
//
//   fake_sd_cli host PIDFILE
// starts this same program in the silent mode through ManagedProcessRunner (on Linux through the launcher
// IMMUCH360_RUN_LAUNCHER names), writes the id of that child to PIDFILE, and waits to be killed: the test kills the host
// and the child must go with it (the job object on Windows, PR_SET_PDEATHSIG on Linux).
//
// Pure Dart, with no Flutter: compiled outside of any test.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty && arguments.first == 'host') {
    await _host(arguments[1]);
    return;
  }
  final pidFile = Platform.environment['IMMUCH360_FAKE_SD_CLI_PID'];
  if (pidFile != null && pidFile.isNotEmpty) {
    File(pidFile).writeAsStringSync('$pid');
  }
  String? option(List<String> names) {
    for (var i = 0; i < arguments.length - 1; i++) {
      if (names.contains(arguments[i])) {
        return arguments[i + 1];
      }
    }
    return null;
  }

  final mode = Platform.environment['IMMUCH360_FAKE_SD_CLI_MODE'] ?? 'ok';
  final stepMs =
      int.tryParse(Platform.environment['IMMUCH360_FAKE_SD_CLI_STEP_MS'] ?? '') ?? (mode == 'slow' ? 500 : 5);
  final output = option(['-o', '--output']) ?? 'output.png';
  _out('[V] version: stable-diffusion.cpp version unknown, commit be48649 --- main.cpp:694');
  _out('ggml_vulkan: Found 1 Vulkan devices:');
  _out('ggml_vulkan: 0 = Fake graphics card (Immuch360) | uma: 0 | fp16: 1 | bf16: 1 | warp size: 32');
  if (option(['-M', '--mode']) == 'upscale') {
    await _upscale(option(['-i', '--init-img'])!, output, stepMs);
    return;
  }
  final width = int.parse(option(['-W', '--width']) ?? '512');
  final height = int.parse(option(['-H', '--height']) ?? '512');
  final steps = int.parse(option(['--steps']) ?? '20');
  final seed = option(['-s', '--seed']) ?? '42';
  _out(
    "[I] loading diffusion model from '${option(['--diffusion-model']) ?? 'model.gguf'}' --- diffusion_engine.cpp:692",
  );
  final free = int.tryParse(Platform.environment['IMMUCH360_FAKE_SD_CLI_FREE_MIB'] ?? '') ?? 7188;
  final maxVram = double.tryParse(option(['--max-vram']) ?? '') ?? 0;
  final budget = switch (maxVram) {
    > 0 => math.min((maxVram * 1024).floor(), free),
    < 0 => math.max(0, free + (maxVram * 1024).ceil()),
    _ => math.max(0, free - 512),
  };
  _out('[I] auto-fit plan: --- backend_fit.cpp:323');
  _out('[I]   devices: --- backend_fit.cpp:324');
  _out(
    '[I]     Vulkan0      Fake graphics card free ${'$free'.padLeft(6)} MiB, budget ${'$budget'.padLeft(6)} MiB '
    '--- backend_fit.cpp:328',
  );
  _out('[I]     RAM          free   4737 MiB, params budget   2689 MiB --- backend_fit.cpp:334');
  await _bar(149, '#', (i) => '${(150 + i).toStringAsFixed(2)}MB/s', 0);
  _out('[I] generate_image ${width}x$height --- image.cpp:869');
  await _bar(40, '=', (i) => '30.30it/s', 0);
  _out('[I] get_learned_condition completed, taking 12.14s --- image.cpp:580');
  _out('[I] generating image: 1/1 - seed $seed --- image.cpp:920');
  if (mode == 'oom') {
    _out(
      '[W] [E] model manager memory on Vulkan0: reported free 2892.77 MB / total 7956.00 MB, tracked weights 4261.84 MB'
      ' / other runtime 0.00 MB / current runtime 0.00 MB --- model_manager.cpp:1788',
    );
    _out(
      '[W] model manager cannot make enough memory available on Vulkan0: need 4109.22 MB device / 3597.22 MB budget, '
      'available 2892.77 MB device / unlimited budget --- model_manager.cpp:2018',
    );
    _out('flux segment 1/1 (graph) failed during weight preparation --- ggml_runner.cpp:899');
    _error('[E] diffusion model compute failed --- diffusion_engine.cpp:2655');
    _error('[E] Diffusion model sampling failed --- diffusion_engine.cpp:2888');
    _error('[E] sampling for image 1/1 failed after 2.35s --- image.cpp:961');
    _error('[E] generate failed --- main.cpp:926');
    await _flush();
    exit(1);
  }
  if (mode == 'fail') {
    _error('[E] load the control image failed --- main.cpp:610');
    await _flush();
    exit(1);
  }
  if (mode == 'segments' || mode == 'recover') {
    _out('[V] flux compute buffer size: 3928.82 MB(VRAM) on Vulkan0 (peak across 1 segment) --- ggml_runner.cpp:1022');
    _out('[V] flux using 27 segments --- ggml_runner.cpp:879');
    _out(
      '[V] flux compute buffer size: 2687.96 MB(VRAM) on Vulkan0 (peak across 27 segments) --- ggml_runner.cpp:1022',
    );
  } else {
    _out('[V] flux compute buffer size: 2607.97 MB(VRAM) on Vulkan0 (peak across 1 segment) --- ggml_runner.cpp:1022');
  }
  if (mode == 'silent') {
    await stdout.flush();
    await Future<void>.delayed(const Duration(hours: 1));
    return;
  }
  await _bar(
    steps,
    '=',
    (i) => '${(8.5 + i / 100).toStringAsFixed(2)}s/it',
    stepMs,
    eta: true,
    before: mode == 'recover'
        ? (step) {
            if (step <= 4) {
              stdout.write('\n');
              _out(
                '[W] model manager cannot make enough memory available on Vulkan0: need 687.21 MB device / 2560.04 MB '
                'budget, available 4290.52 MB device / 2511.54 MB budget --- model_manager.cpp:2018',
              );
            }
          }
        : null,
  );
  await _bar(55, '=', (i) => '16.95it/s', 0);
  _writePng(output, width, height, mode);
  _out('[I] generate_image completed in 198.39s --- image.cpp:1140');
  _out("[I] save result image 0 to '$output' (success) --- main.cpp:495");
  await stdout.flush();
}

void _out(String line) => stdout.write('$line\n');

void _error(String line) => stderr.write('$line\n');

Future<void> _flush() => Future.wait([stdout.flush(), stderr.flush()]);

/// A bar as sd-cli draws it: each step after \r, the end of the line erased, a line end after the last step; [before]
/// writes the lines of a step before its bar
Future<void> _bar(
  int total,
  String fill,
  String Function(int step) speed,
  int stepMs, {
  bool eta = false,
  void Function(int step)? before,
}) async {
  for (var step = 1; step <= total; step++) {
    if (stepMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: stepMs));
    }
    before?.call(step);
    final filled = 50 * step ~/ total;
    final bar = fill * filled + (filled < 50 ? '>' : '') + ' ' * (49 - filled).clamp(0, 50);
    final left = eta && step < total ? ' - ETA 00:${(total - step).toString().padLeft(2, '0')}' : '';
    stdout.write('\r  |$bar| ${'$step'.padLeft('$total'.length)}/$total - ${speed(step).padLeft(10)}$left\x1B[K');
    if (step == total) {
      stdout.write('\n');
    }
    await stdout.flush();
  }
}

void _writePng(String path, int width, int height, String mode) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      switch (mode) {
        case 'grey':
          image.setPixelRgb(x, y, 128, 128, 128);
        case 'green' when x > width ~/ 4:
          image.setPixelRgb(x, y, 0, 255, 0);
        default:
          // Varied, and never the pure green of the control frame: blue stays above 60
          image.setPixelRgb(x, y, (x * 255) ~/ width, (y * 255) ~/ height, 100 + (((x ^ y) * 7) & 0x7F));
      }
    }
  }
  File(path).writeAsBytesSync(img.encodePng(image));
}

Future<void> _upscale(String input, String output, int stepMs) async {
  final header = File(input).openSync();
  final bytes = header.readSync(24);
  header.closeSync();
  final view = ByteData.sublistView(bytes);
  final width = view.getUint32(16);
  final height = view.getUint32(20);
  _out('[I] upscaling from ($width x $height) to (${width * 4} x ${height * 4}) --- upscaler.cpp:214');
  _out('[V] processing 128 tiles --- tiling.cpp:179');
  await _bar(128, '=', (i) => '3.75it/s', stepMs ~/ 4);
  _writePng(output, width * 4, height * 4, 'ok');
  _out("[I] save result image to '$output' (success) --- main.cpp:495");
  await stdout.flush();
}

/// The host of the test of a program that never outlives the app
Future<void> _host(String pidFile) async {
  final launcher = Platform.environment['IMMUCH360_RUN_LAUNCHER'];
  final runner = ManagedProcessRunner(linuxLauncher: launcher);
  final child = await runner.start(
    ProcessLaunch(
      executable: Platform.resolvedExecutable,
      arguments: const ['-o', 'never.png'],
      environment: const {'IMMUCH360_FAKE_SD_CLI_MODE': 'silent', 'IMMUCH360_FAKE_SD_CLI_PID': ''},
    ),
  );
  unawaited(child.stdoutLines.drain<void>());
  unawaited(child.stderrLines.drain<void>());
  File(pidFile).writeAsStringSync('${child.pid}');
  await Future<void>.delayed(const Duration(hours: 1));
}
