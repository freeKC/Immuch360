// sd-cli of stable-diffusion.cpp on Vulkan, the generator and the upscaler of the 360° panoramas (lot P2; design-final
// 2026-10-27, sections 4.3 to 4.5; measure M3, phase23/m3-measures-2026-10-27.md, section 9), behind GeneratorBackend and
// UpscaleBackend. One child process per generation or upscale, started by a ProcessRunner (managed_process.dart in the
// app, the fake runner or the compiled fake sd-cli in the tests):
//  - its arguments are frozen: those M3 ran, every option found in sd_cli_help.txt of the pinned build (the sdcpp jobs
//    compare the build with it), the graphics card named by ggml's index (--backend diffusion=Vulkan<n>,vae=Vulkan<n>,
//    te=CPU: the integrated card comes first on a laptop, so sd-cli never chooses), flash attention on (without it the
//    attention goes to the processor and no step ends in 10 minutes), the VAE in tiles, -t the logical processors less
//    two, -v for the line about segments and the auto-fit plan; since lot 13c (measure of 5 November 2026, section 9),
//    on Windows a budget of the card (--max-vram in GiB, the free memory the queue read less 512 MiB, where sd-cli's
//    own Vulkan reading leaves other programs out; on Linux sd-cli reads the card itself: gpu_budget.dart,
//    panoramaGeneratorBudget, says why) and the convolution of the VAE pinned to its direct path (--conv-direct
//    auto,vae=on: sd-cli times both paths at its start and took the other one in 2 runs of 32, another image by 36 to
//    39 dB for the same photo and seed). sd-cli fixes its budget at its start with or without --max-vram; a switch to
//    segments in the middle of a run comes from its live check of the card at every step, which the flag does not
//    change;
//  - the card it runs on is checked against its own list (release 44, the analysis of 8 November 2026 on the laptop of
//    the owner): the index the app gives first is a guess from the order of the probe (ggmlVulkanIndexOf), and the
//    app's process and sd-cli's may list the cards in different orders (desktop builds 21 to 23 export the requests for
//    the high performance card from immuch360.exe; the probe answered the RTX 4060 as 0 there, sd-cli.exe lists the
//    Intel chip first: proven; how the export turns the order is likely, not proven). sd-cli prints its list at its
//    start, "ggml_vulkan: N = name (driver) | uma: U", before any weight loads, in both modes; when the chosen card is
//    at another index it is stopped and started again there, once ([SdCppDevice], shared by the generator and the
//    upscaler of a job, the index learned kept for the session, [sdCppDeviceVerdict]); a card it does not list, or an
//    integrated chip where a dedicated card was chosen, is refused as gpuUnavailable. The app never sets
//    GGML_VK_VISIBLE_DEVICES: an index into sd-cli's own enumeration, the probe's guess there would be the same wrong
//    one. The line of its auto-fit plan for its device confirms the name, and stands in when no list is printed; the
//    log names the card, a restart and the placement the auto-fit settled on;
//  - each run is written to the log of the job, <work>/logs/sd-cli.log, after a line of its own ([sdCppLogOf]): the
//    panorama engine keeps a copy in the logs folder of the app after a failure (panorama_logs.dart);
//  - its progress is the bar it redraws ("12/20 - 8.65s/it"): the steps of the sampling only, not the loading of the
//    weights nor the tiles of the VAE;
//  - a generation whose graph sd-cli cuts into segments ("flux using 27 segments", when the memory it may use on the
//    card is short) goes on: at the 1536 x 768 of the app the cut gives the same bytes as one segment, slower (measure
//    of 5 November 2026, ai-gpu-budget-2026-11-05/measure.md, section 4: 294 s instead of 202 with 5.5 GiB free, about
//    8 min near the floor of 3.1 GiB; M3 saw spoilt images in segments at 1792 x 896 and 2048 x 1024 only). Each step
//    it reports then carries the number of segments (GeneratorProgress.segments), which the panel says, and the log
//    keeps it with the free memory and the budget sd-cli read on the card (the lines of its auto-fit plan); when its
//    live check lets it go back to one segment ("flux using 1 segment"), the steps say none again;
//  - a failure is named: gpuOutOfMemory when its output says a part could not be placed for want of memory (the
//    segment that failed during weight preparation, as M3 and the measure read it, or Vulkan's two texts; for a
//    generation, its message then starts with what sd-cli read of the card, GeneratorMemoryRead: the free memory and
//    the budget of its plan, and how short the line of its model manager before that segment said it was, so that the
//    panel says it and offers Keep waiting; that line alone is a warning sd-cli recovers from), generatorStalled after
//    180 s without a line (SdCppSettings.stallTimeout, in segments too), generatorFailed with the end of its error
//    output, cancelled within a second of the flag; the process is killed in every case where it still runs (the run
//    of a program, its watch of the silence and of the flag, is SidecarRun of process/sidecar_run.dart since lot SP4,
//    shared with COLMAP and Brush);
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
// Pure Dart rather than Flutter's foundation, so that the runner also builds into the programs without Flutter (the
// fake sd-cli, sdcpp_probe.dart, panorama_probe.dart)
// ignore: depend_on_referenced_packages
import 'package:meta/meta.dart' show visibleForTesting;
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

