// Where the depth model of the 3D videos runs (lot ai-360-3d-51, 23 Nov 2026): on the graphics card when this computer
// has one ONNX Runtime can use, else on the processor, which always works.
//
// What was found. The official ONNX Runtime 1.31.0 the app installs (ai-components-1) has the processor only on
// Windows and Linux; the Apple silicon build has Core ML built in. FreeKC's first 360 3D video (i9-13980HX, RTX 4060
// Laptop 8 GB beside Intel UHD Graphics) took 3.1 s a frame with the card at 6 %. Measured on that PC the same day,
// Video Depth Anything Small, one window of 32 frames of 392 x 392: 6.4 to 7.6 s on the processor (30 threads),
// 0.69 s with DirectML on the RTX 4060 (ONNX Runtime 1.24.4, DirectML.dll of Windows 1.15.5), largest difference
// 9e-6 of the depth range; and DirectML on the Intel UHD Graphics gave a wrong map (differences of 290 % of the
// range, at 112 x 112 as at 392 x 392). So a card is used only after a check against the processor.
//
// The choices:
// * Windows: DirectML, the provider of ONNX Runtime that runs on every DirectX 12 card (NVIDIA, AMD, Intel). The
//   library is onnxruntime.dll of the official package Microsoft.ML.OnnxRuntime.DirectML 1.24.4 (MIT, March 2026, the
//   last of that package: DirectML is in sustained engineering), which calls the DirectML.dll of Windows itself
//   (System32, 1.15.5 on Windows 11 24H2): the redistributable DirectML.dll is under a Microsoft licence the project
//   does not take, so it is never shipped. WebGPU (onnxruntime-webgpu 1.27.0, MIT) was tried: it needs dxil.dll of the
//   DirectX Shader Compiler (Microsoft licence) and ends the whole process without it. The card: the one Windows
//   names first for high performance (the dedicated card of a hybrid laptop), a software adapter never, unless the
//   user picked another in "This computer", or the processor.
// * macOS on Apple silicon: Core ML in the ML Program format, from the library the app has already.
// * Linux: the processor. CUDA needs gigabytes of NVIDIA libraries for NVIDIA cards only, and the WebGPU build has no
//   card of a Linux computer tried and ends the process when its shaders cannot be made.
//
// The session of a card is opened only after a check: the model run at 112 x 112 on a fixed picture by the card and
// by the processor of the same library, compared ([depthCheckTolerance]). Any failure (the library, the provider, the
// adapter, the check) leaves the processor with a line in the job log, and so does a card that fails during the job
// (video_app_runtime.dart): the window is run again on the processor and the job goes on there.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';

/// The choice of "This computer" (DesktopAiSettings.videoDepthDevice): the card of the system, the processor, or one
/// card by its name ([depthDeviceCardPrefix] then the name)
const depthDeviceAuto = 'auto';
const depthDeviceProcessor = 'processor';
const depthDeviceCardPrefix = 'card:';

/// The name of the provider of DirectML in GetEpDevices
const directMlEpName = 'DmlExecutionProvider';

/// The largest difference of the check, as a share of the range of the processor's depth: 2 %. A card that agrees
/// gives 1e-5 (the RTX 4060); the wrong one gave 2.9.
const depthCheckTolerance = 0.02;

/// The side of the picture of the check: a multiple of 14 (the patches of the model), small enough to cost a fraction
/// of a second on the processor
const depthCheckSide = 112;

/// What the app tries for the depth model on this computer
class DepthProviderPlan {
  const DepthProviderPlan(this.provider, {this.device, required this.why});

  final OrtProvider provider;

  /// The card chosen, null for the processor and for Core ML
  final OrtEpDeviceInfo? device;

  /// Why: a few words for the job log
  final String why;

  bool get isGraphicsCard => provider.isGraphicsCard;

