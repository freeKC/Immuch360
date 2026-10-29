// The gate of the 360° panoramas on the graphics card and the memory of the computer (lot C6; design-final 2026-10-27,
// sections 4.7 and 10.1 point 7): the answers of the probe of each case (no Vulkan, no card, an Iris Xe that shares the
// memory, a card of 6 GB, the RTX 4060 of 8 GB, two cards, a probe that does not answer, a Mac, 15.6 GiB of memory) and
// the reason each one gives; the integrated graphics allowed by their switch; the features of phases 1 and 2 never
// starting the probe; the words of each reason. The gates here hold back what this build holds back
// (aiHeldFeatureGroups: nothing since ai-components-3 was published), so the rules of the card are what the tests see;
// one test holds the panoramas back, and the card is looked at first all the same.

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/gpu/gpu_probe.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
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
    final file = File(p.join(folder.path, component.installPath));
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

/// The transformer of the panoramas as the catalogue has it (Q4_0, a card of 7.5 GiB), complete, and ONNX Runtime: the
/// panorama available once the graphics card and the memory pass
AiComponent _transformer({int memory = 8053063680}) => AiComponent(
  id: 'flux-q4',
  version: '1',
  kind: AiComponentKind.model,
  platforms: const {AiPlatform.windowsX64, AiPlatform.linuxX64},
  assetName: 'flux-q4.gguf',
  installPath: 'models/flux/flux-q4.gguf',
  size: 10,
  sha256: 'a' * 64,
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: 'https://huggingface.co/black-forest-labs/FLUX.2-klein-base-4B',
  features: const {AiFeature.panorama},
  minGraphicsMemory: memory,
);

GpuReport _fixture(String name) =>
    GpuReport.fromJson(jsonDecode(File('test/fixtures/ai_immersive/$name').readAsStringSync()));

