// The real probe of the graphics cards (lot C6; design-final 2026-10-27, sections 4.7 and 10.1 point 7), never in the
// suite: IMMUCH360_GPU_PROBE_REAL names a built app (immuch360.exe of the Windows build, the immuch360 of the Linux
// bundle), started with its flag as the app starts it. It must answer within its time without crashing; what it found
// is printed. The jobs of the CI start it on runners without a graphics card (no Vulkan, or a processor through
// llvmpipe); on the PC of the owner it finds the RTX 4060, on ai1 the Iris Xe of Mesa, refused then taken by "Try on
// integrated graphics (untested)". IMMUCH360_GPU_PROBE_EXPECT, when set, is a part of the name the probe must find.

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/gpu/gpu_probe.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';

final _app = Platform.environment['IMMUCH360_GPU_PROBE_REAL'];
final _expected = Platform.environment['IMMUCH360_GPU_PROBE_EXPECT'];

class _NoFiles implements AiComponentFiles {
  @override
  Future<File?> verifiedFile(AiComponent component) async => null;

  @override
  AiComponentState stateOf(AiComponent component) => AiComponentState.notInstalled;
}

/// The reasons that come from the graphics card itself
const _cardReasons = {AiGateReason.gpuNone, AiGateReason.gpuNoAnswer, AiGateReason.gpuIntegrated};

void main() {
  test('the built app answers its flag within its time, and the gate reads its answer', () async {
    final app = File(_app!).absolute.path;
    final watch = Stopwatch()..start();
    final report = await ProcessGpuProbe(executable: app).probe();
    watch.stop();
    stdout.writeln('The probe of $app answered in ${watch.elapsedMilliseconds} ms:');
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));

    expect(report.problem, isNot(GpuProbeProblem.noAnswer), reason: 'the probe must answer within 10 s');
    expect(report.problem, isNot(GpuProbeProblem.failed), reason: 'the probe must write its answer and not crash');
    expect(watch.elapsed, lessThan(gpuProbeTimeout));
    final expected = _expected;
    if (expected != null && expected.isNotEmpty) {
      expect(gpuNameOf(report), contains(expected));
    }

    // The rules of the gate on that answer, the switch of the integrated graphics off then on
    final abi = Platform.isWindows ? Abi.windowsX64 : Abi.linuxX64;
    Future<AiGateResult> panorama({required bool integrated}) => HardwareGate(
      components: _NoFiles(),
      facts: () => AiHardwareFacts(abi: abi, processors: Platform.numberOfProcessors, physicalMemory: 32 << 30),
      gpu: _Answer(report),
      integratedGpuAllowed: () async => integrated,
    ).evaluate(feature: AiFeature.panorama);
    final off = await panorama(integrated: false);
    final on = await panorama(integrated: true);
    for (final (name, result) in [('switch off', off), ('switch on', on)]) {
      final card = result.gpu;
      final index = card == null ? null : ggmlVulkanIndexOf(report, card);
      stdout.writeln(
        'Gate, $name: ${result.reason?.name ?? 'available'}, card ${card?.name}, '
        'Vulkan${index ?? '?'} for ggml, ${card?.freeMemory} bytes free',
      );
    }
    if (off.gpu?.kind == GpuKind.integrated) {
      expect(off.reason, AiGateReason.gpuIntegrated);
      expect(_cardReasons, isNot(contains(on.reason)), reason: 'the switch lets the integrated graphics in');
    }
  }, skip: _app == null ? 'IMMUCH360_GPU_PROBE_REAL names no built app' : false);
}

/// The answer read above, given to the gate as its probe
class _Answer implements GpuProbe {
  const _Answer(this.report);

  final GpuReport report;

  @override
  Future<GpuReport> probe() async => report;
}
