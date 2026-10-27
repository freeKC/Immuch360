// Whether this computer can make 3D photos, and why not (spec 5.1 and 10.2; design-final 2026-10-26, section 2.9),
// evaluated before the button is offered: the button stays visible, greyed with its reason. In order:
//  1. the system and the processor: Windows x64, Linux x64, macOS on Apple silicon and on Intel (ONNX Runtime 1.23.2,
//     asked for API 23); Windows or Linux on another processor (ARM) is "not yet on this processor", any other system
//     "not on this system yet";
//  2. the physical memory: 4 GB at least (GlobalMemoryStatusEx, /proc/meminfo, sysctl hw.memsize; memory_probe.dart);
//  3. the AI components of this system, installed and intact: their size checked at each load, their SHA-256 at the
//     download (AiComponentsService, lot A3a);
//  4. ONNX Runtime loads: tried once per file in a short isolate, its message shown when it does not (a Linux too old
//     for it, a library the system refuses).
// The GPU is not looked at: phase 1 runs on the processor.

import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';

import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';

/// Why the gate refuses
enum AiGateReason {
  /// Not Windows, Linux nor macOS
  system('ai_immersive_unavailable_system'),

  /// Windows or Linux on a processor ONNX Runtime is not offered for here (ARM)
  processor('ai_immersive_unavailable_arm'),

  /// Less physical memory than [aiMinimumPhysicalMemory]
  memory('ai_immersive_unavailable_memory'),

  /// A component of this system is not installed (or is being downloaded, or waits for its removal)
  componentsMissing('ai_immersive_unavailable_missing'),

  /// A component is installed but its file is gone or no longer has its size: to download again
  componentsDamaged('ai_immersive_unavailable_damaged'),

  /// ONNX Runtime does not load here: the text takes its message ({message})
  runtimeFailed('ai_immersive_failed_model');

  const AiGateReason(this.textKey);

  /// The key of i18n/en.json the screens show
  final String textKey;
}

/// What the gate found
class AiGateResult {
  const AiGateResult._({
    this.reason,
    this.message,
    this.platform,
    this.runtimeFile,
    this.modelFile,
    this.runtimeVersion,
    this.missing = const [],
    this.physicalMemory,
    required this.processors,
  });

  /// Null when the AI features can run
  final AiGateReason? reason;

  /// The message of ONNX Runtime or of the system, for [AiGateReason.runtimeFailed]
  final String? message;

  /// The AI platform of this computer, null on a system the AI features do not know
  final AiPlatform? platform;

  /// The files the engine runs, when available
  final File? runtimeFile;
  final File? modelFile;

  /// The version ONNX Runtime gave, when it loaded
  final String? runtimeVersion;

  /// The components to install or download again
  final List<AiComponent> missing;

  /// For the line of the settings: "{processors} logical processors, {memory} of memory"
  final int? physicalMemory;
  final int processors;

  bool get isAvailable => reason == null;

  @override
  String toString() => 'AiGateResult(${reason?.name ?? 'available'}${message == null ? '' : ': $message'})';
}

/// The hardware the gate looks at; the tests give their own
class AiHardwareFacts {
  const AiHardwareFacts({required this.abi, required this.processors, this.physicalMemory});

  /// This computer
  factory AiHardwareFacts.ofThisComputer({MemoryProbe memory = const SystemMemoryProbe()}) => AiHardwareFacts(
    abi: Abi.current(),
    processors: Platform.numberOfProcessors,
    physicalMemory: memory.read().physical,
  );

  /// The system and the processor the app runs on
  final Abi abi;
  final int processors;

  /// Null when it could not be read: the gate then does not refuse on memory
  final int? physicalMemory;
}

const _platforms = {
  Abi.windowsX64: AiPlatform.windowsX64,
  Abi.linuxX64: AiPlatform.linuxX64,
  Abi.macosArm64: AiPlatform.macosArm64,
  Abi.macosX64: AiPlatform.macosX64,
};

/// The AI platform of [abi], null for one the AI features do not run on
AiPlatform? aiPlatformOf(Abi abi) => _platforms[abi];

