import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_licences.dart';

void main() {
  group('the catalogue of the AI components', () {
    test('the models carry the sizes and sums of the design', () {
      expect(depthModelOnnxComponent.size, 99060839);
      expect(depthModelOnnxComponent.sha256, depthModelOnnxSha256);
      expect(depthModelTfliteComponent.size, 99530468);
      expect(depthModelTfliteComponent.sha256, depthModelTfliteSha256);
      expect(depthModelOnnxComponent.isComplete, isTrue);
      expect(depthModelTfliteComponent.isComplete, isTrue);
    });

    test('every system has its runtime and its model, the runtime first; the Quest only the LiteRT model', () {
      for (final platform in [AiPlatform.windowsX64, AiPlatform.linuxX64, AiPlatform.macosArm64, AiPlatform.macosX64]) {
        final components = aiComponentsFor(platform);

        expect(components.map((component) => component.kind), [AiComponentKind.runtime, AiComponentKind.model]);
        expect(components.last, depthModelOnnxComponent);
      }
      expect(aiComponentsFor(AiPlatform.questArm64), [depthModelTfliteComponent]);
      expect(aiComponentsFor(AiPlatform.macosX64).first.version, '1.23.2');
    });

    test('the runtimes carry what the publication script read from the official archives', () {
      final runtimes = aiComponents.where((component) => component.kind == AiComponentKind.runtime);

      expect(runtimes, hasLength(4));
      for (final runtime in runtimes) {
        expect(runtime.isComplete, isTrue, reason: runtime.id);
        expect(runtime.compression, AiCompression.gzip);
        expect(runtime.downloadSize, lessThan(runtime.size!), reason: runtime.id);
        expect(runtime.bytesToDownload, runtime.downloadSize);
        expect(runtime.officialUrls, isEmpty);
        expect(runtime.licence, 'MIT');
      }
      // The sizes the design gives (section 2.1): 17.3 MB, 29 345 384 bytes, 44.8 MB
      expect(onnxRuntimeWindowsComponent.size, 17253176);
      expect(onnxRuntimeLinuxComponent.size, 29345384);
      expect(onnxRuntimeMacArmComponent.size, 44830288);
      expect(onnxRuntimeMacIntelComponent.size, 39742608);
    });

    test('every component has a name; ONNX Runtime has its notices, downloaded as a file of their own', () {
      expect(depthModelOnnxComponent.title, 'Depth Anything V2 Small');
      expect(onnxRuntimeMacIntelComponent.title, 'ONNX Runtime 1.23.2');
      for (final component in aiComponents) {
        expect(component.name, isNotNull, reason: component.id);
        expect(component.notices == null, component.kind != AiComponentKind.runtime, reason: component.id);
      }

      final notices = onnxRuntimeLinuxComponent.noticesDownload!;
      expect(notices.assetName, 'onnxruntime-1.31.0-ThirdPartyNotices.txt');
      expect(notices.installPath, 'licenses/onnxruntime-1.31.0-linux-x64-ThirdPartyNotices.txt');
      expect(notices.size, 338088);
      expect(notices.sha256, '143764b952fdb1a7c69ce653bfba74a7744d6a8a573bfb73e235fba356c83de3');
      expect(notices.compression, AiCompression.none);
      expect(notices.urls(), [
        'https://github.com/freeKC/Immuch360/releases/download/ai-components-1/onnxruntime-1.31.0-ThirdPartyNotices.txt',
      ]);
      expect(onnxRuntimeMacIntelComponent.notices!.assetName, 'onnxruntime-1.23.2-ThirdPartyNotices.txt');
      expect(depthModelOnnxComponent.noticesDownload, isNull);
      // A component without a name shows its id
      expect(onnxRuntimeLinuxComponent.noticesDownload!.title, 'onnxruntime-1.31.0-linux-x64-notices');
    });

    test('ids are unique, licences are permissive, sums are hexadecimal SHA-256', () {
      expect(aiComponents.map((component) => component.id).toSet(), hasLength(aiComponents.length));
      expect(aiComponents.map((component) => component.assetName).toSet(), hasLength(aiComponents.length));
      for (final component in aiComponents) {
        expect(['Apache-2.0', 'MIT', 'BSD-3-Clause'], contains(component.licence), reason: component.id);
        expect(component.licenceUrl, startsWith('https://'));
        final sum = component.sha256;
        if (sum != null) {
          expect(sum, matches(RegExp(r'^[0-9a-f]{64}$')));
        }
        expect(aiComponentById(component.id), same(component));
      }
      expect(aiComponentById('midas-v2.1-small-tflite'), isNull);
    });

    test('each component serves its features: the 3D photo never asks for the components of a later feature', () {
      expect(depthModelOnnxComponent.features, {AiFeature.stereoPhoto, AiFeature.stereoPanorama});
      expect(depthModelTfliteComponent.features, {AiFeature.stereoPhoto});
      for (final runtime in aiComponents.where((component) => component.kind == AiComponentKind.runtime)) {
        expect(runtime.features, AiFeature.values.toSet(), reason: runtime.id);
      }
      for (final platform in AiPlatform.values) {
        // The phase 1 callers, which name no feature, get what they got
        expect(aiComponentsFor(platform), aiComponentsFor(platform, feature: AiFeature.stereoPhoto));
        for (final feature in AiFeature.values) {
          expect(
            aiComponentsFor(platform, feature: feature).every((component) => component.features.contains(feature)),
            isTrue,
          );
        }
      }
      // A scene: ONNX Runtime, MoGe and LaMa; the 3D version of a 360° photo needs phase 1 only
      expect(aiComponentsFor(AiPlatform.linuxX64, feature: AiFeature.scene), [
        onnxRuntimeLinuxComponent,
        mogeGeometryComponent,
        lamaInpaintComponent,
      ]);
      expect(aiComponentsFor(AiPlatform.macosArm64, feature: AiFeature.scene), [
        onnxRuntimeMacArmComponent,
        mogeGeometryComponent,
        lamaInpaintComponent,
      ]);
      expect(aiComponentsFor(AiPlatform.linuxX64, feature: AiFeature.stereoPanorama), [
        onnxRuntimeLinuxComponent,
        depthModelOnnxComponent,
      ]);
      expect(aiComponentsFor(AiPlatform.questArm64, feature: AiFeature.scene), isEmpty);
      // A panorama: the runtime, the archive of the engine, then the models; not on the Macs, nor on the Quest
      expect(aiComponentsFor(AiPlatform.windowsX64, feature: AiFeature.panorama).map((component) => component.id), [
        'onnxruntime-1.31.0-win-x64',
        'sd-cpp-vulkan-win-x64',
        'moge-2-vits-normal-onnx-immuch360',
        'migan-512-places2-onnx',
        'flux2-klein-base-4b-q4_0',
        'qwen3-4b-q4_k_m',
        'flux2-vae',
        'flux2-klein-4b-360-erp-lora-v1',
        'realesrgan-x4plus',
      ]);
      expect(aiComponentsFor(AiPlatform.linuxX64, feature: AiFeature.panorama), contains(sdCppLinuxComponent));
      expect(aiComponentsFor(AiPlatform.macosArm64, feature: AiFeature.panorama), isEmpty);
      expect(aiComponentsFor(AiPlatform.macosX64, feature: AiFeature.panorama), isEmpty);
      expect(aiComponentsFor(AiPlatform.questArm64, feature: AiFeature.panorama), isEmpty);
      expect(aiComponentsFor(AiPlatform.questArm64, feature: AiFeature.stereoPanorama), isEmpty);
    });

    test('each component lives in the release of its family, in one asset each or in parts, no variant yet', () {
      const scenes = {'moge-2-vits-normal-onnx-immuch360', 'lama-onnx'};
      for (final component in aiComponents) {
        final family = component.features.contains(AiFeature.stereoPhoto)
            ? aiComponentsReleaseTag
            : scenes.contains(component.id)
            ? aiComponentsScenesReleaseTag
            : aiComponentsPanoramasReleaseTag;
        expect(component.releaseTag, family, reason: component.id);
        expect(component.variantOf, isNull, reason: component.id);
        expect(component.archiveFiles, isEmpty, reason: '${component.id}: lot P2 writes the files of the archives');
        expect(component.isArchive, component.id.startsWith('sd-cpp-'), reason: component.id);
        // Only a file of 2 GiB or more comes in parts
        expect(component.isInParts, (component.size ?? 0) >= aiReleaseAssetLimit, reason: component.id);
      }
      expect(aiComponentsScenesReleaseTag, 'ai-components-2');
      expect(aiComponentsPanoramasReleaseTag, 'ai-components-3');
      expect(aiComponentsReleaseBaseOf(aiComponentsReleaseTag), aiComponentsReleaseBase);
      expect(mogeGeometryComponent.urls(), [
        'https://github.com/freeKC/Immuch360/releases/download/ai-components-2/moge_2_vits_normal_immuch360.onnx',
      ]);
      expect(
        upscalerComponent.urls().first,
        'https://github.com/freeKC/Immuch360/releases/download/ai-components-3/RealESRGAN_x4plus.pth',
      );
    });

    test(
      'the scenes carry the sums M2 measured: our export of MoGe and LaMa, 349 MB; MI-GAN goes with the panoramas',
      () {
        expect(mogeGeometryComponent.size, 140852051);
        expect(mogeGeometryComponent.sha256, '24eacb5dc7a2c54c7bc98f7de085ffbed79ad006ea5b664c2c2cdc02ff3a52f0');
        expect(mogeGeometryComponent.officialUrls, isEmpty);
        expect(mogeGeometryComponent.features, {AiFeature.scene, AiFeature.panorama});
        expect(lamaInpaintComponent.assetName, 'lama_fp32.onnx');
        expect(lamaInpaintComponent.size, 208044816);
        expect(lamaInpaintComponent.sha256, '1faef5301d78db7dda502fe59966957ec4b79dd64e16f03ed96913c7a4eb68d6');
        expect(lamaInpaintComponent.features, {AiFeature.scene});
        expect(miganInpaintComponent.size, 28079181);
        expect(miganInpaintComponent.sha256, '6f1f3530a1a2324b19752018ce756088b07973cda8d7d890034ace5c8a48c40b');
        expect(miganInpaintComponent.features, {AiFeature.panorama});
        final scenes = aiComponentGroupsFor(
          AiPlatform.windowsX64,
        ).firstWhere((group) => group.group == AiFeatureGroup.scenes);
        expect(scenes.own, [mogeGeometryComponent, lamaInpaintComponent]);
        expect(scenes.own.fold<int>(0, (sum, component) => sum + component.size!), 348896867);
      },
    );

    test('the panoramas wait for P2: the archives of the engine are incomplete, so the group is never offered', () {
      expect(sdCppWindowsComponent.isComplete, isFalse);
      expect(sdCppLinuxComponent.isComplete, isFalse);
      for (final component in [
        miganInpaintComponent,
        fluxTransformerComponent,
        qwenTextEncoderComponent,
        fluxVaeComponent,
        panoramaLoraComponent,
        upscalerComponent,
      ]) {
        expect(component.isComplete, isTrue, reason: component.id);
        expect(component.officialUrls.single, startsWith('https://'), reason: component.id);
      }
      for (final platform in AiPlatform.values) {
        expect(
          aiComponentGroupsFor(platform).map((group) => group.group),
          isNot(contains(AiFeatureGroup.panoramas)),
          reason: platform.name,
        );
      }
      // The transformer M3 kept: Q4_0, for a dedicated card of 7.5 GiB at least
      expect(fluxTransformerComponent.minGraphicsMemory, 8053063680);
      expect(fluxTransformerComponent.assetName, 'flux-2-klein-base-4b-Q4_0.gguf');
      // sd-cli finds the LoRA by the name of its file
      expect(panoramaLoraComponent.installPath, endsWith('/flux-2-klein-4B-360-erp-outpaint-lora_V1.safetensors'));
    });

    test('a file in parts: parts of 1945 MiB end to end, each under the limit of GitHub, in its release', () {
      for (final component in aiComponents.where((component) => component.isInParts)) {
        expect(component.parts.fold<int>(0, (sum, part) => sum + part.size), component.size, reason: component.id);
        for (final (index, part) in component.parts.indexed) {
          expect(part.size, lessThan(aiReleaseAssetLimit));
          expect(part.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
          expect(part.assetName, '${component.assetName}.${'${index + 1}'.padLeft(3, '0')}');
          if (index < component.parts.length - 1) {
            expect(part.size, 1945 * 1024 * 1024);
          }
        }
        expect(component.partUrls().first, startsWith(aiComponentsReleaseBaseOf(component.releaseTag)));
      }
      expect(aiComponents.where((component) => component.isInParts).map((component) => component.id), [
        'flux2-klein-base-4b-q4_0',
        'qwen3-4b-q4_k_m',
      ]);
    });

    test('the app keeps the text of every licence, with its copyright line; the engine of P2 brings its own', () {
      for (final component in aiComponents) {
        final text = aiLicenceText(component);
        if (component.isArchive) {
          expect(text, 'See ${component.licenceUrl}\n', reason: component.id);
          continue;
        }
        expect(text, isNot(startsWith('See ')), reason: component.id);
        expect(text.length, greaterThan(1000), reason: component.id);
      }
      expect(aiLicenceText(mogeGeometryComponent), startsWith('MIT License\n\nCopyright (c) Microsoft Corporation.\n'));
      expect(aiLicenceText(mogeGeometryComponent), contains('Apache License'));
      expect(aiLicenceText(miganInpaintComponent), contains('Copyright (c) 2024 Picsart AI Research (PAIR)'));
      expect(aiLicenceText(upscalerComponent), startsWith('BSD 3-Clause License\n\nCopyright (c) 2021, Xintao Wang\n'));
      expect(aiLicenceText(lamaInpaintComponent), apacheLicence2);
    });

    test('of a component and its variant, the one the card takes with the most memory', () {
      const q8 = AiComponent(
        id: 'transformer-q8',
        version: '1',
        kind: AiComponentKind.model,
        platforms: {AiPlatform.windowsX64},
        assetName: 'q8.gguf',
        installPath: 'models/t/q8.gguf',
        size: 10,
        sha256: null,
        compression: AiCompression.none,
        licence: 'Apache-2.0',
        licenceUrl: 'https://example.org',
        features: {AiFeature.panorama},
        minGraphicsMemory: 10000,
      );
      const q4 = AiComponent(
        id: 'transformer-q4',
        version: '1',
        kind: AiComponentKind.model,
        platforms: {AiPlatform.windowsX64},
        assetName: 'q4.gguf',
        installPath: 'models/t/q4.gguf',
        size: 5,
        sha256: null,
        compression: AiCompression.none,
        licence: 'Apache-2.0',
        licenceUrl: 'https://example.org',
        features: {AiFeature.panorama},
        variantOf: 'transformer-q8',
        minGraphicsMemory: 6000,
      );
      List<String> chosen(int? memory, List<AiComponent> catalogue) => aiComponentsFor(
        AiPlatform.windowsX64,
        feature: AiFeature.panorama,
        graphicsMemory: memory,
        catalogue: catalogue,
      ).map((component) => component.id).toList();

      for (final catalogue in [
        [q8, q4],
        [q4, q8],
      ]) {
        expect(chosen(12000, catalogue), ['transformer-q8']);
        expect(chosen(10000, catalogue), ['transformer-q8']);
        expect(chosen(8000, catalogue), ['transformer-q4']);
        expect(chosen(6000, catalogue), ['transformer-q4']);
        // Too small for both: the one that asks the least, which the gate refuses with its reason
        expect(chosen(4000, catalogue), ['transformer-q4']);
        // Unknown: the main entry
        expect(chosen(null, catalogue), ['transformer-q8']);
      }
    });

    test('the groups: each component under the first group that needs it, a shared one counted once', () {
      final windows = aiComponentGroupsFor(AiPlatform.windowsX64);
      expect(windows.map((group) => group.group), [AiFeatureGroup.photos, AiFeatureGroup.scenes]);
      expect(windows.first.own, [onnxRuntimeWindowsComponent, depthModelOnnxComponent]);
      expect(windows.last.all, [onnxRuntimeWindowsComponent, mogeGeometryComponent, lamaInpaintComponent]);
      expect(windows.last.own, [mogeGeometryComponent, lamaInpaintComponent]);
      expect(aiComponentGroupsFor(AiPlatform.questArm64).single.own, [depthModelTfliteComponent]);

      // Once the engine has its files, the panoramas join: MoGe stays under the scenes, ONNX Runtime under the photos
      const engine = AiComponent(
        id: 'sd-cpp-vulkan-win-x64',
        version: 'test',
        kind: AiComponentKind.archive,
        platforms: {AiPlatform.windowsX64},
        assetName: 'sd-cpp-vulkan-win-x64.zip',
        installPath: 'engines/sd-cpp-vulkan-win-x64',
        size: 100,
        sha256: 'aa',
        compression: AiCompression.none,
        licence: 'MIT',
        licenceUrl: 'https://example.org',
        features: {AiFeature.panorama},
        releaseTag: aiComponentsPanoramasReleaseTag,
        archiveFiles: [
          AiArchiveFile(path: 'ggml-vulkan.dll', size: 40, sha256: 'bb'),
          AiArchiveFile(path: 'sd-cli.exe', size: 50, sha256: 'cc', executable: true),
        ],
      );
      final complete = [for (final component in aiComponents) component.id == engine.id ? engine : component];
      // Held until the engine of P3, the screens of U3 and the publication of ai-components-3: never offered
      expect(aiHeldFeatureGroups, {AiFeatureGroup.panoramas});
      expect(aiComponentGroupsFor(AiPlatform.windowsX64, catalogue: complete).map((group) => group.group), [
        AiFeatureGroup.photos,
        AiFeatureGroup.scenes,
      ]);
      final groups = aiComponentGroupsFor(AiPlatform.windowsX64, catalogue: complete, held: const {});
      expect(groups.map((group) => group.group), AiFeatureGroup.values);
      expect(groups.last.own.map((component) => component.id), [
        'sd-cpp-vulkan-win-x64',
        'migan-512-places2-onnx',
        'flux2-klein-base-4b-q4_0',
        'qwen3-4b-q4_k_m',
        'flux2-vae',
        'flux2-klein-4b-360-erp-lora-v1',
        'realesrgan-x4plus',
      ]);
      expect(groups.last.all, containsAll([onnxRuntimeWindowsComponent, mogeGeometryComponent]));
      // An archive: its size installed is that of its files, the program it runs its first executable
      expect(engine.installedSize, 90);
      expect(engine.mainPath, 'engines/sd-cpp-vulkan-win-x64/sd-cli.exe');
      expect(engine.isComplete, isTrue);
      expect(depthModelOnnxComponent.mainPath, depthModelOnnxComponent.installPath);
      expect(depthModelOnnxComponent.installedSize, depthModelOnnxComponent.size);
    });

    test('the 3D photo keeps the components of phase 1, which alone live in ai-components-1', () {
      // An entry of a later phase that forgets its features (the 3D photo by default) or its release (ai-components-1
      // by default) fails here: the 3D photo never depends on a component of a scene or of a panorama
      const phase1 = {
        'depth-anything-v2-small-onnx',
        'depth-anything-v2-small-tflite',
        'onnxruntime-1.31.0-win-x64',
        'onnxruntime-1.31.0-linux-x64',
        'onnxruntime-1.31.0-osx-arm64',
        'onnxruntime-1.23.2-osx-x86_64',
      };
      Set<String> idsWhere(bool Function(AiComponent) test) =>
          aiComponents.where(test).map((component) => component.id).toSet();

      expect(idsWhere((component) => component.features.contains(AiFeature.stereoPhoto)), phase1);
      expect(idsWhere((component) => component.releaseTag == aiComponentsReleaseTag), phase1);
      expect(
        {
          for (final platform in AiPlatform.values)
            platform: aiComponentsFor(platform).map((component) => component.id).toList(),
        },
        {
          AiPlatform.windowsX64: ['onnxruntime-1.31.0-win-x64', 'depth-anything-v2-small-onnx'],
          AiPlatform.linuxX64: ['onnxruntime-1.31.0-linux-x64', 'depth-anything-v2-small-onnx'],
          AiPlatform.macosArm64: ['onnxruntime-1.31.0-osx-arm64', 'depth-anything-v2-small-onnx'],
          AiPlatform.macosX64: ['onnxruntime-1.23.2-osx-x86_64', 'depth-anything-v2-small-onnx'],
          AiPlatform.questArm64: ['depth-anything-v2-small-tflite'],
        },
      );
    });

    test('a component of another release, in parts, downloads from its own release or the mirror', () {
      const transformer = AiComponent(
        id: 'flux2-klein-base-4b-q8_0',
        version: 'sample',
        kind: AiComponentKind.model,
        platforms: {AiPlatform.windowsX64, AiPlatform.linuxX64},
        assetName: 'flux2-klein-base-4b-q8_0.gguf',
        installPath: 'models/flux2-klein-base-4b/flux2-klein-base-4b-q8_0.gguf',
        size: 4300629440,
        sha256: null,
        compression: AiCompression.none,
        licence: 'Apache-2.0',
        licenceUrl: 'https://huggingface.co/black-forest-labs/FLUX.2-klein-base-4B',
        features: {AiFeature.panorama},
        releaseTag: aiComponentsPanoramasReleaseTag,
        parts: [
          AiComponentPart(assetName: 'flux2-klein-base-4b-q8_0.gguf.part1', size: 2040109465, sha256: 'a'),
          AiComponentPart(assetName: 'flux2-klein-base-4b-q8_0.gguf.part2', size: 2040109465, sha256: 'b'),
          AiComponentPart(assetName: 'flux2-klein-base-4b-q8_0.gguf.part3', size: 220410510, sha256: 'c'),
        ],
        minGraphicsMemory: 8053063680,
      );

      expect(transformer.isInParts, isTrue);
      expect(transformer.parts.fold<int>(0, (sum, part) => sum + part.size), transformer.size);
      expect(
        transformer.urls().first,
        startsWith('https://github.com/freeKC/Immuch360/releases/download/ai-components-3/'),
      );
      expect(transformer.partUrls(), [
        for (var i = 1; i <= 3; i++)
          'https://github.com/freeKC/Immuch360/releases/download/ai-components-3/flux2-klein-base-4b-q8_0.gguf.part$i',
      ]);
      expect(
        transformer.partUrls(mirror: 'file:///mnt/d/mirror').first,
        'file:///mnt/d/mirror/flux2-klein-base-4b-q8_0.gguf.part1',
      );
    });

    test('the release first then the pinned official source; a mirror alone when there is one', () {
      expect(depthModelOnnxComponent.urls(), [
        'https://github.com/freeKC/Immuch360/releases/download/ai-components-1/depth_anything_v2_small.onnx',
        'https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/4472b7362082ad9968fee890ca0f1e5aca36b93d/onnx/model.onnx',
      ]);
      expect(depthModelTfliteComponent.urls(mirror: 'file:///mnt/d/mirror'), [
        'file:///mnt/d/mirror/depth_anything_v2_small.tflite',
      ]);
      expect(onnxRuntimeLinuxComponent.urls(mirror: 'https://mirror.test/ai/'), [
        'https://mirror.test/ai/onnxruntime-1.31.0-linux-x64.so.gz',
      ]);
      expect(depthModelOnnxComponent.urls(release: 'https://127.0.0.1:4430/release'), [
        'https://127.0.0.1:4430/release/depth_anything_v2_small.onnx',
        ...depthModelOnnxComponent.officialUrls,
      ]);
      expect(onnxRuntimeLinuxComponent.urls(mirror: ''), [
        'https://github.com/freeKC/Immuch360/releases/download/ai-components-1/onnxruntime-1.31.0-linux-x64.so.gz',
      ]);
    });
  });
}