  /// "DirectML on NVIDIA GeForce RTX 4060 Laptop GPU (adapter 1, 7956 MB)"
  String get title {
    final card = device;
    if (card == null) {
      return provider.kind == OrtProviderKind.coreMl ? 'Core ML (Apple GPU and Neural Engine)' : provider.title;
    }
    final memory = card.videoMemory;
    return '${provider.title} on ${card.description} (adapter ${card.dxgiAdapter}${memory == null ? '' : ', $memory'})';
  }
}

/// The plan for [choice] on this system: [windows], [appleSilicon], the devices the library of the card gives
/// ([devices], empty when it has none or none was loaded). [allowSoftware] lets the renderer of Windows on the processor
/// (WARP) count as a card: only for the CI, whose runners have no other.
DepthProviderPlan planDepthProvider({
  required String choice,
  required bool windows,
  required bool appleSilicon,
  List<OrtEpDeviceInfo> devices = const [],
  bool cardLibrary = true,
  bool allowSoftware = false,
}) {
  if (choice == depthDeviceProcessor) {
    return const DepthProviderPlan(OrtProvider.cpu, why: 'the processor, as chosen in This computer');
  }
  if (appleSilicon) {
    return const DepthProviderPlan(OrtProvider.coreMl, why: 'Core ML of this Mac');
  }
  if (!windows) {
    return const DepthProviderPlan(OrtProvider.cpu, why: 'no graphics card runtime for this system');
  }
  if (!cardLibrary) {
    return const DepthProviderPlan(OrtProvider.cpu, why: 'the DirectML runtime is not installed');
  }
  final cards = [
    for (final device in devices)
      if (device.epName == directMlEpName &&
          device.isGraphicsCard &&
          device.dxgiAdapter != null &&
          (allowSoftware || !device.isSoftware))
        device,
  ];
  if (cards.isEmpty) {
    return const DepthProviderPlan(OrtProvider.cpu, why: 'no graphics card DirectML can use');
  }
  if (choice.startsWith(depthDeviceCardPrefix)) {
    final name = choice.substring(depthDeviceCardPrefix.length);
    for (final card in cards) {
      if (card.description == name) {
        return DepthProviderPlan(OrtProvider.directMl(card.dxgiAdapter!), device: card, why: 'chosen in This computer');
      }
    }
  }
  // The order of the system for high performance, a dedicated card before an integrated one when it says nothing
  final ordered = [...cards]
    ..sort((a, b) {
      final byIndex = (a.highPerformanceIndex ?? 1 << 20).compareTo(b.highPerformanceIndex ?? 1 << 20);
      if (byIndex != 0) {
        return byIndex;
      }
      return (b.discrete ? 1 : 0).compareTo(a.discrete ? 1 : 0);
    });
  final card = ordered.first;
  final missing = choice.startsWith(depthDeviceCardPrefix)
      ? ' (${choice.substring(depthDeviceCardPrefix.length)} chosen in This computer is not there)'
      : '';
  return DepthProviderPlan(
    OrtProvider.directMl(card.dxgiAdapter!),
    device: card,
    why: 'the high performance card of Windows$missing',
  );
}

/// The cards "This computer" offers: those DirectML sees, the software renderer left out, in the order of the system
List<OrtEpDeviceInfo> depthCards(List<OrtEpDeviceInfo> devices) => [
  for (final device in devices)
    if (device.epName == directMlEpName && device.isGraphicsCard && device.dxgiAdapter != null && !device.isSoftware)
      device,
]..sort((a, b) => (a.highPerformanceIndex ?? 1 << 20).compareTo(b.highPerformanceIndex ?? 1 << 20));

/// The input of the check: 32 frames of [side] x [side], a pattern that moves, normalised as the model takes them
Float32List depthCheckInput({int side = depthCheckSide, int frames = 32}) {
  final plane = side * side;
  final data = Float32List(frames * 3 * plane);
  const mean = [0.485, 0.456, 0.406];
  const std = [0.229, 0.224, 0.225];
  for (var f = 0; f < frames; f++) {
    for (var y = 0; y < side; y++) {
      final v = y / side;
      for (var x = 0; x < side; x++) {
        final u = x / side;
        final base =
            0.5 +
            0.25 * math.sin(6 * u + 0.1 * f) * math.cos(4 * v) +
            (v > 0.6 + 0.1 * math.sin(3 * u + 0.05 * f) ? 0.2 : 0.0);
        for (var c = 0; c < 3; c++) {
          data[(f * 3 + c) * plane + y * side + x] = (base * (0.9 + 0.05 * c) - mean[c]) / std[c];
        }
      }
    }
  }
  return data;
}

