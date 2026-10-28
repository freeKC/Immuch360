// The memory of the graphics card read again before a job on it (lot C6; design-final 2026-10-27, section 4.7, point
// 3): free enough, the job starts on the card the gate would take, with the answer it came from; held by other
// programs, the job waits with what is free; no card any more, it cannot run; each check starts the probe again.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/gpu/gpu_budget.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';

import '../fakes/fake_gpu_probe.dart';

const _gib = 1024 * 1024 * 1024;
const _mib = 1024 * 1024;

void main() {
  GpuBudget budget(FakeGpuProbe probe, {bool integrated = false}) =>
      GpuBudget(probe: probe.probe, integratedAllowed: () async => integrated);

  test('6 GiB free asked, after M3: 5.39 GiB for stable-diffusion.cpp, 512 MiB of reserve, a margin', () {
    expect(panoramaFreeGraphicsMemory, 6 * _gib);
    expect(budget(FakeGpuProbe.of(FakeGpuReports.rtx4060)).need, panoramaFreeGraphicsMemory);
  });

  test('the RTX 4060 with 7.2 GiB free: ready, on that card, with the answer it came from', () async {
    final check = await budget(FakeGpuProbe.of(FakeGpuReports.twoCards)).check();

    expect(check, isA<GpuBudgetReady>());
    final ready = check as GpuBudgetReady;
    expect(ready.card.name, rtx4060Laptop.name);
    expect(ready.free, 7400 * _mib);
    expect(ready.report.adapters, hasLength(2));
  });

  test('a game holds the card, 2.0 GiB free: the job waits, told what is free', () async {
    final check = await budget(FakeGpuProbe.of(FakeGpuReports.rtx4060Busy)).check();

    expect(check, isA<GpuBudgetWait>());
    expect((check as GpuBudgetWait).free, 2000 * _mib);
    expect(check.card.name, rtx4060Laptop.name);
  });

  test('the answer of the probe of Windows on the RTX 4060 while another program held 4.0 GiB: the job waits', () async {
    // V3, on the PC of the owner: the budget of Vulkan alone said 7.5 GB; the probe lowers it to what the counters of
    // Windows leave of the card (windows/runner/gpu_probe.cpp, DedicatedUsage)
    final report = GpuReport.fromJson(
      jsonDecode(File('test/fixtures/ai_immersive/gpu_probe_rtx4060_laptop_busy.json').readAsStringSync())
          as Map<String, Object?>,
    );
    final check = await budget(FakeGpuProbe.of(report)).check();

    expect(check, isA<GpuBudgetWait>());
    expect((check as GpuBudgetWait).card.name, rtx4060Laptop.name);
    expect(check.free, 4064452608);
  });

  test('just the memory asked is enough, a byte less waits', () async {
    GpuReport card(int free) => GpuReport(
      adapters: [
        GpuAdapter(
          name: 'Card',
          kind: GpuKind.discrete,
          localMemory: 8 * _gib,
          apiVersion: '1.3.0',
          budget: free,
          usage: 0,
        ),
      ],
    );
    expect(await budget(FakeGpuProbe.of(card(6 * _gib))).check(), isA<GpuBudgetReady>());
    expect(await budget(FakeGpuProbe.of(card(6 * _gib - 1))).check(), isA<GpuBudgetWait>());
  });

  test('a card without VK_EXT_memory_budget is taken at its memory: nothing tells it is busy', () async {
    const report = GpuReport(
      adapters: [GpuAdapter(name: 'Card', kind: GpuKind.discrete, localMemory: 8 * _gib, apiVersion: '1.2.0')],
    );
    expect(await budget(FakeGpuProbe.of(report)).check(), isA<GpuBudgetReady>());
  });

  test(
    'no card any more, the probe silent, or integrated graphics not allowed: unavailable, with the reason',
    () async {
      Future<AiGateReason?> reason(GpuReport report, {bool integrated = false}) async =>
          switch (await budget(FakeGpuProbe.of(report), integrated: integrated).check()) {
            GpuBudgetUnavailable(:final reason) => reason,
            _ => null,
          };

      expect(await reason(FakeGpuReports.noDevice), AiGateReason.gpuNone);
      expect(await reason(FakeGpuReports.noAnswer), AiGateReason.gpuNoAnswer);
      expect(await reason(FakeGpuReports.integratedOnly), AiGateReason.gpuIntegrated);
      expect(await reason(FakeGpuReports.integratedOnly, integrated: true), isNull);
    },
  );

  test('each check starts the probe again', () async {
    final probe = FakeGpuProbe([FakeGpuReports.rtx4060Busy, FakeGpuReports.rtx4060]);
    final checks = budget(probe);

    expect(await checks.check(), isA<GpuBudgetWait>());
    expect(await checks.check(), isA<GpuBudgetReady>());
    expect(probe.calls, 2);
  });
}
