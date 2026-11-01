// A fake Brush 0.3.0 (brush_app, which also trains from the command line), compiled into a real program by `dart
// compile exe` (the test and windows jobs of the desktop workflow, or by hand) and given to the tests by
// IMMUCH360_FAKE_BRUSH, so that the runner of the splat scenes (lot SP4) and the launcher (managed_process.dart) are
// tested against a real child process, with no graphics card: no runner of the CI has one, and Brush 0.3.0 stops at its
// first kernel on lavapipe and on the Intel UHD (measure of 1 November 2026, section 7).
//
// It takes the options of the help of brush_app 0.3.0 (read by lot SP2 from the official binary) and, as clap does,
// refuses any other with exit code 2. Its lines are those the measure logged with RUST_LOG naming brush_cli,
// brush_process and cubecl_wgpu (env_logger: "[2026-11-01T12:32:45Z INFO  brush_cli] Refine iter 201, 19961 splats."),
// and only those RUST_LOG asks for, as the real one. It reads the dataset it is given (a COLMAP folder: images/ and
// sparse/0) and writes at each multiple of --export-every, in --export-path, the export named by --export-name
// ("export_{iter}.ply"): a PLY of gaussians on the points of sparse/0, its properties in the alphabetical order of Brush
// 0.3.0, after its comments "Exported from Brush", "Vertical axis: y", "SH degree: 3". The card it says it uses
// ("Using adapter AdapterInfo { name: ..., device_type: DiscreteGpu ... }") follows CUBECL_WGPU_DEFAULT_DEVICE: an
// IntegratedGpu(n) is the Intel graphics of the measure, which then stops at its first kernel. IMMUCH360_FAKE_BRUSH_MODE
// says how it goes:
//   ok        the steps, then the export (the default)
//   slow      as ok, half a second between two lines of progress (IMMUCH360_FAKE_BRUSH_STEP_MS sets it otherwise,
//             1 ms); a line every 200 steps, as the real one
//   silent    the lines up to the training, then nothing until killed
//   planes    the panic of the measure on the Intel UHD ("Trying to launch a kernel using plane instructions, but the
//             min and max plane dimensions are different."), whatever the card, then the exit code it had there
//             (0xC0000409 on Windows, SIGABRT elsewhere)
//   oom       a panic whose words carry those Brush issues 500 and 551 report for a memory of the card too short
//             ("failed to reserve", "ErrorOutOfDeviceMemory"; not seen on this PC), exit code 101
//   fail      an error before the training (a dataset it cannot read), exit code 1
// IMMUCH360_FAKE_BRUSH_SPLATS sets the gaussians written (2000 by default, at most --max-splats). It writes its process
// id to the file IMMUCH360_FAKE_BRUSH_PID names, when it does.
//
//   fake_brush host PIDFILE
// starts this same program in the silent mode through ManagedProcessRunner (on Linux through the launcher
// IMMUCH360_RUN_LAUNCHER names), writes the id of that child to PIDFILE, and waits to be killed: the test kills the host
// and the child must go with it.
//
// Pure Dart, with no Flutter: compiled outside of any test.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';

import 'fake_colmap_model.dart';

/// The options of brush_app 0.3.0 that take a value, and those that do not
const _valued = {
  'total-steps',
  'lr-mean',
  'lr-mean-end',
  'mean-noise-weight',
  'lr-coeffs-dc',
  'lr-coeffs-sh-scale',
  'lr-opac', //
  'lr-scale',
  'lr-scale-end',
  'lr-rotation',
  'ssim-weight',
  'opac-loss-weight',
  'scale-loss-weight',
  'aux-loss-time',
  'max-splats',
  'refine-every',
  'growth-grad-threshold',
  'growth-select-fraction',
  'growth-stop-iter',
  'match-alpha-weight',
  'lpips-loss-weight',
  'sh-degree',
  'max-frames',
  'max-resolution',
  'eval-split-every',
  'subsample-frames',
  'subsample-points',
  'seed',
  'start-iter',
  'eval-every',
  'export-every',
  'export-path',
  'export-name',
  'rerun-log-train-stats-every',
  'rerun-log-splats-every',
  'rerun-max-img-size',
};
const _flags = {'with-viewer', 'eval-save-to-disk', 'rerun-enabled'};