/// How far [card] is from [processor]: the largest and the mean difference, as shares of the range of [processor];
/// infinite when a value is not a number or the sizes differ
({double largest, double mean}) depthDifference(Float32List card, Float32List processor) {
  if (card.length != processor.length || processor.isEmpty) {
    return (largest: double.infinity, mean: double.infinity);
  }
  var lo = double.infinity;
  var hi = -double.infinity;
  for (final value in processor) {
    lo = math.min(lo, value);
    hi = math.max(hi, value);
  }
  final span = hi - lo > 0 ? hi - lo : 1.0;
  var largest = 0.0;
  var sum = 0.0;
  for (var i = 0; i < card.length; i++) {
    final d = (card[i] - processor[i]).abs();
    if (!d.isFinite) {
      return (largest: double.infinity, mean: double.infinity);
    }
    largest = math.max(largest, d);
    sum += d;
  }
  return (largest: largest / span, mean: sum / card.length / span);
}

/// Whether every value of [values] is a number: a card that breaks may give NaN rather than an error
bool depthValuesFinite(Float32List values) {
  for (final value in values) {
    if (!value.isFinite) {
      return false;
    }
  }
  return true;
}

/// One window of the depth model with the fall back of a card that fails during the job: [run] on the card when
/// [onCard]; when it throws an [OrtException] that is not a stop, or gives values that are not numbers, [toProcessor]
/// is told why (it opens the processor and says so in the job log) and [run] is called again, on the processor now.
/// A stop (Cancel, Pause) is never a failure of the card.
Float32List runDepthWindow({
  required bool onCard,
  required Float32List Function() run,
  required void Function(String reason) toProcessor,
}) {
  if (!onCard) {
    return run();
  }
  String reason;
  try {
    final values = run();
    if (depthValuesFinite(values)) {
      return values;
    }
    reason = 'it gave values that are not numbers';
  } on OrtRunStopped {
    rethrow;
  } on OrtException catch (error) {
    reason = error.message;
  }
  toProcessor(reason);
  return run();
}

/// A percentage for the log: "0.0009 %"
String depthShare(double share) => share.isFinite ? '${(share * 100).toStringAsPrecision(2)} %' : 'not a number';

/// The session of the depth model a job runs, where it runs, and what the job log says of it
class DepthSession {
  DepthSession({required this.runtime, required this.session, required this.plan, required this.lines});

  final OrtRuntime runtime;
  OrtSession session;

  /// Where it runs now: after a failure of the card, the processor
  DepthProviderPlan plan;

  /// The lines for the job log, oldest first
  final List<String> lines;
}

