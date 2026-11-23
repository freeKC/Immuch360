import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_plan.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';

const _gib = 1024 * 1024 * 1024;

/// The laptop of the probe: 16 GB, 24 threads, the RTX 4060 Laptop with 8 GB
const _laptop = EnhanceMachine(
  platform: AiPlatform.windowsX64,
  physicalMemory: 16 * _gib,
  freeMemory: 8 * _gib,
  processors: 24,
  card: EnhanceCard(name: 'NVIDIA GeForce RTX 4060 Laptop GPU', dedicated: true, localMemory: 8 * _gib),
);

EnhanceMachine _with({
  AiPlatform platform = AiPlatform.windowsX64,
  int physical = 16 * _gib,
  int free = 8 * _gib,
  int processors = 24,
  EnhanceCard? card = const EnhanceCard(name: 'RTX', dedicated: true, localMemory: 8 * _gib),
}) =>
    EnhanceMachine(platform: platform, physicalMemory: physical, freeMemory: free, processors: processors, card: card);

void main() {
  group('the three levels on the laptop of the probe', () {
    test('each runs, with the times the probe measured', () {
      for (final level in EnhanceLevel.values) {
        expect(enhanceVerdict(level, _laptop, width: 4000, height: 3000).refusal, isNull, reason: level.name);
      }
      // Measured: Sharpen 110.5 s and 28.3 s, Rebuild 93.9 s and 35.0 s, Natural 989.9 s and 339.9 s
      Duration of(EnhanceLevel level, int width, int height) =>
          enhanceVerdict(level, _laptop, width: width, height: height).estimate!;
      expect(of(EnhanceLevel.sharpen, 4000, 3000).inSeconds, closeTo(110, 8));
      expect(of(EnhanceLevel.sharpen, 2000, 1500).inSeconds, closeTo(28, 4));
      expect(of(EnhanceLevel.rebuild, 4000, 3000).inSeconds, closeTo(94, 6));
      expect(of(EnhanceLevel.rebuild, 2000, 1500).inSeconds, closeTo(35, 4));
      expect(of(EnhanceLevel.natural, 4000, 3000).inSeconds, closeTo(990, 30));
      expect(of(EnhanceLevel.natural, 2000, 1500).inSeconds, closeTo(340, 15));
    });

    test('Natural on half the threads takes about twice as long', () {
      final full = enhanceVerdict(EnhanceLevel.natural, _laptop, width: 2000, height: 1500).estimate!;
      final half = enhanceVerdict(EnhanceLevel.natural, _with(processors: 12), width: 2000, height: 1500).estimate!;
      expect(half.inSeconds / full.inSeconds, closeTo(2.2, 0.3));
    });
  });

  group('gates', () {
    test('above 50 megapixels every level refuses', () {
      for (final level in EnhanceLevel.values) {
        expect(enhanceVerdict(level, _laptop, width: 9000, height: 6000).refusal, EnhanceRefusal.tooLarge);
      }
      expect(enhanceVerdict(EnhanceLevel.sharpen, _laptop, width: 8000, height: 6000).refusal, isNull);
    });

    test('Rebuild details needs a dedicated card of 6 GB, Sharpen any Vulkan card of 2 GB', () {
      const integrated = EnhanceCard(name: 'Intel UHD', dedicated: false, localMemory: 4 * _gib);
      expect(
        enhanceVerdict(EnhanceLevel.rebuild, _with(card: integrated), width: 100, height: 100).refusal,
        EnhanceRefusal.dedicatedCardNeeded,
      );
      expect(enhanceVerdict(EnhanceLevel.sharpen, _with(card: integrated), width: 100, height: 100).refusal, isNull);
      const small = EnhanceCard(name: 'GTX 1050', dedicated: true, localMemory: 4 * _gib);
      expect(
        enhanceVerdict(EnhanceLevel.rebuild, _with(card: small), width: 100, height: 100).refusal,
        EnhanceRefusal.graphicsCardTooSmall,
      );
      const tiny = EnhanceCard(name: 'old', dedicated: true, localMemory: _gib);
      expect(
        enhanceVerdict(EnhanceLevel.sharpen, _with(card: tiny), width: 100, height: 100).refusal,
        EnhanceRefusal.graphicsCardTooSmall,
      );
      for (final level in [EnhanceLevel.sharpen, EnhanceLevel.rebuild]) {
        expect(
          enhanceVerdict(level, _with(card: null), width: 100, height: 100).refusal,
          EnhanceRefusal.noGraphicsCard,
        );
      }
      // Natural needs no card
      expect(enhanceVerdict(EnhanceLevel.natural, _with(card: null), width: 100, height: 100).refusal, isNull);
    });

    test('on a Mac: Natural on an Apple chip, the levels of the graphics card not yet', () {
      final mac = _with(platform: AiPlatform.macosArm64, card: null);
      expect(enhanceVerdict(EnhanceLevel.natural, mac, width: 100, height: 100).refusal, isNull);
      expect(enhanceVerdict(EnhanceLevel.sharpen, mac, width: 100, height: 100).refusal, EnhanceRefusal.macNotYet);
      expect(enhanceVerdict(EnhanceLevel.rebuild, mac, width: 100, height: 100).refusal, EnhanceRefusal.macNotYet);
      final intel = _with(platform: AiPlatform.macosX64, card: null);
      expect(
        enhanceVerdict(EnhanceLevel.natural, intel, width: 100, height: 100).refusal,
        EnhanceRefusal.intelMacNotChecked,
      );
      expect(
        enhanceVerdict(EnhanceLevel.natural, _with(platform: AiPlatform.questArm64), width: 1, height: 1).refusal,
        EnhanceRefusal.notOnThisSystem,
      );
    });

    test('Natural refuses a computer of less than 16 GB, and warns when the memory free is short', () {
      expect(
        enhanceVerdict(EnhanceLevel.natural, _with(physical: 8 * _gib), width: 100, height: 100).refusal,
        EnhanceRefusal.memoryTooSmall,
      );
      final short = enhanceVerdict(EnhanceLevel.natural, _with(free: 2 * _gib), width: 100, height: 100);
      expect(short.refusal, isNull);
      expect(short.warnings, contains(EnhanceWarning.closeOtherPrograms));
      expect(short.memoryNeeded, naturalFreeMemory);
      // The engine refused SeedVR2 runs with 1 to 2 GB free on the 16 GB laptop of the probe
      final rebuild = enhanceVerdict(EnhanceLevel.rebuild, _with(free: 2 * _gib), width: 100, height: 100);
      expect(rebuild.warnings, contains(EnhanceWarning.closeOtherPrograms));
      expect(enhanceVerdict(EnhanceLevel.rebuild, _laptop, width: 100, height: 100).warnings, isEmpty);
    });

    test('the card short of free memory now is a warning, not a refusal', () {
      const busy = EnhanceCard(name: 'RTX', dedicated: true, localMemory: 8 * _gib, freeMemory: 2 * _gib);
      final verdict = enhanceVerdict(EnhanceLevel.rebuild, _with(card: busy), width: 100, height: 100);
      expect(verdict.refusal, isNull);
      expect(verdict.warnings, contains(EnhanceWarning.graphicsMemoryBusy));
    });

    test('a long Natural run is said to be long', () {
      final slow = enhanceVerdict(EnhanceLevel.natural, _with(processors: 8), width: 4000, height: 3000);
      expect(slow.warnings, contains(EnhanceWarning.longRun));
    });
  });

  test('the time of a batch is the sum of its photos', () {
    final sizes = [(4000, 3000), (2000, 1500)];
    final total = enhanceBatchEstimate(EnhanceLevel.rebuild, _laptop, sizes);
    expect(
      total,
      enhanceVerdict(EnhanceLevel.rebuild, _laptop, width: 4000, height: 3000).estimate! +
          enhanceVerdict(EnhanceLevel.rebuild, _laptop, width: 2000, height: 1500).estimate!,
    );
  });
}