void main() {
  late Directory folder;
  setUpAll(loadEnglishTexts);
  setUp(() => folder = Directory.systemTemp.createTempSync('gpu_gate_test_'));
  tearDown(() => folder.deleteSync(recursive: true));

  HardwareGate gate(
    GpuProbe? gpu, {
    Abi abi = Abi.windowsX64,
    int? memory = 16 * _gib,
    bool integratedAllowed = false,
    List<AiComponent>? catalogue,
    Set<AiFeatureGroup> heldGroups = aiHeldFeatureGroups,
  }) => HardwareGate(
    components: _Installed(folder),
    facts: () => AiHardwareFacts(abi: abi, processors: 32, physicalMemory: memory),
    loadRuntime: (path) async => (version: '1.31.0', error: null),
    gpu: gpu,
    integratedGpuAllowed: () async => integratedAllowed,
    catalogue: catalogue ?? [onnxRuntimeWindowsComponent, onnxRuntimeLinuxComponent, _transformer()],
    heldGroups: heldGroups,
  );

  Future<AiGateResult> panorama(GpuReport report, {Abi abi = Abi.windowsX64, int? memory = 16 * _gib}) =>
      gate(FakeGpuProbe.of(report), abi: abi, memory: memory).evaluate(feature: AiFeature.panorama);

  group('one reason for each answer of the probe', () {
    test('no Vulkan on the system, or no card: no graphics card with Vulkan found', () async {
      for (final report in [FakeGpuReports.noVulkan, FakeGpuReports.noDevice]) {
        final result = await panorama(report);
        expect(result.reason, AiGateReason.gpuNone, reason: '${report.toJson()}');
        expect(result.reason!.textKey, 'ai_immersive_gpu_none');
        expect(result.gpu, isNull);
      }
    });

    test('an Iris Xe that shares the memory of the computer: integrated graphics are too slow', () async {
      final result = await panorama(FakeGpuReports.integratedOnly);

      expect(result.reason, AiGateReason.gpuIntegrated);
      expect(result.gpu!.name, irisXe.name);
    });

    test('a dedicated card of 6 GB: its memory and what the panoramas need', () async {
      final result = await panorama(FakeGpuReports.sixGigabytes);

      expect(result.reason, AiGateReason.gpuTooSmall);
      expect(result.graphicsMemory, 6 * _gib);
      expect(result.graphicsMemoryNeeded, 8053063680);
      expect(result.gpu!.name, sixGigabyteCard.name);
    });

    test('the RTX 4060 Laptop of 8 GB: available, with the transformer of its memory', () async {
      final result = await panorama(FakeGpuReports.rtx4060);

      expect(result.isAvailable, isTrue, reason: '$result');
      expect(result.gpu!.name, rtx4060Laptop.name);
      expect(result.graphicsMemory, rtx4060Laptop.localMemory);
      expect(result.fileOf('flux-q4'), isNotNull);
    });

    test('two cards: the dedicated one, with the index ggml gives it', () async {
      final result = await panorama(FakeGpuReports.twoCards);

      expect(result.isAvailable, isTrue, reason: '$result');
      expect(result.gpu!.name, rtx4060Laptop.name);
      expect(ggmlVulkanIndexOf(result.gpuReport!, result.gpu!), 1);
    });

    test('the laptop of the owner as the native probe read it: the RTX 4060, Vulkan1 for ggml', () async {
      final report = _fixture('gpu_probe_rtx4060_laptop.json');
      final result = await panorama(report);

      expect(result.isAvailable, isTrue, reason: '$result');
      expect(result.gpu!.name, 'NVIDIA GeForce RTX 4060 Laptop GPU');
      expect(result.gpu!.vulkanIndex, 1);
      expect(ggmlVulkanIndexOf(report, result.gpu!), 1);
    });

    test('a probe that does not answer, or ends without its answer: the graphics card did not answer', () async {
      for (final report in [FakeGpuReports.noAnswer, const GpuReport(problem: GpuProbeProblem.failed)]) {
        final result = await panorama(report);
        expect(result.reason, AiGateReason.gpuNoAnswer, reason: '${report.toJson()}');
        expect(result.reason!.textKey, 'ai_immersive_gpu_no_answer');
      }
    });

    test('a Mac: not yet on Mac, without starting the probe', () async {
      for (final abi in [Abi.macosArm64, Abi.macosX64]) {
        final probe = FakeGpuProbe.of(FakeGpuReports.mac);
        final result = await gate(probe, abi: abi).evaluate(feature: AiFeature.panorama);
        expect(result.reason, AiGateReason.notYetOnMac, reason: '$abi');
        expect(result.reason!.textKey, 'ai_immersive_gpu_not_on_mac');
        expect(probe.calls, 0);
      }
    });

    test('Windows or Linux on ARM: not yet on this processor', () async {
      final result = await panorama(FakeGpuReports.rtx4060, abi: Abi.windowsArm64);
      expect(result.reason, AiGateReason.processor);
    });

    test('15.6 GiB of memory seen (a computer sold with 16 GB) passes; 8 GB does not, said with both', () async {
      final sixteen = await panorama(FakeGpuReports.rtx4060, memory: 16790478848);
      final eight = await panorama(FakeGpuReports.rtx4060, memory: 7 * _gib + 800 * _mib);

      expect(sixteen.isAvailable, isTrue, reason: '$sixteen');
      expect(eight.reason, AiGateReason.panoramaMemory);
      expect(eight.memoryNeeded, 14 * _gib);
      expect(eight.physicalMemory, 7 * _gib + 800 * _mib);
      expect(eight.gpu!.name, rtx4060Laptop.name, reason: 'the card is told all the same');
      expect(aiPanoramaMinimumPhysicalMemory, 14 * _gib);
    });

    test('memory that could not be read refuses nothing', () async {
      expect((await panorama(FakeGpuReports.rtx4060, memory: null)).isAvailable, isTrue);
    });
  });

  group('what makes a card usable', () {
    GpuAdapter card({
      String name = 'Card',
      GpuKind kind = GpuKind.discrete,
      int memory = 8 * _gib,
      String api = '1.3.280',
      bool? storage16Bit = true,
      String source = 'vulkan',
    }) => GpuAdapter(
      name: name,
      kind: kind,
      localMemory: memory,
      apiVersion: api,
      storage16Bit: storage16Bit,
      source: source,
    );

    test('Vulkan 1.2 at least, on the card and in the loader', () async {
      expect((await panorama(GpuReport(adapters: [card(api: '1.1.130')]))).reason, AiGateReason.gpuNone);
      expect((await panorama(GpuReport(adapters: [card(api: '1.2.0')]))).isAvailable, isTrue);
      expect((await panorama(GpuReport(adapters: [card()], instanceVersion: '1.1.121'))).reason, AiGateReason.gpuNone);
      expect((await panorama(GpuReport(adapters: [card()], instanceVersion: '1.4.309'))).isAvailable, isTrue);
    });

    test('a card without 16 bit storage buffers is left out, as ggml leaves it out', () async {
      expect((await panorama(GpuReport(adapters: [card(storage16Bit: false)]))).reason, AiGateReason.gpuNone);
    });

    test('a card only DXGI lists has no Vulkan to run on', () async {
      final result = await panorama(GpuReport(adapters: [card(source: 'dxgi')]));
      expect(result.reason, AiGateReason.gpuNone);
    });

    test('of two dedicated cards, the one with the most memory', () async {
      final result = await panorama(
        GpuReport(
          adapters: [
            card(name: 'Small', memory: 8 * _gib),
            card(name: 'Large', memory: 16 * _gib),
          ],
        ),
      );
      expect(result.gpu!.name, 'Large');
    });

    test('one card seen through two drivers: the one ggml keeps, so that sd-cli is given its index', () async {
      // An RX 7600 under AMDVLK (first in the loader) and under RADV, the same UUID: ggml keeps RADV alone, as Vulkan0
      GpuAdapter amd(String name, int place, int driver) => GpuAdapter(
        name: name,
        kind: GpuKind.discrete,
        localMemory: 8 * _gib,
        vendorId: 0x1002,
        apiVersion: '1.3.280',
        vulkanIndex: place,
        uuid: '0000000000000000000000000000abcd',
        driverId: driver,
        storage16Bit: true,
      );
      final report = GpuReport(
        instanceVersion: '1.3.280',
        adapters: [amd('AMD Radeon RX 7600', 0, 2), amd('AMD Radeon RX 7600 (RADV NAVI33)', 1, 3)],
      );
      final card = panoramaCardOf(report, integratedAllowed: false).card!;
      expect(card.name, 'AMD Radeon RX 7600 (RADV NAVI33)');
      expect(ggmlVulkanIndexOf(report, card), 0);
      expect((await panorama(report)).gpu!.vulkanIndex, 1);
    });

    test('a processor that Vulkan lists (llvmpipe) is no graphics card', () async {
      final result = await panorama(
        GpuReport(
          adapters: [card(kind: GpuKind.cpu, memory: 30 * _gib)],
        ),
      );
      expect(result.reason, AiGateReason.gpuNone);
    });
  });

  group('integrated graphics', () {
    test('refused by default, allowed by "Try on integrated graphics (untested)"', () async {
      final refused = await gate(FakeGpuProbe.of(FakeGpuReports.integratedOnly)).evaluate(feature: AiFeature.panorama);
      final allowed = await gate(
        FakeGpuProbe.of(FakeGpuReports.integratedOnly),
        integratedAllowed: true,
      ).evaluate(feature: AiFeature.panorama);

      expect(refused.reason, AiGateReason.gpuIntegrated);
      expect(allowed.isAvailable, isTrue, reason: '$allowed');
      expect(allowed.gpu!.name, irisXe.name);
    });

    test('ai1 as the native probe read it: the Iris Xe of Mesa refused, then taken by the switch', () async {
      final report = _fixture('gpu_probe_iris_xe_mesa.json');
      final refused = await gate(FakeGpuProbe.of(report), abi: Abi.linuxX64).evaluate(feature: AiFeature.panorama);
      final allowed = await gate(
        FakeGpuProbe.of(report),
        abi: Abi.linuxX64,
        integratedAllowed: true,
      ).evaluate(feature: AiFeature.panorama);

      expect(refused.reason, AiGateReason.gpuIntegrated);
      expect(allowed.isAvailable, isTrue, reason: '$allowed');
      expect(allowed.gpu!.name, 'Intel(R) Iris(R) Xe Graphics (TGL GT2)');
      expect(ggmlVulkanIndexOf(report, allowed.gpu!), 0);
    });

    test('the dedicated card goes first, the switch on or off', () async {
      final result = await gate(
        FakeGpuProbe.of(FakeGpuReports.twoCards),
        integratedAllowed: true,
      ).evaluate(feature: AiFeature.panorama);
      expect(result.gpu!.name, rtx4060Laptop.name);
    });

    test('an integrated card still needs the memory of the transformer', () async {
      const small = GpuReport(
        adapters: [
          GpuAdapter(name: 'Small iGPU', kind: GpuKind.integrated, localMemory: 4 * _gib, apiVersion: '1.3.0'),
        ],
      );
      final result = await gate(FakeGpuProbe.of(small), integratedAllowed: true).evaluate(feature: AiFeature.panorama);
      expect(result.reason, AiGateReason.gpuTooSmall);
    });
  });

  group('the probe', () {
    test('never started for the 3D photo, the 3D scene nor the 3D version of a 360° photo', () async {
      final probe = FakeGpuProbe.of(FakeGpuReports.rtx4060);
      final photos = gate(probe, catalogue: aiComponents);
      for (final feature in [AiFeature.stereoPhoto, AiFeature.scene, AiFeature.stereoPanorama]) {
        await photos.evaluate(feature: feature);
      }
      expect(probe.calls, 0);
    });

    test('asked once while its answer is fresh, again when asked for a fresh one', () async {
      final probe = FakeGpuProbe([FakeGpuReports.sixGigabytes, FakeGpuReports.rtx4060]);
      final once = gate(probe);

      expect((await once.evaluate(feature: AiFeature.panorama)).reason, AiGateReason.gpuTooSmall);
      expect((await once.evaluate(feature: AiFeature.panorama)).reason, AiGateReason.gpuTooSmall);
      expect(probe.calls, 1);
      await once.gpuReport(fresh: true);
      expect((await once.evaluate(feature: AiFeature.panorama)).isAvailable, isTrue);
      expect(probe.calls, 2);
    });

    test('an answer without a card is asked again sooner than a card', () async {
      var now = DateTime(2026, 10, 28, 12);
      final probe = FakeGpuProbe([FakeGpuReports.noAnswer, FakeGpuReports.rtx4060]);
      final timed = HardwareGate(
        components: _Installed(folder),
        facts: () => const AiHardwareFacts(abi: Abi.windowsX64, processors: 32, physicalMemory: 16 * _gib),
        loadRuntime: (path) async => (version: '1.31.0', error: null),
        gpu: probe,
        now: () => now,
        catalogue: [onnxRuntimeWindowsComponent, _transformer()],
      );

      expect((await timed.evaluate(feature: AiFeature.panorama)).reason, AiGateReason.gpuNoAnswer);
      now = now.add(const Duration(seconds: 20));
      expect((await timed.evaluate(feature: AiFeature.panorama)).reason, AiGateReason.gpuNoAnswer);
      now = now.add(const Duration(seconds: 20));
      expect((await timed.evaluate(feature: AiFeature.panorama)).isAvailable, isTrue);
      now = now.add(const Duration(minutes: 5));
      await timed.evaluate(feature: AiFeature.panorama);
      expect(probe.calls, 2);
    });

    test('a gate without a probe knows no card', () async {
      final result = await gate(null).evaluate(feature: AiFeature.panorama);
      expect(result.reason, AiGateReason.gpuNone);
    });
  });

  test('while the panoramas are held back, the card is looked at first, refused or named for the settings', () async {
    Future<AiGateResult> held(GpuReport report) => gate(
      FakeGpuProbe.of(report),
      heldGroups: const {AiFeatureGroup.panoramas},
    ).evaluate(feature: AiFeature.panorama);

    final passes = await held(FakeGpuReports.rtx4060);
    expect(passes.reason, AiGateReason.notInThisVersion);
    expect(passes.missing, isEmpty);
    expect(passes.gpu!.name, rtx4060Laptop.name);

    final integrated = await held(FakeGpuReports.integratedOnly);
    expect(integrated.reason, AiGateReason.gpuIntegrated);
    expect(integrated.gpu!.name, irisXe.name);
  });

  test('the words of each reason, with the memories they name', () async {
    final t = StaticTranslations.instance;
    Future<String> text(GpuReport report, {int memory = 16 * _gib, Abi abi = Abi.windowsX64}) async =>
        aiGateReasonText(t, await panorama(report, memory: memory, abi: abi));

    expect(await text(FakeGpuReports.noVulkan), 'No graphics card with Vulkan found');
    expect(await text(FakeGpuReports.noAnswer), 'The graphics card did not answer');
    expect(
      await text(FakeGpuReports.integratedOnly),
      "Integrated graphics share the computer's memory: too slow for panoramas",
    );
    expect(
      await text(FakeGpuReports.sixGigabytes),
      'The graphics card has 6.0 GiB of memory, 360° panoramas need 7.5 GiB',
    );
    expect(
      await text(FakeGpuReports.rtx4060, memory: 7 * _gib + 800 * _mib),
      'Needs 14.0 GiB of memory, this computer has 7.8 GiB',
    );
    expect(await text(FakeGpuReports.mac, abi: Abi.macosArm64), 'Not yet on Mac');
  });
}
