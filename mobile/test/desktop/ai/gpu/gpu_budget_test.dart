// The memory of the graphics card read again before a job on it (lot C6; design-final 2026-10-27, section 4.7, point
// 3): free enough, the job starts on the card the gate would take, with the answer it came from; held by other
// programs, the job waits with what is free; no card any more, it cannot run; each check starts the probe again.
// Issue #13: a panorama starts from 3.5 GiB free with the full reference, whole from 5 716 MiB and in segments below
// (the measure of 5 November 2026), and a wait says what it needs and what the app itself holds of the card.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/gpu/gpu_budget.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/splat/brush_runner.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

import '../fakes/fake_gpu_probe.dart';

const _gib = 1024 * 1024 * 1024;
const _mib = 1024 * 1024;

void main() {
  GpuBudget budget(FakeGpuProbe probe, {bool integrated = false}) =>
      GpuBudget(probe: probe.probe, integratedAllowed: () async => integrated);

  test('3.5 GiB free with the full reference: the floor of the graph cut and a margin; whole from 5 716 MiB', () {
    // Measure of 5 November 2026, section 6: in segments down to 3 212 MiB free, a failure at 3 112, one segment from
    // 5 716 MiB (it cut at 5 701)
    expect(panoramaFreeGraphicsMemory, 3758096384);
    expect(panoramaFreeGraphicsMemory - 3212 * _mib, greaterThan(0.35 * _gib));
    expect(panoramaFreeGraphicsMemory, greaterThan(3112 * _mib));
    expect(panoramaWholeGraphicsMemory, 5716 * _mib);
    expect(panoramaGpuNeed.bytes, panoramaFreeGraphicsMemory);
    expect(panoramaGpuNeed.whole, panoramaWholeGraphicsMemory);
    expect(splatGpuNeed.whole, isNull, reason: 'a splat scene runs the same with any memory above its need');
    expect(budget(FakeGpuProbe.of(FakeGpuReports.rtx4060)).need, panoramaFreeGraphicsMemory);
  });

  test('the budget sd-cli plans with: the free memory read less its own reserve of 512 MiB', () {
    expect(panoramaGeneratorReserve, 512 * _mib);
    expect(panoramaGeneratorBudget(5530 * _mib), 5018 * _mib);
    expect(panoramaGeneratorBudget(panoramaFreeGraphicsMemory), 3 * _gib);
    expect(panoramaGeneratorBudget(512 * _mib), isNull);
    expect(panoramaGeneratorBudget(0), isNull);
  });

  test('the RTX 4060 with 7.2 GiB free: ready, on that card, with the answer it came from', () async {
    final check = await budget(FakeGpuProbe.of(FakeGpuReports.twoCards)).check();

    expect(check, isA<GpuBudgetReady>());
    final ready = check as GpuBudgetReady;
    expect(ready.card.name, rtx4060Laptop.name);
    expect(ready.free, 7400 * _mib);
    expect(ready.report.adapters, hasLength(2));
    expect(ready.whole, isTrue);
  });

  test('a game holds the card, 2.0 GiB free: the job waits, told what is free and what it needs', () async {
    final check = await budget(FakeGpuProbe.of(FakeGpuReports.rtx4060Busy)).check();

    expect(check, isA<GpuBudgetWait>());
    expect((check as GpuBudgetWait).free, 2000 * _mib);
    expect(check.card.name, rtx4060Laptop.name);
    expect(check.need, panoramaFreeGraphicsMemory);
    expect(check.appHolds, isNull, reason: 'the fake probe reads no share of the app');
  });

  group('a panorama starts from 3.5 GiB free, whole from 5 716 MiB', () {
    GpuReport card(int free, {int? app}) => GpuReport(
      adapters: [
        GpuAdapter(
          name: 'NVIDIA GeForce RTX 2060',
          kind: GpuKind.discrete,
          localMemory: 8 * _gib,
          vendorId: 0x10de,
          apiVersion: '1.3.277',
          budget: free,
          usage: 0,
          appMemory: app,
        ),
      ],
    );

    test('5 716 MiB free: whole; a byte less: in segments; 3.5 GiB: in segments; a byte less: a wait', () async {
      Future<GpuBudgetCheck> at(int free) => budget(FakeGpuProbe.of(card(free))).check();

      expect((await at(panoramaWholeGraphicsMemory) as GpuBudgetReady).whole, isTrue);
      expect((await at(panoramaWholeGraphicsMemory - 1) as GpuBudgetReady).whole, isFalse);
      expect((await at(panoramaFreeGraphicsMemory) as GpuBudgetReady).whole, isFalse);
      final wait = await at(panoramaFreeGraphicsMemory - 1) as GpuBudgetWait;
      expect(wait.need, panoramaFreeGraphicsMemory);
      expect(wait.free, panoramaFreeGraphicsMemory - 1);
    });

    test('issue #13: the RTX 2060 of 8 GB with 5.4 GiB free starts, in segments, with the full reference', () async {
      // His probe said 5.4 GiB free, Immuch360 holding 1 402 MiB of the card: desktop build 21 started it with the
      // reduced reference and stopped it at "flux using N segments"; the cut gives the same image (measure of 5
      // November 2026, his budget: 27 segments, 294 s on the RTX 4060)
      final check = await budget(FakeGpuProbe.of(card(5530 * _mib, app: 1402 * _mib))).check() as GpuBudgetReady;

      expect(check.whole, isFalse);
      expect(check.free, 5530 * _mib);
      expect(check.appHolds, 1402 * _mib);
    });

    test('the same card with 3.1 GiB free waits, told the 3.5 GiB it needs and the share of the app', () async {
      final check = await budget(FakeGpuProbe.of(card(3174 * _mib, app: 1402 * _mib))).check() as GpuBudgetWait;

      expect(check.need, panoramaFreeGraphicsMemory);
      expect(check.free, 3174 * _mib);
      expect(check.appHolds, 1402 * _mib);
    });

    test('the share of the app read apart when the probe could not read it (the DRM fdinfo on Linux)', () async {
      final asked = <String?>[];
      final check =
          await GpuBudget(
                probe: FakeGpuProbe.of(
                  const GpuReport(
                    adapters: [
                      GpuAdapter(
                        name: 'AMD Radeon RX 7600',
                        kind: GpuKind.discrete,
                        localMemory: 8 * _gib,
                        apiVersion: '1.3.287',
                        budget: 3 * _gib,
                        usage: 0,
                        pci: '0000:03:00.0',
                      ),
                    ],
                  ),
                ).probe,
                appMemoryOf: (card) async {
                  asked.add(card.pci);
                  return 900 * _mib;
                },
              ).check()
              as GpuBudgetWait;

      expect(asked, ['0000:03:00.0']);
      expect(check.appHolds, 900 * _mib);
    });

    test('a share told by the probe is taken as it is, and a reader that fails tells none', () async {
      var asked = 0;
      final told = await GpuBudget(
        probe: FakeGpuProbe.of(card(2 * _gib, app: 300 * _mib)).probe,
        appMemoryOf: (card) async => ++asked,
      ).check();
      expect((told as GpuBudgetWait).appHolds, 300 * _mib);
      expect(asked, 0);

      final failed = await GpuBudget(
        probe: FakeGpuProbe.of(card(2 * _gib)).probe,
        appMemoryOf: (card) async => throw const FileSystemException('gone'),
      ).check();
      expect((failed as GpuBudgetWait).appHolds, isNull);
    });
  });

  test('the answer of the probe of Windows on the RTX 4060 while another program held 4.0 GiB: 3.8 GiB free, the job '
      'starts in segments', () async {
    // V3, on the PC of the owner: the budget of Vulkan alone said 7.5 GB; the probe lowers it to what the counters of
    // Windows leave of the card (windows/runner/gpu_probe.cpp, DedicatedUsage). It waited before lot 13c (6 GiB
    // asked), and runs in segments since (3.5 GiB asked)
    final report = GpuReport.fromJson(
      jsonDecode(File('test/fixtures/ai_immersive/gpu_probe_rtx4060_laptop_busy.json').readAsStringSync())
          as Map<String, Object?>,
    );
    final check = await budget(FakeGpuProbe.of(report)).check();

    expect(check, isA<GpuBudgetReady>());
    expect((check as GpuBudgetReady).card.name, rtx4060Laptop.name);
    expect(check.free, 4064452608);
    expect(check.whole, isFalse);
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
    expect(await budget(FakeGpuProbe.of(card(panoramaFreeGraphicsMemory))).check(), isA<GpuBudgetReady>());
    expect(await budget(FakeGpuProbe.of(card(panoramaFreeGraphicsMemory - 1))).check(), isA<GpuBudgetWait>());
    // A splat scene asked with its own need: whole whatever the memory above it
    final splat = await budget(FakeGpuProbe.of(card(3 * _gib))).check(need: splatGpuNeed) as GpuBudgetReady;
    expect(splat.whole, isTrue);
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

  test('the runner of Brush gets the card and its report, what is free, or the reason of the gate (lot SP4)', () async {
    GpuBudget splat(GpuReport report) =>
        GpuBudget(probe: FakeGpuProbe.of(report).probe, need: SplatV1.freeGraphicsMemory);

    final ready = await brushCardOf(splat(FakeGpuReports.twoCards));
    expect(ready, isA<BrushCardReady>());
    expect((ready as BrushCardReady).card.name, rtx4060Laptop.name);
    expect(ready.report.adapters, hasLength(2));
    // 2.0 GiB free under the 2.5 GiB of a splat scene
    final wait = await brushCardOf(splat(FakeGpuReports.rtx4060Busy));
    expect((wait as BrushCardWait).free, 2000 * _mib);
    expect(await brushCardOf(splat(FakeGpuReports.noDevice)), isA<BrushCardRefused>());
    expect((await brushCardOf(splat(FakeGpuReports.integratedOnly)) as BrushCardRefused).reason, 'gpuIntegrated');
  });

  test(
    'the rule that chooses the card is the one given, that of the panoramas unless told (lot SP4, for SP6)',
    () async {
      final seen = <GpuReport>[];
      final budget = GpuBudget(
        probe: FakeGpuProbe.of(FakeGpuReports.twoCards).probe,
        need: 0,
        cardOf: (report, {required integratedAllowed}) {
          seen.add(report);
          return (card: null, refusal: AiGateReason.gpuTooSmall);
        },
      );
      final check = await budget.check();
      expect((check as GpuBudgetUnavailable).reason, AiGateReason.gpuTooSmall);
      expect(seen, hasLength(1));
      expect(GpuBudget(probe: FakeGpuProbe.of(FakeGpuReports.twoCards).probe).cardOf, panoramaCardOf);
    },
  );
}
