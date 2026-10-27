import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

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
        expect(component.notices == null, component.kind == AiComponentKind.model, reason: component.id);
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
        expect(['Apache-2.0', 'MIT'], contains(component.licence));
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
      // No component of a scene yet (lot C2): ONNX Runtime alone; the 3D version of a 360° photo needs phase 1 only
      expect(aiComponentsFor(AiPlatform.linuxX64, feature: AiFeature.scene), [onnxRuntimeLinuxComponent]);
      expect(aiComponentsFor(AiPlatform.linuxX64, feature: AiFeature.stereoPanorama), [
        onnxRuntimeLinuxComponent,
        depthModelOnnxComponent,
      ]);
      expect(aiComponentsFor(AiPlatform.questArm64, feature: AiFeature.scene), isEmpty);
    });

    test('the components of phase 1 stay in ai-components-1, in one asset each, no variant', () {
      for (final component in aiComponents) {
        expect(component.releaseTag, aiComponentsReleaseTag, reason: component.id);
        expect(component.parts, isEmpty);
        expect(component.isInParts, isFalse);
        expect(component.archiveFiles, isEmpty);
        expect(component.variantOf, isNull);
        expect(component.minGraphicsMemory, isNull);
      }
      expect(aiComponentsScenesReleaseTag, 'ai-components-2');
      expect(aiComponentsPanoramasReleaseTag, 'ai-components-3');
      expect(aiComponentsReleaseBaseOf(aiComponentsReleaseTag), aiComponentsReleaseBase);
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
