// The memory of the graphics card read again before a job on it (lot C6; design-final 2026-10-27, section 4.7, point
// 3): free enough, the job starts on the card the gate would take, with the answer it came from; held by other
// programs, the job waits with what is free; no card any more, it cannot run; each check starts the probe again.
// Issue #13: the way the panorama is made follows the memory free (the full reference from 6 GiB, the reduced one from
// 5.1 GiB, as measured on 4 November 2026), and a wait says what it needs and what the app itself holds of the card.

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

  test('6 GiB free for the full reference, 5.1 GiB for the reduced one: the measured thresholds and a margin', () {
    // One segment of sd-cli from 5.54 to 5.60 GiB free with the arguments of M3, from 4.74 to 4.82 GiB with the reference
    // capped at 1280 x 640 (measure of 4 November 2026, section 2.4)
    expect(panoramaFreeGraphicsMemory, 6 * _gib);
    expect(panoramaReducedFreeGraphicsMemory, 5476083302);
    expect(PanoramaReference.full.need - 5.60 * _gib, greaterThan(0.39 * _gib));
    expect(PanoramaReference.reduced.need - 4.82 * _gib, greaterThan(0.25 * _gib));
    expect(PanoramaReference.full.maxPixels, isNull);
    expect(PanoramaReference.reduced.maxPixels, 1280 * 640);
    expect(PanoramaReference.values, [PanoramaReference.full, PanoramaReference.reduced]);
    // The least memory a panorama starts with
    expect(budget(FakeGpuProbe.of(FakeGpuReports.rtx4060)).need, panoramaReducedFreeGraphicsMemory);
    expect(
      GpuBudget(probe: FakeGpuProbe.of(FakeGpuReports.rtx4060).probe, references: const [PanoramaReference.full]).need,
      panoramaFreeGraphicsMemory,
    );
  });

  test('the RTX 4060 with 7.2 GiB free: ready, on that card, with the answer it came from', () async {
    final check = await budget(FakeGpuProbe.of(FakeGpuReports.twoCards)).check();

    expect(check, isA<GpuBudgetReady>());
    final ready = check as GpuBudgetReady;
    expect(ready.card.name, rtx4060Laptop.name);
    expect(ready.free, 7400 * _mib);
    expect(ready.report.adapters, hasLength(2));
    expect(ready.reference, PanoramaReference.full);
  });

  test('a game holds the card, 2.0 GiB free: the job waits, told what is free and what it needs', () async {
    final check = await budget(FakeGpuProbe.of(FakeGpuReports.rtx4060Busy)).check();

    expect(check, isA<GpuBudgetWait>());
    expect((check as GpuBudgetWait).free, 2000 * _mib);
    expect(check.card.name, rtx4060Laptop.name);
    expect(check.need, panoramaReducedFreeGraphicsMemory);
    expect(check.appHolds, isNull, reason: 'the fake probe reads no share of the app');
  });

  group('the way a panorama is made follows the memory free', () {
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

    test('6 GiB free: the full reference; just under it, the reduced one; under 5.1 GiB, a wait', () async {
      Future<GpuBudgetCheck> at(int free) => budget(FakeGpuProbe.of(card(free))).check();

      expect((await at(6 * _gib) as GpuBudgetReady).reference, PanoramaReference.full);
      expect((await at(6 * _gib - 1) as GpuBudgetReady).reference, PanoramaReference.reduced);
      expect((await at(panoramaReducedFreeGraphicsMemory) as GpuBudgetReady).reference, PanoramaReference.reduced);
      final wait = await at(panoramaReducedFreeGraphicsMemory - 1) as GpuBudgetWait;
      expect(wait.need, panoramaReducedFreeGraphicsMemory);
    });

    test(
      'issue #13: the RTX 2060 of 8 GB with 5.4 GiB free runs the reduced reference, which one segment holds',
      () async {
        // His probe said 5.4 GiB free, Immuch360 holding 1 402 MiB of the card; the reduced reference ran in one segment
        // with that budget (run E2 of the measure)
        final check = await budget(FakeGpuProbe.of(card(5530 * _mib, app: 1402 * _mib))).check() as GpuBudgetReady;

        expect(check.reference, PanoramaReference.reduced);
        expect(check.free, 5530 * _mib);
        expect(check.appHolds, 1402 * _mib);
      },
    );

    test(
      'with the full reference only, the same card waits, told the 6 GiB it needs and the share of the app',
      () async {
        final check =
            await GpuBudget(
                  probe: FakeGpuProbe.of(card(5530 * _mib, app: 1402 * _mib)).probe,
                  references: const [PanoramaReference.full],
                ).check()
                as GpuBudgetWait;

        expect(check.need, panoramaFreeGraphicsMemory);
        expect(check.free, 5530 * _mib);
        expect(check.appHolds, 1402 * _mib);
      },
    );

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
                        budget: 4 * _gib,
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

  test(
    'the answer of the probe of Windows on the RTX 4060 while another program held 4.0 GiB: the job waits',
    () async {
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
    },
  );

  test('just the memory asked is enough, a byte less waits (the reduced reference)', () async {
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
    expect(await budget(FakeGpuProbe.of(card(panoramaReducedFreeGraphicsMemory))).check(), isA<GpuBudgetReady>());
    expect(await budget(FakeGpuProbe.of(card(panoramaReducedFreeGraphicsMemory - 1))).check(), isA<GpuBudgetWait>());
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
