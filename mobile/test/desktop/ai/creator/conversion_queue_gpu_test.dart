// The memory of the graphics card asked before each job on it (lot C6; design-final 2026-10-27, section 4.7, point 3),
// in the queue: a panorama waits while other programs hold the card, with what is free, and the processor lane goes
// on; it starts once the card is free, asked again a little later or at once; no card fails it; a panorama waiting
// holds the next one back and only one probe runs per check; a panorama cancelled while it waits or while the probe
// answers never runs. Issue #13: before it asks, the app lets go of its share of the card, once per job, says so, and
// asks again while that memory comes back; the panorama is made the way the memory free allows (the full reference,
// else the reduced one).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/gpu/gpu_budget.dart';
import 'package:immich_mobile/desktop/ai/gpu/graphics_release.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_conversion_engines.dart';
import '../fakes/fake_conversion_output.dart';
import '../fakes/fake_gpu_probe.dart';
import '../fakes/fake_immersive_engine.dart';
import '../fakes/fake_panorama_engine.dart';
import '../fakes/fake_scene_engine.dart';

const _mib = 1024 * 1024;

/// An RTX 2060 of 8 GB under Linux with [freeMib] free, Immuch360 holding [appMib] of it (issue #13)
GpuReport _rtx2060(int freeMib, {int? appMib}) => GpuReport(
  adapters: [
    GpuAdapter(
      name: 'NVIDIA GeForce RTX 2060',
      kind: GpuKind.discrete,
      localMemory: 8192 * _mib,
      vendorId: 0x10de,
      apiVersion: '1.3.277',
      budget: freeMib * _mib,
      usage: 0,
      appMemory: appMib == null ? null : appMib * _mib,
    ),
  ],
);

Future<String> _sum(String path, NativeCancelFlag cancel) async => 'c3VtCg==';

/// A computer whose memory holds a scene beside a panorama, whatever the machine of the test has free
class _Roomy implements MemoryProbe {
  @override
  MemoryFacts read() => const MemoryFacts(physical: 64 * 1024 * _mib, available: 48 * 1024 * _mib);
}

