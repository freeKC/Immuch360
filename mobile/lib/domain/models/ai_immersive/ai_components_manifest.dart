// The catalogue of the AI components the app downloads when the user asks for them: the depth model and, on the
// computers, ONNX Runtime (design-final 2026-10-26, section 2.2). Compiled into the app: no remote manifest, so no
// network call without a gesture of the user, and a new version of a component comes with a new version of the app.
// The sums are always checked, whatever the source, so a mirror can serve nothing else.
//
// Phases 2 and 3 (design-final 2026-10-27, section 7.1): each component lists the features it serves (AiFeature), so
// that the 3D photo never depends on the components of a scene or of a panorama, and names the release that hosts it
// (ai-components-1 for phase 1, ai-components-2 for the scenes, ai-components-3 for the panoramas). A file of 2 GiB or
// more travels in parts of the release, put end to end; an engine of several files (stable-diffusion.cpp) is an
// archive with the list of its files; a variant (Q8_0 or Q4_0 of the same transformer) names the component it stands
// for and the memory of graphics card it needs, and only one is downloaded.
//
// Shared with the Meta Quest, which reads the LiteRT model from it.

/// The tag of the prerelease that hosts the files of phase 1 (never "Latest": the app reads releases/latest)
const aiComponentsReleaseTag = 'ai-components-1';

/// The tags of the releases of the components of the scenes and of the panoramas, prereleases too
const aiComponentsScenesReleaseTag = 'ai-components-2';
const aiComponentsPanoramasReleaseTag = 'ai-components-3';

/// Where the files of the release [tag] are downloaded from
String aiComponentsReleaseBaseOf(String tag) => 'https://github.com/freeKC/Immuch360/releases/download/$tag/';

/// Where the files of [aiComponentsReleaseTag] are downloaded from
const aiComponentsReleaseBase = 'https://github.com/freeKC/Immuch360/releases/download/$aiComponentsReleaseTag/';

/// The environment variable that replaces [aiComponentsReleaseBase] for the tests and the checks made before the
/// release is published: an https URL or a local folder (file://) holding the same files. The mirror is not exempt
/// from the rule of the downloads: an http:// mirror is refused like any http:// address.
const aiComponentsMirrorVariable = 'IMMUCH360_AI_COMPONENTS_MIRROR';

/// The systems and processors a component runs on
enum AiPlatform { windowsX64, linuxX64, macosArm64, macosX64, questArm64 }

/// What a component is: a model, a runtime library, or an archive of several files (an engine and its libraries),
/// installed in `engines/<id>/`
enum AiComponentKind { model, runtime, archive }

/// The features of the AI a component serves: the 3D photo (phase 1), the 3D scene, the 360° panorama and the 360° 3D
/// panorama. The gate, the dialog, the tile and the engines ask for the components of one feature.
enum AiFeature { stereoPhoto, scene, panorama, stereoPanorama }

/// One part of a file of 2 GiB or more, an asset of the release under 2 GiB (GitHub refuses larger ones): the parts
/// are put end to end in the order of the list, each checked by its own sum, the whole by the sum of the component
class AiComponentPart {
  const AiComponentPart({required this.assetName, required this.size, required this.sha256});

  final String assetName;
  final int size;

  /// SHA-256 in hexadecimal
  final String sha256;
}

/// One file of an archive: its path inside the archive and under `engines/<id>/` (never absolute, never "..", checked by
/// the installer), its size, its sum, and whether it is a program to run
class AiArchiveFile {
  const AiArchiveFile({required this.path, required this.size, required this.sha256, this.executable = false});

  final String path;
  final int size;

  /// SHA-256 in hexadecimal
  final String sha256;
  final bool executable;
}

/// How the file travels: as it is, or gzip compressed (the libraries), unpacked while it downloads
enum AiCompression { none, gzip }

/// A text that comes with a component and is installed with it in the licences folder: the notices of the libraries
/// built into ONNX Runtime, its ThirdPartyNotices.txt
class AiNoticesFile {
  const AiNoticesFile({required this.assetName, required this.size, required this.sha256});

  /// The name of the file in the release (and in a mirror)
  final String assetName;
  final int size;

