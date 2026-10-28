// The hardware gate of the AI features on a computer (lot A4b): the reasons of a refusal on each system, with fake
// probes for the processor, the memory, the components and ONNX Runtime; the texts they name.

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:path/path.dart' as p;

const _gib = 1024 * 1024 * 1024;

/// Components in chosen states; the installed ones are files of [folder]
class _FakeComponents implements AiComponentFiles {
  _FakeComponents(this.folder, {this.states = const {}});

  final Directory folder;

  /// By component id; installed when not given
  final Map<String, AiComponentState> states;

  AiComponentState _state(AiComponent component) => states[component.id] ?? AiComponentState.installed;

  @override
  Future<File?> verifiedFile(AiComponent component) async {
    if (_state(component) != AiComponentState.installed) {
      return null;
    }
    final file = File(p.join(folder.path, component.installPath));
    if (!file.existsSync()) {
      file
        ..createSync(recursive: true)
        ..writeAsStringSync(component.id);
    }
    return file;
  }

  @override
  AiComponentState stateOf(AiComponent component) => _state(component);
}

void main() {
  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('hardware_gate_test_'));
  tearDown(() => folder.deleteSync(recursive: true));

  HardwareGate gate({
    Abi abi = Abi.windowsX64,
    int? memory = 16 * _gib,
    Map<String, AiComponentState> states = const {},
    String? runtimeError,
    List<String>? loads,
  }) => HardwareGate(
    components: _FakeComponents(folder, states: states),
    facts: () => AiHardwareFacts(abi: abi, processors: 8, physicalMemory: memory),
    loadRuntime: (path) async {
      loads?.add(path);
      return runtimeError == null ? (version: '1.31.0', error: null) : (version: null, error: runtimeError);
    },
  );

  group('by feature, each component asked for by its id', () {
    test('a 3D scene asks for ONNX Runtime, MoGe and LaMa, and gives each file by its id', () async {
      final loads = <String>[];
      final result = await gate(abi: Abi.linuxX64, loads: loads).evaluate(feature: AiFeature.scene);

      expect(result.isAvailable, isTrue, reason: '$result');
      expect(result.feature, AiFeature.scene);
      expect(result.fileOf(mogeGeometryComponent.id)!.path, endsWith(mogeGeometryComponent.installPath));
      expect(result.fileOf(lamaInpaintComponent.id)!.path, endsWith(lamaInpaintComponent.installPath));
      expect(result.fileOf(depthModelOnnxComponent.id), isNull);
      expect(result.runtimeFile!.path, endsWith(onnxRuntimeLinuxComponent.installPath));
      expect(loads, hasLength(1));
    });

    test('LaMa missing: the scene is refused with LaMa to install; the 3D photo stays available', () async {
      final missing = gate(abi: Abi.linuxX64, states: {lamaInpaintComponent.id: AiComponentState.notInstalled});

      final scene = await missing.evaluate(feature: AiFeature.scene);
      final photo = await missing.evaluate();

      expect(scene.reason, AiGateReason.componentsMissing);
      expect(scene.missing, [lamaInpaintComponent]);
      expect(photo.isAvailable, isTrue);
      expect(photo.feature, AiFeature.stereoPhoto);
    });

    test('the 3D photo never asks for a component of a later feature', () async {
      final result = await gate(
        abi: Abi.windowsX64,
        states: {
          for (final component in aiComponents)
            if (!component.features.contains(AiFeature.stereoPhoto)) component.id: AiComponentState.damaged,
        },
      ).evaluate();

      expect(result.isAvailable, isTrue, reason: '$result');
      expect(result.files.keys, unorderedEquals([onnxRuntimeWindowsComponent.id, depthModelOnnxComponent.id]));
    });

    test('a 360° panorama: not on a Mac; not in this version until the engine of P2 is in the catalogue', () async {
      final mac = await gate(abi: Abi.macosArm64).evaluate(feature: AiFeature.panorama);
      final windows = await gate(abi: Abi.windowsX64).evaluate(feature: AiFeature.panorama);

      expect(mac.reason, AiGateReason.notHere);
      expect(mac.reason!.textKey, 'ai_immersive_unavailable_system');
      expect(windows.reason, AiGateReason.notInThisVersion);
      expect(windows.reason!.textKey, 'ai_immersive_unavailable_build');
      expect(windows.missing, [sdCppWindowsComponent]);
    });

    test('the variant of a component is the one the memory of the card takes', () async {
      AiComponent transformer(String id, int memory, {String? of}) => AiComponent(
        id: id,
        version: '1',
        kind: AiComponentKind.model,
        platforms: const {AiPlatform.linuxX64},
        assetName: '$id.gguf',
        installPath: 'models/t/$id.gguf',
        size: 10,
        sha256: 'a' * 64,
        compression: AiCompression.none,
        licence: 'Apache-2.0',
        licenceUrl: 'https://example.org',
        features: const {AiFeature.panorama},
        variantOf: of,
        minGraphicsMemory: memory,
      );
      final catalogue = [
        onnxRuntimeLinuxComponent,
        transformer('q8', 10 * _gib),
        transformer('q4', 7 * _gib, of: 'q8'),
      ];
      final variants = HardwareGate(
        components: _FakeComponents(folder),
        facts: () => const AiHardwareFacts(abi: Abi.linuxX64, processors: 8, physicalMemory: 16 * _gib),
        loadRuntime: (path) async => (version: '1.31.0', error: null),
        catalogue: catalogue,
      );

      final small = await variants.evaluate(feature: AiFeature.panorama, graphicsMemory: 8 * _gib);
      final large = await variants.evaluate(feature: AiFeature.panorama, graphicsMemory: 12 * _gib);

      expect(small.files.keys, unorderedEquals([onnxRuntimeLinuxComponent.id, 'q4']));
      expect(large.files.keys, unorderedEquals([onnxRuntimeLinuxComponent.id, 'q8']));
    });
  });

  group('the system and the processor', () {
    test('Windows x64, Linux x64 and both kinds of Mac are offered, each with its own runtime', () async {
      for (final (abi, platform, runtime) in [
        (Abi.windowsX64, AiPlatform.windowsX64, onnxRuntimeWindowsComponent),
        (Abi.linuxX64, AiPlatform.linuxX64, onnxRuntimeLinuxComponent),
        (Abi.macosArm64, AiPlatform.macosArm64, onnxRuntimeMacArmComponent),
        (Abi.macosX64, AiPlatform.macosX64, onnxRuntimeMacIntelComponent),
      ]) {
        final result = await gate(abi: abi).evaluate();
        expect(result.isAvailable, isTrue, reason: '$abi: $result');
        expect(result.platform, platform);
        expect(result.runtimeFile!.path, endsWith(runtime.installPath));
        expect(result.modelFile!.path, endsWith(depthModelOnnxComponent.installPath));
        expect(result.runtimeVersion, '1.31.0');
        expect((result.processors, result.physicalMemory), (8, 16 * _gib));
      }
    });

    test('Windows or Linux on ARM: not yet on this processor', () async {
      for (final abi in [Abi.windowsArm64, Abi.windowsIA32, Abi.linuxArm64, Abi.linuxArm, Abi.linuxRiscv64]) {
        final result = await gate(abi: abi).evaluate();
        expect(result.reason, AiGateReason.processor, reason: '$abi');
        expect(result.reason!.textKey, 'ai_immersive_unavailable_arm');
        expect(result.platform, isNull);
      }
    });

    test('any other system: not on this system yet', () async {
      for (final abi in [Abi.androidArm64, Abi.iosArm64, Abi.fuchsiaX64]) {
        expect((await gate(abi: abi).evaluate()).reason, AiGateReason.system, reason: '$abi');
      }
    });
  });

  group('the memory', () {
    test('under 3.5 GiB of physical memory: not enough memory', () async {
      final result = await gate(memory: 3 * _gib).evaluate();
      expect(result.reason, AiGateReason.memory);
      expect(result.reason!.textKey, 'ai_immersive_unavailable_memory');
      expect(result.physicalMemory, 3 * _gib);
    });

    test('a computer sold with 4 GB passes; memory that could not be read refuses nothing', () async {
      expect((await gate(memory: (3.7 * _gib).round()).evaluate()).isAvailable, isTrue);
      expect((await gate(memory: null).evaluate()).isAvailable, isTrue);
      expect(aiMinimumPhysicalMemory, 3584 * 1024 * 1024);
    });
  });

  group('the components', () {
    test('one not installed, or being downloaded: missing, and which', () async {
      for (final state in [
        AiComponentState.notInstalled,
        AiComponentState.downloading,
        AiComponentState.removedNextStart,
      ]) {
        final result = await gate(states: {depthModelOnnxComponent.id: state}).evaluate();
        expect(result.reason, AiGateReason.componentsMissing, reason: '$state');
        expect(result.missing, [depthModelOnnxComponent]);
        expect(result.reason!.textKey, 'ai_immersive_unavailable_missing');
      }
    });

    test('one damaged: damaged, to download again', () async {
      final result = await gate(
        abi: Abi.linuxX64,
        states: {
          onnxRuntimeLinuxComponent.id: AiComponentState.damaged,
          depthModelOnnxComponent.id: AiComponentState.notInstalled,
        },
      ).evaluate();
      expect(result.reason, AiGateReason.componentsDamaged);
      expect(result.missing, [onnxRuntimeLinuxComponent, depthModelOnnxComponent]);
      expect(result.reason!.textKey, 'ai_immersive_unavailable_damaged');
    });
  });

  group('ONNX Runtime', () {
    test('a library that does not load: refused with its message', () async {
      const message = 'ONNX Runtime could not be loaded from /x/libonnxruntime.so.1.31.0: GLIBC_2.28 not found';
      final result = await gate(abi: Abi.linuxX64, runtimeError: message).evaluate();
      expect(result.reason, AiGateReason.runtimeFailed);
      expect(result.message, message);
      expect(result.reason!.textKey, 'ai_immersive_failed_model');
      expect(result.runtimeFile, isNull);
    });

    test('tried once per file; a file installed again is tried again', () async {
      final loads = <String>[];
      final check = gate(loads: loads);
      await check.evaluate();
      await check.evaluate();
      expect(loads, hasLength(1));
      final runtime = File(p.join(folder.path, onnxRuntimeWindowsComponent.installPath));
      runtime.writeAsStringSync('another build of the same version');
      await check.evaluate();
      expect(loads, hasLength(2));
    });

    test('loaded in a short isolate: a missing library says where it looked', () async {
      final missing = p.join(folder.path, 'nothing', 'onnxruntime.dll');
      final load = await loadRuntimeInIsolate(missing);
      expect(load.version, isNull);
      expect(load.error, 'No ONNX Runtime library at $missing');
    });
  });

  test('every text of a refusal is in i18n/en.json', () {
    final texts = jsonDecode(File('../i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    for (final reason in AiGateReason.values) {
      expect(texts, contains(reason.textKey), reason: reason.name);
    }
    expect(texts['ai_immersive_failed_model'], contains('{message}'));
  });

  test('the facts of this computer', () {
    final facts = AiHardwareFacts.ofThisComputer();
    expect(facts.abi, Abi.current());
    expect(facts.processors, Platform.numberOfProcessors);
    expect(facts.physicalMemory, greaterThan(_gib));
    expect(aiPlatformOf(Abi.current()), isNotNull, reason: 'the tests run on a computer the AI features support');
  });

  test('the processor of a refused system', () {
    expect(refusalOf(Abi.windowsArm64), AiGateReason.processor);
    expect(refusalOf(Abi.linuxIA32), AiGateReason.processor);
    expect(refusalOf(Abi.androidX64), AiGateReason.system);
  });
}
