// The engine of the splat scenes as the app makes it (DesktopSplatEngine of desktop_conversion_tools.dart, lot SP6): made
// for each job from what the gate of the feature splatScene finds then; a refusal of the gate fails the job with its
// code and the name of its reason, never downloads anything; COLMAP and Brush found in the folders of their archives.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_gpu_probe.dart';
import '../fakes/fake_immersive_engine.dart';

/// Every component installed under [folder], each archive at its main file
class _Installed implements AiComponentFiles {
  _Installed(this.folder, {this.missing = false});

  final Directory folder;
  final bool missing;

  @override
  Future<File?> verifiedFile(AiComponent component) async {
    if (missing) {
      return null;
    }
    final file = File(p.join(folder.path, component.mainPath))..createSync(recursive: true);
    return file;
  }

  @override
  AiComponentState stateOf(AiComponent component) =>
      missing ? AiComponentState.notInstalled : AiComponentState.installed;
}

/// [component] complete, its archive holding [main] first
AiComponent _complete(AiComponent component, String main) => AiComponent(
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
  archiveFiles: [AiArchiveFile(path: main, size: 100, sha256: 'bb', executable: true)],
);

void main() {
  late Directory folder;
  late NativeCancelFlag cancel;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('desktop_splat_engine_test_');
    cancel = NativeCancelFlag();
  });
  tearDown(() {
    cancel.free();
    folder.deleteSync(recursive: true);
  });

  List<AiComponent> catalogue({String colmapMain = 'colmap.exe', String brushMain = 'brush_app.exe'}) => [
    for (final component in aiComponents)
      if (component.id == colmapWindowsComponent.id)
        _complete(component, colmapMain)
      else if (component.id == brushWindowsComponent.id)
        _complete(component, brushMain)
      else
        component,
  ];

  HardwareGate gate(
    FakeGpuProbe probe, {
    bool missing = false,
    Set<AiFeatureGroup> held = const {},
    List<AiComponent>? components,
  }) => HardwareGate(
    components: _Installed(folder, missing: missing),
    facts: () => const AiHardwareFacts(abi: Abi.windowsX64, processors: 24, physicalMemory: 16790478848),
    loadRuntime: (path) async => throw StateError('no ONNX Runtime for a splat scene'),
    gpu: probe,
    catalogue: components ?? catalogue(),
    heldGroups: held,
  );

  SplatJob job() => SplatJob(
    id: 'conversion-1',
    lead: const ImmersiveSource(name: 'a.jpg', size: 1, sha1: 'x', path: 'a.jpg'),
    members: const [],
    partPath: p.join(folder.path, '.salon_splat.spz.part'),
    derivativeId: 'd',
    creatorTool: 't',
    created: 'c',
  );

  test('available: COLMAP and Brush of their archives given to the engine of the job, which runs it', () async {
    SplatSetup? given;
    final engine = DesktopSplatEngine(
      gate: gate(FakeGpuProbe.of(FakeGpuReports.twoCards)),
      create: (setup, found) {
        given = setup;
        expect(found.gpu!.name, rtx4060Laptop.name);
        return _Done();
      },
    );
    final result = await engine.run(job(), cancel: cancel);

    expect(result.isDone, isTrue);
    expect(given!.colmap, p.join(folder.path, 'engines', 'colmap-cpu-win-x64', 'colmap.exe'));
    expect(given!.brush, p.join(folder.path, 'engines', 'brush-vulkan-win-x64', 'brush_app.exe'));
    expect(given!.linuxLauncher, isNull);
    expect(engine.isRunning, isFalse);
  });

  test('an archive whose first program is not COLMAP: the COLMAP of its folder', () async {
    final found = await gate(
      FakeGpuProbe.of(FakeGpuReports.rtx4060),
      components: catalogue(colmapMain: 'bin/vcomp140.dll', brushMain: 'bin/brush_app.exe'),
    ).evaluate(feature: AiFeature.splatScene);
    final setup = splatSetupOf(found);

    expect(setup.colmap, p.join(folder.path, 'engines', 'colmap-cpu-win-x64', 'bin', 'colmap.exe'));
    expect(setup.brush, p.join(folder.path, 'engines', 'brush-vulkan-win-x64', 'bin', 'brush_app.exe'));
  });

  test('integrated graphics alone: gpuUnavailable with the reason of the splat scenes, nothing made', () async {
    final engine = DesktopSplatEngine(
      gate: gate(FakeGpuProbe.of(FakeGpuReports.integratedOnly)),
      create: (setup, found) => fail('no engine for a refused card'),
    );
    final result = await engine.run(job(), cancel: cancel);

    expect((result.error, result.message), (ImmersiveErrorCode.gpuUnavailable, AiGateReason.splatGpuIntegrated.name));
  });

  test('a component missing: componentsMissing, nothing downloaded', () async {
    final engine = DesktopSplatEngine(
      gate: gate(FakeGpuProbe.of(FakeGpuReports.rtx4060), missing: true),
      create: (setup, found) => fail('no engine without its programs'),
    );
    expect((await engine.run(job(), cancel: cancel)).error, ImmersiveErrorCode.componentsMissing);
  });

  test('held back in this version: the reason said, nothing made', () async {
    final engine = DesktopSplatEngine(
      gate: gate(FakeGpuProbe.of(FakeGpuReports.rtx4060), held: aiHeldFeatureGroups),
      create: (setup, found) => fail('held back'),
    );
    final result = await engine.run(job(), cancel: cancel);
    expect((result.error, result.message), (ImmersiveErrorCode.modelFailed, AiGateReason.notInThisVersion.name));
  });

  test('registered for the splat scenes, no version looked for', () async {
    final registered = splatConversionEngine(FakeImmersiveEngine());
    expect(await registered.settingsKey(const ImmersiveSource(name: 'a', size: 1, sha1: 'x', path: 'a'), 0), isNull);
  });
}

class _Done implements ImmersiveEngine {
  @override
  Future<ImmersiveResult> run(
    covariant ImmersiveJobSpec job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async => const ImmersiveResult.made(
    details: SplatResultDetails(gaussians: 1, images: 20, placed: 20, subject: SplatSubject.place, scale: 1),
    bytesWritten: 1,
  );

  @override
  Future<void> dispose() async {}
}
