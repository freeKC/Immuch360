// The gate of the splat scenes (plan 2026-11-01, sections 2.4 and 4.1, lot SP6): a feature of archives alone, which
// never loads ONNX Runtime; the dedicated card of Vulkan 1.2 with the most memory, a card sold with 4 GB at least (3.5
// GiB as it is read), an integrated one refused with its own words (Brush 0.3.0 fails on the Intel UHD with the cache
// of another card, and trains ten times slower with its own: a decision of time for the first test build); a computer
// sold with 8 GB (7 GiB as it is read); and the budget of the queue asked with the need of the kind of the job, 2.5 GiB
// free for a splat scene, 6 GiB for a panorama.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/gpu/gpu_budget.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:path/path.dart' as p;

import '../creator/english_texts.dart';
import '../fakes/fake_gpu_probe.dart';

const _gib = 1024 * 1024 * 1024;
const _mib = 1024 * 1024;

/// Every component installed, as files of [folder]
class _Installed implements AiComponentFiles {
  _Installed(this.folder);

  final Directory folder;

  @override
  Future<File?> verifiedFile(AiComponent component) async {
    final file = File(p.join(folder.path, component.installPath, 'program.exe'));
    if (!file.existsSync()) {
      file
        ..createSync(recursive: true)
        ..writeAsStringSync(component.id);
    }
    return file;
  }

  @override
  AiComponentState stateOf(AiComponent component) => AiComponentState.installed;
}

/// [component] complete, as the branch of the test build makes it with the sums of the CI
AiComponent _complete(AiComponent component) => AiComponent(
  id: component.id,
  name: component.name,
  version: component.version,
  kind: component.kind,
  platforms: component.platforms,
  assetName: component.assetName,
  installPath: component.installPath,
  size: 100,
  sha256: 'a' * 64,
  compression: component.compression,
  licence: component.licence,
  licenceUrl: component.licenceUrl,
  features: component.features,
  releaseTag: component.releaseTag,
  minGraphicsMemory: component.minGraphicsMemory,
  archiveFiles: const [AiArchiveFile(path: 'program.exe', size: 100, sha256: 'bb', executable: true)],
);

/// The catalogue of the test build: the splat components complete, ONNX Runtime and the depth model as they are
final _built = [for (final component in aiComponents) component.isComplete ? component : _complete(component)];

GpuAdapter _card({
  String name = 'Card',
  GpuKind kind = GpuKind.discrete,
  int memory = 8 * _gib,
  String api = '1.3.280',
  String source = 'vulkan',
  int? budget,
  int? usage,
}) => GpuAdapter(
  name: name,
  kind: kind,
  localMemory: memory,
  vendorId: 0x10de,
  deviceId: 0x2000,
  apiVersion: api,
  source: source,
  budget: budget,
  usage: usage,
);

