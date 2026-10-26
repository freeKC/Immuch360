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

    test('the runtimes wait for lot A3b and are never offered meanwhile', () {
      final runtimes = aiComponents.where((component) => component.kind == AiComponentKind.runtime);

      expect(runtimes, hasLength(4));
      for (final runtime in runtimes) {
        expect(runtime.isComplete, isFalse, reason: runtime.id);
        expect(runtime.compression, AiCompression.gzip);
        expect(runtime.officialUrls, isEmpty);
        expect(runtime.licence, 'MIT');
      }
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

    test('the release first then the pinned official source; a mirror alone when there is one', () {
      expect(depthModelOnnxComponent.urls(), [
        'https://github.com/freeKC/Immuch360/releases/download/ai-components-1/depth_anything_v2_small.onnx',
        'https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/4472b7362082ad9968fee890ca0f1e5aca36b93d/onnx/model.onnx',
      ]);
      expect(depthModelTfliteComponent.urls(mirror: 'file:///mnt/d/mirror'), [
        'file:///mnt/d/mirror/depth_anything_v2_small.tflite',
      ]);
      expect(onnxRuntimeLinuxComponent.urls(mirror: 'http://127.0.0.1:8080/'), [
        'http://127.0.0.1:8080/onnxruntime-1.31.0-linux-x64.so.gz',
      ]);
      expect(onnxRuntimeLinuxComponent.urls(mirror: ''), [
        'https://github.com/freeKC/Immuch360/releases/download/ai-components-1/onnxruntime-1.31.0-linux-x64.so.gz',
      ]);
    });
  });
}
