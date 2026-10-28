// The graphics card in the settings (lot C6; design-final 2026-10-27, section 4.7, point 6): its name from the probe,
// the dedicated card of a laptop rather than the first adapter of Windows (V2, remark 10); and the line of the card
// for the 360° panoramas, which lot U3 shows: the card, its memory and its Vulkan when it passes, whatever the
// components; the card and the reason when it does not; the reason alone without a card.

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/ui/ai_settings_section.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/generated/translations.g.dart';

import '../creator/english_texts.dart';
import '../fakes/fake_gpu_probe.dart';

const _gib = 1024 * 1024 * 1024;
const _mib = 1024 * 1024;

class _NoFiles implements AiComponentFiles {
  @override
  Future<File?> verifiedFile(AiComponent component) async => null;

  @override
  AiComponentState stateOf(AiComponent component) => AiComponentState.notInstalled;
}

HardwareGate _gate(GpuReport report, {Abi abi = Abi.windowsX64, int memory = 16 * _gib}) => HardwareGate(
  components: _NoFiles(),
  facts: () => AiHardwareFacts(abi: abi, processors: 32, physicalMemory: memory),
  gpu: FakeGpuProbe.of(report),
);

void main() {
  setUpAll(loadEnglishTexts);

  group('the name of the graphics card', () {
    Future<String?> nameWith(GpuReport report) async {
      final container = ProviderContainer(overrides: [desktopAiGateProvider.overrideWithValue(_gate(report))]);
      addTearDown(container.dispose);
      return container.read(aiGpuNameProvider.future);
    }

    test('the dedicated card of a laptop, not its integrated graphics listed first', () async {
      expect(await nameWith(FakeGpuReports.twoCards), 'NVIDIA GeForce RTX 4060 Laptop GPU');
      final laptop = GpuReport.fromJson(
        jsonDecode(File('test/fixtures/ai_immersive/gpu_probe_rtx4060_laptop.json').readAsStringSync()),
      );
      expect(await nameWith(laptop), 'NVIDIA GeForce RTX 4060 Laptop GPU');
    });

    test('the integrated graphics when there is nothing else', () async {
      expect(await nameWith(FakeGpuReports.integratedOnly), irisXe.name);
    });
  });

  group('the line of the card for the panoramas', () {
    Future<String> line(GpuReport report, {Abi abi = Abi.windowsX64, int memory = 16 * _gib}) async => aiGpuLineText(
      StaticTranslations.instance,
      await _gate(report, abi: abi, memory: memory).evaluate(feature: AiFeature.panorama),
    );

    test('the card passes: its name, memory and Vulkan, the components not installed yet', () async {
      expect(
        await line(FakeGpuReports.twoCards),
        'NVIDIA GeForce RTX 4060 Laptop GPU, 8.0 GiB, Vulkan 1.4: 360° panoramas available',
      );
    });

    test('the card does not: its name and why', () async {
      expect(
        await line(FakeGpuReports.integratedOnly),
        "Intel(R) Iris(R) Xe Graphics (TGL GT2): Integrated graphics share the computer's memory: too slow for panoramas",
      );
      expect(
        await line(FakeGpuReports.sixGigabytes),
        'NVIDIA GeForce RTX 3060 Laptop GPU: The graphics card has 6.0 GiB of memory, 360° panoramas need 7.5 GiB',
      );
      expect(
        await line(FakeGpuReports.rtx4060, memory: 7 * _gib + 800 * _mib),
        'NVIDIA GeForce RTX 4060 Laptop GPU: Needs 14.0 GiB of memory, this computer has 7.8 GiB',
      );
    });

    test('no card: the reason alone', () async {
      expect(await line(FakeGpuReports.noVulkan), 'No graphics card with Vulkan found');
      expect(await line(FakeGpuReports.noAnswer), 'The graphics card did not answer');
      expect(await line(FakeGpuReports.mac, abi: Abi.macosArm64), 'Not yet on Mac');
    });
  });
}
