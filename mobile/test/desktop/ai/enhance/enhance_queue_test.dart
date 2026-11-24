// "Enhance (AI)" through the queue of the conversions, with a fake engine per level: the batch, the lanes, the
// settings each job carries, Pause, Resume and Stop.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_plan.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_conversion_output.dart';
import '../fakes/fake_immersive_engine.dart';

const _gib = 1024 * 1024 * 1024;

/// One level of "Enhance (AI)": its runs, held while [hold] is not complete, stopped by the flag of the job
class _FakeEnhance implements ImmersiveEngine {
  final specs = <EnhanceJob>[];
  Completer<void>? hold;
  var running = 0;

  @override
  Future<ImmersiveResult> run(
    covariant EnhanceJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    specs.add(job);
    running++;
    try {
      onProgress?.call(const ImmersiveProgress(ImmersiveStage.generating, 300, step: 1, steps: 3));
      final held = hold;
      while (held != null && !held.isCompleted) {
        if (cancel.isCancelled) {
          return const ImmersiveResult.failed(ImmersiveErrorCode.cancelled);
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      if (cancel.isCancelled) {
        return const ImmersiveResult.failed(ImmersiveErrorCode.cancelled);
      }
      File(job.partPath).writeAsBytesSync(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]));
      return ImmersiveResult.made(
        details: EnhanceResultDetails(width: 8, height: 8, level: job.level, strength: job.strength, model: 'fake'),
        bytesWritten: 4,
      );
    } finally {
      running--;
    }
  }

  @override
  Future<void> dispose() async {}
}

class _Memory implements MemoryProbe {
  int? available = 16 * _gib;

  @override
  MemoryFacts read() => MemoryFacts(physical: 32 * _gib, available: available);
}

