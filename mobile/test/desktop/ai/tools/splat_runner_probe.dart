// The runners of the splat scenes (lot SP4) on real programs, outside of the app: COLMAP and Brush started through the
// launcher of the app (ManagedProcessRunner: the job object on Windows, immuch360-run on Linux), so that the PC of the
// essay runs the archives of lots SP1 and SP2 exactly as the app will, and so that a test kills the host and sees its
// child go. Compiled by `dart compile exe` (the windows job of the desktop workflow keeps it in the artifact
// Immuch360-AI-tools-windows-x64; the test job on Linux for splat_runners_real_test.dart). Pure Dart, with no Flutter.
//
//   splat_runner_probe colmap --colmap EXE --work DIR [--images N] [--video] [--launcher RUN]
//       the poses of the images of DIR/dataset/images; a JSON line per progress, then one with the poses
//   splat_runner_probe brush --brush EXE --work DIR --cache DIR [--steps N] [--max-gaussians N] [--resolution N]
//       [--card nvidia-smi|fake-rtx|fake-intel] [--need-mib N] [--wait-max-s N] [--pid-file F] [--launcher RUN]
//       the training of DIR/dataset into DIR/brush; the card read from nvidia-smi on the PC, or one of the fake cards
//       of the fake Brush; while less than --need-mib is free it waits, at most --wait-max-s, then cancels; the id of
//       brush_app written to --pid-file once it runs
//   splat_runner_probe host-colmap --colmap EXE --work DIR --pid-file F [--launcher RUN]
//       COLMAP extracting until killed (the fake COLMAP in its silent mode): the id of COLMAP written to F, then the
//       probe waits to be killed
//   splat_runner_probe parse --stage features|matching|mapping|training [--images N] FILE...
//       the progress a log of the measure gives, read as the runners read it: its count of lines, its first and last
//   splat_runner_probe model FOLDER...
//       a model of COLMAP read as the app reads it (the largest when FOLDER holds the models 0, 1...): its images,
//       points, cameras, mean reprojection error and floor
//
// Exit codes: 0 done, 1 a failure of the runner (its code and message in the last JSON line), 2 bad arguments.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/ai/splat/brush_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/colmap_model.dart';
import 'package:immich_mobile/desktop/ai/splat/colmap_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_work_folder.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';

final _clock = Stopwatch()..start();

void _emit(Map<String, Object?> event) =>
    stdout.writeln(jsonEncode({'t': (_clock.elapsedMilliseconds / 1000).toStringAsFixed(1), ...event}));

Never _usage(String why) {
  stderr.writeln('splat_runner_probe: $why');
  exit(2);
}

Map<String, String> _options(List<String> arguments, {Set<String> flags = const {}}) {
  final options = <String, String>{};
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (!argument.startsWith('--')) {
      options['_${options.length}'] = argument;
      continue;
    }
    final name = argument.substring(2);
    if (flags.contains(name)) {
      options[name] = 'true';
    } else if (i + 1 < arguments.length) {
      options[name] = arguments[++i];
    } else {
      _usage('$argument needs a value');
    }
  }
  return options;
}

ManagedProcessRunner _runner(Map<String, String> options) => ManagedProcessRunner(linuxLauncher: options['launcher']);

int _countImages(Directory folder) => folder
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => RegExp(r'\.(jpe?g|png)$', caseSensitive: false).hasMatch(file.path))
    .length;

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    _usage('colmap, brush, host-colmap, parse or model');
  }
  final command = arguments.first;
  final options = _options(arguments.sublist(1), flags: {'video'});
  final cancel = NativeCancelFlag();
  try {
    switch (command) {
      case 'colmap':
        await _colmap(options, cancel);
      case 'brush':
        await _brush(options, cancel);
      case 'host-colmap':
        await _hostColmap(options, cancel);
      case 'parse':
        _parse(options);
      case 'model':
        _model(options);
      default:
        _usage('unknown command $command');
    }
  } on BackendException catch (failure) {
    _emit({'event': 'failed', 'code': failure.code.name, 'message': failure.message});
    await stdout.flush();
    exit(1);
  }
  await stdout.flush();
  exit(0);
}