/// The graphics card the gate chose, as sd-cli must list it: its name, and whether it is the integrated chip, which the
/// gate chooses only when "Try on integrated graphics" is on (panoramaCardOf of hardware_gate.dart)
class SdCppCard {
  const SdCppCard({required this.name, required this.integrated});

  /// The name the probe read, Vulkan's deviceName, the one ggml lists
  final String name;
  final bool integrated;
}

/// How sd-cli ran: the program, the models, the graphics card, the threads, and the watchdogs
class SdCppSettings {
  SdCppSettings({
    required this.sdCli,
    required this.models,
    required this.device,
    this.card,
    int? threads,
    this.stallTimeout = const Duration(seconds: 180),
    this.pollInterval = const Duration(milliseconds: 200),
    this.environment = const {},
  }) : threads = threads ?? math.max(1, Platform.numberOfProcessors - 2),
       assert(RegExp(r'^Vulkan\d+$').hasMatch(device), 'A Vulkan device of ggml, Vulkan0, Vulkan1...');

  final String sdCli;
  final SdCppModels models;

  /// The graphics card by ggml's name for it, "Vulkan1": a first guess from the order of the probe (ggmlVulkanIndexOf),
  /// which sd-cli's own list confirms or corrects when [card] is given ([SdCppDevice])
  final String device;

  /// The card the gate chose, as sd-cli must list it; null: not checked (the measure programs without --card)
  final SdCppCard? card;

  /// -t: the logical processors less two, at least one
  final int threads;

  /// Stopped and named generatorStalled after this long without a line on either output: 180 s on a dedicated card,
  /// in segments as well. A run in segments writes one bar line a step, so its silence is a step: the slowest the
  /// measure of 5 November 2026 saw in segments took 73 s, at the floor with the owner's app and a splat job on the
  /// same RTX 4060 Laptop (21.7 s alone, 36.7 s with the app). A card 2.5 times slower under that load would reach
  /// 180 s: to raise for a run in segments if a log of a slower card comes near (the generation time of the
  /// panorama's summary line, over its 20 steps)
  final Duration stallTimeout;

  /// How often the cancel flag and the silence are looked at
  final Duration pollInterval;

  /// Added to the environment of the app for sd-cli
  final Map<String, String> environment;
}

/// The texts of a failure for want of memory of the graphics card: the segment sd-cli could not place, after its model
/// manager could not make the memory available (M3, section 5; the measure of 5 November 2026 below the floor), and
/// Vulkan's two, by prudence, never seen. The model manager's own line ([sdCppShortOf]) is not one of them: sd-cli
/// recovers from it (cut runs near the floor print it several times and end well), so that a run failing later for
/// another reason stays generatorFailed.
const sdCppOutOfMemoryTexts = [sdCppFailedSegmentText, 'ErrorOutOfDeviceMemory', 'Failed to allocate'];

/// "flux segment 7/27 (flux.single_blocks.0) failed during weight preparation --- ggml_runner.cpp:899", the line right
/// after the model manager's shortfall it fails with
const sdCppFailedSegmentText = 'failed during weight preparation';

/// Why a budget the app gave sd-cli (Windows) is the one to read: sd-cli's own free figure there is Vulkan's
const _givenWhy = " (from the free memory Windows counts: Vulkan's figure leaves other programs out)";

/// The most lines of the error output a failure carries in its message
const sdCppErrorTailLines = 20;

final _bar = RegExp(r'\|\s*(\d+)/(\d+)\s*-\s*([\d.]+)\s*(s/it|it/s)');
final _segments = RegExp(r'\bflux (?:using (\d+) segments?\b|compute buffer size:.*\(peak across (\d+) segments?\))');

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

