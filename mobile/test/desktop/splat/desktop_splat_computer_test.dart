import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/splat/desktop_splat_computer.dart';
import 'package:immich_mobile/domain/models/splat/splat_computer.dart';
import 'package:immich_mobile/domain/services/splat_viewer_files.dart';

import '../ai/fakes/fake_gpu_probe.dart';

class _Memory implements MemoryProbe {
  const _Memory(this.physical);

  final int? physical;

  @override
  MemoryFacts read() => MemoryFacts(physical: physical);
}

/// Which chip draws the splat viewer on a computer (lot SVC): the renderer the page last named, the cards of the probe
/// with the graphics card setting of Windows (D2), the Macs; the memory read; the cards listed once per run.
void main() {
  const rtxRenderer = 'ANGLE (NVIDIA, NVIDIA GeForce RTX 4060 Laptop GPU (0x000028A0) Direct3D11 vs_5_0 ps_5_0, D3D11)';
  const intelRenderer = 'ANGLE (Intel, Intel(R) UHD Graphics (0x0000A788) Direct3D11 vs_5_0 ps_5_0, D3D11)';
  final rtx = SplatGpu(SplatGpuKind.dedicated, name: rtx4060Laptop.name, memory: rtx4060Laptop.localMemory);

  test('Windows, a laptop with two chips: the dedicated card with the setting on, the integrated chip without', () {
    expect(splatGpuOf(system: SplatDesktopSystem.windows, cards: FakeGpuReports.twoCards, highPerformance: true), rtx);
    expect(
      splatGpuOf(system: SplatDesktopSystem.windows, cards: FakeGpuReports.twoCards),
      SplatGpu(SplatGpuKind.integrated, name: irisXe.name),
    );
  });

  test('the renderer the page last named wins over the cards, with the memory of the card it names', () {
    expect(splatGpuOf(system: SplatDesktopSystem.windows, cards: FakeGpuReports.twoCards, renderer: rtxRenderer), rtx);
    // The setting asked the dedicated card, Windows gave the Intel (its own graphics setting for the app)
    expect(
      splatGpuOf(
        system: SplatDesktopSystem.windows,
        cards: FakeGpuReports.twoCards,
        renderer: intelRenderer,
        highPerformance: true,
      ).kind,
      SplatGpuKind.integrated,
    );
    // No list of the cards: a dedicated card of unknown memory
    expect(splatGpuOf(system: SplatDesktopSystem.windows, renderer: rtxRenderer).memory, isNull);
  });

  test('a computer with one dedicated card draws with it on every system; one with none keeps the integrated chip', () {
    for (final system in [SplatDesktopSystem.windows, SplatDesktopSystem.linux]) {
      expect(
        splatGpuOf(system: system, cards: FakeGpuReports.rtx4060),
        rtx,
        reason: '$system',
      );
      expect(splatGpuOf(system: system, cards: FakeGpuReports.integratedOnly).kind, SplatGpuKind.integrated);
    }
  });

  test(
    'Linux: WebKitGTK draws on the chip of the display, the integrated one of a laptop; its "Apple GPU" says nothing',
    () {
      expect(
        splatGpuOf(system: SplatDesktopSystem.linux, cards: FakeGpuReports.twoCards).kind,
        SplatGpuKind.integrated,
      );
      expect(splatGpuOf(system: SplatDesktopSystem.linux, cards: FakeGpuReports.rtx4060, renderer: 'Apple GPU'), rtx);
    },
  );

  test('a Mac shares its memory; no probe, no card: unknown', () {
    expect(splatGpuOf(system: SplatDesktopSystem.macos, renderer: 'Apple GPU').kind, SplatGpuKind.integrated);
    for (final report in [FakeGpuReports.noVulkan, FakeGpuReports.noDevice, FakeGpuReports.noAnswer, null]) {
      expect(splatGpuOf(system: SplatDesktopSystem.windows, cards: report, highPerformance: true), SplatGpu.unknown);
    }
  });

  group('the reader', () {
    late Directory folder;
    late SplatAnswerStore answers;

    setUp(() async {
      folder = await Directory.systemTemp.createTemp('desktop_splat_computer_test');
      answers = SplatAnswerStore(() async => File('${folder.path}/answers.json'));
    });

    tearDown(() => folder.delete(recursive: true));

    test('lists the cards once per run, reads the memory and the renderer kept for the setting of now', () async {
      final probe = FakeGpuProbe.of(FakeGpuReports.twoCards);
      var high = true;
      final reader = DesktopSplatComputer(
        probe: probe,
        answers: answers,
        highPerformance: () => high,
        memory: const _Memory(16 << 30),
        system: SplatDesktopSystem.windows,
      );
      expect(await reader.read(), SplatComputer(gpu: rtx, physicalMemory: 16 << 30));
      high = false;
      expect((await reader.read()).gpu.kind, SplatGpuKind.integrated);
      // The page then drew with the RTX without the setting (a desktop where Windows gives it): known from then on
      await answers.writeRenderer(rtxRenderer, highPerformance: false);
      expect((await reader.read()).gpu, rtx);
      expect(probe.calls, 1);
    });

    test(
      'a probe that failed is asked once more at the next splat; a chip the page named as integrated needs none',
      () async {
        final probe = FakeGpuProbe([FakeGpuReports.noAnswer, FakeGpuReports.twoCards, FakeGpuReports.noAnswer]);
        final reader = DesktopSplatComputer(
          probe: probe,
          answers: answers,
          highPerformance: () => true,
          memory: const _Memory(16 << 30),
          system: SplatDesktopSystem.windows,
        );
        expect((await reader.read()).gpu, SplatGpu.unknown);
        expect((await reader.read()).gpu, rtx);
        expect((await reader.read()).gpu, rtx);
        expect(probe.calls, 2, reason: 'the list kept once it answered');
        final quiet = FakeGpuProbe.of(FakeGpuReports.twoCards);
        await answers.writeRenderer(intelRenderer, highPerformance: true);
        final named = DesktopSplatComputer(
          probe: quiet,
          answers: answers,
          highPerformance: () => true,
          memory: const _Memory(16 << 30),
          system: SplatDesktopSystem.windows,
        );
        expect((await named.read()).gpu.kind, SplatGpuKind.integrated);
        expect(quiet.calls, 0, reason: 'no card woken for nothing');
      },
    );

    test(
      'a probe that fails leaves the chip unknown, which keeps the cap of the chips that share the memory',
      () async {
        final reader = DesktopSplatComputer(
          probe: _Failing(),
          answers: answers,
          highPerformance: () => true,
          memory: const _Memory(null),
          system: SplatDesktopSystem.linux,
        );
        final computer = await reader.read();
        expect(computer.gpu, SplatGpu.unknown);
        expect(computer.showsWhole, isFalse);
      },
    );
  });
}

class _Failing implements GpuProbe {
  @override
  Future<GpuReport> probe() async => throw const ProcessException('immuch360', []);
}
