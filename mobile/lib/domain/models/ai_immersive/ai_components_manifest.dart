// The catalogue of the AI components the app downloads when the user asks for them: the depth model and, on the
// computers, ONNX Runtime (design-final 2026-10-26, section 2.2). Compiled into the app: no remote manifest, so no
// network call without a gesture of the user, and a new version of a component comes with a new version of the app.
// The sums are always checked, whatever the source, so a mirror can serve nothing else.
//
// Shared with the Meta Quest, which reads the LiteRT model from it.

/// The tag of the prerelease that hosts the files (never "Latest": the app reads releases/latest)
const aiComponentsReleaseTag = 'ai-components-1';

/// Where the files of [aiComponentsReleaseTag] are downloaded from
const aiComponentsReleaseBase = 'https://github.com/freeKC/Immuch360/releases/download/$aiComponentsReleaseTag/';

/// The environment variable that replaces [aiComponentsReleaseBase] for the tests and the checks made before the
/// release is published: a URL or a file:// folder holding the same files
const aiComponentsMirrorVariable = 'IMMUCH360_AI_COMPONENTS_MIRROR';

/// The systems and processors a component runs on
enum AiPlatform { windowsX64, linuxX64, macosArm64, macosX64, questArm64 }

enum AiComponentKind { model, runtime }

/// How the file travels: as it is, or gzip compressed (the libraries), unpacked while it downloads
enum AiCompression { none, gzip }

/// One downloadable file
class AiComponent {
  const AiComponent({
    required this.id,
    required this.version,
    required this.kind,
    required this.platforms,
    required this.assetName,
    required this.installPath,
    required this.size,
    required this.sha256,
    required this.compression,
    required this.licence,
    required this.licenceUrl,
    this.downloadSize,
    this.officialUrls = const [],
  });

  /// "depth-anything-v2-small-onnx"
  final String id;
  final String version;
  final AiComponentKind kind;
  final Set<AiPlatform> platforms;

  /// The name of the file in the release (and in a mirror)
  final String assetName;

  /// Where the file goes in the components folder, with "/" between folders: "models/depth-anything-v2-small/..."
  final String installPath;

  /// The size of the file once installed, in bytes; null until the publication script of lot A3b reads it
  final int? size;

  /// The SHA-256 of the installed file, in hexadecimal; null until the publication script of lot A3b reads it
  final String? sha256;
  final AiCompression compression;

  /// The bytes to download when they differ from [size] (a compressed library); null when the same
  final int? downloadSize;

  /// SPDX identifier of the licence, and where to read it
  final String licence;
  final String licenceUrl;

  /// The official source, pinned to a commit, tried after the release; never for a library
  final List<String> officialUrls;

  /// Whether the catalogue knows the size and the sum: an incomplete component is never offered
  bool get isComplete => size != null && sha256 != null;

  /// The bytes the download takes
  int? get bytesToDownload => downloadSize ?? size;

  /// The addresses tried in order: the mirror alone when one is given (the tests stay offline), else the release then
  /// the official source
  List<String> urls({String? mirror}) {
    if (mirror != null && mirror.isNotEmpty) {
      return [_joined(mirror, assetName)];
    }
    return [_joined(aiComponentsReleaseBase, assetName), ...officialUrls];
  }
}

String _joined(String base, String name) => base.endsWith('/') ? '$base$name' : '$base/$name';

/// The depth model of the computers: Depth Anything V2 Small, fp32 ONNX export of onnx-community, revision 4472b736
const depthModelOnnxComponent = AiComponent(
  id: 'depth-anything-v2-small-onnx',
  version: '4472b736',
  kind: AiComponentKind.model,
  platforms: {AiPlatform.windowsX64, AiPlatform.linuxX64, AiPlatform.macosArm64, AiPlatform.macosX64},
  assetName: 'depth_anything_v2_small.onnx',
  installPath: 'models/depth-anything-v2-small/depth_anything_v2_small.onnx',
  size: 99060839,
  sha256: 'afb6a5c28f3b6bf1618c6e43f02073ef9dfdc70e937502d51603e57b0a1df10c',
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: 'https://huggingface.co/onnx-community/depth-anything-v2-small',
  officialUrls: [
    'https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/4472b7362082ad9968fee890ca0f1e5aca36b93d/onnx/model.onnx',
  ],
);

/// The depth model of the Quest: the same weights, fp32 LiteRT export of litert-community, revision 178427e4
const depthModelTfliteComponent = AiComponent(
  id: 'depth-anything-v2-small-tflite',
  version: '178427e4',
  kind: AiComponentKind.model,
  platforms: {AiPlatform.questArm64},
  assetName: 'depth_anything_v2_small.tflite',
  installPath: 'models/depth-anything-v2-small/depth_anything_v2_small.tflite',
  size: 99530468,
  sha256: '651415f1774e02d06de946eccf2e6dbbc5f499a9e932d9de7ada3d59637d2e8e',
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: 'https://huggingface.co/litert-community/depth-anything-v2-small/blob/main/LICENSE',
  officialUrls: [
    'https://huggingface.co/litert-community/depth-anything-v2-small/resolve/178427e448dbf4da93b1e7b1b2abc103ad329bd6/tflite/depth_anything_v2_small.tflite',
  ],
);