/// The number of segments a line says the transformer's graph was cut into, 1 for a graph whole ("flux using 1 segment"
/// when the live check of sd-cli lets a cut run go back to one, "peak across 1 segment"), null when it says nothing
int? sdCppSegmentsOf(String line) {
  final match = _segments.firstMatch(line);
  return match == null ? null : int.parse(match.group(1) ?? match.group(2)!);
}

const _mib = 1024 * 1024;

/// A Vulkan device as the ggml of sd-cli lists it at its start: its index (`Vulkan<index>`), its name, its driver, and
/// uma for an integrated chip, which shares the memory of the computer
typedef GgmlVulkanDevice = ({int index, String name, String driver, bool uma});

/// "ggml_vulkan: 1 = NVIDIA GeForce RTX 4060 Laptop GPU (NVIDIA) | uma: 0 | fp16: 1 | ..." (ggml_vk_print_gpu_info of
/// ggml a5915eb): the name greedy, so that a name with parentheses of its own keeps them ("Intel(R) RaptorLake-S Mobile
/// Graphics Controller (Intel Corporation)", "AMD Radeon RX 7600 (RADV NAVI33) (radv)"), the driver in the last
/// parentheses before "| uma"
final _ggmlDevice = RegExp(r'^ggml_vulkan: (\d+) = (.+) \(([^()]*)\) \| uma: (\d+)');

/// "ggml_vulkan: Found 2 Vulkan devices:", before the list
final _ggmlCount = RegExp(r'^ggml_vulkan: Found (\d+) Vulkan devices?:');

/// The device a line of sd-cli's list names; null for any other line
GgmlVulkanDevice? ggmlVulkanDeviceOf(String line) {
  final match = _ggmlDevice.firstMatch(line);
  if (match == null) {
    return null;
  }
  final [index, name, driver, uma] = [for (var group = 1; group <= 4; group++) match.group(group)!];
  return (index: int.parse(index), name: name, driver: driver, uma: uma != '0');
}

/// How many devices the list of sd-cli holds, from the line before it ("Found 2 Vulkan devices:"), 0 when ggml found
/// none ("ggml_vulkan: No devices found."); null for any other line
int? ggmlVulkanCountOf(String line) {
  if (line.startsWith('ggml_vulkan: No devices found')) {
    return 0;
  }
  final match = _ggmlCount.firstMatch(line);
  return match == null ? null : int.parse(match.group(1)!);
}

/// A card of the auto-fit plan sd-cli writes before it loads its weights, "[I]     Vulkan1      NVIDIA GeForce RTX 4060
/// Laptop GPU free   7188 MiB, budget   3072 MiB --- backend_fit.cpp:328": the name greedy up to the last "free" of
/// the line (the name of a card holds no figure in MiB), padded to 32 columns when shorter
final _plan = RegExp(r'^\[I\]\s+(Vulkan\d+)\s+(?:(.*\S)\s+)?free\s+(\d+) MiB, budget\s+(\d+) MiB');

/// What a line of the auto-fit plan says of one card: its device ("Vulkan1"), its name ('' when the line has none), and
/// in bytes the memory free and the budget sd-cli plans with (the free memory less its reserve of 512 MiB, or the one
/// --max-vram gives, capped at the free memory); null for any other line
({String device, String name, int free, int budget})? sdCppPlanCardOf(String line) {
  final match = _plan.firstMatch(line);
  if (match == null) {
    return null;
  }
  return (
    device: match.group(1)!,
    name: match.group(2) ?? '',
    free: int.parse(match.group(3)!) * _mib,
    budget: int.parse(match.group(4)!) * _mib,
  );
}

/// What sd-cli read of the memory of the card [device] ("Vulkan1"), from the line of its auto-fit plan for that card:
/// the bytes free and the budget it plans with; null for any other line
({int free, int budget})? sdCppCardMemoryOf(String line, String device) {
  final plan = sdCppPlanCardOf(line);
  return plan == null || plan.device != device ? null : (free: plan.free, budget: plan.budget);
}

/// The placement the auto-fit of sd-cli settled on, "[I] auto-fit: --backend "diffusion=Vulkan1,vae=Vulkan1,te=CPU"
/// --params-backend "te=cpu" --- backend_fit.cpp:477"
final _placement = RegExp(r'^\[I\] auto-fit: (--backend .*?)(?: --- \S+)?$');

/// The variable of ggml that limits the devices it lists, each number an index into the Vulkan devices of sd-cli's own
/// process (ggml a5915eb, ggml-vulkan.cpp 5304 to 5322): the app never sets it, a user may have
const _visibleDevices = 'GGML_VK_VISIBLE_DEVICES';

