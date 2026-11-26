import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_layout.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_plan.dart';
import 'package:immich_mobile/desktop/ai/gpu/metal_probe.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_enhance_manifest.dart' show aiEnhanceMacRebuildOffered;

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

/// A Mac with an Apple chip of [gigabytes] of unified memory, its GPU as Metal tells it: about two thirds of the memory
/// advised as the working set of a process, the family of the M1 and later unless [apple7] is false
EnhanceMachine _mac(int gigabytes, {bool apple7 = true, bool metal = true, int? workingSet}) => EnhanceMachine(
  platform: AiPlatform.macosArm64,
  physicalMemory: gigabytes * _gib,
  processors: 10,
  metal: metal
      ? MetalFacts(
          name: 'Apple M2 Pro',
          workingSet: workingSet ?? gigabytes * _gib * 2 ~/ 3,
          unifiedMemory: true,
          apple7: apple7,
        )
      : null,
);

void main() {
  group('a Mac with an Apple chip (release 53, not tried on a Mac yet)', () {
    test('8 GB: Sharpen only, Rebuild details and Natural need 16 GB', () {
      final mac = _mac(8);
      expect(
        enhanceVerdict(EnhanceLevel.sharpen, mac, width: 4000, height: 3000, macRebuildOffered: true).refusal,
        isNull,
      );
      expect(
        enhanceVerdict(EnhanceLevel.rebuild, mac, width: 4000, height: 3000, macRebuildOffered: true).refusal,
        EnhanceRefusal.memoryTooSmall,
      );
      expect(
        enhanceVerdict(EnhanceLevel.natural, mac, width: 4000, height: 3000, macRebuildOffered: true).refusal,
        EnhanceRefusal.memoryTooSmall,
      );
    });

    test('the graphics: none from Metal, not of the Apple family 7, too small a working set', () {
      for (final level in [EnhanceLevel.sharpen, EnhanceLevel.rebuild]) {
        expect(
          enhanceVerdict(level, _mac(16, metal: false), width: 100, height: 100, macRebuildOffered: true).refusal,
          EnhanceRefusal.macGraphicsUnusable,
          reason: level.name,
        );
      }
      // A virtual Mac without the family of the Apple chips: Sharpen runs, Rebuild details and its int8 weights not
      final virtual = _mac(16, apple7: false);
      expect(
        enhanceVerdict(EnhanceLevel.sharpen, virtual, width: 100, height: 100, macRebuildOffered: true).refusal,
        isNull,
      );
      expect(
        enhanceVerdict(EnhanceLevel.rebuild, virtual, width: 100, height: 100, macRebuildOffered: true).refusal,
        EnhanceRefusal.macGraphicsUnusable,
      );
      // Natural needs no graphics
      expect(
        enhanceVerdict(
          EnhanceLevel.natural,
          _mac(16, metal: false),
          width: 100,
          height: 100,
          macRebuildOffered: true,
        ).refusal,
        isNull,
      );
      expect(
        enhanceVerdict(
          EnhanceLevel.rebuild,
          _mac(32, workingSet: 4 * _gib),
          width: 100,
          height: 100,
          macRebuildOffered: true,
        ).refusal,
        EnhanceRefusal.graphicsCardTooSmall,
      );
      expect(
        enhanceVerdict(EnhanceLevel.rebuild, _mac(24), width: 100, height: 100, macRebuildOffered: true).refusal,
        isNull,
      );
    });

    test('Rebuild details is held on every Mac until it has run on a real Apple chip; Sharpen and Natural are not', () {
      expect(aiEnhanceMacRebuildOffered, isFalse);
      for (final mac in [_mac(16), _mac(64)]) {
        expect(
          enhanceVerdict(EnhanceLevel.rebuild, mac, width: 4000, height: 3000).refusal,
          EnhanceRefusal.macRebuildNotYet,
        );
        expect(enhanceVerdict(EnhanceLevel.sharpen, mac, width: 4000, height: 3000).refusal, isNull);
        expect(enhanceVerdict(EnhanceLevel.natural, mac, width: 4000, height: 3000).refusal, isNull);
      }
      // Windows and Linux never wait for it
      expect(enhanceVerdict(EnhanceLevel.rebuild, _laptop, width: 4000, height: 3000).refusal, isNull);
    });

    test('two jobs side by side only when the memory holds both whole, macOS and the app apart', () {
      expect(enhanceUnifiedJobMemoryOf(EnhanceLevel.rebuild), rebuildJobMemory + rebuildFreeGraphicsMemory);
      expect(enhanceUnifiedJobMemoryOf(EnhanceLevel.sharpen), sharpenJobMemory + sharpenFreeGraphicsMemory);
      expect(enhanceUnifiedJobMemoryOf(EnhanceLevel.natural), naturalJobMemory);
      final rebuild = enhanceUnifiedJobMemoryOf(EnhanceLevel.rebuild);
      final natural = enhanceUnifiedJobMemoryOf(EnhanceLevel.natural);
      expect(enhanceFitsBesideOnUnifiedMemory(rebuild, natural, 16 * _gib), isFalse);
      expect(enhanceFitsBesideOnUnifiedMemory(rebuild, natural, 32 * _gib), isTrue);
      expect(
        enhanceFitsBesideOnUnifiedMemory(enhanceUnifiedJobMemoryOf(EnhanceLevel.sharpen), 2 * _gib, 16 * _gib),
        isTrue,
      );
      expect(enhanceFitsBesideOnUnifiedMemory(1, 1, null), isFalse);
    });
  });

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

    test('on a Mac: every level on an Apple chip of 16 GB, none on an Intel Mac', () {
      final mac = _mac(16);
      for (final level in EnhanceLevel.values) {
        final verdict = enhanceVerdict(level, mac, width: 4000, height: 3000, macRebuildOffered: true);
        expect(verdict.refusal, isNull, reason: level.name);
        // macOS gives no figure of the memory free: no warning made up
        expect(verdict.warnings, isNot(contains(EnhanceWarning.closeOtherPrograms)), reason: level.name);
        expect(verdict.estimate, isNotNull);
      }
      final intel = _with(platform: AiPlatform.macosX64, card: null);
      expect(
        enhanceVerdict(EnhanceLevel.natural, intel, width: 100, height: 100).refusal,
        EnhanceRefusal.intelMacNotChecked,
      );
      expect(
        enhanceVerdict(EnhanceLevel.sharpen, intel, width: 100, height: 100).refusal,
        EnhanceRefusal.appleChipNeeded,
      );
      expect(
        enhanceVerdict(EnhanceLevel.rebuild, intel, width: 100, height: 100).refusal,
        EnhanceRefusal.appleChipNeeded,
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

  test('the memory a photo needs grows above the 12 MP the probe measured', () {
    for (final level in EnhanceLevel.values) {
      expect(enhanceJobMemoryOf(level, pixels: 12000000), enhanceJobMemoryOf(level));
      expect(enhanceFreeMemoryOf(level, pixels: 3000000), enhanceFreeMemoryOf(level));
      // The float sums of the blend and the colour fix of 50 MP, about 1.5 GB more
      expect(enhanceJobMemoryOf(level, pixels: 50000000) - enhanceJobMemoryOf(level), 40 * 38000000);
    }
    expect(enhanceJobMemoryOf(EnhanceLevel.sharpen, pixels: 50000000), greaterThan(3 * _gib));
    // The dialog says to close other programs for a large photo sooner than for a small one
    final free = _with(free: 4 * _gib);
    expect(enhanceVerdict(EnhanceLevel.rebuild, free, width: 4000, height: 3000).warnings, isEmpty);
    final large = enhanceVerdict(EnhanceLevel.rebuild, free, width: 8000, height: 6000);
    expect(large.warnings, contains(EnhanceWarning.closeOtherPrograms));
    expect(large.memoryNeeded, rebuildFreeMemory + 40 * 36000000);
  });

  test('a 360 photo needs the memory of all its work pixels: the seam copy and the faces of the poles', () {
    const sphere = EnhanceLayout(sphere: true);
    final work = enhanceWorkPixels(9600, 4800, sphere);
    expect(work, greaterThan(9600 * 4800 * 13 ~/ 10));
    final flat = enhanceVerdict(EnhanceLevel.sharpen, _laptop, width: 9600, height: 4800);
    final round = enhanceVerdict(EnhanceLevel.sharpen, _laptop, width: 9600, height: 4800, layout: sphere);
    expect(flat.memoryNeeded, enhanceFreeMemoryOf(EnhanceLevel.sharpen, pixels: 9600 * 4800));
    expect(round.memoryNeeded, enhanceFreeMemoryOf(EnhanceLevel.sharpen, pixels: work));
    // A 3D photo side by side works on its own pixels only
    const stereo = EnhanceLayout(eyes: EnhanceEyes.sideBySide);
    expect(enhanceWorkPixels(8000, 4000, stereo), 8000 * 4000);
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