void main() {
  late Directory folder;
  setUpAll(loadEnglishTexts);
  setUp(() => folder = Directory.systemTemp.createTempSync('splat_gate_test_'));
  tearDown(() => folder.deleteSync(recursive: true));

  var runtimeLoads = 0;

  HardwareGate gate(
    FakeGpuProbe? probe, {
    Abi abi = Abi.windowsX64,
    int? memory = 16790478848,
    Set<AiFeatureGroup> heldGroups = const {},
    List<AiComponent>? catalogue,
  }) => HardwareGate(
    components: _Installed(folder),
    facts: () => AiHardwareFacts(abi: abi, processors: 24, physicalMemory: memory),
    loadRuntime: (path) async {
      runtimeLoads++;
      return (version: '1.23.2', error: null);
    },
    gpu: probe,
    catalogue: catalogue ?? _built,
    heldGroups: heldGroups,
  );

  Future<AiGateResult> splat(GpuReport report, {int? memory = 16790478848, Abi abi = Abi.windowsX64}) =>
      gate(FakeGpuProbe.of(report), memory: memory, abi: abi).evaluate(feature: AiFeature.splatScene);

  setUp(() => runtimeLoads = 0);

  group('a feature of archives alone', () {
    test('available with COLMAP and Brush installed, ONNX Runtime never loaded nor asked for', () async {
      final result = await splat(FakeGpuReports.rtx4060);

      expect(result.isAvailable, isTrue, reason: '$result');
      expect(runtimeLoads, 0);
      expect(result.runtimeFile, isNull);
      expect(result.modelFile, isNull);
      expect(result.fileOf(colmapWindowsComponent.id), isNotNull);
      expect(result.fileOf(brushWindowsComponent.id), isNotNull);
      expect(result.gpu!.name, rtx4060Laptop.name);
      expect(result.graphicsMemoryNeeded, SplatV1.minGraphicsMemory);
    });

    test('a component missing is said as for the other features', () async {
      final empty = HardwareGate(
        components: _Missing(),
        facts: () => const AiHardwareFacts(abi: Abi.windowsX64, processors: 24, physicalMemory: 16 * _gib),
        loadRuntime: (path) async => throw StateError('never loaded'),
        gpu: FakeGpuProbe.of(FakeGpuReports.rtx4060),
        catalogue: _built,
        heldGroups: const {},
      );
      final result = await empty.evaluate(feature: AiFeature.splatScene);

      expect(result.reason, AiGateReason.componentsMissing);
      expect(result.missing.map((component) => component.id), [colmapWindowsComponent.id, brushWindowsComponent.id]);
    });

    test('the 3D photo still needs ONNX Runtime and its model, loaded once', () async {
      final result = await gate(null).evaluate();

      expect(result.isAvailable, isTrue, reason: '$result');
      expect(result.runtimeFile, isNotNull);
      expect(result.modelFile, isNotNull);
      expect(runtimeLoads, 1);
    });

    test('held back: not in this version, before the probe of the cards is started', () async {
      final probe = FakeGpuProbe.of(FakeGpuReports.rtx4060);
      final result = await gate(
        probe,
        heldGroups: const {AiFeatureGroup.splats},
      ).evaluate(feature: AiFeature.splatScene);

      expect(result.reason, AiGateReason.notInThisVersion);
      expect(probe.calls, 0);
    });

    test('not on Linux nor on a Mac in the first test build, without starting the probe', () async {
      for (final abi in [Abi.linuxX64, Abi.macosArm64, Abi.macosX64]) {
        final probe = FakeGpuProbe.of(FakeGpuReports.rtx4060);
        final result = await gate(probe, abi: abi).evaluate(feature: AiFeature.splatScene);
        expect(result.reason, AiGateReason.notHere, reason: '$abi');
        expect(probe.calls, 0, reason: '$abi');
      }
    });
  });

  group('the card and the memory', () {
    test('two cards: the dedicated one', () async {
      final result = await splat(FakeGpuReports.twoCards);

      expect(result.isAvailable, isTrue, reason: '$result');
      expect(result.gpu!.name, rtx4060Laptop.name);
    });

    test('integrated graphics alone are refused with the words of the splat scenes, the card named', () async {
      final result = await splat(FakeGpuReports.integratedOnly);

      expect(result.reason, AiGateReason.splatGpuIntegrated);
      expect(result.reason!.textKey, 'ai_immersive_splat_gpu_integrated');
      expect(result.gpu!.name, irisXe.name);
    });

    test('no Vulkan, no card, a card of Vulkan 1.1, or a loader of Vulkan 1.1: no graphics card with Vulkan', () async {
      for (final report in [
        FakeGpuReports.noVulkan,
        FakeGpuReports.noDevice,
        GpuReport(adapters: [_card(api: '1.1.130')]),
        GpuReport(adapters: [_card()], instanceVersion: '1.1.121'),
        GpuReport(adapters: [_card(source: 'dxgi')]),
      ]) {
        expect((await splat(report)).reason, AiGateReason.gpuNone, reason: '${report.toJson()}');
      }
    });

    test('a probe that does not answer: the graphics card did not answer', () async {
      expect((await splat(FakeGpuReports.noAnswer)).reason, AiGateReason.gpuNoAnswer);
    });

    test('a dedicated card of 3 GiB is too small, said with its memory and the 3.5 GiB needed', () async {
      final result = await splat(GpuReport(adapters: [_card(memory: 3 * _gib)]));

      expect(result.reason, AiGateReason.splatGpuTooSmall);
      expect(result.graphicsMemory, 3 * _gib);
      expect(result.graphicsMemoryNeeded, 3584 * _mib);
    });

    test(
      'a card sold with 4 GB, read as 3 962 MiB, makes splat scenes; the 8 GB of the RTX 4060 read as 7.77 GiB',
      () async {
        final four = await splat(GpuReport(adapters: [_card(memory: 3962 * _mib)]));
        final eight = await splat(GpuReport(adapters: [_card(memory: 8342470656)]));

        expect(four.isAvailable, isTrue, reason: '$four');
        expect(eight.isAvailable, isTrue, reason: '$eight');
      },
    );

    test('a dedicated card of 6 GiB, too small for a panorama, makes splat scenes', () async {
      final result = await splat(FakeGpuReports.sixGigabytes);

      expect(result.isAvailable, isTrue, reason: '$result');
      expect(result.gpu!.name, sixGigabyteCard.name);
    });

    test('the dedicated card with the most memory of two', () async {
      final small = _card(name: 'Small', memory: 4 * _gib);
      final large = _card(name: 'Large', memory: 12 * _gib);
      expect((await splat(GpuReport(adapters: [small, large]))).gpu!.name, 'Large');
    });

    test(
      'a computer sold with 8 GB, read as 7.8 GiB, makes splat scenes; 6.9 GiB is refused, said with both',
      () async {
        final eight = await splat(FakeGpuReports.rtx4060, memory: 7 * _gib + 800 * _mib);
        final short = await splat(FakeGpuReports.rtx4060, memory: 6 * _gib + 922 * _mib);

        expect(eight.isAvailable, isTrue, reason: '$eight');
        expect(short.reason, AiGateReason.splatMemory);
        expect(short.memoryNeeded, 7 * _gib);
        expect(short.physicalMemory, 6 * _gib + 922 * _mib);
      },
    );

    test('splatCardOf alone: integrated never allowed, whatever the switch of the panoramas says', () {
      final choice = splatCardOf(FakeGpuReports.integratedOnly, integratedAllowed: true);
      expect(choice.card!.name, irisXe.name);
      expect(choice.refusal, AiGateReason.splatGpuIntegrated);
      expect(splatCardOf(FakeGpuReports.twoCards, integratedAllowed: false).refusal, isNull);
    });
  });

  group('the budget of the queue, by kind', () {
    test('a splat scene needs 2.5 GiB free on its card, a panorama 6 GiB', () async {
      final busy = GpuReport(
        adapters: [_card(memory: 8 * _gib, budget: 7 * _gib, usage: 4 * _gib)],
      );
      final budget = GpuBudget(probe: () async => busy);

      expect(gpuNeedOf(ImmersiveKind.gaussianSplat).bytes, SplatV1.freeGraphicsMemory);
      expect(gpuNeedOf(ImmersiveKind.panorama360).bytes, panoramaFreeGraphicsMemory);
      expect(await budget.check(need: gpuNeedOf(ImmersiveKind.gaussianSplat)), isA<GpuBudgetReady>());
      expect(await budget.check(need: gpuNeedOf(ImmersiveKind.panorama360)), isA<GpuBudgetWait>());
      // Without a need, the one the budget was made with
      expect(await budget.check(), isA<GpuBudgetWait>());
    });

    test('integrated graphics alone: no card can take a splat scene', () async {
      final budget = GpuBudget(probe: () async => FakeGpuReports.integratedOnly, integratedAllowed: () async => true);

      final check = await budget.check(need: gpuNeedOf(ImmersiveKind.gaussianSplat));
      expect(check, isA<GpuBudgetUnavailable>());
      expect((check as GpuBudgetUnavailable).reason, AiGateReason.splatGpuIntegrated);
      // The panoramas keep their switch: on, the Iris Xe takes one
      expect(await budget.check(need: gpuNeedOf(ImmersiveKind.panorama360)), isA<GpuBudgetReady>());
    });
  });

  group('the words', () {
    test('each refusal of the gate in the words of the splat scenes', () async {
      final t = StaticTranslations.instance;

      expect(
        aiGateReasonText(t, await splat(FakeGpuReports.integratedOnly)),
        'Integrated graphics are not supported for splat scenes yet: a dedicated graphics card with Vulkan is needed',
      );
      expect(
        aiGateReasonText(t, await splat(GpuReport(adapters: [_card(memory: 3 * _gib)]))),
        'The graphics card has ${formatBytes(3 * _gib)} of memory, splat scenes need ${formatBytes(3584 * _mib)}',
      );
      expect(
        aiGateReasonText(t, await splat(FakeGpuReports.rtx4060, memory: 6 * _gib)),
        'Needs ${formatBytes(7 * _gib)} of memory, this computer has ${formatBytes(6 * _gib)}',
      );
    });

    test('a job the queue could not give a card says it in the words of the splat scenes', () {
      final t = StaticTranslations.instance;
      String text(String? message) =>
          conversionFailureText(t, ImmersiveErrorCode.gpuUnavailable, message, kind: ConversionKind.splatScene);

      expect(
        text(AiGateReason.splatGpuIntegrated.name),
        'Integrated graphics are not supported for splat scenes yet: a dedicated graphics card with Vulkan is needed',
      );
      expect(text(AiGateReason.gpuNone.name), 'No graphics card with Vulkan found');
      // Brush refused its kernels, or took another card
      expect(
        text('Brush cannot run its kernels on Intel UHD: plane instructions'),
        'This graphics card cannot run the splat training',
      );
      // A panorama keeps its words
      expect(
        conversionFailureText(t, ImmersiveErrorCode.gpuUnavailable, 'other'),
        'No graphics card can make this panorama',
      );
    });

    test('a refusal of the gate fails an engine of the graphics card with its code', () {
      expect(panoramaRefusalCode(AiGateReason.splatGpuIntegrated), ImmersiveErrorCode.gpuUnavailable);
      expect(panoramaRefusalCode(AiGateReason.splatGpuTooSmall), ImmersiveErrorCode.gpuUnavailable);
      expect(panoramaRefusalCode(AiGateReason.splatMemory), ImmersiveErrorCode.outOfMemory);
    });
  });
}

/// Nothing installed
class _Missing implements AiComponentFiles {
  @override
  Future<File?> verifiedFile(AiComponent component) async => null;

  @override
  AiComponentState stateOf(AiComponent component) => AiComponentState.notInstalled;
}