Future<void> _colmap(Map<String, String> options, NativeCancelFlag cancel) async {
  final work = SplatWorkFolder(Directory(options['work'] ?? _usage('--work')));
  final images = int.tryParse(options['images'] ?? '') ?? _countImages(work.images);
  final colmap = ColmapRunner(runner: _runner(options), colmap: options['colmap'] ?? _usage('--colmap'));
  _emit({
    'event': 'start',
    'images': images,
    'video': options['video'] == 'true',
    'threads': colmapThreadsFor(available: colmap.memory.read().available, processors: colmap.processors),
  });
  final poses = await colmap.poses(
    work,
    images: images,
    video: options['video'] == 'true',
    cancel: cancel,
    onProgress: (progress) =>
        _emit({'event': 'progress', 'stage': progress.stage.name, 'done': progress.done, 'total': progress.total}),
  );
  final floor = poses.floor;
  _emit({
    'event': 'poses',
    'images': poses.images,
    'placed': poses.placed,
    'partial': poses.partial,
    'threads': poses.threads,
    'cameras': poses.model.cameras.length,
    'points': poses.model.points.length,
    'meanReprojectionError': poses.model.meanReprojectionError,
    'floor': floor == null ? null : {'y': floor.y, 'cameraHeight': floor.cameraHeight, 'support': floor.support},
    'seconds': {for (final MapEntry(:key, :value) in poses.times.entries) key: value.inMilliseconds / 1000},
  });
}

/// The cards nvidia-smi lists, as dedicated cards of Vulkan in its order (the PC of the essay has one)
Future<GpuReport> _nvidiaSmi() async {
  final result = await Process.run('nvidia-smi', [
    '--query-gpu=index,name,memory.total,memory.used,pci.device_id,driver_version',
    '--format=csv,noheader,nounits',
  ]);
  if (result.exitCode != 0) {
    return const GpuReport(problem: GpuProbeProblem.failed);
  }
  const mib = 1024 * 1024;
  return GpuReport(
    adapters: [
      for (final line in LineSplitter.split('${result.stdout}'))
        if (line.trim().isNotEmpty)
          () {
            final fields = line.split(',').map((field) => field.trim()).toList();
            final pci = int.parse(fields[4].replaceFirst('0x', ''), radix: 16);
            final total = int.parse(fields[2]) * mib;
            return GpuAdapter(
              name: fields[1],
              kind: GpuKind.discrete,
              localMemory: total,
              vendorId: pci & 0xFFFF,
              deviceId: pci >> 16,
              driverVersion: fields[5],
              budget: total,
              usage: int.parse(fields[3]) * mib,
              vulkanIndex: int.parse(fields[0]),
            );
          }(),
    ],
  );
}

/// The two cards the fake Brush knows, as the probe of the app reads them on the PC of the essay
const _fakeIntel = GpuAdapter(
  name: 'Intel(R) RaptorLake-S Mobile Graphics Controller',
  kind: GpuKind.integrated,
  localMemory: 2 << 30,
  vendorId: 0x8086,
  deviceId: 0xA788,
  driverVersion: '101.7088',
  vulkanIndex: 0,
);
const _fakeRtx = GpuAdapter(
  name: 'NVIDIA GeForce RTX 4060 Laptop GPU',
  kind: GpuKind.discrete,
  localMemory: 8 << 30,
  vendorId: 0x10DE,
  deviceId: 0x28A0,
  driverVersion: '616.56',
  vulkanIndex: 1,
);

Future<void> _brush(Map<String, String> options, NativeCancelFlag cancel) async {
  final work = SplatWorkFolder(Directory(options['work'] ?? _usage('--work')));
  final card = options['card'] ?? 'nvidia-smi';
  final need = (int.tryParse(options['need-mib'] ?? '') ?? 2560) * 1024 * 1024;
  final waitMax = int.tryParse(options['wait-max-s'] ?? '');
  final pidFile = options['pid-file'];
  Timer? giveUp;
  final brush = BrushRunner(
    runner: _runner(options),
    brush: options['brush'] ?? _usage('--brush'),
    cacheRoot: Directory(options['cache'] ?? _usage('--cache')),
    recheck: const Duration(seconds: 5),
    cardCheck: () async {
      if (card == 'fake-rtx' || card == 'fake-intel') {
        final chosen = card == 'fake-rtx' ? _fakeRtx : _fakeIntel;
        return BrushCardReady(chosen, const GpuReport(adapters: [_fakeIntel, _fakeRtx]));
      }
      final report = await _nvidiaSmi();
      final found = report.adapters.isEmpty ? null : report.adapters.first;
      if (found == null) {
        return const BrushCardRefused('gpuNone');
      }
      _emit({'event': 'card', 'name': found.name, 'free': found.freeMemory, 'need': need});
      return found.freeMemory >= need ? BrushCardReady(found, report) : BrushCardWait(found.freeMemory);
    },
  );
  final settings = SplatSettings(
    steps: int.tryParse(options['steps'] ?? '') ?? 20000,
    maxGaussians: int.tryParse(options['max-gaussians'] ?? '') ?? 150000,
    trainingResolution: int.tryParse(options['resolution'] ?? '') ?? 1024,
  );
  final result = await brush.train(
    work,
    settings: settings,
    cancel: cancel,
    onWaiting: (free) {
      _emit({'event': 'waiting', 'free': free});
      if (waitMax != null) {
        giveUp ??= Timer(Duration(seconds: waitMax), cancel.cancel);
      }
    },
    onStarted: (pid) {
      _emit({'event': 'started', 'pid': pid});
      if (pidFile != null) {
        File(pidFile).writeAsStringSync('$pid');
      }
    },
    onProgress: (progress) => _emit({
      'event': 'progress',
      'step': progress.step,
      'steps': progress.steps,
      'splats': progress.splats,
      'seconds': progress.elapsed.inMilliseconds / 1000,
    }),
  );
  giveUp?.cancel();
  _emit({
    'event': 'trained',
    'ply': result.ply.path,
    'bytes': result.ply.lengthSync(),
    'splats': result.splats,
    'views': result.views,
    'adapter': result.adapter?.toString(),
    'psnr': result.psnr,
    'seconds': result.time.inMilliseconds / 1000,
  });
}

