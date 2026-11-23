// The runtime of the graphics card of the 3D videos on Windows (lot ai-360-3d-51, 23 Nov 2026,
// desktop/ai/ort/depth_provider.dart): onnxruntime.dll of the official NuGet package Microsoft.ML.OnnxRuntime.DirectML
// 1.24.4 (MIT), which runs on the DirectML.dll of Windows itself. Made by .github/desktop/ai/gpu_runtime.py from the
// package pinned by its SHA-256, for the prerelease ai-components-6, which is NOT published yet: until it is, the app
// never downloads it, and a test build of the CI carries the library next to its executable instead
// ([directMlBundledPath]). Once ai-components-6 is out, the component joins the catalogue of ai_components_manifest.dart
// (the videos group, Windows) and publish_ai_components.py.

import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:path/path.dart' as p;

/// The prerelease that will host the runtime of the graphics card
const aiComponentsGpuReleaseTag = 'ai-components-6';

/// The official package the library is taken from, its size and its sum (api.nuget.org, read 23 Nov 2026)
const directMlPackageSize = 12458649;
const directMlPackageUrl =
    'https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime.directml/1.24.4/microsoft.ml.onnxruntime.directml.1.24.4.nupkg';
const directMlPackageSha256 = '57e9f11b73437bef7a309496135d4c1f96b1a8e9ddba60013fa27bfc1d788681';

/// ThirdPartyNotices.txt of the package (CRLF line ends, as the package holds it)
const _directMlNotices = AiNoticesFile(
  assetName: 'onnxruntime-directml-1.24.4-ThirdPartyNotices.txt',
  size: 331175,
  sha256: 'fb0af774b4d7cffc5b9d046f2aaeade2f37df2f80abf8033c95dfffcc77a8866',
);

/// ONNX Runtime 1.24.4 with DirectML for Windows x64: runtimes/win-x64/native/onnxruntime.dll of the package, as it
/// is (its Authenticode signature kept), gzip compressed for the release
const onnxRuntimeDirectMlComponent = AiComponent(
  id: 'onnxruntime-directml-1.24.4-win-x64',
  name: 'ONNX Runtime 1.24.4 DirectML',
  version: '1.24.4',
  kind: AiComponentKind.runtime,
  platforms: {AiPlatform.windowsX64},
  assetName: 'onnxruntime-directml-1.24.4-win-x64.dll.gz',
  installPath: 'runtime/onnxruntime-directml-1.24.4/onnxruntime.dll',
  size: 17328152,
  sha256: 'e7eedec6a6f26dc39dc948276a75ef6d2bee3fff944d874ceed0bbd3b97bff40',
  compression: AiCompression.gzip,
  downloadSize: 6157978,
  licence: 'MIT',
  licenceUrl: 'https://www.nuget.org/packages/Microsoft.ML.OnnxRuntime.DirectML/1.24.4/License',
  notices: _directMlNotices,
  features: {AiFeature.stereoVideo},
  releaseTag: aiComponentsGpuReleaseTag,
);

/// Where a test build of the CI carries the library: beside its executable
const directMlBundledPath = 'ai-gpu/onnxruntime-directml-1.24.4/onnxruntime.dll';

/// The library of the graphics card of this computer: installed in the components folder [componentsFolder] (a later
/// build), else beside the executable [executableFolder] (a test build), each only with the size and the SHA-256 of
/// the catalogue; null when there is none, on any system but Windows
Future<String?> findDirectMlRuntime({String? componentsFolder, String? executableFolder}) async {
  const component = onnxRuntimeDirectMlComponent;
  final places = [
    if (componentsFolder != null) p.joinAll([componentsFolder, ...component.installPath.split('/')]),
    if (executableFolder != null) p.joinAll([executableFolder, ...directMlBundledPath.split('/')]),
  ];
  for (final place in places) {
    final file = File(place);
    if (!file.existsSync() || file.lengthSync() != component.size) {
      continue;
    }
    final digest = (await crypto.sha256.bind(file.openRead()).first).toString();
    if (digest == component.sha256) {
      return place;
    }
  }
  return null;
}
