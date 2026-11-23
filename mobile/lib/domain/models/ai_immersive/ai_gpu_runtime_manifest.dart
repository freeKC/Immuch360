// The runtime of the graphics card of the 3D videos on Windows (lot ai-360-3d-51, 23 Nov 2026,
// desktop/ai/ort/depth_provider.dart): onnxruntime.dll of the official NuGet package Microsoft.ML.OnnxRuntime.DirectML
// 1.24.4 (MIT), which runs on the DirectML.dll of Windows itself. Its entry, onnxRuntimeDirectMlComponent, is in the
// catalogue of ai_components_manifest.dart (the videos group, Windows), in the prerelease ai-components-6 made by
// publish_ai_components.py from the package pinned by its SHA-256 (.github/desktop/ai/gpu_runtime.py makes the same
// files for the CI). This file says where the app finds the library: installed with the other components, or beside
// the executable of a test build of the CI made before that release ([directMlBundledPath]).

import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:path/path.dart' as p;

/// The official package the library is taken from, its size and its sum (api.nuget.org, read 23 Nov 2026)
const directMlPackageSize = 12458649;
const directMlPackageUrl =
    'https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime.directml/1.24.4/microsoft.ml.onnxruntime.directml.1.24.4.nupkg';
const directMlPackageSha256 = '57e9f11b73437bef7a309496135d4c1f96b1a8e9ddba60013fa27bfc1d788681';

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