/// What sd-cli's own list says of the chosen card ([sdCppDeviceVerdict])
enum SdCppDeviceAction {
  /// The card is the device sd-cli was given: the run goes on
  run,

  /// The card is another device: the run is stopped and started again on it
  restart,

  /// The card is not listed, or only an integrated chip stands where a dedicated card was chosen
  refuse,
}

/// The verdict on a list: what to do, the device that is the card (run, restart), whether it was taken by its kind with
/// no name matching, and the words of a refusal
class SdCppDeviceVerdict {
  const SdCppDeviceVerdict(this.action, {this.device, this.byKind = false, this.refusal});

  final SdCppDeviceAction action;
  final GgmlVulkanDevice? device;
  final bool byKind;
  final String? refusal;
}

final _spaces = RegExp(r'\s+');

/// A card name as it is compared: its spaces trimmed and collapsed, its case ignored
String _cardName(String name) => name.trim().replaceAll(_spaces, ' ').toLowerCase();

bool _sameName(String a, String b) => _cardName(a) == _cardName(b);

/// The devices of a list as the log and the messages say them
String _listOf(List<GgmlVulkanDevice> listed) {
  if (listed.isEmpty) {
    return 'no Vulkan device';
  }
  final said = [for (final device in listed) '${device.index} = ${device.name}${device.uma ? ', integrated' : ''}'];
  return said.join('; ');
}

/// The verdict on the list sd-cli printed ([listed]) for the [card] the gate chose, sd-cli having been given the
/// device [given] (see the top of this file): the devices of the card's name, case and spaces aside, and of its kind
/// (uma for an integrated chip, never for a dedicated card); when no name matches and the card is dedicated, the only
/// dedicated device listed, a driver that names the card otherwise ([SdCppDeviceVerdict.byKind]). [given] among them:
/// run; otherwise the first of them: restart; none: refuse, the message naming the card, the list and [visibleDevices],
/// the GGML_VK_VISIBLE_DEVICES of the user when set.
SdCppDeviceVerdict sdCppDeviceVerdict(
  List<GgmlVulkanDevice> listed,
  SdCppCard card,
  int given, {
  String? visibleDevices,
}) {
  var found = listed.where((device) => _sameName(device.name, card.name) && device.uma == card.integrated).toList();
  var byKind = false;
  if (found.isEmpty && !card.integrated) {
    final dedicated = listed.where((device) => !device.uma).toList();
    if (dedicated.length == 1) {
      found = dedicated;
      byKind = true;
    }
  }
  if (found.isEmpty) {
    final kind = card.integrated ? 'integrated chip' : 'dedicated card';
    final limited = visibleDevices != null && visibleDevices.trim().isNotEmpty;
    final limit = limited ? '; $_visibleDevices=$visibleDevices is set, which limits the devices it lists' : '';
    return SdCppDeviceVerdict(
      SdCppDeviceAction.refuse,
      refusal: 'sd-cli does not list the chosen $kind, ${card.name}: it lists ${_listOf(listed)}$limit',
    );
  }
  final mine = found.where((device) => device.index == given).firstOrNull;
  if (mine != null) {
    return SdCppDeviceVerdict(SdCppDeviceAction.run, device: mine, byKind: byKind);
  }
  return SdCppDeviceVerdict(SdCppDeviceAction.restart, device: found.first, byKind: byKind);
}

/// sd-cli lists the chosen card at another index than the one it was given: its run is stopped, to start again on
/// [index] (gpuUnavailable if it ever left the runner, which never lets it)
class SdCppWrongDevice extends BackendException {
  const SdCppWrongDevice(this.index, String message) : super(ImmersiveErrorCode.gpuUnavailable, message);

  final int index;
}

/// The graphics card of one job, shared by its generator and its upscaler (DesktopPanoramaEngine.sdCppEngineFor): the
/// index sd-cli is given, first the guess of the probe ([SdCppSettings.device]) or the index sd-cli listed the same
/// card at earlier in this session (the same sd-cli, the same card name), then the one its own list gives the card
class SdCppDevice {
  SdCppDevice(this.settings) {
    final card = settings.card;
    final learned = card == null ? null : _learned[(settings.sdCli, card.name)];
    _index = learned ?? guess;
    if (card != null && learned != null && learned != guess) {
      _log.info(
        'sd-cli listed ${card.name} as Vulkan$learned earlier in this session: started there, not on Vulkan$guess',
      );
    }
  }