Future<void> main(List<String> arguments) async {
  if (arguments.length == 2 && arguments.first == 'host') {
    await _host(arguments[1]);
    return;
  }
  final pidFile = Platform.environment['IMMUCH360_FAKE_BRUSH_PID'];
  if (pidFile != null && pidFile.isNotEmpty) {
    File(pidFile).writeAsStringSync('$pid');
  }
  final options = <String, String>{};
  String? source;
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (argument == '-h' || argument == '--help') {
      stdout.write('Brush - universal splats (fake of Immuch360)\n\nUsage: brush_app [OPTIONS] [PATH_OR_URL]\n');
      return;
    }
    if (argument == '-V' || argument == '--version') {
      stdout.write('brush_app 0.3.0\n');
      return;
    }
    if (argument.startsWith('--')) {
      final name = argument.substring(2);
      if (_flags.contains(name)) {
        options[name] = 'true';
      } else if (_valued.contains(name) && i + 1 < arguments.length) {
        options[name] = arguments[++i];
      } else {
        stderr.write(
          "error: unexpected argument '$argument' found\n\nUsage: brush_app [OPTIONS] [PATH_OR_URL]\n\n"
          "For more information, try '--help'.\n",
        );
        await _flush();
        exit(2);
      }
    } else if (source == null) {
      source = argument;
    } else {
      stderr.write("error: unexpected argument '$argument' found\n");
      await _flush();
      exit(2);
    }
  }
  final mode = Platform.environment['IMMUCH360_FAKE_BRUSH_MODE'] ?? 'ok';
  final stepMs = int.tryParse(Platform.environment['IMMUCH360_FAKE_BRUSH_STEP_MS'] ?? '') ?? (mode == 'slow' ? 500 : 1);
  final total = int.parse(options['total-steps'] ?? '30000');
  final maxSplats = int.parse(options['max-splats'] ?? '10000000');
  final degree = int.parse(options['sh-degree'] ?? '3');
  final refineEvery = int.parse(options['refine-every'] ?? '200');
  final growthStop = int.parse(options['growth-stop-iter'] ?? '15000');
  final exportEvery = int.parse(options['export-every'] ?? '5000');
  final exportPath = options['export-path'] ?? '.';
  final exportName = options['export-name'] ?? 'export_{iter}.ply';
  final evalEvery = int.parse(options['eval-every'] ?? '1000');
  final evalSplit = int.tryParse(options['eval-split-every'] ?? '');

  final device = Platform.environment['CUBECL_WGPU_DEFAULT_DEVICE'] ?? '';
  final integrated = device.startsWith('IntegratedGpu');
  final adapter = integrated
      ? 'AdapterInfo { name: "Intel(R) RaptorLake-S Mobile Graphics Controller", vendor: 32902, device: 42888, '
            'device_type: IntegratedGpu, driver: "Intel Corporation", driver_info: "101.7088", backend: Vulkan }'
      : 'AdapterInfo { name: "NVIDIA GeForce RTX 4060 Laptop GPU", vendor: 4318, device: 10400, device_type: '
            'DiscreteGpu, driver: "NVIDIA", driver_info: "616.56", backend: Vulkan }';
  _log('cubecl_wgpu::runtime', 'Using adapter $adapter');
  _log('brush_cli', 'Starting up');
  _log('brush_process::process', 'Starting process with source Path("${source ?? ''}")');
  final model = source == null ? null : FakeColmapModel.readFrom(Directory('$source/sparse/0'));
  if (mode == 'fail' || (model == null && mode != 'silent')) {
    stderr.write('Error: Failed to load dataset: no COLMAP model in ${source ?? '(none)'}\n');
    await _flush();
    exit(1);
  }
  final views = model?.images.length ?? 0;
  final evalViews = evalSplit == null || evalSplit <= 0 ? 0 : (views + evalSplit - 1) ~/ evalSplit;
  _log('brush_process::process', 'Mounted VFS with ${views + 5} files. (plys: 0)');
  _log('brush_process::process', 'Start of view stream');
  _log('brush_process::train_stream', 'Start of training stream');
  _log('brush_process::train_stream', 'Using seed ${options['seed'] ?? '42'}');
  _log('brush_process::train_stream', 'Loading dataset');
  _log('brush_process::train_stream', 'Log scene to rerun');
  _log('brush_process::train_stream', 'Dataset loaded');
  _log('brush_cli', 'Loaded dataset with ${views - evalViews} training, $evalViews eval views');
  _log('brush_process::train_stream', 'Loading initial splats if any.');
  _log('brush_cli', 'Completed loading.');
  _log('brush_process::train_stream', 'Start training loop.');
  await _flush();
  if (mode == 'silent') {
    await Future<void>.delayed(const Duration(hours: 1));
    return;
  }
  if (mode == 'planes' || integrated) {
    stderr.write(
      "\nthread 'main' panicked at C:\\Users\\runneradmin\\.cargo\\git\\checkouts\\cubecl-01990d4f7f2c358d\\43580a8\\"
      'crates\\cubecl-runtime\\src\\tune\\local.rs:180:30:\nShould run when selected by autotune.: Unknown("Trying to '
      'launch a kernel using plane instructions, but the min and max plane dimensions are different.")\n'
      'note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace\n',
    );
    await _flush();
    if (Platform.isWindows) {
      exit(-1073740791);
    }
    Process.killPid(pid, ProcessSignal.sigabrt);
    await Future<void>.delayed(const Duration(hours: 1));
    return;
  }
  if (model == null) {
    return;
  }
  final wanted = int.tryParse(Platform.environment['IMMUCH360_FAKE_BRUSH_SPLATS'] ?? '') ?? 2000;
  final finalSplats = math.min(wanted, maxSplats);
  final started = DateTime.now();
  for (var iter = 1; iter <= total; iter++) {
    if (iter % refineEvery == 1 && iter > 1) {
      final grown = (finalSplats * math.min(1.0, (iter + 1000) / (growthStop + 1000))).round();
      _log('brush_cli', 'Refine iter $iter, ${math.min(grown, finalSplats)} splats.');
      if (mode == 'oom' && iter > total ~/ 2) {
        stderr.write(
          "\nthread 'main' panicked at crates\\cubecl-wgpu\\src\\compute\\server.rs:412:18:\n"
          'failed to reserve 2147483648 bytes of graphics memory: ErrorOutOfDeviceMemory\n'
          'note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace\n',
        );
        await _flush();
        exit(101);
      }
      await stdout.flush();
      if (stepMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: stepMs));
      }
    }
    if (evalViews > 0 && iter % evalEvery == 0) {
      _log('brush_process::train_stream', 'Running evaluation for iteration $iter');
      _log('brush_cli', 'Eval iter $iter: PSNR ${(24 + 6 * iter / total).toStringAsFixed(6)}, ssim 0.9071395');
    }
    if (iter % exportEvery == 0) {
      _export(model, '$exportPath/${exportName.replaceAll('{iter}', '$iter')}', finalSplats, degree);
    }
  }
  final seconds = DateTime.now().difference(started).inSeconds;
  _log('brush_cli', 'Done training! Took FormattedDuration(${seconds}s).');
  await _flush();
}