// ONNX Runtime, the libraries of the official archives copied as they are (the Authenticode signature of the DLL
// kept), gzip compressed in the release. To be completed by lot A3b: the size and SHA-256 of each installed file, and
// the size of each compressed one, which its publication script reads. Known so far: onnxruntime.dll 17.3 MB,
// libonnxruntime.so.1.31.0 29 345 384 bytes (archive of 11 408 003 bytes), libonnxruntime.1.31.0.dylib 44.8 MB.

const _ortLicence = 'MIT';

/// ONNX Runtime 1.31.0 for Windows x64
const onnxRuntimeWindowsComponent = AiComponent(
  id: 'onnxruntime-1.31.0-win-x64',
  version: '1.31.0',
  kind: AiComponentKind.runtime,
  platforms: {AiPlatform.windowsX64},
  assetName: 'onnxruntime-1.31.0-win-x64.dll.gz',
  installPath: 'runtime/onnxruntime-1.31.0/onnxruntime.dll',
  size: null,
  sha256: null,
  compression: AiCompression.gzip,
  licence: _ortLicence,
  licenceUrl: 'https://github.com/microsoft/onnxruntime/blob/v1.31.0/LICENSE',
);

/// ONNX Runtime 1.31.0 for Linux x64 (glibc 2.28 and later)
const onnxRuntimeLinuxComponent = AiComponent(
  id: 'onnxruntime-1.31.0-linux-x64',
  version: '1.31.0',
  kind: AiComponentKind.runtime,
  platforms: {AiPlatform.linuxX64},
  assetName: 'onnxruntime-1.31.0-linux-x64.so.gz',
  installPath: 'runtime/onnxruntime-1.31.0/libonnxruntime.so.1.31.0',
  size: null,
  sha256: null,
  compression: AiCompression.gzip,
  licence: _ortLicence,
  licenceUrl: 'https://github.com/microsoft/onnxruntime/blob/v1.31.0/LICENSE',
);

/// ONNX Runtime 1.31.0 for macOS on Apple silicon
const onnxRuntimeMacArmComponent = AiComponent(
  id: 'onnxruntime-1.31.0-osx-arm64',
  version: '1.31.0',
  kind: AiComponentKind.runtime,
  platforms: {AiPlatform.macosArm64},
  assetName: 'onnxruntime-1.31.0-osx-arm64.dylib.gz',
  installPath: 'runtime/onnxruntime-1.31.0/libonnxruntime.1.31.0.dylib',
  size: null,
  sha256: null,
  compression: AiCompression.gzip,
  licence: _ortLicence,
  licenceUrl: 'https://github.com/microsoft/onnxruntime/blob/v1.31.0/LICENSE',
);

/// ONNX Runtime 1.23.2 for the Intel Macs, the last release with an osx-x86_64 archive; the app asks it for API 23
const onnxRuntimeMacIntelComponent = AiComponent(
  id: 'onnxruntime-1.23.2-osx-x86_64',
  version: '1.23.2',
  kind: AiComponentKind.runtime,
  platforms: {AiPlatform.macosX64},
  assetName: 'onnxruntime-1.23.2-osx-x86_64.dylib.gz',
  installPath: 'runtime/onnxruntime-1.23.2/libonnxruntime.1.23.2.dylib',
  size: null,
  sha256: null,
  compression: AiCompression.gzip,
  licence: _ortLicence,
  licenceUrl: 'https://github.com/microsoft/onnxruntime/blob/v1.23.2/LICENSE',
);

/// Every component of this version of the app. MiDaS v2.1 Small (MIT) joins only if the measures of the Quest (Q0)
/// ask for it.
const aiComponents = <AiComponent>[
  depthModelOnnxComponent,
  depthModelTfliteComponent,
  onnxRuntimeWindowsComponent,
  onnxRuntimeLinuxComponent,
  onnxRuntimeMacArmComponent,
  onnxRuntimeMacIntelComponent,
];

/// The components [platform] needs, the runtime first
List<AiComponent> aiComponentsFor(AiPlatform platform) => [
  for (final kind in const [AiComponentKind.runtime, AiComponentKind.model])
    ...aiComponents.where((component) => component.kind == kind && component.platforms.contains(platform)),
];

/// The component of [id], null for an id this version does not know (an installed.json of a newer version)
AiComponent? aiComponentById(String id) {
  for (final component in aiComponents) {
    if (component.id == id) {
      return component;
    }
  }
  return null;
}
