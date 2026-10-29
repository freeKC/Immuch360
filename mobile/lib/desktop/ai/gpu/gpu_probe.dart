// The probe of the graphics cards (design-final 2026-10-27, section 4.7, point 1): the executable of the app started
// again with --immuch360-gpu-probe=<file> (windows/runner/gpu_probe.cpp, linux/runner/gpu_probe.cc), handled before
// the guard of the single instance and before any window. In a child process, so that a driver that crashes or hangs
// (an implicit layer of an overlay, a broken install) takes down the child and never the app: past 10 s it is stopped
// and the answer is "The graphics card did not answer". Its JSON (GpuReport) lists each card Vulkan sees, with the
// budget of VK_EXT_memory_budget, and on Windows the adapters of DXGI that Vulkan does not list. Nothing is allocated on
// a card. macOS has no Vulkan: nothing is started there, the panoramas wait for a lot of their own on the Macs.
//
// The gate asks for it when it looks at the panoramas (hardware_gate.dart), and the queue again before each job on the
// graphics card (gpu_budget.dart).
//
// stable-diffusion.cpp must be told which card to run on: left to choose, ggml numbers the cards its own way, and on a
// laptop the integrated graphics come first (M3: Vulkan0 the Intel, Vulkan1 the RTX 4060). [ggmlVulkanDevices] follows
// ggml_vk_instance_init of the ggml the pinned stable-diffusion.cpp builds (ggml a5915eb, src/ggml-vulkan/ggml-vulkan.cpp
// 5300 to 5440) on what the probe read: the dedicated and integrated cards with 16 bit storage buffers in the order of
// the loader, a card seen twice (same UUID, or same LUID) kept once by the driver ggml prefers, and when there is none,
// the first card that is not a processor. Setting GGML_VK_VISIBLE_DEVICES to [GpuAdapter.vulkanIndex] instead makes
// that card Vulkan0 whatever ggml would do: the safer of the two for the launcher of lot P2.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart' show aiWorkFolderName;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('GpuProbe');

/// The flag the runners read; the path of the JSON follows it
const gpuProbeFlag = '--immuch360-gpu-probe=';

/// How long the probe may take; the runners end it past the same time themselves
const gpuProbeTimeout = Duration(seconds: 10);

/// The folder of the files of the AI jobs, under the temporary folder of the system (design 4.5, point 2): the one of
/// the work folders and the journal of the programs of lot P2 (AiWorkFolders)
Directory aiWorkFolder() => Directory(p.join(Directory.systemTemp.path, aiWorkFolderName));

/// The probe of the app: its own executable started with [gpuProbeFlag]
class ProcessGpuProbe implements GpuProbe {
  ProcessGpuProbe({
    required this.executable,
    this.runner = const SystemProcessRunner(),
    this.timeout = gpuProbeTimeout,
    Directory Function()? folder,
    bool? isMacOS,
  }) : _folder = folder ?? aiWorkFolder,
       _isMacOS = isMacOS ?? Platform.isMacOS;

  /// The executable of this app: the runner of a release, of a debug build, or of a test of the real probe
  factory ProcessGpuProbe.ofThisApp() => ProcessGpuProbe(executable: Platform.resolvedExecutable);

  final String executable;
  final Duration timeout;
  final ProcessRunner runner;
  final Directory Function() _folder;
  final bool _isMacOS;

  static var _count = 0;

  @override
  Future<GpuReport> probe() async {
    if (_isMacOS) {
      return const GpuReport(problem: GpuProbeProblem.notSupported);
    }
    // Under flutter test the executable of this process is the runner of the tests, which knows no such flag: a test
    // of the real probe names the app it starts
    if (p.basenameWithoutExtension(executable) == 'flutter_tester') {
      _log.warning('No probe of the graphics cards in the runner of the tests');
      return const GpuReport(problem: GpuProbeProblem.failed);
    }
    final File output;
    try {
      final folder = await _folder().create(recursive: true);
      output = File(p.join(folder.path, 'gpu-probe-$pid-${++_count}.json'));
    } on FileSystemException catch (error) {
      _log.warning('No folder for the probe of the graphics cards: $error');
      return const GpuReport(problem: GpuProbeProblem.failed);
    }
    try {
      final RunningProcess process;
      try {
        process = await runner.start(
          ProcessLaunch(executable: executable, arguments: ['$gpuProbeFlag${output.path}'], lowPriority: false),
        );
      } on Object catch (error) {
        _log.warning('The probe of the graphics cards did not start: $error');
        return const GpuReport(problem: GpuProbeProblem.failed);
      }
      // Read, so that its pipes never fill
      unawaited(process.stdoutLines.drain<void>().catchError((_) {}));
      unawaited(process.stderrLines.drain<void>().catchError((_) {}));
      final code = await process.exitCode
          .then<int?>((code) => code)
          .timeout(
            timeout,
            onTimeout: () {
              process.kill();
              return null;
            },
          );
      if (code == null) {
        _log.warning('The probe of the graphics cards did not answer within ${timeout.inSeconds} s: stopped');
        return const GpuReport(problem: GpuProbeProblem.noAnswer);
      }
      if (!output.existsSync()) {
        _log.warning('The probe of the graphics cards ended with $code and no answer');
        return const GpuReport(problem: GpuProbeProblem.failed);
      }
      return GpuReport.fromJson(jsonDecode(await output.readAsString()));
    } on FormatException catch (error) {
      _log.warning('The answer of the probe of the graphics cards does not read: $error');
      return const GpuReport(problem: GpuProbeProblem.failed);
    } on FileSystemException catch (error) {
      _log.warning('The answer of the probe of the graphics cards could not be read: $error');
      return const GpuReport(problem: GpuProbeProblem.failed);
    } finally {
      try {
        if (output.existsSync()) {
          output.deleteSync();
        }
      } on FileSystemException {
        // Left in the temporary folder
      }
    }
  }
}