  /// The program, the card it must run on, and the guess of the probe
  final SdCppSettings settings;

  /// The index the order of the probe gives the card, from [SdCppSettings.device]
  int get guess => int.parse(settings.device.substring('Vulkan'.length));

  late int _index;

  /// Whether a list or a plan of sd-cli confirmed the card in this job: the next runs of the job say nothing more of it
  var _settled = false;

  /// Whether the job warned once that the card could not be checked
  var _warned = false;

  /// The index of the card in sd-cli's own list, as far as known
  int get index => _index;

  /// The device as sd-cli takes it, "Vulkan1"
  String get name => 'Vulkan$_index';

  /// The index sd-cli listed each card at in this session, by the path of sd-cli and the name of the card
  static final _learned = <(String, String), int>{};

  /// Forgets what the session learned
  @visibleForTesting
  static void forgetLearned() => _learned.clear();

  void _settle(int index) {
    _index = index;
    _settled = true;
    final card = settings.card;
    if (card != null) {
      _learned[(settings.sdCli, card.name)] = index;
    }
  }
}

/// What one run of sd-cli tells of its card: its list as it starts, and the line of its auto-fit plan for the device it
/// was given (see the top of this file)
class _DeviceCheck {
  _DeviceCheck(this.device, {required this.visibleDevices}) : given = device.index;

  final SdCppDevice device;

  /// The index this run was given
  final int given;
  final String? visibleDevices;
  final _listed = <GgmlVulkanDevice>[];
  int? _count;

  /// Whether the card of this run is decided: by the list, by the plan when no list came, or left unchecked
  var _decided = false;

  /// The device the list confirmed in this run
  GgmlVulkanDevice? _taken;

  /// The name the plan gave the device of this run before the list came
  String? _planned;

  SdCppCard? get _card => device.settings.card;

  /// Each line of the run: a failure to stop it with, or null to go on
  BackendException? read(String line) {
    final card = _card;
    if (card == null) {
      return null;
    }
    final count = ggmlVulkanCountOf(line);
    if (count != null) {
      _count = count;
      return count == 0 && !_decided ? _decide(card) : null;
    }
    final listed = ggmlVulkanDeviceOf(line);
    if (listed != null) {
      if (!_decided) {
        _listed.add(listed);
        if (_listed.length == _count) {
          return _decide(card);
        }
      }
      return null;
    }
    final plan = sdCppPlanCardOf(line);
    if (plan == null || plan.device != 'Vulkan$given') {
      return null;
    }
    final taken = _taken;
    if (taken != null) {
      return _sameName(plan.name, taken.name) ? null : _plannedOther(plan.name, taken.name);
    }
    // Decided with the list (it may come later on the other output), or when the work starts without one
    _planned ??= plan.name;
    return null;
  }

  /// When the work starts ("generating image", "upscaling from") or the run ended well: the card decided by the list
  /// that came without its count, by the plan when no list came, or else left unchecked (one warning a job); a failure
  /// to stop the run with, or null
  BackendException? atWork() {
    final card = _card;
    if (card == null || _decided) {
      return null;
    }
    if (_listed.isNotEmpty) {
      return _decide(card);
    }
    _decided = true;
    final planned = _planned;
    if (planned == null) {
      if (!device._settled && !device._warned) {
        device._warned = true;
        _log.warning(
          'sd-cli did not list its devices: the card could not be checked (${card.name}, given Vulkan$given)',
        );
      }
      return null;
    }
    if (!_sameName(planned, card.name)) {
      return _plannedOther(planned, card.name);
    }
    if (!device._settled) {
      _log.info('sd-cli did not list its devices; its auto-fit plan names the chosen card, ${card.name}, Vulkan$given');
    }
    device._settle(given);
    return null;
  }

  BackendException? _decide(SdCppCard card) {
    _decided = true;
    final verdict = sdCppDeviceVerdict(_listed, card, given, visibleDevices: visibleDevices);
    final chosen = verdict.device;
    if (chosen == null) {
      return BackendException(ImmersiveErrorCode.gpuUnavailable, verdict.refusal ?? 'sd-cli lists no ${card.name}');
    }
    final said = _listOf(_listed);
    if (verdict.action == SdCppDeviceAction.restart) {
      return SdCppWrongDevice(chosen.index, said);
    }
    _taken = chosen;
    if (!device._settled) {
      if (verdict.byKind) {
        _log.warning(
          'sd-cli lists no card named ${card.name}: its only dedicated one, ${chosen.name}, is taken as '
          'Vulkan${chosen.index} ($said)',
        );
      } else {
        _log.info('sd-cli lists the chosen card, ${card.name}, as Vulkan${chosen.index} ($said)');
      }
    }
    device._settle(chosen.index);
    final planned = _planned;
    return planned == null || _sameName(planned, chosen.name) ? null : _plannedOther(planned, chosen.name);
  }