/// Opens the depth model at [modelPath] for frames of [width] x [height]: on the card of [choice] when the library at
/// [cardLibrary] (Windows) or the processor library (Core ML on Apple silicon) gives one that passes the check, else
/// on the processor with the library at [processorLibrary]. [settings] gives the threads and the arena; [open] wraps
/// each opening (the lower priority of the threads). Never throws for the card: only when the processor fails too.
DepthSession openDepthSession({
  required String processorLibrary,
  String? cardLibrary,
  required String modelPath,
  required int width,
  required int height,
  required OrtSessionSettings settings,
  String choice = depthDeviceAuto,
  bool allowSoftware = false,
  OrtSession Function(OrtSession Function() open)? wrap,
  bool? windows,
  bool? appleSilicon,
}) {
  final lines = <String>[];
  final onWindows = windows ?? Platform.isWindows;
  final onAppleSilicon = appleSilicon ?? (Platform.isMacOS && _isArm64());
  OrtSession opened(OrtRuntime runtime, OrtSessionSettings given) {
    OrtSession open() => runtime.openSession(modelPath, settings: given);
    return wrap == null ? open() : wrap(open);
  }

  final dimensions = {'height': height, 'width': width};
  OrtRuntime? cardRuntime;
  var devices = const <OrtEpDeviceInfo>[];
  var cardLoaded = false;
  if (choice != depthDeviceProcessor) {
    final library = onWindows ? cardLibrary : (onAppleSilicon ? processorLibrary : null);
    if (onWindows && library == null) {
      lines.add('depth model: the DirectML runtime is not on this computer');
    } else if (library != null) {
      try {
        cardRuntime = OrtRuntime.load(library);
        cardLoaded = true;
        if (onWindows) {
          devices = cardRuntime.executionDevices();
          final cards = [
            for (final device in devices)
              if (device.epName == directMlEpName) device,
          ];
          lines.add(
            'graphics cards of DirectML (ONNX Runtime ${cardRuntime.version}): '
            '${cards.isEmpty ? 'none' : cards.map((card) => '${card.description} (adapter ${card.dxgiAdapter}, high performance order ${card.highPerformanceIndex}, ${card.videoMemory ?? 'memory not given'})').join('; ')}',
          );
        }
      } on OrtException catch (error) {
        lines.add('depth model: the runtime of the graphics card did not load: ${error.message}');
      }
    }
  }
  final plan = planDepthProvider(
    choice: choice,
    windows: onWindows,
    appleSilicon: onAppleSilicon,
    devices: devices,
    cardLibrary: cardLoaded,
    allowSoftware: allowSoftware,
  );
  if (plan.isGraphicsCard && cardRuntime != null) {
    final card = cardRuntime;
    OrtSession? checkCard;
    OrtSession? checkProcessor;
    try {
      final side = {'height': depthCheckSide, 'width': depthCheckSide};
      final watch = Stopwatch()..start();
      checkCard = opened(card, settings.copyWith(provider: plan.provider, fixedDimensions: side));
      checkProcessor = opened(card, settings.copyWith(provider: OrtProvider.cpu, fixedDimensions: side));
      final input = depthCheckInput();
      final shape = [1, 32, 3, depthCheckSide, depthCheckSide];
      final onCard = checkCard.run(input, shape).values;
      final onProcessor = checkProcessor.run(input, shape).values;
      final difference = depthDifference(onCard, onProcessor);
      checkCard.close();
      checkProcessor.close();
      checkCard = checkProcessor = null;
      final passed = difference.largest <= depthCheckTolerance;
      lines.add(
        'check of ${plan.title} against the processor at $depthCheckSide x $depthCheckSide: largest difference '
        '${depthShare(difference.largest)}, mean ${depthShare(difference.mean)} of the depth range '
        '(${watch.elapsedMilliseconds} ms): ${passed ? 'passed' : 'failed, the card gives another depth'}',
      );
      if (passed) {
        final session = opened(card, settings.copyWith(provider: plan.provider, fixedDimensions: dimensions));
        lines.add('depth model on the graphics card: ${plan.title}, ONNX Runtime ${card.version}, ${plan.why}');
        return DepthSession(runtime: card, session: session, plan: plan, lines: lines);
      }
    } on OrtException catch (error) {
      lines.add('depth model: ${plan.title} could not be used: ${error.message}');
    } finally {
      checkCard?.close();
      checkProcessor?.close();
    }
  }
  final runtime = OrtRuntime.load(processorLibrary);
  // As before this lot: the free dimensions left free on the processor
  final session = opened(runtime, settings.copyWith(provider: OrtProvider.cpu));
  final why = plan.isGraphicsCard ? 'the graphics card did not pass' : plan.why;
  lines.add('depth model on the processor: ONNX Runtime ${runtime.version}, ${settings.intraOpThreads} threads ($why)');
  return DepthSession(
    runtime: runtime,
    session: session,
    plan: DepthProviderPlan(OrtProvider.cpu, why: why),
    lines: lines,
  );
}

bool _isArm64() {
  final version = Platform.version;
  return version.contains('arm64') || version.contains('aarch64');
}