/// A line of env_logger, written when RUST_LOG asks for its target at the level info
void _log(String target, String message) {
  final directives = (Platform.environment['RUST_LOG'] ?? '').split(',').map((part) => part.trim());
  final shown = directives.any((directive) {
    final parts = directive.split('=');
    final level = parts.length == 2 ? parts[1] : parts[0];
    final named = parts.length == 2 ? parts[0] : null;
    final loud = const {'info', 'debug', 'trace'}.contains(level.toLowerCase());
    return loud && (named == null || target == named || target.startsWith('$named::'));
  });
  if (!shown) {
    return;
  }
  final now = DateTime.now().toUtc().toIso8601String();
  stdout.write('[${now.substring(0, 19)}Z INFO  $target] $message\n');
}

Future<void> _flush() => Future.wait([stdout.flush(), stderr.flush()]);

/// The export of Brush 0.3.0: its comments, then its properties in alphabetical order, binary little endian
void _export(FakeColmapModel model, String path, int count, int degree) {
  final rest = 3 * ((degree + 1) * (degree + 1) - 1);
  final names = [
    'f_dc_0', 'f_dc_1', 'f_dc_2', //
    for (var k = 0; k < rest; k++) 'f_rest_$k',
    'opacity',
    'rot_0',
    'rot_1',
    'rot_2',
    'rot_3',
    'scale_0',
    'scale_1',
    'scale_2',
    'x',
    'y',
    'z',
  ]..sort();
  final header = StringBuffer('ply\nformat binary_little_endian 1.0\n')
    ..write('comment Exported from Brush\ncomment Vertical axis: y\ncomment SH degree: $degree\n')
    ..write('element vertex $count\n');
  for (final name in names) {
    header.write('property float $name\n');
  }
  header.write('end_header\n');
  final data = ByteData(count * names.length * 4);
  final random = math.Random(count);
  for (var i = 0; i < count; i++) {
    final point = model.points.isEmpty ? null : model.points[i % model.points.length];
    final values = <String, double>{
      'x': (point?.xyz[0] ?? 0) + random.nextDouble() * 0.02 - 0.01,
      'y': (point?.xyz[1] ?? 0) + random.nextDouble() * 0.02 - 0.01,
      'z': (point?.xyz[2] ?? 0) + random.nextDouble() * 0.02 - 0.01,
      for (var k = 0; k < 3; k++) 'f_dc_$k': ((point?.rgb[k] ?? 128) / 255 - 0.5) / 0.28209479177387814,
      for (var k = 0; k < rest; k++) 'f_rest_$k': random.nextDouble() * 0.1 - 0.05,
      'opacity': 2.0,
      for (var k = 0; k < 3; k++) 'scale_$k': math.log(0.02),
      'rot_0': 1.0,
      'rot_1': 0.0,
      'rot_2': 0.0,
      'rot_3': 0.0,
    };
    for (var k = 0; k < names.length; k++) {
      data.setFloat32((i * names.length + k) * 4, values[names[k]]!, Endian.little);
    }
  }
  final file = File(path)..parent.createSync(recursive: true);
  file.writeAsBytesSync([...header.toString().codeUnits, ...data.buffer.asUint8List()]);
}

/// The host of the test of a program that never outlives the app
Future<void> _host(String pidFile) async {
  final launcher = Platform.environment['IMMUCH360_RUN_LAUNCHER'];
  final runner = ManagedProcessRunner(linuxLauncher: launcher);
  final child = await runner.start(
    ProcessLaunch(
      executable: Platform.resolvedExecutable,
      arguments: const ['never'],
      environment: const {'IMMUCH360_FAKE_BRUSH_MODE': 'silent', 'IMMUCH360_FAKE_BRUSH_PID': ''},
    ),
  );
  unawaited(child.stdoutLines.drain<void>());
  unawaited(child.stderrLines.drain<void>());
  File(pidFile).writeAsStringSync('${child.pid}');
  await Future<void>.delayed(const Duration(hours: 1));
}