  /// The plan of the device of this run names [planned], not the [expected] card
  BackendException _plannedOther(String planned, String expected) => BackendException(
    ImmersiveErrorCode.gpuUnavailable,
    'The auto-fit plan of sd-cli names Vulkan$given $planned, not the chosen card, $expected',
  );
}

/// The log of the runs of sd-cli of a job, `<work>/logs/sd-cli.log`, which PanoramaEngine copies after a failure; null
/// when its folder cannot be made, the runs going on without it
File? sdCppLogOf(String workFolder) {
  try {
    final logs = Directory(p.join(workFolder, 'logs'))..createSync(recursive: true);
    return File(p.join(logs.path, 'sd-cli.log'));
  } on FileSystemException {
    return null;
  }
}

/// The line before a run in [log]: when it starts, the device and the attempt, what it makes, and its command
void _logRun(File? log, String head, ProcessLaunch launch) {
  if (log == null) {
    return;
  }
  try {
    log.writeAsStringSync(
      '===== ${DateTime.now().toIso8601String()} $head =====\n${launch.executable} ${launch.arguments.join(' ')}\n',
      mode: FileMode.append,
    );
  } on FileSystemException {
    // The run goes on without its line
  }
}

/// "[W] model manager cannot make enough memory available on Vulkan1: need 2896.82 MB device / 2492.82 MB budget,
/// available 6705.71 MB device / 2478.82 MB budget --- model_manager.cpp:2018" (the measure of 5 November 2026 below
/// the floor; "unlimited budget" without one, M3); ggml's MB are MiB
final _short = RegExp(
  r'cannot make enough memory available on (Vulkan\d+): need ([\d.]+) MB device / ([\d.]+) MB budget, '
  r'available ([\d.]+) MB device / (?:([\d.]+) MB|unlimited) budget',
);

/// How many bytes sd-cli was short of on the card [device] for the part it could not place, from the line of its model
/// manager: the larger shortfall of the card itself and of the budget, at least one byte; null for any other line. Its
/// figures have two decimals: read as hundredths of a MiB, so that 2492.82 less 2478.82 is 14 MiB to the byte.
int? sdCppShortOf(String line, String device) {
  final match = _short.firstMatch(line);
  if (match == null || match.group(1) != device) {
    return null;
  }
  int hundredths(int group) {
    final [whole, ...decimals] = match.group(group)!.split('.');
    return int.parse(whole) * 100 + (decimals.isEmpty ? 0 : int.parse(decimals.first.padRight(2, '0').substring(0, 2)));
  }

  final card = hundredths(2) - hundredths(4);
  final budget = match.group(5) == null ? card : hundredths(3) - hundredths(5);
  return math.max(1, (math.max(card, budget) * _mib + 99) ~/ 100);
}

String _decimal(double value) => value.toString();

/// The VAE's 2D convolution on its direct path whatever sd-cli times at its start, the other modules on its own choice
/// (the form of the pinned build's help: "on|off|auto or diffusion/vae/controlnet assignments")
const sdCppConvDirect = 'auto,vae=on';

/// [bytes] as --max-vram takes them: GiB with four decimals, rounded down so that sd-cli never plans with more than it
/// was given ("2.7343" for 2 800 MiB; the measure of 5 November 2026 gave "2.7344", "3", "4"). A single value is the
/// budget of every card sd-cli sees, as the measure ran it: the generator uses the one --backend names. sd-cli takes
/// the smaller of it and the free memory it reads, with no reserve of its own.
String sdCppVramBudget(int bytes) {
  final tenThousandths = bytes * 10000 ~/ (1024 * _mib);
  return '${tenThousandths ~/ 10000}.${'${tenThousandths % 10000}'.padLeft(4, '0')}';
}