Future<void> _hostColmap(Map<String, String> options, NativeCancelFlag cancel) async {
  final work = SplatWorkFolder(Directory(options['work'] ?? _usage('--work')));
  final pidFile = options['pid-file'] ?? _usage('--pid-file');
  final runner = _runner(options);
  final recording = _RecordingRunner(runner, (pid) => File(pidFile).writeAsStringSync('$pid'));
  final colmap = ColmapRunner(runner: recording, colmap: options['colmap'] ?? _usage('--colmap'));
  await colmap.poses(work, images: _countImages(work.images), video: false, cancel: cancel);
}

/// A runner that tells the id of each program it starts
class _RecordingRunner implements ProcessRunner {
  _RecordingRunner(this.inner, this.onStart);

  final ProcessRunner inner;
  final void Function(int pid) onStart;

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async {
    final process = await inner.start(launch);
    onStart(process.pid);
    return process;
  }
}

void _parse(Map<String, String> options) {
  final stage = options['stage'] ?? _usage('--stage');
  final files = [
    for (final MapEntry(:key, :value) in options.entries)
      if (key.startsWith('_')) value,
  ];
  for (final path in files) {
    final lines = File(path).readAsLinesSync();
    if (stage == 'training') {
      final steps = <int>[];
      var splats = 0;
      double? psnr;
      var adapter = '';
      var done = false;
      for (final line in lines) {
        final match = RegExp(r'\] Refine iter (\d+), (\d+) splats\.').firstMatch(line);
        if (match != null) {
          steps.add(int.parse(match.group(1)!));
          splats = int.parse(match.group(2)!);
        }
        final eval = RegExp(r'\] Eval iter \d+: PSNR ([\d.]+)').firstMatch(line);
        if (eval != null) {
          psnr = double.parse(eval.group(1)!);
        }
        adapter = brushAdapterOf(line)?.toString() ?? adapter;
        done = done || line.contains('] Done training!');
      }
      _emit({
        'file': path,
        'refines': steps.length,
        'first': steps.firstOrNull,
        'last': steps.lastOrNull,
        'splats': splats,
        'psnr': psnr,
        'adapter': adapter,
        'done': done,
      });
      continue;
    }
    final log = ColmapLog(ImmersiveStage.values.byName(stage), images: int.tryParse(options['images'] ?? '') ?? 0);
    final progress = [for (final line in lines) ?log.read(line)];
    _emit({
      'file': path,
      'progress': progress.length,
      'first': progress.isEmpty ? null : '${progress.first.done}/${progress.first.total}',
      'last': progress.isEmpty ? null : '${progress.last.done}/${progress.last.total}',
    });
  }
}

void _model(Map<String, String> options) {
  for (final MapEntry(:key, :value) in options.entries) {
    if (!key.startsWith('_')) {
      continue;
    }
    final largest = largestColmapModel(Directory(value));
    final folder = largest?.folder ?? Directory(value);
    final model = ColmapModel.read(folder);
    final floor = model.floor();
    _emit({
      'model': folder.path,
      'placed': colmapPlacedIn(folder),
      'images': model.images.length,
      'points': model.points.length,
      'cameras': model.cameras.length,
      'meanReprojectionError': model.meanReprojectionError,
      'floor': floor == null ? null : {'y': floor.y, 'cameraHeight': floor.cameraHeight, 'support': floor.support},
    });
  }
}