  /// SHA-256 in hexadecimal
  final String sha256;
}

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
    this.name,
    this.notices,
    this.features = const {AiFeature.stereoPhoto},
    this.releaseTag = aiComponentsReleaseTag,
    this.parts = const [],
    this.archiveFiles = const [],
    this.variantOf,
    this.minGraphicsMemory,
  });

  /// "depth-anything-v2-small-onnx"
  final String id;

  /// What the screens call it: "Depth Anything V2 Small", "ONNX Runtime 1.31.0"; the id when null
  final String? name;
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

  /// The notices downloaded with the component (ONNX Runtime), from the release only
  final AiNoticesFile? notices;

  /// The features it serves
  final Set<AiFeature> features;

  /// The release that hosts it
  final String releaseTag;

  /// The parts of a file of 2 GiB or more, empty for a file in one asset
  final List<AiComponentPart> parts;

  /// The files of an archive, empty for any other kind
  final List<AiArchiveFile> archiveFiles;

  /// The id of the component this one is a variant of (the Q4_0 of a transformer whose Q8_0 is the main entry); the
  /// gate keeps the variant whose [minGraphicsMemory] the card has, one only is downloaded
  final String? variantOf;

  /// The memory of graphics card it needs, in bytes; null for a component of the processor
  final int? minGraphicsMemory;

  /// Whether it comes in parts
  bool get isInParts => parts.isNotEmpty;

  /// The name shown
  String get title => name ?? id;

  /// Whether the catalogue knows the size and the sum: an incomplete component is never offered
  bool get isComplete => size != null && sha256 != null;

  /// The bytes the download takes, the notices apart
  int? get bytesToDownload => downloadSize ?? size;

  /// The notices as the downloader takes them: a file of their own, installed as licenses/ID-ThirdPartyNotices.txt;
  /// null when the component has none
  AiComponent? get noticesDownload {
    final file = notices;
    if (file == null) {
      return null;
    }
    return AiComponent(
      id: '$id-notices',
      version: version,
      kind: kind,
      platforms: platforms,
      assetName: file.assetName,
      installPath: 'licenses/$id-ThirdPartyNotices.txt',
      size: file.size,
      sha256: file.sha256,
      compression: AiCompression.none,
      licence: licence,
      licenceUrl: licenceUrl,
    );
  }

  /// The addresses tried in order: the mirror alone when one is given (the tests stay offline), else the release then
  /// the official source. [release] is the base of the release, that of [releaseTag] when null; another one only in
  /// the tests of the downloader.
  List<String> urls({String? mirror, String? release}) {
    if (mirror != null && mirror.isNotEmpty) {
      return [_joined(mirror, assetName)];
    }
    return [_joined(release ?? aiComponentsReleaseBaseOf(releaseTag), assetName), ...officialUrls];
  }

  /// The address of each part, in order: in the mirror when one is given, else in the release
  List<String> partUrls({String? mirror, String? release}) => [
    for (final part in parts)
      _joined(
        mirror != null && mirror.isNotEmpty ? mirror : release ?? aiComponentsReleaseBaseOf(releaseTag),
        part.assetName,
      ),
  ];
}

String _joined(String base, String name) => base.endsWith('/') ? '$base$name' : '$base/$name';

/// The depth model of the computers: Depth Anything V2 Small, fp32 ONNX export of onnx-community, revision 4472b736
const depthModelOnnxComponent = AiComponent(
  id: 'depth-anything-v2-small-onnx',
  name: 'Depth Anything V2 Small',
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
  features: {AiFeature.stereoPhoto, AiFeature.stereoPanorama},
  officialUrls: [
    'https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/4472b7362082ad9968fee890ca0f1e5aca36b93d/onnx/model.onnx',
  ],
);