/// Why [abi] is refused: "not yet on this processor" for Windows and Linux on another processor, "not on this system
/// yet" for the rest
AiGateReason refusalOf(Abi abi) {
  final name = abi.toString();
  return name.startsWith('windows') || name.startsWith('linux') ? AiGateReason.processor : AiGateReason.system;
}

/// What the gate asks of the AI components
abstract interface class AiComponentFiles {
  /// The file of [component] when it is installed and has its size, null otherwise
  Future<File?> verifiedFile(AiComponent component);

  AiComponentState stateOf(AiComponent component);
}

/// The components of AiComponentsService (lot A3a)
class ServiceComponentFiles implements AiComponentFiles {
  const ServiceComponentFiles(this.service);

  final AiComponentsService service;

  @override
  Future<File?> verifiedFile(AiComponent component) => service.verifiedFile(component);

  @override
  AiComponentState stateOf(AiComponent component) => service.statusOf(component).state;
}

/// What loading ONNX Runtime from a file gave: its version, or why it did not load
typedef RuntimeLoad = ({String? version, String? error});

/// Loads ONNX Runtime from [path] in a short isolate, never in the window's: the library stays loaded in the process
/// for the worker of the jobs
Future<RuntimeLoad> loadRuntimeInIsolate(String path) => Isolate.run(() {
  try {
    return (version: OrtRuntime.load(path).version, error: null);
  } on OrtException catch (error) {
    return (version: null, error: error.message);
  }
}, debugName: 'ai-runtime-check');

/// See the top of this file
class HardwareGate {
  HardwareGate({
    required this.components,
    AiHardwareFacts Function()? facts,
    Future<RuntimeLoad> Function(String path)? loadRuntime,
    this.minimumMemory = aiMinimumPhysicalMemory,
  }) : _facts = facts ?? AiHardwareFacts.ofThisComputer,
       _loadRuntime = loadRuntime ?? loadRuntimeInIsolate;

  final AiComponentFiles components;
  final AiHardwareFacts Function() _facts;
  final Future<RuntimeLoad> Function(String path) _loadRuntime;
  final int minimumMemory;

  /// One try per file, by its path, size and date: a file installed again is tried again
  final _loads = <String, Future<RuntimeLoad>>{};

  Future<AiGateResult> evaluate() async {
    final facts = _facts();
    final memory = facts.physicalMemory;
    final platform = aiPlatformOf(facts.abi);
    AiGateResult refused(AiGateReason reason, {String? message, List<AiComponent> missing = const []}) =>
        AiGateResult._(
          reason: reason,
          message: message,
          platform: platform,
          missing: missing,
          physicalMemory: memory,
          processors: facts.processors,
        );

    if (platform == null) {
      return refused(refusalOf(facts.abi));
    }
    if (memory != null && memory < minimumMemory) {
      return refused(AiGateReason.memory);
    }

    final files = <AiComponentKind, File>{};
    final missing = <AiComponent>[];
    var damaged = false;
    for (final component in aiComponentsFor(platform)) {
      final file = await components.verifiedFile(component);
      if (file != null) {
        files[component.kind] = file;
        continue;
      }
      missing.add(component);
      damaged = damaged || components.stateOf(component) == AiComponentState.damaged;
    }
    final runtime = files[AiComponentKind.runtime];
    final model = files[AiComponentKind.model];
    if (missing.isNotEmpty || runtime == null || model == null) {
      return refused(damaged ? AiGateReason.componentsDamaged : AiGateReason.componentsMissing, missing: missing);
    }

    final stat = runtime.statSync();
    final load = await (_loads['${runtime.path}|${stat.size}|${stat.modified.microsecondsSinceEpoch}'] ??= _loadRuntime(
      runtime.path,
    ));
    if (load.error != null) {
      return refused(AiGateReason.runtimeFailed, message: load.error);
    }
    return AiGateResult._(
      platform: platform,
      runtimeFile: runtime,
      modelFile: model,
      runtimeVersion: load.version,
      physicalMemory: memory,
      processors: facts.processors,
    );
  }
}