void main() {
  late Directory photos;
  late FakePanoramaEngine panorama;
  late FakeSceneEngine scene;
  late ProviderContainer container;

  setUp(() {
    photos = Directory.systemTemp.createTempSync('conversion_queue_gpu_test_');
    addTearDown(() => photos.deleteSync(recursive: true));
    panorama = FakePanoramaEngine();
    scene = FakeSceneEngine();
  });

  ProviderContainer containerWith(
    Future<GpuReport> Function() probe, {
    Duration recheck = const Duration(milliseconds: 30),
    Future<GraphicsRelease> Function()? release,
    Duration settle = const Duration(milliseconds: 100),
    Duration settlePoll = const Duration(milliseconds: 10),
  }) {
    final made = ProviderContainer(
      overrides: [
        conversionToolsProvider.overrideWith(
          (ref) => ConversionTools(
            engine: FakeImmersiveEngine(),
            engines: fakeConversionEngines(scene: scene, panorama: panorama),
            output: FakeConversionOutput(),
            finder: ExistingVersionFinder(),
            creatorTool: 'Immuch360 Desktop 3.3.0 (windows)',
            memory: _Roomy(),
            gpuBudget: GpuBudget(probe: probe),
            gpuRecheck: recheck,
            releaseGraphics: release,
            gpuSettle: settle,
            gpuSettlePoll: settlePoll,
          ),
        ),
      ],
    );
    addTearDown(made.dispose);
    return made;
  }

  ConversionQueueNotifier queue() => container.read(conversionQueueProvider.notifier);
  ConversionJob job(String id) => container.read(conversionQueueProvider).byId(id)!;

  ConversionRequest photo(String name, ConversionKind kind) {
    final path = p.join(photos.path, name);
    File(path).writeAsBytesSync(Uint8List.fromList(List.generate(64, (i) => i)));
    return ConversionRequest(
      source: LocalFileSource(path, hash: _sum),
      target: ConversionTarget.nextTo(path, kind: kind),
    );
  }

  String add(String name, ConversionKind kind) => queue().add([photo(name, kind)], kind: kind).single;

  Future<void> until(bool Function(ConversionQueueState state) test) async {
    if (test(container.read(conversionQueueProvider))) {
      return;
    }
    final reached = Completer<void>();
    final subscription = container.listen(conversionQueueProvider, (_, next) {
      if (!reached.isCompleted && test(next)) {
        reached.complete();
      }
    });
    try {
      await reached.future.timeout(const Duration(seconds: 10));
    } finally {
      subscription.close();
    }
  }

  /// A card held by a game until the test frees it, and how often it was asked
  ({Future<GpuReport> Function() probe, void Function() free, int Function() calls}) heldCard() {
    var held = true;
    var calls = 0;
    return (
      probe: () async {
        calls++;
        return held ? FakeGpuReports.rtx4060Busy : FakeGpuReports.rtx4060;
      },
      free: () => held = false,
      calls: () => calls,
    );
  }

  test(
    'a panorama waits while a game holds the card, told what is free; scenes go on; it runs once the card is free',
    () async {
      final card = heldCard();
      container = containerWith(card.probe);

      final pano = add('salon.jpg', ConversionKind.panoramaFromPhoto);
      final made = add('jardin.jpg', ConversionKind.sceneFromPhoto);
      await until((state) => state.byId(pano)!.waitingFor == ConversionWait.graphicsMemory);

      expect(job(pano).state, ConversionState.waiting);
      expect(job(pano).waitingFree, 2000 * _mib);
      await until((state) => state.byId(made)!.state == ConversionState.done);
      // Asked again every 30 ms meanwhile, and still held
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(card.calls(), greaterThan(1));
      expect(job(pano).waitingFor, ConversionWait.graphicsMemory);
      expect(panorama.jobs, isEmpty);

      card.free();
      await until((state) => state.byId(pano)!.state.isEnded);
      expect(job(pano).state, ConversionState.done);
      expect(job(pano).waitingFor, isNull);
      expect(job(pano).waitingFree, isNull);
      expect(panorama.jobs, hasLength(1));
      expect(panorama.jobs.single.referenceMaxPixels, isNull, reason: 'the full reference on 7.2 GiB free');
    },
  );

  test('no card any more: the panorama fails, no graphics card can make it', () async {
    container = containerWith(FakeGpuProbe.of(FakeGpuReports.noDevice).probe);

    final pano = add('salon.jpg', ConversionKind.panoramaFromPhoto);
    await until((state) => state.byId(pano)!.state.isEnded);

    expect(job(pano).state, ConversionState.failed);
    expect(job(pano).error, ImmersiveErrorCode.gpuUnavailable);
    expect(job(pano).message, AiGateReason.gpuNone.name);
    expect(panorama.jobs, isEmpty);
  });

  test('a panorama waiting holds the next one back: one probe per check, the first runs first', () async {
    final card = heldCard();
    container = containerWith(card.probe, recheck: const Duration(hours: 1));

    final first = add('a.jpg', ConversionKind.panoramaFromPhoto);
    final second = add('b.jpg', ConversionKind.panoramaFromPhoto);
    await until((state) => state.byId(first)!.waitingFor == ConversionWait.graphicsMemory);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(card.calls(), 1, reason: 'the second panorama is not asked while the first waits');
    expect(job(second).waitingFor, isNull);

    // Asked again with the card still held: the first only
    queue().checkGraphicsCardAgain();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(card.calls(), 2);
    expect(job(first).waitingFor, ConversionWait.graphicsMemory);

    card.free();
    queue().checkGraphicsCardAgain();
    await until((state) => state.jobs.every((job) => job.state.isEnded));
    expect([for (final spec in panorama.jobs) spec.source.name], ['a.jpg', 'b.jpg']);
    expect(card.calls(), 4, reason: 'each panorama asks before it runs');
  });

  test('asked again at once when the user asks for it', () async {
    final probe = FakeGpuProbe([FakeGpuReports.rtx4060Busy, FakeGpuReports.rtx4060]);
    container = containerWith(probe.probe, recheck: const Duration(hours: 1));

    final pano = add('salon.jpg', ConversionKind.panoramaFromPhoto);
    await until((state) => state.byId(pano)!.waitingFor == ConversionWait.graphicsMemory);
    queue().checkGraphicsCardAgain();
    await until((state) => state.byId(pano)!.state.isEnded);

    expect(job(pano).state, ConversionState.done);
    expect(probe.calls, 2);
  });

  test('cancelled while it waits: never runs, and the next panorama is asked at once', () async {
    final probe = FakeGpuProbe([FakeGpuReports.rtx4060Busy, FakeGpuReports.rtx4060]);
    container = containerWith(probe.probe, recheck: const Duration(hours: 1));

    final first = add('a.jpg', ConversionKind.panoramaFromPhoto);
    final second = add('b.jpg', ConversionKind.panoramaFromPhoto);
    await until((state) => state.byId(first)!.waitingFor == ConversionWait.graphicsMemory);
    queue().cancel(first);
    await until((state) => state.byId(second)!.state.isEnded);

    expect(job(first).state, ConversionState.cancelled);
    expect(job(second).state, ConversionState.done);
    expect([for (final spec in panorama.jobs) spec.source.name], ['b.jpg']);
  });

  test('after Cancel all, a panorama added asks the card at once', () async {
    final card = heldCard();
    container = containerWith(card.probe, recheck: const Duration(hours: 1));

    final first = add('a.jpg', ConversionKind.panoramaFromPhoto);
    await until((state) => state.byId(first)!.waitingFor == ConversionWait.graphicsMemory);
    queue().cancelAll();
    card.free();
    final second = add('b.jpg', ConversionKind.panoramaFromPhoto);
    await until((state) => state.byId(second)!.state.isEnded);

    expect(job(first).state, ConversionState.cancelled);
    expect(job(second).state, ConversionState.done);
    expect([for (final spec in panorama.jobs) spec.source.name], ['b.jpg']);
  });

  test('cancelled while the probe answers: never runs', () async {
    final answer = Completer<GpuReport>();
    var asked = 0;
    container = containerWith(() {
      asked++;
      return answer.future;
    });

    final pano = add('salon.jpg', ConversionKind.panoramaFromPhoto);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(asked, 1);
    queue().cancel(pano);
    answer.complete(FakeGpuReports.rtx4060);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(job(pano).state, ConversionState.cancelled);
    expect(panorama.jobs, isEmpty);
  });

  test('the way the card allows reaches the panorama: the full reference, else the reduced one (issue #13)', () async {
    final probe = FakeGpuProbe([_rtx2060(7000), _rtx2060(5530, appMib: 1402)]);
    container = containerWith(probe.probe);

    final roomy = add('a.jpg', ConversionKind.panoramaFromPhoto);
    await until((state) => state.byId(roomy)!.state.isEnded);
    final tight = add('b.jpg', ConversionKind.panoramaFromPhoto);
    await until((state) => state.byId(tight)!.state.isEnded);

    expect(job(roomy).state, ConversionState.done);
    expect(job(tight).state, ConversionState.done);
    expect([for (final spec in panorama.jobs) spec.referenceMaxPixels], [null, panoramaReducedReferencePixels]);
  });

  test('the jobs of the processor never ask the graphics card, nor let go of anything', () async {
    final probe = FakeGpuProbe.of(FakeGpuReports.noDevice);
    var released = 0;
    container = containerWith(
      probe.probe,
      release: () async {
        released++;
        return const GraphicsRelease(players: 1);
      },
    );

    final made = add('jardin.jpg', ConversionKind.sceneFromPhoto);
    await until((state) => state.byId(made)!.state.isEnded);

    expect(job(made).state, ConversionState.done);
    expect(probe.calls, 0);
    expect(released, 0);
  });

  test('the way the card allows reaches the panorama: the full reference, else the reduced one (issue #13)', () async {
    final probe = FakeGpuProbe([_rtx2060(7000), _rtx2060(5530, appMib: 1402)]);
    container = containerWith(probe.probe);

    final roomy = add('a.jpg', ConversionKind.panoramaFromPhoto);
    await until((state) => state.byId(roomy)!.state.isEnded);
    final tight = add('b.jpg', ConversionKind.panoramaFromPhoto);
    await until((state) => state.byId(tight)!.state.isEnded);

    expect(job(roomy).state, ConversionState.done);
    expect(job(tight).state, ConversionState.done);
    expect([for (final spec in panorama.jobs) spec.referenceMaxPixels], [null, panoramaReducedReferencePixels]);
  });

  group('the app lets go of its share of the card first (issue #13)', () {
    test('once per job, before the card is asked; the panel says so meanwhile', () async {
      final letGo = Completer<GraphicsRelease>();
      var released = 0;
      final probe = FakeGpuProbe.of(_rtx2060(7000));
      container = containerWith(
        probe.probe,
        release: () {
          released++;
          return letGo.future;
        },
      );

      final pano = add('salon.jpg', ConversionKind.panoramaFromPhoto);
      await until((state) => state.byId(pano)!.waitingFor == ConversionWait.graphicsRelease);
      expect(job(pano).state, ConversionState.waiting);
      expect(probe.calls, 0, reason: 'the card is asked once the app let go of its share');

      letGo.complete(GraphicsRelease.nothing);
      await until((state) => state.byId(pano)!.state.isEnded);

      expect(job(pano).state, ConversionState.done);
      expect(released, 1);
      expect(probe.calls, 1, reason: 'nothing let go: nothing to wait for');
    });

    test('what was let go comes back within seconds: the card asked again until the full reference fits', () async {
      // The 1.4 GiB of the app coming back to the card in two steps after the players are disposed
      final probe = FakeGpuProbe([
        _rtx2060(4900, appMib: 1400),
        _rtx2060(5500, appMib: 800),
        _rtx2060(6400, appMib: 0),
      ]);
      container = containerWith(probe.probe, release: () async => const GraphicsRelease(players: 2, pictureBytes: 9));

      final pano = add('salon.jpg', ConversionKind.panoramaFromPhoto);
      await until((state) => state.byId(pano)!.state.isEnded);

      expect(job(pano).state, ConversionState.done);
      expect(probe.calls, 3);
      expect(panorama.jobs.single.referenceMaxPixels, isNull, reason: 'the full reference once 6 GiB are free');
    });

    test('the time is up with only the reduced reference fitting: the panorama made with it', () async {
      final probe = FakeGpuProbe.of(_rtx2060(5500, appMib: 300));
      container = containerWith(
        probe.probe,
        release: () async => const GraphicsRelease(players: 1),
        settle: const Duration(milliseconds: 50),
        settlePoll: const Duration(milliseconds: 10),
      );

      final pano = add('salon.jpg', ConversionKind.panoramaFromPhoto);
      await until((state) => state.byId(pano)!.state.isEnded);

      expect(job(pano).state, ConversionState.done);
      expect(probe.calls, 6, reason: 'once, then every 10 ms for 50 ms');
      expect(panorama.jobs.single.referenceMaxPixels, panoramaReducedReferencePixels);
    });

    test('the wait asked again by its timer lets go of nothing more; the user asking again does', () async {
      var released = 0;
      final card = heldCard();
      container = containerWith(
        card.probe,
        recheck: const Duration(milliseconds: 20),
        release: () async {
          released++;
          return GraphicsRelease.nothing;
        },
      );

      final pano = add('salon.jpg', ConversionKind.panoramaFromPhoto);
      await until((state) => state.byId(pano)!.waitingFor == ConversionWait.graphicsMemory);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(card.calls(), greaterThan(2));
      expect(released, 1);

      queue().checkGraphicsCardAgain();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(released, 2);
      queue().cancel(pano);
    });
  });
}