/// Starts a program with dart:io, its lines read as UTF-8: enough for the probe, which ends by itself. The generator
/// gets the launcher of lot P2, which no process outlives.
class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async => _SystemProcess(
    await Process.start(
      launch.executable,
      launch.arguments,
      workingDirectory: launch.workingDirectory,
      environment: launch.environment.isEmpty ? null : launch.environment,
    ),
  );
}

class _SystemProcess implements RunningProcess {
  _SystemProcess(this._process) : stdoutLines = _lines(_process.stdout), stderrLines = _lines(_process.stderr);

  final Process _process;

  static Stream<String> _lines(Stream<List<int>> bytes) =>
      bytes.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter());

  @override
  int get pid => _process.pid;

  @override
  final Stream<String> stdoutLines;

  @override
  final Stream<String> stderrLines;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void kill() => _process.kill(ProcessSignal.sigkill);
}

// The vendors and drivers ggml tells apart when one card is seen twice (VkDriverId of vulkan_core.h)
const _amd = 0x1002;
const _intel = 0x8086;
const _nvidia = 0x10de;
const _qualcomm = 0x5143;
const _moltenVk = 14;
const _mesaDozen = 23;
const _driverPriorities = {
  // RADV, then the open source driver of AMD, then its proprietary one
  _amd: {3: 1, 2: 2, 1: 3},
  // Mesa, then the driver of Intel for Windows
  _intel: {6: 1, 5: 2},
  // The driver of NVIDIA, then NVK
  _nvidia: {4: 1, 24: 2},
  // The driver of Qualcomm, then Turnip
  _qualcomm: {8: 1, 18: 2},
};

int _priority(int? vendor, int? driver) {
  if (driver == _mesaDozen) {
    return 100;
  }
  return _driverPriorities[vendor]?[driver] ?? 1 << 30;
}

bool _sameCard(GpuAdapter old, GpuAdapter seen) {
  final sameUuid = old.uuid != null && old.uuid == seen.uuid;
  final sameLuid = old.luid != null && old.luid == seen.luid;
  final bothMoltenVk = old.driverId == _moltenVk && seen.driverId == _moltenVk;
  return (sameUuid || sameLuid) && !bothMoltenVk;
}

/// The cards of [report] as ggml numbers them when GGML_VK_VISIBLE_DEVICES is not set, Vulkan0 first (see the top of
/// this file); empty when ggml finds none
List<GpuAdapter> ggmlVulkanDevices(GpuReport report) {
  // In the order of the loader; a card that does not tell its place keeps its place in the report
  final listed = [
    for (final (index, adapter) in report.adapters.indexed)
      if (adapter.source == 'vulkan') (adapter: adapter, place: adapter.vulkanIndex ?? index, index: index),
  ]..sort((a, b) => a.place != b.place ? a.place.compareTo(b.place) : a.index.compareTo(b.index));
  final vulkan = [for (final entry in listed) entry.adapter];

  final chosen = <GpuAdapter>[];
  for (final seen in vulkan) {
    if ((seen.kind != GpuKind.discrete && seen.kind != GpuKind.integrated) || seen.storage16Bit == false) {
      continue;
    }
    final old = chosen.indexWhere((kept) => _sameCard(kept, seen));
    if (old < 0) {
      chosen.add(seen);
      continue;
    }
    // The one of the driver ggml prefers for the vendor of the card kept, the card kept when neither is preferred
    final kept = chosen[old];
    if (_priority(kept.vendorId, seen.driverId) < _priority(kept.vendorId, kept.driverId)) {
      chosen
        ..removeAt(old)
        ..add(seen);
    }
  }
  if (chosen.isEmpty) {
    final first = vulkan.where((adapter) => adapter.kind != GpuKind.cpu).firstOrNull;
    if (first != null) {
      chosen.add(first);
    }
  }
  return chosen;
}

/// The index ggml gives [card] (its name `Vulkan<n>`) among the cards of [report], the answer it came from or another one
/// of the same probe (the same place in the loader, the same name); null for a card ggml leaves out
int? ggmlVulkanIndexOf(GpuReport report, GpuAdapter card) {
  final index = ggmlVulkanDevices(report).indexWhere(
    (device) =>
        identical(device, card) ||
        (device.vulkanIndex != null && device.vulkanIndex == card.vulkanIndex && device.name == card.name),
  );
  return index < 0 ? null : index;
}

/// The name of the graphics card to show for this computer: the dedicated card with the most memory, else the first
/// integrated one, else the first card that is not a processor; null when the probe found none
String? gpuNameOf(GpuReport report) {
  final cards = [
    for (final adapter in report.adapters)
      if (adapter.kind != GpuKind.cpu) adapter,
  ];
  return (report.bestDiscrete ??
          cards.where((adapter) => adapter.kind == GpuKind.integrated).firstOrNull ??
          cards.firstOrNull)
      ?.name;
}