/// The arguments of one generation, frozen (M3, section 9, point 4); --max-vram when the request carries a budget, which
/// the queue gives on Windows only (GeneratorRequest.graphicsBudget); on [device], [SdCppSettings.device] by default
List<String> sdCppGenerationArguments(SdCppSettings settings, GeneratorRequest request, {String? device}) {
  final models = settings.models;
  final vulkan = device ?? settings.device;
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
    'diffusion=$vulkan,vae=$vulkan,te=CPU',
    if (request.graphicsBudget case final budget?) ...['--max-vram', sdCppVramBudget(budget)],
    '--flash-attn',
    'on',
    '--conv-direct',
    sdCppConvDirect,
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

/// The arguments of one upscale by Real-ESRGAN x4plus on the same card, [device] or [SdCppSettings.device]
List<String> sdCppUpscaleArguments(SdCppSettings settings, UpscaleRequest request, {String? device}) => [
  '-M',
  'upscale',
  '-i',
  request.inputPath,
  '--upscale-model',
  settings.models.upscaler,
  '--backend',
  device ?? settings.device,
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

/// sd-cli on the card of its job ([device]) to its end, read as it goes: stopped as soon as its list puts the chosen
/// card at another index, and started again there once; a second time, the card is refused (see the top of this file).
/// [onStart] at the start of each run, [onLine] for each line the check of the card lets through, with the device of
/// the run; [what] in the line before each run in the log of the job.
Future<void> _sdCppRunOn(
  SdCppDevice device, {
  required ProcessRunner runner,
  required List<String> Function(String vulkan) arguments,
  required String workFolder,
  required String what,
  required NativeCancelFlag cancel,
  required Duration Function() elapsed,
  required BackendException? Function(String line, String vulkan, _DeviceCheck check) onLine,
  void Function()? onStart,
}) async {
  final settings = device.settings;
  final log = sdCppLogOf(workFolder);
  final visible = settings.environment[_visibleDevices] ?? Platform.environment[_visibleDevices];
  for (var attempt = 1; ; attempt++) {
    final vulkan = device.name;
    final check = _DeviceCheck(device, visibleDevices: visible);
    final launch = ProcessLaunch(
      executable: settings.sdCli,
      arguments: arguments(vulkan),
      workingDirectory: workFolder,
      environment: settings.environment,
    );
    onStart?.call();
    _logRun(log, 'sd-cli on $vulkan, attempt $attempt: $what', launch);
    try {
      await SidecarRun(
        runner: runner,
        program: sdCppProgram,
        launch: launch,
        cancel: cancel,
        elapsed: elapsed,
        stallTimeout: settings.stallTimeout,
        pollInterval: settings.pollInterval,
        log: log,
        onLine: (line, {required isError}) => check.read(line) ?? onLine(line, vulkan, check),
      ).run();
    } on SdCppWrongDevice catch (wrong) {
      final card = settings.card?.name ?? 'the card';
      if (cancel.isCancelled) {
        throw const BackendException(ImmersiveErrorCode.cancelled, 'Cancelled');
      }
      if (attempt > 1) {
        throw BackendException(
          ImmersiveErrorCode.gpuUnavailable,
          'sd-cli still lists $card as Vulkan${wrong.index} once started again on $vulkan (${wrong.message})',
        );
      }
      _log.warning(
        'sd-cli lists $card as Vulkan${wrong.index}, not $vulkan: started again on Vulkan${wrong.index} '
        '(${wrong.message})',
      );
      device._index = wrong.index;
      continue;
    }
    // Ended well before the work said it started: what can still be said of its card
    if (check.atWork() case final failure?) {
      _log.warning(failure.message);
    }
    return;
  }
}

/// The generator of a panorama: klein base 4B with the 360 ERP LoRA, through sd-cli
class SdCppGenerator implements GeneratorBackend {
  SdCppGenerator({
    required this.runner,
    required this.settings,
    required this.generatorSha256,
    required this.loraSha256,
    SdCppDevice? device,
    Duration Function()? elapsed,
    this.checkImages = true,
  }) : device = device ?? SdCppDevice(settings),
       _elapsed = elapsed ?? sidecarStopwatch();

  final ProcessRunner runner;
  final SdCppSettings settings;

  /// The card of the job, shared with its upscaler ([SdCppDevice])
  final SdCppDevice device;
  final Duration Function() _elapsed;

  /// Whether the image is checked once written (the tests of the process alone leave it out)
  final bool checkImages;

  @override
  final String generatorSha256;

  @override
  final String loraSha256;

  /// The arguments of [request], as sd-cli gets them on the card of the job as far as known
  List<String> argumentsOf(GeneratorRequest request) =>
      sdCppGenerationArguments(settings, request, device: device.name);

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
    // The shortfall of the model manager's last line, which sd-cli may recover from, and the one of the line right
    // before the segment that failed: the shortfall it failed with
    int? lastShort;
    int? short;
    // A budget given (Windows): sd-cli's free memory is Vulkan's figure there, which leaves other programs out
    final given = request.graphicsBudget != null ? ' given by the app' : '';
    String said(String vulkan) => read == null
        ? 'what it read of the card unknown'
        : '${read!.free ~/ _mib} MiB free read on $vulkan, budget ${read!.budget ~/ _mib} MiB$given';
    try {
      await _sdCppRunOn(
        device,
        runner: runner,
        arguments: (vulkan) => sdCppGenerationArguments(settings, request, device: vulkan),
        workFolder: request.workFolder,
        what: 'generation, seed ${request.seed}',
        cancel: cancel,
        elapsed: _elapsed,
        onStart: () {
          sampling = false;
          done = 0;
          segments = 1;
          read = null;
          lastShort = null;
          short = null;
        },
        onLine: (line, vulkan, check) {
          if (sdCppShortOf(line, vulkan) case final lacking?) {
            lastShort = lacking;
            return null;
          }
          if (line.contains(sdCppFailedSegmentText)) {
            short ??= lastShort;
            return null;
          }
          final plan = sdCppPlanCardOf(line);
          if (plan != null) {
            if (plan.device == vulkan) {
              read = (free: plan.free, budget: plan.budget);
              final named = plan.name.isEmpty ? '' : ' (${plan.name})';
              _log.info(
                'sd-cli read ${plan.free ~/ _mib} MiB free on $vulkan$named, budget ${plan.budget ~/ _mib} MiB$given'
                '${given.isEmpty ? '' : _givenWhy}',
              );
            }
            return null;
          }
          if (_placement.firstMatch(line) case final placed?) {
            _log.info('sd-cli auto-fit: ${placed.group(1)}');
            return null;
          }
          // The graph cut into segments: the run goes on, slower, the same image (see the top of this file); back to
          // one when the live check of sd-cli allows it
          final cut = sdCppSegmentsOf(line);
          if (cut != null) {
            if (cut != segments) {
              segments = cut;
              _log.info(
                cut > 1
                    ? 'sd-cli runs the generator in $cut segments (${said(vulkan)}): slower, the same image'
                    : 'sd-cli runs the generator whole again (${said(vulkan)})',
              );
            }
            return null;
          }
          if (line.contains('generating image')) {
            sampling = true;
            return check.atWork();
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
      );
    } on BackendException catch (error) {
      // Short of memory even in segments: what sd-cli read goes first, for the panel and the log
      if (error.code != ImmersiveErrorCode.gpuOutOfMemory || (read == null && short == null)) {
        rethrow;
      }
      final memory = GeneratorMemoryRead(free: read?.free, budget: read?.budget, short: short);
      _log.warning(
        'sd-cli ran out of the memory of ${device.name} in $segments segment${segments == 1 ? '' : 's'}: '
        '${memory.message}',
      );
      throw BackendException(ImmersiveErrorCode.gpuOutOfMemory, '${memory.message}\n${error.message}');
    }
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
  SdCppUpscaler({
    required this.runner,
    required this.settings,
    required this.modelSha256,
    SdCppDevice? device,
    Duration Function()? elapsed,
  }) : device = device ?? SdCppDevice(settings),
       _elapsed = elapsed ?? sidecarStopwatch();

  final ProcessRunner runner;
  final SdCppSettings settings;

  /// The card of the job, the one its generator settled ([SdCppDevice])
  final SdCppDevice device;
  final Duration Function() _elapsed;

  @override
  final String modelSha256;

  List<String> argumentsOf(UpscaleRequest request) => sdCppUpscaleArguments(settings, request, device: device.name);

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
    await _sdCppRunOn(
      device,
      runner: runner,
      arguments: (vulkan) => sdCppUpscaleArguments(settings, request, device: vulkan),
      workFolder: request.workFolder,
      what: 'upscale x${request.scale}',
      cancel: cancel,
      elapsed: _elapsed,
      onStart: () {
        tiling = false;
        done = 0;
      },
      onLine: (line, vulkan, check) {
        if (line.contains('upscaling from')) {
          tiling = true;
          return check.atWork();
        }
        final bar = tiling ? sdCppBarOf(line) : null;
        if (bar != null && bar.step > done) {
          done = bar.step;
          onProgress?.call(bar);
        }
        return null;
      },
    );
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