/// The depth model of the Quest: the same weights, fp32 LiteRT export of litert-community, revision 178427e4
const depthModelTfliteComponent = AiComponent(
  id: 'depth-anything-v2-small-tflite',
  name: 'Depth Anything V2 Small',
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
// kept), gzip compressed in the release, with the notices of the libraries built into each version. The size and
// SHA-256 of each installed file, the size of each compressed one and those of the notices are written by
// .github/desktop/ai/publish_ai_components.py --write, from the files it makes for the release (lot A3b), and checked
// against licenses/ai-components/MODEL-LICENSES.md by its --check.

const _ortLicence = 'MIT';

/// ONNX Runtime runs the models of every feature of the computers: depth, geometry, filling
const _onnxRuntimeFeatures = {AiFeature.stereoPhoto, AiFeature.scene, AiFeature.panorama, AiFeature.stereoPanorama};

/// ThirdPartyNotices.txt of ONNX Runtime 1.31.0, the same in its three archives (CRLF line ends in the Windows one)
const _onnxRuntimeNotices1310 = AiNoticesFile(
  assetName: 'onnxruntime-1.31.0-ThirdPartyNotices.txt',
  size: 338088,
  sha256: '143764b952fdb1a7c69ce653bfba74a7744d6a8a573bfb73e235fba356c83de3',
);

/// ThirdPartyNotices.txt of ONNX Runtime 1.23.2
const _onnxRuntimeNotices1232 = AiNoticesFile(
  assetName: 'onnxruntime-1.23.2-ThirdPartyNotices.txt',
  size: 326866,
  sha256: 'e9e90971a8e75a9a8ac0c6412e29c1202d079998389915aa485f46c816c3b4cc',
);

/// ONNX Runtime 1.31.0 for Windows x64
const onnxRuntimeWindowsComponent = AiComponent(
  id: 'onnxruntime-1.31.0-win-x64',
  name: 'ONNX Runtime 1.31.0',
  version: '1.31.0',
  kind: AiComponentKind.runtime,
  platforms: {AiPlatform.windowsX64},
  assetName: 'onnxruntime-1.31.0-win-x64.dll.gz',
  installPath: 'runtime/onnxruntime-1.31.0/onnxruntime.dll',
  size: 17253176,
  sha256: '0c42dc4e278f0968fdf9ebf1b1e54a74c657a9942e70803e453c91993451cf4c',
  compression: AiCompression.gzip,
  downloadSize: 6308414,
  licence: _ortLicence,
  licenceUrl: 'https://github.com/microsoft/onnxruntime/blob/v1.31.0/LICENSE',
  notices: _onnxRuntimeNotices1310,
  features: _onnxRuntimeFeatures,
);

/// ONNX Runtime 1.31.0 for Linux x64 (glibc 2.28 and later)
const onnxRuntimeLinuxComponent = AiComponent(
  id: 'onnxruntime-1.31.0-linux-x64',
  name: 'ONNX Runtime 1.31.0',
  version: '1.31.0',
  kind: AiComponentKind.runtime,
  platforms: {AiPlatform.linuxX64},
  assetName: 'onnxruntime-1.31.0-linux-x64.so.gz',
  installPath: 'runtime/onnxruntime-1.31.0/libonnxruntime.so.1.31.0',
  size: 29345384,
  sha256: '469849977cb60744ea160927e1a3a0643fd4c55c0aff743251c6d293402e334e',
  compression: AiCompression.gzip,
  downloadSize: 11112796,
  licence: _ortLicence,
  licenceUrl: 'https://github.com/microsoft/onnxruntime/blob/v1.31.0/LICENSE',
  notices: _onnxRuntimeNotices1310,
  features: _onnxRuntimeFeatures,
);

/// ONNX Runtime 1.31.0 for macOS on Apple silicon
const onnxRuntimeMacArmComponent = AiComponent(
  id: 'onnxruntime-1.31.0-osx-arm64',
  name: 'ONNX Runtime 1.31.0',
  version: '1.31.0',
  kind: AiComponentKind.runtime,
  platforms: {AiPlatform.macosArm64},
  assetName: 'onnxruntime-1.31.0-osx-arm64.dylib.gz',
  installPath: 'runtime/onnxruntime-1.31.0/libonnxruntime.1.31.0.dylib',
  size: 44830288,
  sha256: '2a50a63e7f41f8d4d551d3ee47248df3864f6540109fce8ad520ca3b51af4b70',
  compression: AiCompression.gzip,
  downloadSize: 12524281,
  licence: _ortLicence,
  licenceUrl: 'https://github.com/microsoft/onnxruntime/blob/v1.31.0/LICENSE',
  notices: _onnxRuntimeNotices1310,
  features: _onnxRuntimeFeatures,
);

/// ONNX Runtime 1.23.2 for the Intel Macs, the last release with an osx-x86_64 archive; the app asks it for API 23
const onnxRuntimeMacIntelComponent = AiComponent(
  id: 'onnxruntime-1.23.2-osx-x86_64',
  name: 'ONNX Runtime 1.23.2',
  version: '1.23.2',
  kind: AiComponentKind.runtime,
  platforms: {AiPlatform.macosX64},
  assetName: 'onnxruntime-1.23.2-osx-x86_64.dylib.gz',
  installPath: 'runtime/onnxruntime-1.23.2/libonnxruntime.1.23.2.dylib',
  size: 39742608,
  sha256: '8c9c78de65ea3786f987c0d980e9c1b13a3a5fbc6b3e2965ba05b450e6e4c054',
  compression: AiCompression.gzip,
  downloadSize: 11437397,
  licence: _ortLicence,
  licenceUrl: 'https://github.com/microsoft/onnxruntime/blob/v1.23.2/LICENSE',
  notices: _onnxRuntimeNotices1232,
  features: _onnxRuntimeFeatures,
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

/// The components [platform] needs for [feature] (the 3D photo when not given), the runtimes first, then the
/// archives, then the models
List<AiComponent> aiComponentsFor(AiPlatform platform, {AiFeature feature = AiFeature.stereoPhoto}) => [
  for (final kind in const [AiComponentKind.runtime, AiComponentKind.archive, AiComponentKind.model])
    ...aiComponents.where(
      (component) =>
          component.kind == kind && component.platforms.contains(platform) && component.features.contains(feature),
    ),
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