void main() {
  late Directory root;
  late FakeConversionOutput output;
  late Map<EnhanceLevel, _FakeEnhance> levels;
  late _Memory memory;
  late ProviderContainer container;

  setUp(() {
    root = Directory.systemTemp.createTempSync('enhance_queue');
    addTearDown(() => root.deleteSync(recursive: true));
    output = FakeConversionOutput();
    memory = _Memory();
    levels = {for (final level in EnhanceLevel.values) level: _FakeEnhance()};
    container = ProviderContainer(
      overrides: [
        conversionToolsProvider.overrideWith(
          (ref) => ConversionTools(
            engine: FakeImmersiveEngine(),
            engines: {
              for (final MapEntry(key: level, value: engine) in levels.entries)
                ConversionKind.enhanceAt(level): ConversionEngine(engine: engine, settingsKey: (_, _) => null),
            },
            output: output,
            finder: ExistingVersionFinder(),
            creatorTool: 'Immuch360 Desktop 3.4.6 (linux)',
            memory: memory,
            memoryRecheck: const Duration(milliseconds: 20),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  ConversionQueueNotifier queue() => container.read(conversionQueueProvider.notifier);
  ConversionQueueState current() => container.read(conversionQueueProvider);
  ConversionJob job(String id) => current().byId(id)!;

  ConversionRequest photo(String name, {int? pixels}) {
    final path = p.join(root.path, name);
    File(path).writeAsBytesSync(Uint8List.fromList(List.generate(64, (i) => (i * 7 + name.length) & 0xff)));
    return ConversionRequest(
      source: LocalFileSource(path, hash: (path, cancel) async => 'c2hh'),
      target: ConversionTarget(folder: root.path, fileName: versionTargetName(ImmersiveKind.enhancedPhoto, name)),
      pixels: pixels,
    );
  }

  Future<void> until(bool Function(ConversionQueueState state) test) async {
    if (test(current())) {
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

  /// Completes once [engines] run [count] jobs between them
  Future<void> running(List<_FakeEnhance> engines, int count) async {
    for (var tries = 0; engines.fold(0, (sum, engine) => sum + engine.running) < count; tries++) {
      expect(tries, lessThan(2000), reason: 'the engines never ran $count jobs');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('a batch runs each photo at its level and strength, one after the other, beside its original', () async {
    final ids = queue().add(
      [photo('a.jpg'), photo('b.png'), photo('c.heic')],
      kind: ConversionKind.enhanceRebuild,
      existing: ExistingVersionChoice.newVersion,
      enhance: const EnhanceSettings(level: EnhanceLevel.rebuild, strength: 50),
    );
    await until((state) => ids.every((id) => state.byId(id)!.state == ConversionState.done));
    final specs = levels[EnhanceLevel.rebuild]!.specs;
    expect(specs.map((spec) => (spec.level, spec.strength)).toSet(), {(EnhanceLevel.rebuild, 50)});
    expect(specs.map((spec) => spec.source.name), ['a.jpg', 'b.png', 'c.heic']);
    expect(
      [for (final id in ids) p.basename(job(id).writtenPath!)],
      ['a_enhanced.jpg', 'b_enhanced.jpg', 'c_enhanced.jpg'],
    );
    expect(job(ids.first).enhance, const EnhanceSettings(level: EnhanceLevel.rebuild, strength: 50));
    expect(job(ids.first).details, isA<EnhanceResultDetails>());
    expect(job(ids.first).kind.lane, ConversionLane.gpu);
  });

  test('a job without settings takes the default strength of its level', () async {
    final ids = queue().add([photo('a.jpg')], kind: ConversionKind.enhanceSharpen);
    await until((state) => state.byId(ids.single)!.state == ConversionState.done);
    expect(levels[EnhanceLevel.sharpen]!.specs.single.strength, EnhanceLevel.sharpen.defaultStrength);
  });

  test('Natural runs on the processor beside a level of the graphics card', () async {
    final sharpen = levels[EnhanceLevel.sharpen]!..hold = Completer<void>();
    final natural = levels[EnhanceLevel.natural]!..hold = Completer<void>();
    final card = queue().add([photo('a.jpg')], kind: ConversionKind.enhanceSharpen);
    final processor = queue().add([photo('b.jpg')], kind: ConversionKind.enhanceNatural);
    await running([sharpen, natural], 2);
    expect(job(card.single).state.isActive && job(processor.single).state.isActive, isTrue);
    sharpen.hold!.complete();
    natural.hold!.complete();
    await until((state) => state.jobs.every((job) => job.state == ConversionState.done));
  });

  test('Natural waits while the memory free cannot hold it beside the other lane', () async {
    final sharpen = levels[EnhanceLevel.sharpen]!..hold = Completer<void>();
    memory.available = 4 * _gib;
    queue().add([photo('a.jpg')], kind: ConversionKind.enhanceSharpen);
    final natural = queue().add([photo('b.jpg')], kind: ConversionKind.enhanceNatural);
    await until((state) => state.byId(natural.single)!.waitingFor == ConversionWait.memory);
    expect(naturalJobMemory, greaterThan(4 * _gib));
    sharpen.hold!.complete();
    await until((state) => state.byId(natural.single)!.state == ConversionState.done);
  });

  test('a photo of 50 MP holds more memory beside the other lane than one of 12 MP', () async {
    final natural = levels[EnhanceLevel.natural]!..hold = Completer<void>();
    queue().add([photo('n.jpg')], kind: ConversionKind.enhanceNatural);
    await running([natural], 1);
    // 3.5 GB free: Sharpen of 12 MP takes 2 GB and the reserve of 1 GB, Sharpen of 50 MP 1.5 GB more
    memory.available = 7 * _gib ~/ 2;
    final small = queue().add([photo('small.jpg', pixels: 12000000)], kind: ConversionKind.enhanceSharpen);
    await until((state) => state.byId(small.single)!.state == ConversionState.done);
    final big = queue().add([photo('big.jpg', pixels: 50000000)], kind: ConversionKind.enhanceSharpen);
    await until((state) => state.byId(big.single)!.waitingFor == ConversionWait.memory);
    expect(job(big.single).enhance!.pixels, 50000000);
    memory.available = 16 * _gib;
    await until((state) => state.byId(big.single)!.state == ConversionState.done);
    natural.hold!.complete();
    await until((state) => state.jobs.every((job) => job.state == ConversionState.done));
  });

  test('Pause stops the photo under way and keeps the next one out; Resume runs them again from the start', () async {
    final engine = levels[EnhanceLevel.sharpen]!..hold = Completer<void>();
    final ids = queue().add([photo('a.jpg'), photo('b.jpg'), photo('c.jpg')], kind: ConversionKind.enhanceSharpen);
    await running([engine], 1);
    queue().pause(ids[1]);
    queue().pause(ids[0]);
    await until((state) => state.byId(ids[0])!.state == ConversionState.paused);
    expect(job(ids[1]).state, ConversionState.paused);
    // The third goes on meanwhile
    await until((state) => state.byId(ids[2])!.state.isActive);
    engine.hold!.complete();
    await until((state) => state.byId(ids[2])!.state == ConversionState.done);
    expect(job(ids[0]).state, ConversionState.paused);
    expect(job(ids[0]).writtenPath, isNull);

    queue().retry(ids[0]);
    queue().retry(ids[1]);
    await until((state) => ids.every((id) => state.byId(id)!.state == ConversionState.done));
    expect(engine.specs.map((spec) => spec.source.name), ['a.jpg', 'c.jpg', 'a.jpg', 'b.jpg']);
  });

  test('Pause all stops the whole batch, Resume all runs it again in its order', () async {
    final engine = levels[EnhanceLevel.rebuild]!..hold = Completer<void>();
    final ids = queue().add([photo('a.jpg'), photo('b.jpg'), photo('c.jpg')], kind: ConversionKind.enhanceRebuild);
    await running([engine], 1);
    expect(current().hasEnhanceToPause, isTrue);
    queue().pauseEnhance();
    await until((state) => ids.every((id) => state.byId(id)!.state == ConversionState.paused));
    expect(current().hasEnhanceToPause, isFalse);
    expect(current().hasEnhancePaused, isTrue);
    engine.hold!.complete();
    queue().resumeEnhance();
    await until((state) => ids.every((id) => state.byId(id)!.state == ConversionState.done));
    expect(engine.specs.map((spec) => spec.source.name), ['a.jpg', 'a.jpg', 'b.jpg', 'c.jpg']);
  });

  test('Cancel of a paused photo forgets it; Cancel all stops the batch, a paused photo stays paused', () async {
    final engine = levels[EnhanceLevel.natural]!..hold = Completer<void>();
    final ids = queue().add([photo('a.jpg'), photo('b.jpg'), photo('c.jpg')], kind: ConversionKind.enhanceNatural);
    await running([engine], 1);
    queue().pause(ids[2]);
    queue().cancelAll();
    await until((state) => !state.byId(ids[0])!.state.isActive);
    expect(
      [for (final id in ids) job(id).state],
      [ConversionState.cancelled, ConversionState.cancelled, ConversionState.paused],
    );
    queue().cancel(ids[2]);
    expect(job(ids[2]).state, ConversionState.cancelled);
    expect(engine.specs, hasLength(1));
  });
}
