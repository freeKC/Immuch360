// The catalogue of the AI components the app downloads when the user asks for them: the depth model and, on the
// computers, ONNX Runtime (design-final 2026-10-26, section 2.2). Compiled into the app: no remote manifest, so no
// network call without a gesture of the user, and a new version of a component comes with a new version of the app:
// another SHA-256 under the same id, or a new id that lists the older one in [AiComponent.replaces], which the app
// then offers as an update of what the user installed (issue 21, ai_components_service.dart).
// The sums are always checked, whatever the source, so a mirror can serve nothing else.
//
// Phases 2 and 3 (design-final 2026-10-27, section 7.1): each component lists the features it serves (AiFeature), so
// that the 3D photo never depends on the components of a scene or of a panorama, and names the release that hosts it
// (ai-components-1 for phase 1, ai-components-2 for the scenes, ai-components-3 for the panoramas). A file of 2 GiB or
// more travels in parts of the release, put end to end; an engine of several files (stable-diffusion.cpp) is an
// archive with the list of its files; a variant (Q8_0 or Q4_0 of the same transformer) names the component it stands
// for and the memory of graphics card it needs, and only one is downloaded.
//
// The entries of the scenes carry the sums measured by M2 (phase23/m2-measures-2026-10-27.md, section 10): our export of
// MoGe-2 ViT-S, and LaMa, which fills the hidden bands of every scene. MI-GAN fills the seam of a panorama only, so it
// travels with the panoramas. The entries of the panoramas carry the files M3 measured (Q4_0 of the transformer, the
// one that holds in 8 GB) and wait for P2 (the archives of stable-diffusion.cpp, built and signed by our CI) and for the
// verdict of M3 before ai-components-3 is published: an entry without its size or sum is never offered.
//
// The AV2 decoder of the computers (store/m2/av2-2026-11-02/plan-2026-11-02.md, section 3) is no AI, but it downloads,
// checks and installs as the components do: three archives of a release of its own repository,
// github.com/immuch360/av2-companion, shown in the video settings and never in the tile of the AI components. Their
// entries carry the sizes and sums of the archives of that release, as its manifest gives them (a copy in
// .github/desktop/ai/av2-companion-1.0.1.json).
//
// The splat scenes (store/m2/splat-maker-2026-11-01/plan-2026-11-01.md, section 2.3) take two programs built by our CI
// from pinned sources, COLMAP 4.2.1 without its GPL parts (lot SP1) and Brush 0.3.0 without the LPIPS weights (lot
// SP2), as archives of ai-components-4, made by .github/desktop/ai/publish_ai_components.py from the artifacts of the
// run 41884480484 of the release workflow (with_splat and sign_test: colmap.exe and brush_app.exe signed by APROGSYS)
// for its publication (lot SP14).
//
// The 3D videos of the computers (store/m2/release-49/lots/video3d-plan.md, sections 3 and 4.1, experimental) take
// Video Depth Anything Small (Apache-2.0, the ONNX export of looplj at a pinned revision) from ai-components-5, ONNX
// Runtime shared with the photos, and an FFmpeg program under the LGPL 2.1 or later: three archives of a release of
// github.com/immuch360/libmpv-builds (.github/workflows/ffmpeg.yml), as its manifest gives them (a copy in
// .github/desktop/ai/ffmpeg-lgpl-<tag>.json). Their group, held in aiHeldFeatureGroups until the screens of the 3D
// videos offered it, is offered since release 49, labelled experimental.
//
// Shared with the Meta Quest, which reads the LiteRT model from it.

/// The tag of the prerelease that hosts the files of phase 1 (never "Latest": the app reads releases/latest)
const aiComponentsReleaseTag = 'ai-components-1';

/// The tags of the releases of the components of the scenes, of the panoramas and of the splat scenes, prereleases too
const aiComponentsScenesReleaseTag = 'ai-components-2';
const aiComponentsPanoramasReleaseTag = 'ai-components-3';
const aiComponentsSplatsReleaseTag = 'ai-components-4';
const aiComponentsVideosReleaseTag = 'ai-components-5';

/// The runtime of the graphics card of the 3D videos on Windows (release 51, ai_gpu_runtime_manifest.dart)
const aiComponentsGpuReleaseTag = 'ai-components-6';

/// The components of "Enhance (AI)" (release 51, ai_enhance_manifest.dart)
const aiComponentsEnhanceReleaseTag = 'ai-components-7';

/// The release of the app this catalogue comes with (its versionCode less 3029998, so 52 for 3030050), written into
/// each entry of installed.json: an older version of the app that shares the folder of the components (an AppImage
/// beside an older .deb, a CI build beside the release) knows by it a file that a newer version installed, and never
/// puts its own older version in its place by itself nor counts it as no longer used (review of issue 21, release
/// 52). ai_components_catalogue_release_test.dart keeps it equal to the release of pubspec.yaml.
const aiComponentsCatalogueRelease = 52;

/// The repository whose releases host the components, but the AV2 decoder ([av2DecoderRepository])
const aiComponentsRepository = 'freeKC/Immuch360';

/// Where the files of the release [tag] of [repository] are downloaded from
String aiComponentsReleaseBaseOf(String tag, {String repository = aiComponentsRepository}) =>
    'https://github.com/$repository/releases/download/$tag/';

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

/// The features of the AI a component serves: the 3D photo (phase 1), the 3D scene, the 360° panorama, the 360° 3D
/// panorama and the splat scene; and the AV2 videos, which are no AI. The gate, the dialog, the tile and the engines
/// ask for the components of one feature.
enum AiFeature {
  stereoPhoto([..._computers, AiPlatform.questArm64]),
  scene(_computers),
  panorama([AiPlatform.windowsX64, AiPlatform.linuxX64]),
  stereoPanorama(_computers),

  /// Windows since the first test build (plan 2026-11-01, section 4.1), Linux since release 51 (lot L03 of the desktop
  /// parity plan: the same rule of the dedicated card, the chain run end to end on the CI on lavapipe; no Linux PC
  /// with a dedicated card has run it yet), macOS later
  splatScene([AiPlatform.windowsX64, AiPlatform.linuxX64]),

  /// The AV2 videos of the computers, decoded by the processor with the AV2 decoder: no AI, see [isAi]
  av2Video(_computers),

  /// A flat video made 3D side by side on the computers (experimental, video3d-plan.md): Video Depth Anything Small on
  /// the processor and the FFmpeg program of immuch360/libmpv-builds. On Intel Macs since release 51 (lot L06 of the
  /// desktop parity plan): ONNX Runtime 1.23.2 runs the model there, on the Intel runner of the CI and on Linux; slow
  /// on the processor of such a Mac, whose speed was not measured on a real one
  stereoVideo(_computers);

  const AiFeature(this.platforms);

  /// Where the feature is offered: the generated panorama waits for a lot of its own on the Macs (design 4.7, point
  /// 7), and the headset computes only the 3D photo
  final List<AiPlatform> platforms;

  /// Whether it is a feature of the AI, whose components the tile of the AI components shows
  bool get isAi => this != av2Video;
}

const _computers = [AiPlatform.windowsX64, AiPlatform.linuxX64, AiPlatform.macosArm64, AiPlatform.macosX64];

/// The groups the screens show the components in (design 7.1, point 7): the 3D photos, with the 3D version of a 360°
/// photo, which needs nothing more; the 3D scenes; the 360° panoramas; the splat scenes; the AV2 decoder, which the
/// video settings show; and the 3D videos. Each is installed, sized and removed as a whole.
enum AiFeatureGroup {
  photos({AiFeature.stereoPhoto, AiFeature.stereoPanorama}),
  scenes({AiFeature.scene}),
  panoramas({AiFeature.panorama}),
  splats({AiFeature.splatScene}),
  av2({AiFeature.av2Video}),
  videos({AiFeature.stereoVideo});

  const AiFeatureGroup(this.features);

  final Set<AiFeature> features;

  /// Whether the tile of the AI components shows it: every group but that of the AV2 decoder
  bool get isAi => features.every((feature) => feature.isAi);
}

/// The largest asset a release holds: GitHub refuses a file of 2 GiB or more
const aiReleaseAssetLimit = 2 * 1024 * 1024 * 1024;

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
    this.releaseRepository = aiComponentsRepository,
    this.parts = const [],
    this.archiveFiles = const [],
    this.variantOf,
    this.minGraphicsMemory,
    this.replaces = const [],
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

  /// The repository of that release ("freeKC/Immuch360", "immuch360/av2-companion")
  final String releaseRepository;

  /// Where the files of its release are downloaded from
  String get releaseBase => aiComponentsReleaseBaseOf(releaseTag, repository: releaseRepository);

  /// The parts of a file of 2 GiB or more, empty for a file in one asset
  final List<AiComponentPart> parts;

  /// The files of an archive, empty for any other kind
  final List<AiArchiveFile> archiveFiles;

  /// The id of the component this one is a variant of (the Q4_0 of a transformer whose Q8_0 is the main entry); the
  /// gate keeps the variant whose [minGraphicsMemory] the card has, one only is downloaded
  final String? variantOf;

  /// The memory of graphics card it needs, in bytes; null for a component of the processor
  final int? minGraphicsMemory;

  /// The ids an earlier version of the app gave the same component (issue 21): ONNX Runtime carries its version in its
  /// id, so its next version comes under a new id. An installed one of them makes this component an update, and its
  /// files go once this one is installed and checked. A component that keeps its id needs nothing here: another
  /// SHA-256 under the same id is the update.
  final List<String> replaces;

  /// Whether it comes in parts
  bool get isInParts => parts.isNotEmpty;

  /// Whether it is an archive, unpacked into the folder [installPath]
  bool get isArchive => kind == AiComponentKind.archive;

  /// The name shown
  String get title => name ?? id;

  /// Whether the catalogue knows the size and the sum (of the archive and of each of its files): an incomplete
  /// component is never offered
  bool get isComplete => size != null && sha256 != null && (!isArchive || archiveFiles.isNotEmpty);

  /// The bytes the download takes, the notices apart
  int? get bytesToDownload => downloadSize ?? size;

  /// The bytes it takes once installed, the notices apart: the files of an archive, else the file
  int? get installedSize => isArchive ? archiveFiles.fold<int>(0, (sum, file) => sum + file.size) : size;

  /// The file the engines run or read: the file itself, or the first program of an archive (its first file when it
  /// has no program), "/" between folders
  String get mainPath {
    if (!isArchive || archiveFiles.isEmpty) {
      return installPath;
    }
    final main = archiveFiles.firstWhere((file) => file.executable, orElse: () => archiveFiles.first);
    return '$installPath/${main.path}';
  }

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
    return [_joined(release ?? releaseBase, assetName), ...officialUrls];
  }

  /// The address of each part, in order: in the mirror when one is given, else in the release
  List<String> partUrls({String? mirror, String? release}) => [
    for (final part in parts)
      _joined(mirror != null && mirror.isNotEmpty ? mirror : release ?? releaseBase, part.assetName),
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
const _onnxRuntimeFeatures = {
  AiFeature.stereoPhoto,
  AiFeature.scene,
  AiFeature.panorama,
  AiFeature.stereoPanorama,
  AiFeature.stereoVideo,
};

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

// The 3D scenes, in ai-components-2 (design-final 2026-10-27, sections 2.2 and 7.2; measure M2). Their sums are those
// M2 read, each checked against the Hugging Face API at the pinned revision, and checked again by
// .github/desktop/ai/publish_ai_components.py --release ai-components-2.

/// MoGe-2 ViT-S, the metric geometry of a scene (and of the photo inside a panorama): our ONNX export of the MIT weights
/// Ruicheng/moge-2-vits-normal at 26b477f4, by the method of MoGe at 74fbce05, opset 14
/// (.github/desktop/ai/export_moge_onnx.py). Byte for byte the file of Ruicheng/moge-2-vits-normal-onnx at e50ffda4,
/// a repository without a card nor a licence: not used as a source, so only the release and the mirror serve it.
const mogeGeometryComponent = AiComponent(
  id: 'moge-2-vits-normal-onnx-immuch360',
  name: 'MoGe-2 ViT-S',
  version: '26b477f4',
  kind: AiComponentKind.model,
  platforms: {AiPlatform.windowsX64, AiPlatform.linuxX64, AiPlatform.macosArm64, AiPlatform.macosX64},
  assetName: 'moge_2_vits_normal_immuch360.onnx',
  installPath: 'models/moge-2-vits-normal/moge_2_vits_normal_immuch360.onnx',
  size: 140852051,
  sha256: '24eacb5dc7a2c54c7bc98f7de085ffbed79ad006ea5b664c2c2cdc02ff3a52f0',
  compression: AiCompression.none,
  licence: 'MIT',
  licenceUrl: 'https://github.com/microsoft/MoGe/blob/74fbce054ebed49800de42d0ad0e83495065719a/LICENSE',
  features: {AiFeature.scene, AiFeature.panorama},
  releaseTag: aiComponentsScenesReleaseTag,
);

/// LaMa, which fills the hidden bands of a scene: lama_fp32.onnx of Carve/LaMa-ONNX at c3c0c9e4 (not lama.onnx of the
/// same revision, which ONNX Runtime 1.31.0 refuses to load)
const lamaInpaintComponent = AiComponent(
  id: 'lama-onnx',
  name: 'LaMa',
  version: 'c3c0c9e4',
  kind: AiComponentKind.model,
  platforms: {AiPlatform.windowsX64, AiPlatform.linuxX64, AiPlatform.macosArm64, AiPlatform.macosX64},
  assetName: 'lama_fp32.onnx',
  installPath: 'models/lama/lama_fp32.onnx',
  size: 208044816,
  sha256: '1faef5301d78db7dda502fe59966957ec4b79dd64e16f03ed96913c7a4eb68d6',
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: 'https://github.com/advimman/lama/blob/786f5936b27fb3dacd2b1ad799e4de968ea697e7/LICENSE',
  features: {AiFeature.scene},
  releaseTag: aiComponentsScenesReleaseTag,
  officialUrls: [
    'https://huggingface.co/Carve/LaMa-ONNX/resolve/c3c0c9e468934d62e79c329e35d82dd09ff8c444/lama_fp32.onnx',
  ],
);

// The 360° panoramas, in ai-components-3 (design-final 2026-10-27, sections 4.1, 4.3 and 7.2; measure M3, section 9).
// To be completed by P2 and M3: P2 writes the archives of stable-diffusion.cpp (their files and sums come from the
// signed artifacts of our CI), and ai-components-3 is published only if M3 says yes. The models are those M3 ran, each
// checked against the Hugging Face API (Real-ESRGAN: its GitHub release) at the pinned revision; the two files of
// 2 GiB or more travel in parts.

/// MI-GAN, which fills the seam of a panorama (measure M2: LaMa fills the bands of a scene)
const miganInpaintComponent = AiComponent(
  id: 'migan-512-places2-onnx',
  name: 'MI-GAN',
  version: '406830d0',
  kind: AiComponentKind.model,
  platforms: {AiPlatform.windowsX64, AiPlatform.linuxX64, AiPlatform.macosArm64, AiPlatform.macosX64},
  assetName: 'migan_pipeline_v2.onnx',
  installPath: 'models/migan/migan_pipeline_v2.onnx',
  size: 28079181,
  sha256: '6f1f3530a1a2324b19752018ce756088b07973cda8d7d890034ace5c8a48c40b',
  compression: AiCompression.none,
  licence: 'MIT',
  licenceUrl:
      'https://github.com/Picsart-AI-Research/MI-GAN/blob/680b0c6149c51e272412f0e4686c0d6668dba15c/LICENSE-WEIGHTS',
  features: {AiFeature.panorama},
  releaseTag: aiComponentsPanoramasReleaseTag,
  officialUrls: [
    'https://huggingface.co/andraniksargsyan/migan/resolve/406830d0fa60666da0071c342ad2fbc8f30c5c64/migan_pipeline_v2.onnx',
  ],
);

/// stable-diffusion.cpp on Vulkan for Windows x64, built by our CI from .github/desktop/ai/sd_cpp.lock.json (its id is
/// the version) and signed by the release workflow (lot P2): sd-cli.exe, the libraries of stable-diffusion.cpp and of
/// ggml, the Visual C++ runtime they import, and the licences in licenses/, unpacked into engines/
const sdCppWindowsComponent = AiComponent(
  id: 'sd-cpp-vulkan-win-x64',
  name: 'stable-diffusion.cpp (Vulkan)',
  version: 'be48649-2',
  kind: AiComponentKind.archive,
  platforms: {AiPlatform.windowsX64},
  assetName: 'sd-cpp-vulkan-win-x64.zip',
  installPath: 'engines/sd-cpp-vulkan-win-x64',
  size: 30853245,
  sha256: '6aacb8a7831c8b43bc66f177f3961169df345ed55d80ff4519db4f73aed35d57',
  compression: AiCompression.none,
  licence: 'MIT',
  licenceUrl: 'https://github.com/leejet/stable-diffusion.cpp/blob/be486498eadc29dc3cd234d944c2180ed42b1415/LICENSE',
  features: {AiFeature.panorama},
  releaseTag: aiComponentsPanoramasReleaseTag,
  archiveFiles: [
    AiArchiveFile(
      path: 'BUILD-INFO.txt',
      size: 866,
      sha256: 'b0ecfcf53275bed6db8468f9bb5b38a678bb1e7052377149abbaf029ddf93664',
    ),
    AiArchiveFile(
      path: 'ggml-base.dll',
      size: 697160,
      sha256: '0e93bda5087456fbcfef7fada22e1a6ffd44463ebe1c002d4e9968ffdc2ba30a',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-alderlake.dll',
      size: 1016648,
      sha256: '24d18be3806be9f11172b5fa91f790c686baf65c3d00a84a35d269b35fc5fbeb',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-cannonlake.dll',
      size: 1062216,
      sha256: 'e2a640523f66bc1b14782027ce1c356e2037cfec8ec2fb78c43095452effda85',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-cascadelake.dll',
      size: 1060680,
      sha256: '2a6463b9acf1a87a516e638fdc59ea2dbf76054b7f92ad6d541a6c71d2e50815',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-haswell.dll',
      size: 1017672,
      sha256: '48c7c4483b46e1c5041fc54e4aa4c12892d3f072dd60be9b8a138c45919fc061',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-icelake.dll',
      size: 1060680,
      sha256: 'fff19b695e5c0d2b599bcd22be03f81e057faeff691046aa66b826fb4a4c45c1',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-sandybridge.dll',
      size: 1046344,
      sha256: 'f5d8821452620b645d761528f61ee2661a62413175122bae87d1091acd073ed6',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-skylakex.dll',
      size: 1062216,
      sha256: 'aeeb1df73493ba54ed5225c2c99b940f590daba35339df5b600b5307cd51a003',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-sse42.dll',
      size: 883016,
      sha256: '2abb813018268da1853849812867c5abf8b3008cd53c6663885b3ff15dbc8094',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-x64.dll',
      size: 885064,
      sha256: '89d0aabc54fddf30040656654238ac78844950a1f90c978ec9b2fc27767db8e9',
    ),
    AiArchiveFile(
      path: 'ggml-vulkan.dll',
      size: 40152904,
      sha256: '781624a958dacf56c4c354c86aaacd7cbfc56ac04ed2d4e86b3cd33cac5f4ce9',
    ),
    AiArchiveFile(
      path: 'ggml.dll',
      size: 76104,
      sha256: '9549c8c214d97e3fb0ab95606e7be3d52ed730e06b42e7e447948a141953948f',
    ),
    AiArchiveFile(
      path: 'licenses/README.md',
      size: 1185,
      sha256: '26f980b88d5210da2e6024efbd56d3d2ca77de7010bc73989b660187ce53528a',
    ),
    AiArchiveFile(
      path: 'licenses/THIRD-PARTY.md',
      size: 6968,
      sha256: '0d58c599729e84498452fce4fbafa819cc6529683d0711c60b3a965132444b70',
    ),
    AiArchiveFile(
      path: 'licenses/darts-clone-LICENSE.txt',
      size: 1491,
      sha256: 'ed8437dc7358a40ef10afd3635ac1cd43c88fbaaaf6cd27c414f8ada5d68f447',
    ),
    AiArchiveFile(
      path: 'licenses/ggml-LICENSE.txt',
      size: 1099,
      sha256: 'bcd8ec749126d45cb06737d0690295d73df4b6e7e194205bcf91190368f27285',
    ),
    AiArchiveFile(
      path: 'licenses/oniguruma-COPYING.txt',
      size: 1366,
      sha256: '0dff717fb611b9c9bd9776a5df9c4e029030f8dbc023b77f3678cf495495b933',
    ),
    AiArchiveFile(
      path: 'licenses/stable-diffusion.cpp-LICENSE.txt',
      size: 1082,
      sha256: '4e76049398df734a97db46f3bd4b5cbc460cb5f6bfaf737cdc3d6fbb8ab3de27',
    ),
    AiArchiveFile(
      path: 'licenses/utf8proc-LICENSE.md',
      size: 5218,
      sha256: '767edbcafb23016d7f203aaf2cbdef5690ad58bcede52ee241427dcb816cd644',
    ),
    AiArchiveFile(
      path: 'msvcp140.dll',
      size: 557728,
      sha256: '0f885b509a685d2bbfa652fed26b5fb31d88fbdab0a978c641d1c7b8aa460aa9',
    ),
    AiArchiveFile(
      path: 'msvcp140_codecvt_ids.dll',
      size: 31872,
      sha256: 'f2069a52880ec885ee7f0511186100eb7fada0411a2b4948fafea7735b878a18',
    ),
    AiArchiveFile(
      path: 'sd-cli.exe',
      size: 801096,
      sha256: 'd33481cef0001920f878ede5101dfeef4fa05df50bd6201048cb45a51b88ba1d',
      executable: true,
    ),
    AiArchiveFile(
      path: 'stable-diffusion.dll',
      size: 36008776,
      sha256: 'ad6b904bdbda24a347db9c84a70249980d500b2831e6615c0430b8b9939d85ff',
    ),
    AiArchiveFile(
      path: 'vcruntime140.dll',
      size: 124544,
      sha256: 'd5e4d9a3e835fa679450145d6a7d94e36573a509317111904d9b3712c30d9066',
    ),
    AiArchiveFile(
      path: 'vcruntime140_1.dll',
      size: 49792,
      sha256: '1f2d41c4aa5db0bc33ebf7b66d72943a817d7ce6cbe880502a9403823633093f',
    ),
  ],
);

/// stable-diffusion.cpp on Vulkan for Linux x64, built by our CI from the same lock (lot P2): sd-cli, the libraries of
/// stable-diffusion.cpp and of ggml, and immuch360-run, the launcher that makes sd-cli die with the app, the first
/// program of the archive by the order of the paths (mainPath); the runner finds sd-cli beside it (sdCliIn)
const sdCppLinuxComponent = AiComponent(
  id: 'sd-cpp-vulkan-linux-x64',
  name: 'stable-diffusion.cpp (Vulkan)',
  version: 'be48649-2',
  kind: AiComponentKind.archive,
  platforms: {AiPlatform.linuxX64},
  assetName: 'sd-cpp-vulkan-linux-x64.zip',
  installPath: 'engines/sd-cpp-vulkan-linux-x64',
  size: 35817545,
  sha256: '5e7052dc93eec36ad156974e7f56bd7fa13df3482b412935848319680cb5d535',
  compression: AiCompression.none,
  licence: 'MIT',
  licenceUrl: 'https://github.com/leejet/stable-diffusion.cpp/blob/be486498eadc29dc3cd234d944c2180ed42b1415/LICENSE',
  features: {AiFeature.panorama},
  releaseTag: aiComponentsPanoramasReleaseTag,
  archiveFiles: [
    AiArchiveFile(
      path: 'BUILD-INFO.txt',
      size: 816,
      sha256: '1549479c0023cb2ea02dfbcbcc9e1773e682f2308fdf70b5261069d2f809545d',
    ),
    AiArchiveFile(
      path: 'immuch360-run',
      size: 16552,
      sha256: '779dfe821cc14fbbd8e6f7420ccba3f08509a5802f89d18a5f5a606b2dd79a7b',
      executable: true,
    ),
    AiArchiveFile(
      path: 'libggml-base.so.0',
      size: 905856,
      sha256: '724d0388655f31af515a16a06e89852529286936bc3905fb0fc000391f06af09',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-alderlake.so',
      size: 1306432,
      sha256: 'db8a29641675ad642fc7056932568f20bc3216224eaf9b803b5ae15df9725f25',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-cannonlake.so',
      size: 1384360,
      sha256: '66d26b13e9c989dc898be445a894916a9923eab34b328871a73163c98d056e57',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-cascadelake.so',
      size: 1400448,
      sha256: '204de1f7d965852dc2122fb4a0b00240af20f234efe55416cd989e0330b5a3d8',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-cooperlake.so',
      size: 1400448,
      sha256: '68d763f49d062b0b74bde1afaae488bafae2f52da04874b0eba730b61ae0de0a',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-haswell.so',
      size: 1306432,
      sha256: '9d597a3d4fe9cc4257fce0bfd634850f037ed9f54647c0403ed1c0088c347666',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-icelake.so',
      size: 1400448,
      sha256: '7e1da9f4a14883fd0ae7771d31f228efc9d6ae92cd9c5341a09e74edd40bc4cf',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-ivybridge.so',
      size: 1235152,
      sha256: '757283c265130c252eb1a2b411eca6139579417151e0f764f6163bbdb7049867',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-piledriver.so',
      size: 1231056,
      sha256: 'f459112286127171de81c29978aa7e1ac150fa73bf8d0964c871ff10bcd83858',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-sandybridge.so',
      size: 1255752,
      sha256: '6873b28211bdaa720a7d79c7605fa10a933db7ab6de07df59501695b0037eafd',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-sapphirerapids.so',
      size: 1696688,
      sha256: 'd696cdc358c7cc3135e7ea8b2ef721a9d292ca31482791817e84a1b2ed792ce6',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-skylakex.so',
      size: 1384360,
      sha256: '2aa0285fca0986a124071e5c2f0e9d722615a113e698d913730cb7c29b5b1979',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-sse42.so',
      size: 984640,
      sha256: 'c2adef8dff8e2ee42a2029de496161601b7bd6c536ba8c8df2f6efb84689f6d4',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-x64.so',
      size: 980680,
      sha256: '4138dcbf8b45b21880c92fd7248c14eb0f8deb1f796a6f0c1bf595ac7e91a8b2',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-zen4.so',
      size: 1400448,
      sha256: '712d67cbda8490241de13934a1c6a6c1f0a2c359ff41eab9706d60a9211998ce',
    ),
    AiArchiveFile(
      path: 'libggml-vulkan.so',
      size: 40829024,
      sha256: '655e8a3ac90e029a12d8a29fe73b4be2ad55d389e161ac87c12a4e95b5ecdef7',
    ),
    AiArchiveFile(
      path: 'libggml.so.0',
      size: 51040,
      sha256: 'f7edd32a571306f777f380ca868af8728a89d21a3abcc8b97a7e4f738ab40c0a',
    ),
    AiArchiveFile(
      path: 'libstable-diffusion.so',
      size: 41639088,
      sha256: 'a0d2134f6f82bd97f7c56376cad7aea0d3b6fdc950f8a31b3a8e55698492500d',
    ),
    AiArchiveFile(
      path: 'licenses/README.md',
      size: 1169,
      sha256: 'dfc8ee008f776c77648f9c6692fce332ad190a2479653c6399bc2873b5d7e8be',
    ),
    AiArchiveFile(
      path: 'licenses/THIRD-PARTY.md',
      size: 6862,
      sha256: 'de31b8552d1bdb1765a3b75781df6763f576d8762fc9a58d652a4d4733bcf70b',
    ),
    AiArchiveFile(
      path: 'licenses/darts-clone-LICENSE.txt',
      size: 1481,
      sha256: '155f59997298ee336602c49f9c1110f268ac394ca2197eb02647a3555935ad52',
    ),
    AiArchiveFile(
      path: 'licenses/ggml-LICENSE.txt',
      size: 1078,
      sha256: '94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d',
    ),
    AiArchiveFile(
      path: 'licenses/oniguruma-COPYING.txt',
      size: 1366,
      sha256: '0dff717fb611b9c9bd9776a5df9c4e029030f8dbc023b77f3678cf495495b933',
    ),
    AiArchiveFile(
      path: 'licenses/stable-diffusion.cpp-LICENSE.txt',
      size: 1062,
      sha256: 'b53fa08f515cb5a6fff7b9fd8fcd0961a4b80df29d74372d25e1f9171aa042ee',
    ),
    AiArchiveFile(
      path: 'licenses/utf8proc-LICENSE.md',
      size: 5218,
      sha256: '767edbcafb23016d7f203aaf2cbdef5690ad58bcede52ee241427dcb816cd644',
    ),
    AiArchiveFile(
      path: 'sd-cli',
      size: 1368216,
      sha256: '6d8f92b3cb97c27cfc6b2a8e97a76b09bcedf3a68f2358df0b72e288105d715e',
      executable: true,
    ),
  ],
);

/// The memory of graphics card the Q4_0 transformer asks for: a dedicated card of 7.5 GiB at least (M3: 5.39 GiB
/// taken by sd-cli, cards of 6 GB not tried)
const _q4GraphicsMemory = 8053063680;

/// FLUX.2 klein base 4B, Q4_0 GGUF of leejet at d1267112 (M3: the Q8_0 cuts its graph on a card of 8 GB and spoils the
/// image; no Q8_0 variant until a larger card is measured)
const fluxTransformerComponent = AiComponent(
  id: 'flux2-klein-base-4b-q4_0',
  name: 'FLUX.2 klein base 4B (Q4_0)',
  version: 'd1267112',
  kind: AiComponentKind.model,
  platforms: {AiPlatform.windowsX64, AiPlatform.linuxX64},
  assetName: 'flux-2-klein-base-4b-Q4_0.gguf',
  installPath: 'models/flux2-klein-base-4b/flux-2-klein-base-4b-Q4_0.gguf',
  size: 2460378560,
  sha256: 'c3a2854510677b7aa37dd7547d908c54889a76c6d6aa3ffe902fcaa092d1328b',
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: 'https://huggingface.co/black-forest-labs/FLUX.2-klein-base-4B',
  features: {AiFeature.panorama},
  releaseTag: aiComponentsPanoramasReleaseTag,
  officialUrls: [
    'https://huggingface.co/leejet/FLUX.2-klein-base-4B-GGUF/resolve/d12671125306ca6b5f6db1b33ed4c80c8511a53f/flux-2-klein-base-4b-Q4_0.gguf',
  ],
  parts: [
    AiComponentPart(
      assetName: 'flux-2-klein-base-4b-Q4_0.gguf.001',
      size: 2039480320,
      sha256: 'c1b9bb49b725bd8b6f958cfcf48d27026d9dd53bc54a83b0604e91630c2003cc',
    ),
    AiComponentPart(
      assetName: 'flux-2-klein-base-4b-Q4_0.gguf.002',
      size: 420898240,
      sha256: 'b84cb446ad7f881c4c2eccdd20829a51c6419e2939b33804ba40d0c41f913bb1',
    ),
  ],
  minGraphicsMemory: _q4GraphicsMemory,
);

/// Qwen3 4B, the text encoder of FLUX.2 klein, Q4_K_M GGUF of unsloth at 22c9fc8a
const qwenTextEncoderComponent = AiComponent(
  id: 'qwen3-4b-q4_k_m',
  name: 'Qwen3 4B (Q4_K_M)',
  version: '22c9fc8a',
  kind: AiComponentKind.model,
  platforms: {AiPlatform.windowsX64, AiPlatform.linuxX64},
  assetName: 'Qwen3-4B-Q4_K_M.gguf',
  installPath: 'models/qwen3-4b/Qwen3-4B-Q4_K_M.gguf',
  size: 2497281312,
  sha256: 'f6f851777709861056efcdad3af01da38b31223a3ba26e61a4f8bf3a2195813a',
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: 'https://huggingface.co/Qwen/Qwen3-4B',
  features: {AiFeature.panorama},
  releaseTag: aiComponentsPanoramasReleaseTag,
  officialUrls: [
    'https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/22c9fc8a8c7700b76a1789366280a6a5a1ad1120/Qwen3-4B-Q4_K_M.gguf',
  ],
  parts: [
    AiComponentPart(
      assetName: 'Qwen3-4B-Q4_K_M.gguf.001',
      size: 2039480320,
      sha256: 'ab33d061bb101f87505c5e13bec02b39da4d310f1bcde1a5a916691230183ad3',
    ),
    AiComponentPart(
      assetName: 'Qwen3-4B-Q4_K_M.gguf.002',
      size: 457800992,
      sha256: 'ed05d20e6c453c59371bac0e35f3f6dc3fbc551088e6628a8e79f94db3512a51',
    ),
  ],
);

/// The VAE of FLUX.2 klein base 4B (vae/diffusion_pytorch_model.safetensors at a3b4f484), loaded as it is
const fluxVaeComponent = AiComponent(
  id: 'flux2-vae',
  name: 'FLUX.2 VAE',
  version: 'a3b4f484',
  kind: AiComponentKind.model,
  platforms: {AiPlatform.windowsX64, AiPlatform.linuxX64},
  assetName: 'flux2-klein-base-4b-vae.safetensors',
  installPath: 'models/flux2-klein-base-4b/flux2-klein-base-4b-vae.safetensors',
  size: 168120878,
  sha256: 'ca70d2202afe6415bdbcb8793ba8cd99fd159cfe6192381504d6c4d3036e0f04',
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: 'https://huggingface.co/black-forest-labs/FLUX.2-klein-base-4B',
  features: {AiFeature.panorama},
  releaseTag: aiComponentsPanoramasReleaseTag,
  officialUrls: [
    'https://huggingface.co/black-forest-labs/FLUX.2-klein-base-4B/resolve/a3b4f4849157f664bdbc776fd7453c2783562f4d/vae/diffusion_pytorch_model.safetensors',
  ],
);

/// The "360 ERP Outpaint" LoRA of nomadoor for klein 4B at 124129f3. sd-cli finds it by its file name in its folder,
/// so the installed name is the one of its source.
const panoramaLoraComponent = AiComponent(
  id: 'flux2-klein-4b-360-erp-lora-v1',
  name: '360 ERP Outpaint LoRA',
  version: '124129f3',
  kind: AiComponentKind.model,
  platforms: {AiPlatform.windowsX64, AiPlatform.linuxX64},
  assetName: 'flux-2-klein-4B-360-erp-outpaint-lora_V1.safetensors',
  installPath: 'models/flux2-klein-4b-360-erp-lora/flux-2-klein-4B-360-erp-outpaint-lora_V1.safetensors',
  size: 46224184,
  sha256: '567cc22de03800d2c9d4309e0cf6f971cc00da6b39fb26b0311031f2563de166',
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: 'https://huggingface.co/nomadoor/flux-2-klein-4B-360-erp-outpaint-lora',
  features: {AiFeature.panorama},
  releaseTag: aiComponentsPanoramasReleaseTag,
  officialUrls: [
    'https://huggingface.co/nomadoor/flux-2-klein-4B-360-erp-outpaint-lora/resolve/124129f3ebce357c007ffca177d19567246f8bff/flux-2-klein-4B-360-erp-outpaint-lora_V1.safetensors',
  ],
);

/// Real-ESRGAN x4plus, which enlarges the generated panorama four times (release v0.1.0 of xinntao/Real-ESRGAN)
const upscalerComponent = AiComponent(
  id: 'realesrgan-x4plus',
  name: 'Real-ESRGAN x4plus',
  version: 'v0.1.0',
  kind: AiComponentKind.model,
  platforms: {AiPlatform.windowsX64, AiPlatform.linuxX64},
  assetName: 'RealESRGAN_x4plus.pth',
  installPath: 'models/realesrgan/RealESRGAN_x4plus.pth',
  size: 67040989,
  sha256: '4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1',
  compression: AiCompression.none,
  licence: 'BSD-3-Clause',
  licenceUrl: 'https://github.com/xinntao/Real-ESRGAN/blob/0573f32dd04a6ff9dbafff67df23f808dffc8811/LICENSE',
  features: {AiFeature.panorama},
  releaseTag: aiComponentsPanoramasReleaseTag,
  officialUrls: ['https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth'],
);

// The AV2 decoder (store/m2/av2-2026-11-02/plan-2026-11-02.md, section 3): immuch360-av2, our companion in C on the
// library of dav2d (VideoLAN, BSD-2-Clause) at the commit of its lock, whose id is the version, built, checked and
// released by github.com/immuch360/av2-companion (MIT, its own repository since build 45 of the app; the builds before
// took the prerelease av2-decoder-1 of this repository). Each archive holds the program (on Linux with immuch360-run
// beside it), and in licenses/ the COPYING of dav2d, the ISC header of x86inc.asm, the Alliance for Open Media Patent
// License 1.0, the MIT licence of the companion and the address of its source, with BUILD-INFO.txt and
// SHA256SUMS.txt. Its size, its sum and the list of its files are those of the archives of the release v1.0.1 (run
// 42843116104 of av2-companion at 6d9e3c32f, the Windows program signed by APROGSYS), as its manifest
// av2-companion-1.0.1.json gives them; the gate of the catalogue (publish_ai_components.py --check) holds them to the
// copy of that manifest in .github/desktop/ai on every branch.

/// The repository of the AV2 decoder, whose releases host its archives: AV2 is no AI (plan, section 2.7)
const av2DecoderRepository = 'immuch360/av2-companion';

/// The release of [av2DecoderRepository] the app takes the AV2 decoder from
const av2DecoderReleaseTag = 'v1.0.1';

/// Where the files of [av2DecoderReleaseTag] are downloaded from: the [AiComponent.releaseBase] of its three entries
const av2DecoderReleaseBase = 'https://github.com/immuch360/av2-companion/releases/download/$av2DecoderReleaseTag/';

/// The licence of dav2d at the pinned commit (its COPYING: BSD 2-Clause, VideoLAN and dav2d authors)
const _dav2dLicenceUrl =
    'https://code.videolan.org/videolan/dav2d/-/blob/30140b563596a1b14aef808ff021c90288948315/COPYING';

/// The AV2 decoder for Windows x64: immuch360-av2.exe, built with the static C runtime, and its licences
const av2DecoderWindowsComponent = AiComponent(
  id: 'av2-decoder-windows-x64',
  name: 'AV2 decoder',
  version: '30140b5-1',
  kind: AiComponentKind.archive,
  platforms: {AiPlatform.windowsX64},
  assetName: 'Immuch360-av2-decoder-30140b5-1-windows-x64.zip',
  installPath: 'engines/av2-decoder-windows-x64',
  size: 791323,
  sha256: '56a23c1d22d2ae5352329a8344d23574a7ca8df3f48716c0d2858a1e38e7fe6e',
  compression: AiCompression.none,
  licence: 'BSD-2-Clause',
  licenceUrl: _dav2dLicenceUrl,
  features: {AiFeature.av2Video},
  releaseTag: av2DecoderReleaseTag,
  releaseRepository: av2DecoderRepository,
  archiveFiles: [
    AiArchiveFile(
      path: 'BUILD-INFO.txt',
      size: 947,
      sha256: 'd0d299db55c3effb5df3c23fc268b2473f1313a4149a84461b99ebd43ae6d562',
    ),
    AiArchiveFile(
      path: 'SHA256SUMS.txt',
      size: 721,
      sha256: '1888a3b9f8034bcab61f583d162fbf9da9435732c360a7857d526a1b0c769482',
    ),
    AiArchiveFile(
      path: 'immuch360-av2.exe',
      size: 1646408,
      sha256: '3bd58ab4b8aa389327fe6bcadc763f5fd0501707866b0a95674434c19282168e',
      executable: true,
    ),
    AiArchiveFile(
      path: 'licenses/AOM-PATENTS.txt',
      size: 5730,
      sha256: '335eca574598bf4ca181b12f708d6669e5a5e78c8e1513e5b35fa1f03901484b',
    ),
    AiArchiveFile(
      path: 'licenses/README.md',
      size: 2160,
      sha256: '114dcbb91027be7c751257176173e949f3554f1c1fc2ba1e17cef847a14ece91',
    ),
    AiArchiveFile(
      path: 'licenses/dav2d-COPYING.txt',
      size: 1317,
      sha256: 'c8380b7afd97b17c2d645122001f534d877d6b2612c1138acb9c41f7750c9c7b',
    ),
    AiArchiveFile(
      path: 'licenses/immuch360-av2-MIT.txt',
      size: 1063,
      sha256: 'e97493fbff4a1a7096ad1061d303faeafe7234a48b7f86331dfe01e80119fc96',
    ),
    AiArchiveFile(
      path: 'licenses/immuch360-av2-SOURCE.txt',
      size: 359,
      sha256: 'b23bffa9fefb8cecc5f700faef5053f297edf64536ccaec1409282d7990c5c8b',
    ),
    AiArchiveFile(
      path: 'licenses/x86inc-ISC.txt',
      size: 1162,
      sha256: '1c20545ce9b2407beccfcf88f33fd0588e8988afaeef31bed7acc30803d2204c',
    ),
  ],
);

/// The AV2 decoder for Linux x64 (glibc of Ubuntu 22.04 and later), with immuch360-run
const av2DecoderLinuxComponent = AiComponent(
  id: 'av2-decoder-linux-x64',
  name: 'AV2 decoder',
  version: '30140b5-1',
  kind: AiComponentKind.archive,
  platforms: {AiPlatform.linuxX64},
  assetName: 'Immuch360-av2-decoder-30140b5-1-linux-x64.zip',
  installPath: 'engines/av2-decoder-linux-x64',
  size: 942607,
  sha256: 'd9ba78ff359ab2ec730b3448bb1d1b75eb2744a697bb0059a28aa6e3618dd959',
  compression: AiCompression.none,
  licence: 'BSD-2-Clause',
  licenceUrl: _dav2dLicenceUrl,
  features: {AiFeature.av2Video},
  releaseTag: av2DecoderReleaseTag,
  releaseRepository: av2DecoderRepository,
  archiveFiles: [
    AiArchiveFile(
      path: 'BUILD-INFO.txt',
      size: 797,
      sha256: '6592f75533ed00755c1eb916f1369181a5e0afef5849abe009d7c2d56bfd3c3b',
    ),
    AiArchiveFile(
      path: 'SHA256SUMS.txt',
      size: 894,
      sha256: '6d32fbfd36bc4460a5ec045a952b6e13358a75c3007b3965a9a49fb527ba2023',
    ),
    AiArchiveFile(
      path: 'immuch360-av2',
      size: 2037904,
      sha256: '030825530e07b926ce7b634f181a3fcd0f2b0c2db1544cc1f078f1572112d185',
      executable: true,
    ),
    AiArchiveFile(
      path: 'immuch360-run',
      size: 16552,
      sha256: '779dfe821cc14fbbd8e6f7420ccba3f08509a5802f89d18a5f5a606b2dd79a7b',
      executable: true,
    ),
    AiArchiveFile(
      path: 'licenses/AOM-PATENTS.txt',
      size: 5730,
      sha256: '335eca574598bf4ca181b12f708d6669e5a5e78c8e1513e5b35fa1f03901484b',
    ),
    AiArchiveFile(
      path: 'licenses/README.md',
      size: 2160,
      sha256: '114dcbb91027be7c751257176173e949f3554f1c1fc2ba1e17cef847a14ece91',
    ),
    AiArchiveFile(
      path: 'licenses/dav2d-COPYING.txt',
      size: 1317,
      sha256: 'c8380b7afd97b17c2d645122001f534d877d6b2612c1138acb9c41f7750c9c7b',
    ),
    AiArchiveFile(
      path: 'licenses/immuch360-av2-MIT.txt',
      size: 1063,
      sha256: 'e97493fbff4a1a7096ad1061d303faeafe7234a48b7f86331dfe01e80119fc96',
    ),
    AiArchiveFile(
      path: 'licenses/immuch360-av2-SOURCE.txt',
      size: 359,
      sha256: 'b23bffa9fefb8cecc5f700faef5053f297edf64536ccaec1409282d7990c5c8b',
    ),
    AiArchiveFile(
      path: 'licenses/immuch360-run-MIT.txt',
      size: 1156,
      sha256: 'e1ca99633c8cb8df3e8189b0c4b804e91b6dca413ae4022ea3d905e0f94ef191',
    ),
    AiArchiveFile(
      path: 'licenses/x86inc-ISC.txt',
      size: 1162,
      sha256: '1c20545ce9b2407beccfcf88f33fd0588e8988afaeef31bed7acc30803d2204c',
    ),
  ],
);

/// The AV2 decoder for macOS: one universal program, arm64 with NEON and x86_64 with AVX2
const av2DecoderMacComponent = AiComponent(
  id: 'av2-decoder-macos-universal',
  name: 'AV2 decoder',
  version: '30140b5-1',
  kind: AiComponentKind.archive,
  platforms: {AiPlatform.macosArm64, AiPlatform.macosX64},
  assetName: 'Immuch360-av2-decoder-30140b5-1-macos-universal.zip',
  installPath: 'engines/av2-decoder-macos-universal',
  size: 1653707,
  sha256: 'c25da3e20a3ac7754264440c19c6f416b3495fc583bf71309f5e8a5ba8af1007',
  compression: AiCompression.none,
  licence: 'BSD-2-Clause',
  licenceUrl: _dav2dLicenceUrl,
  features: {AiFeature.av2Video},
  releaseTag: av2DecoderReleaseTag,
  releaseRepository: av2DecoderRepository,
  archiveFiles: [
    AiArchiveFile(
      path: 'BUILD-INFO.txt',
      size: 789,
      sha256: '92a2658149dc3c7cb330c324ec1ddf79be13b908b7dea74abca9cb0533667b84',
    ),
    AiArchiveFile(
      path: 'SHA256SUMS.txt',
      size: 717,
      sha256: 'b4149c3a840b8d7904dcb5ca67bd29be93d4bb410206552724e59ed8042c0f93',
    ),
    AiArchiveFile(
      path: 'immuch360-av2',
      size: 3769216,
      sha256: 'f87e5490c8d634ddd3554f6631097fdd24186c9209ef1e2aeb0d448259ff62fd',
      executable: true,
    ),
    AiArchiveFile(
      path: 'licenses/AOM-PATENTS.txt',
      size: 5730,
      sha256: '335eca574598bf4ca181b12f708d6669e5a5e78c8e1513e5b35fa1f03901484b',
    ),
    AiArchiveFile(
      path: 'licenses/README.md',
      size: 2160,
      sha256: '114dcbb91027be7c751257176173e949f3554f1c1fc2ba1e17cef847a14ece91',
    ),
    AiArchiveFile(
      path: 'licenses/dav2d-COPYING.txt',
      size: 1317,
      sha256: 'c8380b7afd97b17c2d645122001f534d877d6b2612c1138acb9c41f7750c9c7b',
    ),
    AiArchiveFile(
      path: 'licenses/immuch360-av2-MIT.txt',
      size: 1063,
      sha256: 'e97493fbff4a1a7096ad1061d303faeafe7234a48b7f86331dfe01e80119fc96',
    ),
    AiArchiveFile(
      path: 'licenses/immuch360-av2-SOURCE.txt',
      size: 359,
      sha256: 'b23bffa9fefb8cecc5f700faef5053f297edf64536ccaec1409282d7990c5c8b',
    ),
    AiArchiveFile(
      path: 'licenses/x86inc-ISC.txt',
      size: 1162,
      sha256: '1c20545ce9b2407beccfcf88f33fd0588e8988afaeef31bed7acc30803d2204c',
    ),
  ],
);

// The two programs of a splat scene, each an archive of ai-components-4 built by our CI for Windows x64 and Linux x64
// (plan 2026-11-01, section 2.3): COLMAP for the poses of the cameras, on the processor, and Brush for the training, on
// the graphics card by Vulkan. Their size, their sum and the list of their files are written by
// .github/desktop/ai/publish_ai_components.py --release ai-components-4 from the artifacts of the CI (both programs
// and both systems from the run 41884480484 of the release workflow, a new build of the same locks after the test
// builds T1 to T3, colmap.exe and brush_app.exe of the Windows archives signed by APROGSYS), each file with its size
// and SHA-256, colmap.exe and brush_app.exe the programs the engines run. Neither has an official
// source: the official binaries of COLMAP carry SiftGPU (non commercial), LSD (AGPL 3) and the GPL parts of CHOLMOD,
// and those of Brush the LPIPS weights, whose origin is not written. The Linux entries, complete from the start, are
// offered since release 51 (AiFeature.splatScene).

/// The licence of COLMAP at the tag 4.2.1 (its COPYING.txt: the new BSD licence of ETH Zurich and UNC Chapel Hill)
const _colmapLicenceUrl = 'https://github.com/colmap/colmap/blob/4.2.1/COPYING.txt';

/// The licence of Brush at the tag v0.3.0 (its LICENSE: the Apache License 2.0)
const _brushLicenceUrl = 'https://github.com/ArthurBrussee/brush/blob/v0.3.0/LICENSE';

/// COLMAP 4.2.1 on the processor for Windows x64, our build without its GPL parts (lot SP1): colmap.exe, the Visual
/// C++ runtime, and the licences of the libraries built into it in licenses/, unpacked into engines/
const colmapWindowsComponent = AiComponent(
  id: 'colmap-cpu-win-x64',
  name: 'COLMAP',
  version: '4.2.1-imm1',
  kind: AiComponentKind.archive,
  platforms: {AiPlatform.windowsX64},
  assetName: 'colmap-cpu-win-x64.zip',
  installPath: 'engines/colmap-cpu-win-x64',
  size: 10100055,
  sha256: '9ab1f508fdbc85e65964a7107b1c72ea680ba7c1cc4e06d1423b604b01bf7848',
  compression: AiCompression.none,
  licence: 'BSD-3-Clause',
  licenceUrl: _colmapLicenceUrl,
  features: {AiFeature.splatScene},
  releaseTag: aiComponentsSplatsReleaseTag,
  archiveFiles: [
    AiArchiveFile(
      path: 'BUILD-INFO.txt',
      size: 1337,
      sha256: 'e46a3339b04a5ed7a3b2ef6db1b37731051b66bab4b86229ac6309b383913f93',
    ),
    AiArchiveFile(
      path: 'SHA256SUMS.txt',
      size: 11850,
      sha256: '1b4995932c1f36dcbaf73d1bc125623fdd12b98c278dffca306c746f10d868ac',
    ),
    AiArchiveFile(
      path: 'colmap.exe',
      size: 26246984,
      sha256: '52b69e006b3dd0168d1fb4548b754f18435811e7edb00b99d84810d54c092e5b',
      executable: true,
    ),
    AiArchiveFile(
      path: 'licenses/COPYING.txt',
      size: 1942,
      sha256: 'beda69d6c1e7544a470002af34c5d754497f0ad7da168556a9b20852993404c3',
    ),
    AiArchiveFile(
      path: 'licenses/PoissonRecon-LICENSE.txt',
      size: 1096,
      sha256: 'bbcbdc44ed818f009eb4433db9ab5e6509578d0ba43ddcb662b8a0cc9c160fb3',
    ),
    AiArchiveFile(
      path: 'licenses/PoseLib-LICENSE.txt',
      size: 1551,
      sha256: 'f2974dfc7803858e4c3d35c4d5f26291cf072b6607a561caa2fae4758bfc13d2',
    ),
    AiArchiveFile(
      path: 'licenses/README.md',
      size: 3568,
      sha256: '4538aaaaebf4ab65bb8c21f71bad530a5966837445dfe220c14f341b5099fac9',
    ),
    AiArchiveFile(
      path: 'licenses/THIRD-PARTY.md',
      size: 13063,
      sha256: '4f98948de029572969568477be74c24d26fe46997e0288bc0aff245fafe1f1cf',
    ),
    AiArchiveFile(
      path: 'licenses/VLFeat-LICENSE.txt',
      size: 1390,
      sha256: 'a31ef034eeab41e1c24e72747608a54c8e72c7e7f6ebcf7391f00c7e63c1495e',
    ),
    AiArchiveFile(
      path: 'licenses/faiss-LICENSE.txt',
      size: 1107,
      sha256: 'f08a94bfb0bdc1d7f1cb59badaf0f8c551b10db871185622dbf1fd036affa9cb',
    ),
    AiArchiveFile(
      path: 'licenses/libf2c-Notice.txt',
      size: 1235,
      sha256: 'cabd9f61080c1d7c155121cb4b7a57dfa0e7482449c640b7eeb633d9d757bacf',
    ),
    AiArchiveFile(
      path: 'licenses/patches/0001-without-cholmod.patch',
      size: 5514,
      sha256: 'a6cc9cc28c9256cee75ca8f62661ccc4262c4bf5f14940aadec272b3a9ac191b',
    ),
    AiArchiveFile(
      path: 'licenses/patches/0002-vcpkg-without-suitesparse.patch',
      size: 1119,
      sha256: 'a916f7ba404eca19298f24031287fd23a3dc8d25807e9bdcc48448d10ca68c2e',
    ),
    AiArchiveFile(
      path: 'licenses/patches/0003-faiss-without-blas.patch',
      size: 2438,
      sha256: '88f6efa8303509abc27a29b792c674a47834fa34ce122f1c9fba4e28f60f0642',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-algorithm.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-align.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-any.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-array.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-assert.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-atomic.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-bimap.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-bind.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-chrono.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-cmake.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-compat.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-concept-check.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-config.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-container-hash.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-container.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-conversion.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-core.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-date-time.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-describe.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-detail.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-dynamic-bitset.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-endian.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-exception.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-foreach.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-function-types.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-function.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-fusion.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-graph.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-headers.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-heap.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-integer.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-intrusive.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-io.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-iterator.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-lambda.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-lexical-cast.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-math.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-move.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-mp11.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-mpl.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-multi-index.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-multiprecision.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-numeric-conversion.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-optional.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-parameter.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-phoenix.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-pool.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-predef.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-preprocessor.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-program-options.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-property-map.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-property-tree.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-proto.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-random.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-range.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-ratio.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-regex.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-serialization.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-smart-ptr.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-spirit.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-static-assert.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-system.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-thread.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-throw-exception.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-tokenizer.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-tti.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-tuple.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-type-index.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-type-traits.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-typeof.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-unordered.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-utility.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-variant.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-variant2.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-winapi.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-xpressive.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/ceres.txt',
      size: 14355,
      sha256: '765fd9eac4cb827fa5de4304d1f81f4f2c5c332a3f1d6f0f3f7a69a33156729b',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/clapack.txt',
      size: 1607,
      sha256: '23014869214a231525b38c39fdb5f82364fa24154ac80fdcab2a79671460fd09',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/eigen3.txt',
      size: 32831,
      sha256: 'ad251846a5a37acfed04407b7eee9161fbd58a91874b20fd949904413c407b2a',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/expat.txt',
      size: 1144,
      sha256: '31b15de82aa19a845156169a17a5488bf597e561b2c318d159ed583139b25e87',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/fmt.txt',
      size: 1094,
      sha256: 'a65fcc5a1095fc33cc37e4fff69366e49d7e92f613558a2b95ed1b70e33758b4',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/gflags.txt',
      size: 1479,
      sha256: '90d1f3701813c3cd65eee2dc736746fe46b465918f3f7d6d31463a2018b33fa5',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/gklib.txt',
      size: 641,
      sha256: '81118d7ac02c98ad2d49a8b7d12d24f41e3bef962342f5483bf1b80a79ce1992',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/glog.txt',
      size: 1479,
      sha256: '136d48dea7a681413691f3db3098f6cf5ffaa3119d96d97bb83b8cff3ce38c4a',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/imath.txt',
      size: 1497,
      sha256: 'c20236d3b39fd20eba8e3d1fb3b892a5483df2e7d8d61bf43f165d3fac22f601',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/libdeflate.txt',
      size: 1078,
      sha256: '4ad69099cb4374836fd27583d9991e2838cd86b6e4666ab26b2d32582c91e73a',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/libjpeg-turbo.txt',
      size: 6077,
      sha256: 'ba6bceebcba0fdd35488477c2cca8c4632ce82c74dbfbc87d886ce6fc4433579',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/libpng.txt',
      size: 5345,
      sha256: 'bdb0a645ea18c60507d0368379b1ac5474b92255fcc2d115e07486a7672ba526',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/metis.txt',
      size: 641,
      sha256: '64ab947d7b289ad76e935adff51b31e4ac160df7dfad24480dbaa452e39bbe79',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/minizip-ng.txt',
      size: 877,
      sha256: '675181c03fc1302a1c8554c00f7be9bb420c5dbc9dcc2013433cec144413de03',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/openblas.txt',
      size: 1548,
      sha256: '190b5a9c8d9723fe958ad33916bd7346d96fab3c5ea90832bb02d854f620fcff',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/opencolorio.txt',
      size: 1485,
      sha256: '82a40c52065ee968aa62015735e84378ac11425db7a233e6a2dcd2c83fc24276',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/openexr.txt',
      size: 1501,
      sha256: '84853c91d4c2e0310741d4773469d98bb93e61029608e0ba0882a3fffdf330bd',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/openimageio.txt',
      size: 25011,
      sha256: '7585beae16904f28ee1a32fcc97f108e7717d78ddec927ebb98e09be7c5530d5',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/openjph.txt',
      size: 1448,
      sha256: '5ddf5177863dfc9ab65fa129d587db651241f00e21ed2427b218bea997591f98',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/pystring.txt',
      size: 1530,
      sha256: 'f7f060301402ea0b5c507b865b1a9de037d4d7b24f37422a93b70fe9c7a9b78a',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/robin-map.txt',
      size: 1102,
      sha256: '11f2c685ba565a31aef1219f63a7a8845602c97bff70016b9e3278dfe51a2ec5',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/sqlite3.txt',
      size: 71,
      sha256: '3cafdd9b568b924b234b91f4a24649d509f02643ae727eac6a4e33818288c9c4',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/tiff.txt',
      size: 2416,
      sha256: '0e27c2382d7b8147972bbb746e04059a1152c8d0fda9d03ef1399d1a433c4ade',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/vcpkg-boost.txt',
      size: 1073,
      sha256: '1ee376fc340e0aa6ad6a3581c94126e741468705096ac92263048a21daa86460',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/vcpkg-cmake-config.txt',
      size: 1096,
      sha256: '04b60f99a43bfd7fefdc8364b24aac704a2160cef969b75ba6a38b62dc4c4b70',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/vcpkg-cmake.txt',
      size: 1073,
      sha256: '1ee376fc340e0aa6ad6a3581c94126e741468705096ac92263048a21daa86460',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/yaml-cpp.txt',
      size: 1061,
      sha256: 'aa6fcc27be034e41e21dd832f9175bfe694a48491d9e14ff0fa278e19ad14f1b',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/zlib.txt',
      size: 1002,
      sha256: 'e32ff4e00d9d94930537635291da39e7e612703334bf6fde8c7f1686fe8a45a2',
    ),
    AiArchiveFile(
      path: 'msvcp140.dll',
      size: 557728,
      sha256: '0f885b509a685d2bbfa652fed26b5fb31d88fbdab0a978c641d1c7b8aa460aa9',
    ),
    AiArchiveFile(
      path: 'msvcp140_2.dll',
      size: 280200,
      sha256: '3ea06f0ee098b4823cb79599df3780e7f23cce52c19aac31d2a0d47efe33a5e9',
    ),
    AiArchiveFile(
      path: 'vcomp140.dll',
      size: 193152,
      sha256: '55aba23cdcd6484fbb06f4155b8ca75adfce7a881f10afd0c49457165e677164',
    ),
    AiArchiveFile(
      path: 'vcruntime140.dll',
      size: 124544,
      sha256: 'd5e4d9a3e835fa679450145d6a7d94e36573a509317111904d9b3712c30d9066',
    ),
    AiArchiveFile(
      path: 'vcruntime140_1.dll',
      size: 49792,
      sha256: '1f2d41c4aa5db0bc33ebf7b66d72943a817d7ce6cbe880502a9403823633093f',
    ),
  ],
);

/// COLMAP 4.2.1 on the processor for Linux x64, our build without its GPL parts (lot SP1), with immuch360-run
const colmapLinuxComponent = AiComponent(
  id: 'colmap-cpu-linux-x64',
  name: 'COLMAP',
  version: '4.2.1-imm1',
  kind: AiComponentKind.archive,
  platforms: {AiPlatform.linuxX64},
  assetName: 'colmap-cpu-linux-x64.zip',
  installPath: 'engines/colmap-cpu-linux-x64',
  size: 25856357,
  sha256: 'ed3feff65a24c0e112e1d5218c4d49fb963b8212eabb239ae95f8f3cad878ad2',
  compression: AiCompression.none,
  licence: 'BSD-3-Clause',
  licenceUrl: _colmapLicenceUrl,
  features: {AiFeature.splatScene},
  releaseTag: aiComponentsSplatsReleaseTag,
  archiveFiles: [
    AiArchiveFile(
      path: 'BUILD-INFO.txt',
      size: 1170,
      sha256: '88c8e89a491698586122db71c3f0b01117470e659a560a9bc6c670f8876c251d',
    ),
    AiArchiveFile(
      path: 'SHA256SUMS.txt',
      size: 11519,
      sha256: 'f2bd59f5ec6f6eaa322f3a95c751c900c8d5e0bc2d0ef1899fa06b4708a57b12',
    ),
    AiArchiveFile(
      path: 'colmap',
      size: 72599544,
      sha256: '29dd48e5589100be0a6580045d1533787f46bb8ede50e868fb749446f6ce8caa',
      executable: true,
    ),
    AiArchiveFile(
      path: 'immuch360-run',
      size: 16552,
      sha256: '779dfe821cc14fbbd8e6f7420ccba3f08509a5802f89d18a5f5a606b2dd79a7b',
      executable: true,
    ),
    AiArchiveFile(
      path: 'licenses/COPYING.txt',
      size: 1909,
      sha256: 'ab30dabb4f0a6731f980108f57aa160cc8f5cebae6984e01a5d109df99669233',
    ),
    AiArchiveFile(
      path: 'licenses/PoissonRecon-LICENSE.txt',
      size: 1075,
      sha256: 'addfdacb0d5e30f25641fc2c26cc423c541a60e16624b29d80d3490608ba4956',
    ),
    AiArchiveFile(
      path: 'licenses/PoseLib-LICENSE.txt',
      size: 1522,
      sha256: 'f956d2d12c3a58c72e936bb390071d4c4df8f4da008bdcd617bb0a8a890eda1c',
    ),
    AiArchiveFile(
      path: 'licenses/README.md',
      size: 3531,
      sha256: '1f37f574c955e08a6add640df92525556c4fe4ec140629440e8e675d78da5f36',
    ),
    AiArchiveFile(
      path: 'licenses/THIRD-PARTY.md',
      size: 12923,
      sha256: '6d1cc2cad7ce9ae8e756f58116adec5f79923c5aa56e976998d984861ab8ad86',
    ),
    AiArchiveFile(
      path: 'licenses/VLFeat-LICENSE.txt',
      size: 1365,
      sha256: '33b9f7703327199088d74f884b19997a0084180f984724720095a7cb412c4d89',
    ),
    AiArchiveFile(
      path: 'licenses/faiss-LICENSE.txt',
      size: 1086,
      sha256: '52412d7bc7ce4157ea628bbaacb8829e0a9cb3c58f57f99176126bc8cf2bfc85',
    ),
    AiArchiveFile(
      path: 'licenses/libf2c-Notice.txt',
      size: 1212,
      sha256: '44561c447e91203ddc747beeca5cc2794d95ee982c17c578670e4f0408bc3904',
    ),
    AiArchiveFile(
      path: 'licenses/patches/0001-without-cholmod.patch',
      size: 5514,
      sha256: 'a6cc9cc28c9256cee75ca8f62661ccc4262c4bf5f14940aadec272b3a9ac191b',
    ),
    AiArchiveFile(
      path: 'licenses/patches/0002-vcpkg-without-suitesparse.patch',
      size: 1119,
      sha256: 'a916f7ba404eca19298f24031287fd23a3dc8d25807e9bdcc48448d10ca68c2e',
    ),
    AiArchiveFile(
      path: 'licenses/patches/0003-faiss-without-blas.patch',
      size: 2438,
      sha256: '88f6efa8303509abc27a29b792c674a47834fa34ce122f1c9fba4e28f60f0642',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-algorithm.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-align.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-any.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-array.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-assert.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-atomic.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-bimap.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-bind.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-chrono.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-cmake.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-compat.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-concept-check.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-config.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-container-hash.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-container.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-conversion.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-core.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-date-time.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-describe.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-detail.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-dynamic-bitset.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-endian.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-exception.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-foreach.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-function-types.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-function.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-fusion.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-graph.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-headers.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-heap.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-integer.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-intrusive.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-io.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-iterator.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-lambda.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-lexical-cast.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-math.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-move.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-mp11.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-mpl.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-multi-index.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-multiprecision.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-numeric-conversion.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-optional.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-parameter.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-phoenix.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-pool.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-predef.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-preprocessor.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-program-options.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-property-map.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-property-tree.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-proto.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-random.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-range.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-ratio.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-regex.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-serialization.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-smart-ptr.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-spirit.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-static-assert.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-system.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-thread.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-throw-exception.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-tokenizer.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-tti.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-tuple.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-type-index.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-type-traits.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-typeof.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-unordered.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-utility.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-variant.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-variant2.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-winapi.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/boost-xpressive.txt',
      size: 1338,
      sha256: 'c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/ceres.txt',
      size: 14355,
      sha256: '765fd9eac4cb827fa5de4304d1f81f4f2c5c332a3f1d6f0f3f7a69a33156729b',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/clapack.txt',
      size: 1607,
      sha256: '23014869214a231525b38c39fdb5f82364fa24154ac80fdcab2a79671460fd09',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/eigen3.txt',
      size: 32154,
      sha256: '9af2ed6fee290d31684b61774741b985aa2505e246fc28eca403f407262daf77',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/expat.txt',
      size: 1144,
      sha256: '31b15de82aa19a845156169a17a5488bf597e561b2c318d159ed583139b25e87',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/fmt.txt',
      size: 1094,
      sha256: 'a65fcc5a1095fc33cc37e4fff69366e49d7e92f613558a2b95ed1b70e33758b4',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/gflags.txt',
      size: 1479,
      sha256: '90d1f3701813c3cd65eee2dc736746fe46b465918f3f7d6d31463a2018b33fa5',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/gklib.txt',
      size: 641,
      sha256: '81118d7ac02c98ad2d49a8b7d12d24f41e3bef962342f5483bf1b80a79ce1992',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/glog.txt',
      size: 1479,
      sha256: '136d48dea7a681413691f3db3098f6cf5ffaa3119d96d97bb83b8cff3ce38c4a',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/imath.txt',
      size: 1497,
      sha256: 'c20236d3b39fd20eba8e3d1fb3b892a5483df2e7d8d61bf43f165d3fac22f601',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/libdeflate.txt',
      size: 1078,
      sha256: '4ad69099cb4374836fd27583d9991e2838cd86b6e4666ab26b2d32582c91e73a',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/libjpeg-turbo.txt',
      size: 6077,
      sha256: 'ba6bceebcba0fdd35488477c2cca8c4632ce82c74dbfbc87d886ce6fc4433579',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/libpng.txt',
      size: 5345,
      sha256: 'bdb0a645ea18c60507d0368379b1ac5474b92255fcc2d115e07486a7672ba526',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/metis.txt',
      size: 641,
      sha256: '64ab947d7b289ad76e935adff51b31e4ac160df7dfad24480dbaa452e39bbe79',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/minizip-ng.txt',
      size: 877,
      sha256: '675181c03fc1302a1c8554c00f7be9bb420c5dbc9dcc2013433cec144413de03',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/openblas.txt',
      size: 1548,
      sha256: '190b5a9c8d9723fe958ad33916bd7346d96fab3c5ea90832bb02d854f620fcff',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/opencolorio.txt',
      size: 1485,
      sha256: '82a40c52065ee968aa62015735e84378ac11425db7a233e6a2dcd2c83fc24276',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/openexr.txt',
      size: 1501,
      sha256: '84853c91d4c2e0310741d4773469d98bb93e61029608e0ba0882a3fffdf330bd',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/openimageio.txt',
      size: 24701,
      sha256: '95b56cf947151b6007f9b458bc9b7da974982715aabd2f5d25b366275f2142fa',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/openjph.txt',
      size: 1448,
      sha256: '5ddf5177863dfc9ab65fa129d587db651241f00e21ed2427b218bea997591f98',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/pystring.txt',
      size: 1530,
      sha256: 'f7f060301402ea0b5c507b865b1a9de037d4d7b24f37422a93b70fe9c7a9b78a',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/robin-map.txt',
      size: 1102,
      sha256: '11f2c685ba565a31aef1219f63a7a8845602c97bff70016b9e3278dfe51a2ec5',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/sqlite3.txt',
      size: 69,
      sha256: '1472ec10e27c62157cebd95d9186e8912a75a1a829fe3a612611710da2992ed5',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/tiff.txt',
      size: 2416,
      sha256: '0e27c2382d7b8147972bbb746e04059a1152c8d0fda9d03ef1399d1a433c4ade',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/vcpkg-boost.txt',
      size: 1073,
      sha256: '1ee376fc340e0aa6ad6a3581c94126e741468705096ac92263048a21daa86460',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/vcpkg-cmake-config.txt',
      size: 1096,
      sha256: '04b60f99a43bfd7fefdc8364b24aac704a2160cef969b75ba6a38b62dc4c4b70',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/vcpkg-cmake.txt',
      size: 1073,
      sha256: '1ee376fc340e0aa6ad6a3581c94126e741468705096ac92263048a21daa86460',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/yaml-cpp.txt',
      size: 1061,
      sha256: 'aa6fcc27be034e41e21dd832f9175bfe694a48491d9e14ff0fa278e19ad14f1b',
    ),
    AiArchiveFile(
      path: 'licenses/vcpkg/zlib.txt',
      size: 1002,
      sha256: 'e32ff4e00d9d94930537635291da39e7e612703334bf6fde8c7f1686fe8a45a2',
    ),
  ],
);

/// Brush 0.3.0 on Vulkan for Windows x64, our build of the tag v0.3.0 without the LPIPS weights (lot SP2): brush_app.exe
/// and the licences of its crates in licenses/. It needs a dedicated graphics card of 4 GiB at least.
const brushWindowsComponent = AiComponent(
  id: 'brush-vulkan-win-x64',
  name: 'Brush',
  version: '0.3.0-imm1',
  kind: AiComponentKind.archive,
  platforms: {AiPlatform.windowsX64},
  assetName: 'brush-vulkan-win-x64.zip',
  installPath: 'engines/brush-vulkan-win-x64',
  size: 16364150,
  sha256: 'aaa3ad8bf55c4369a12b86cbcdffdcaf68f0054a42693f34e2e7679f26d55a77',
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: _brushLicenceUrl,
  features: {AiFeature.splatScene},
  releaseTag: aiComponentsSplatsReleaseTag,
  archiveFiles: [
    AiArchiveFile(
      path: 'BUILD-INFO.txt',
      size: 2780,
      sha256: '426d3817f80d976a8dfa18b3718b3421d434726f394e0edec83cd71c0b2c14d6',
    ),
    AiArchiveFile(
      path: 'brush_app.exe',
      size: 63775560,
      sha256: '47064cf96a84482aa79d5f76653a152166c15ad80ad8dfbaee6d330287ccfcf0',
      executable: true,
    ),
    AiArchiveFile(
      path: 'licenses/EXTRA-NOTICES.md',
      size: 5935,
      sha256: '2b18770127e5c1212e88983220ec5a9eb8559df9033bd1b62ec89ef3307ebf31',
    ),
    AiArchiveFile(
      path: 'licenses/README.md',
      size: 4527,
      sha256: '07d0bba845a345ebfd2ededea5ae022e353262b2b4eab78eb929e25f9fc1ecaf',
    ),
    AiArchiveFile(
      path: 'licenses/THIRD-PARTY.md',
      size: 467291,
      sha256: 'e5d8003e290996831420222a73dc69cee5a0653ed978170d4378db1243d9814a',
    ),
    AiArchiveFile(
      path: 'licenses/brush-LICENSE.txt',
      size: 11358,
      sha256: 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30',
    ),
    AiArchiveFile(
      path: 'licenses/patches/0001-immuch360-headless-trainer.patch',
      size: 17608,
      sha256: '788070930f92eb8922209337429762df0a5748567586cf2bb7e880f5d17be1bf',
    ),
    AiArchiveFile(
      path: 'vcruntime140.dll',
      size: 124544,
      sha256: 'd5e4d9a3e835fa679450145d6a7d94e36573a509317111904d9b3712c30d9066',
    ),
  ],
  minGraphicsMemory: _splatGraphicsMemory,
);

/// Brush 0.3.0 on Vulkan for Linux x64, our build (lot SP2), with immuch360-run
const brushLinuxComponent = AiComponent(
  id: 'brush-vulkan-linux-x64',
  name: 'Brush',
  version: '0.3.0-imm1',
  kind: AiComponentKind.archive,
  platforms: {AiPlatform.linuxX64},
  assetName: 'brush-vulkan-linux-x64.zip',
  installPath: 'engines/brush-vulkan-linux-x64',
  size: 17627739,
  sha256: '24613b141da3c019ee23fed30ab43967e7a8549900ff764526d2868ba7a3d503',
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: _brushLicenceUrl,
  features: {AiFeature.splatScene},
  releaseTag: aiComponentsSplatsReleaseTag,
  archiveFiles: [
    AiArchiveFile(
      path: 'BUILD-INFO.txt',
      size: 2463,
      sha256: '7c001b43debec6455c7c0191a9ce004f2dbdd7d194456fc9f610e98ba0fa43d4',
    ),
    AiArchiveFile(
      path: 'brush_app',
      size: 66707984,
      sha256: '87573191097e23762c8ce50755dfc49d8446f8c1e446db6b137ac90e72ebb8da',
      executable: true,
    ),
    AiArchiveFile(
      path: 'immuch360-run',
      size: 16552,
      sha256: '779dfe821cc14fbbd8e6f7420ccba3f08509a5802f89d18a5f5a606b2dd79a7b',
      executable: true,
    ),
    AiArchiveFile(
      path: 'licenses/EXTRA-NOTICES.md',
      size: 5935,
      sha256: '2b18770127e5c1212e88983220ec5a9eb8559df9033bd1b62ec89ef3307ebf31',
    ),
    AiArchiveFile(
      path: 'licenses/README.md',
      size: 4527,
      sha256: '07d0bba845a345ebfd2ededea5ae022e353262b2b4eab78eb929e25f9fc1ecaf',
    ),
    AiArchiveFile(
      path: 'licenses/THIRD-PARTY.md',
      size: 430400,
      sha256: '02effca99500521dd2698ec911518c66a8d86f6897c560c2ea5592a7fce2bc27',
    ),
    AiArchiveFile(
      path: 'licenses/brush-LICENSE.txt',
      size: 11358,
      sha256: 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30',
    ),
    AiArchiveFile(
      path: 'licenses/patches/0001-immuch360-headless-trainer.patch',
      size: 17608,
      sha256: '788070930f92eb8922209337429762df0a5748567586cf2bb7e880f5d17be1bf',
    ),
  ],
  minGraphicsMemory: _splatGraphicsMemory,
);

/// The memory of graphics card the training of a splat scene asks for (SplatV1.minGraphicsMemory: 1.1 to 1.6 GB used
/// on the RTX 4060 Laptop for the copy of 150 000 gaussians, 3.0 GB for a whole splat at 1 557 pixels): a card sold
/// with 4 GB, as its memory is read
const _splatGraphicsMemory = 3584 * 1024 * 1024;

// The 3D videos, in ai-components-5 (video3d-plan.md, section 3): the sum checked against the Hugging Face API at the
// pinned revision by .github/desktop/ai/publish_ai_components.py --release ai-components-5.

/// Video Depth Anything Small, the depth of a video 32 frames at a time (input [1, 32, 3, H, W], H and W multiples of
/// 14): the ONNX export (fp32, opset 17) of looplj at ff810849 of the Apache-2.0 weights of ByteDance, a community
/// export validated against them (its validation.json)
const videoDepthModelComponent = AiComponent(
  id: 'video-depth-anything-small-onnx',
  name: 'Video Depth Anything Small',
  version: 'ff810849',
  kind: AiComponentKind.model,
  platforms: {AiPlatform.windowsX64, AiPlatform.linuxX64, AiPlatform.macosArm64, AiPlatform.macosX64},
  assetName: 'video-depth-anything-small-dynamic-fp32.onnx',
  installPath: 'models/video-depth-anything-small/video-depth-anything-small-dynamic-fp32.onnx',
  size: 116528885,
  sha256: 'eb5926ad36741e911c43cb010cc2f74604aa524744feeaf57979c178ede4bb99',
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl:
      'https://huggingface.co/looplj/video-depth-anything-small-onnx/blob/ff810849333df46d37ea18a885fc11689661fe96/LICENSE',
  features: {AiFeature.stereoVideo},
  releaseTag: aiComponentsVideosReleaseTag,
  officialUrls: [
    'https://huggingface.co/looplj/video-depth-anything-small-onnx/resolve/ff810849333df46d37ea18a885fc11689661fe96/video-depth-anything-small-dynamic-fp32.onnx',
  ],
);

// The FFmpeg program of the 3D videos (video3d-plan.md, section 3): ffmpeg and ffprobe 9.0.2 with their shared
// libraries, LGPL 2.1 or later (no GPL or non free part), built from pinned sources, checked, signed for Windows and
// released by github.com/immuch360/libmpv-builds (.github/workflows/ffmpeg.yml at v1.3.1). Each archive holds bin/ (and
// lib/ but on Windows; immuch360-run on Linux), its licence texts, PATENTS-NOTE.md and FFmpeg-SOURCE.txt (the
// corresponding source of the release) in licenses/, BUILD-INFO.txt with the configure lines, and SHA256SUMS.txt. The
// entries carry the archives of the run 44422001622 at b9e49ddba, as the manifest of the release gives them
// (.github/desktop/ai/ffmpeg-lgpl-ffmpeg-lgpl-20261118-9.json); publish_ai_components.py --check holds them to it.

/// The repository of the FFmpeg program, whose releases host its archives
const ffmpegProgramRepository = 'immuch360/libmpv-builds';

/// The release of [ffmpegProgramRepository] the app takes the FFmpeg program from, a prerelease never marked latest
const ffmpegProgramReleaseTag = 'ffmpeg-lgpl-20261118-9';

/// The LGPL 2.1 of FFmpeg at the commit of n9.0.2 (its COPYING.LGPLv2.1; LICENSE.md says which parts are under other
/// permissive licences, all in the licenses/ folder of each archive)
const _ffmpegLicenceUrl =
    'https://github.com/FFmpeg/FFmpeg/blob/946fcce07b6dcd0331c8cc609192aeff5e1924f8/COPYING.LGPLv2.1';

/// The FFmpeg program for Windows x64: ffmpeg.exe, ffprobe.exe and the FFmpeg DLLs beside them, signed by APROGSYS
const ffmpegWindowsComponent = AiComponent(
  id: 'ffmpeg-lgpl-windows-x64',
  name: 'FFmpeg program',
  version: '9.0.2-2',
  kind: AiComponentKind.archive,
  platforms: {AiPlatform.windowsX64},
  assetName: 'Immuch360-ffmpeg-9.0.2-2-windows-x64.zip',
  installPath: 'engines/ffmpeg-lgpl-windows-x64',
  size: 8424233,
  sha256: '7b76b85a6dde6e2e9d7ad84ec695c033e9151578297167b21482591770d14a5e',
  compression: AiCompression.none,
  licence: 'LGPL-2.1-or-later',
  licenceUrl: _ffmpegLicenceUrl,
  features: {AiFeature.stereoVideo},
  releaseTag: ffmpegProgramReleaseTag,
  releaseRepository: ffmpegProgramRepository,
  archiveFiles: [
    AiArchiveFile(
      path: 'BUILD-INFO.txt',
      size: 4172,
      sha256: '86a2a5a6f8960cd3d1126c9bcd2d01862b6beaea49905c01275844faba7dacf4',
    ),
    AiArchiveFile(
      path: 'SHA256SUMS.txt',
      size: 2583,
      sha256: '4a3efaf8c57333f4d064fa7cf04212de98b289673241fb4590d292e1fc54e74f',
    ),
    AiArchiveFile(
      path: 'bin/avcodec-63.dll',
      size: 15607128,
      sha256: '2540b47eb31ae5c07774a5dfed8df91f4dc11162e20e6b9ac90ef6df416690f1',
    ),
    AiArchiveFile(
      path: 'bin/avdevice-63.dll',
      size: 81240,
      sha256: 'dfae378a9a35c63dd5c628133dee0dd7cfc0679503e1bfb76e489f703bc8ffe2',
    ),
    AiArchiveFile(
      path: 'bin/avfilter-12.dll',
      size: 1285976,
      sha256: '491d3bbf642ccd6359b497c57b68c99a2781ba1b276c24397af4dd2e6f6e9cd2',
    ),
    AiArchiveFile(
      path: 'bin/avformat-63.dll',
      size: 1102680,
      sha256: 'd3b1457546356e9dc52dc348e4753446aadc225d29b10f943107f80a9a08c601',
    ),
    AiArchiveFile(
      path: 'bin/avutil-61.dll',
      size: 1076056,
      sha256: '4982261173745e69a2ac6817d9c72d1ea82c0941dfeb96d309ca7d228fee904a',
    ),
    AiArchiveFile(
      path: 'bin/ffmpeg.exe',
      size: 503128,
      sha256: '6335c3d05a688bba0d08a37892dcbb4bbe02edf5b45b6129a30b399f030513a3',
      executable: true,
    ),
    AiArchiveFile(
      path: 'bin/ffprobe.exe',
      size: 233304,
      sha256: '6b05d30cd16bcda55e79b7aaf2eb26f0cf7318ccfe0a418a0eed22ea50b58a4e',
      executable: true,
    ),
    AiArchiveFile(
      path: 'bin/swresample-7.dll',
      size: 139096,
      sha256: 'eb5b2ec8c1369158c03aaf45fd3a4fad44cb67f2edcaeadd65b6cb17a91d8969',
    ),
    AiArchiveFile(
      path: 'bin/swscale-10.dll',
      size: 1120600,
      sha256: 'c16d4d2eb4830bed5a3b597e140b44e124c34391bcb85b9eebe586d7f84c855b',
    ),
    AiArchiveFile(
      path: 'licenses/FFmpeg-COPYING.LGPLv2.1.txt',
      size: 26517,
      sha256: '246041b6ecf9bc32d718a62c57877c78b5eb397b6467e74ed7ae2626ab189c30',
    ),
    AiArchiveFile(
      path: 'licenses/FFmpeg-IJG.txt',
      size: 1961,
      sha256: '9fd403421481cb9f88141c852b259da5a0f65fc15017405862b6370e2df1347c',
    ),
    AiArchiveFile(
      path: 'licenses/FFmpeg-LICENSE.md',
      size: 4346,
      sha256: '2e1d16c72fd74e12063776371da757322f8b77589386532f4fd8634bde7de1af',
    ),
    AiArchiveFile(
      path: 'licenses/FFmpeg-SOURCE.txt',
      size: 675,
      sha256: 'fc8c8971342fe3386551f6b6817a99df429e31a93bf1a2a8b931c8d00a03dd5d',
    ),
    AiArchiveFile(
      path: 'licenses/PATENTS-NOTE.md',
      size: 992,
      sha256: '2524b8924ad94c944c966f33567ade71302c3d04306dc561f96a0dc92232f35a',
    ),
    AiArchiveFile(
      path: 'licenses/README.md',
      size: 4804,
      sha256: '1524f0da7d2c4106a2a8ac92e6eff9325ee04c913b96cd3a2dd18c89489b40dd',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-LICENSE-BSD2.md',
      size: 1316,
      sha256: 'c582fcbeb9cf972a60d298bfaf41dc5adff2dd14208946edcb9bb56a281e8438',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-LICENSE.md',
      size: 1709,
      sha256: '0acc2fcb27472bdc9aaf8b71f37055bbdac4f54671b7d922f241bd7fcd0dd3e6',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-PATENTS.md',
      size: 5767,
      sha256: '20678ab10402659106dc4c147c97b2a6e94b5c0695415e15a8f195ebc3547922',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-fastfeat-LICENSE.txt',
      size: 1506,
      sha256: '043dcfd059386f9facd376351b2bd79325778744aa442177390cdfcca54babed',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-safestringlib-LICENSE.txt',
      size: 2247,
      sha256: 'c0f99a208799ca20c9ccf31a30533d49334eb458dca5a3d14f9afe3e884e5d7d',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-vector-MIT.txt',
      size: 1084,
      sha256: '0baa179c776937c84107ce35bb0bb3d036ed6e5289215241e72701bfc48126d9',
    ),
    AiArchiveFile(
      path: 'licenses/dav1d-COPYING.txt',
      size: 1317,
      sha256: 'dd92c3c2247c5651606fc23a5e2d6a1ebc5ace9a3e49cbde0e12f05ad1cb1ee5',
    ),
    AiArchiveFile(
      path: 'licenses/dav1d-x86inc-ISC.txt',
      size: 1162,
      sha256: '1c20545ce9b2407beccfcf88f33fd0588e8988afaeef31bed7acc30803d2204c',
    ),
    AiArchiveFile(
      path: 'licenses/mingw-gcc-runtime-copyright.txt',
      size: 75729,
      sha256: 'a481f772f7a53335f13b32c6c54eb1c8577ce97704edd3757ab7ed4287a8e96a',
    ),
    AiArchiveFile(
      path: 'licenses/mingw-w64-runtime-copyright.txt',
      size: 35571,
      sha256: 'f27a58667538b6913ea23cb9e07e270922761ebf7c22d94bda7f819aaf08ea08',
    ),
    AiArchiveFile(
      path: 'licenses/zimg-COPYING.txt',
      size: 484,
      sha256: '7637386b5f81e8a719ca336233149005e5fa28b5e6054ea7b67de49355b0ad40',
    ),
    AiArchiveFile(
      path: 'licenses/zlib-LICENSE.txt',
      size: 1002,
      sha256: 'e32ff4e00d9d94930537635291da39e7e612703334bf6fde8c7f1686fe8a45a2',
    ),
  ],
);

/// The FFmpeg program for Linux x64 (glibc of Ubuntu 22.04 and later): the programs in bin/ with immuch360-run, the FFmpeg libraries and libva in lib/
const ffmpegLinuxComponent = AiComponent(
  id: 'ffmpeg-lgpl-linux-x64',
  name: 'FFmpeg program',
  version: '9.0.2-2',
  kind: AiComponentKind.archive,
  platforms: {AiPlatform.linuxX64},
  assetName: 'Immuch360-ffmpeg-9.0.2-2-linux-x64.zip',
  installPath: 'engines/ffmpeg-lgpl-linux-x64',
  size: 8202937,
  sha256: '6a3102ce743507395370c1d4aacb67ea153d065cb05636806af436ca6d2e13f4',
  compression: AiCompression.none,
  licence: 'LGPL-2.1-or-later',
  licenceUrl: _ffmpegLicenceUrl,
  features: {AiFeature.stereoVideo},
  releaseTag: ffmpegProgramReleaseTag,
  releaseRepository: ffmpegProgramRepository,
  archiveFiles: [
    AiArchiveFile(
      path: 'BUILD-INFO.txt',
      size: 4328,
      sha256: '05b738615cf6d71e52241c6da0290e09efc99c82074fa1ba533af8cb960f36ee',
    ),
    AiArchiveFile(
      path: 'SHA256SUMS.txt',
      size: 2815,
      sha256: 'ff99d6e629864301fbef01d6786b966fce993e202fe45a45cdb8fa96d75544c0',
    ),
    AiArchiveFile(
      path: 'bin/ffmpeg',
      size: 504128,
      sha256: '66bb34aa82c122eb5519b2c87144a100819281af61afbba94644dc7676eac0a4',
      executable: true,
    ),
    AiArchiveFile(
      path: 'bin/ffprobe',
      size: 228424,
      sha256: '3531c352a3f000ad1441b71f94ef7cba484118590dacbf54c857d40b149fec99',
      executable: true,
    ),
    AiArchiveFile(
      path: 'bin/immuch360-run',
      size: 14472,
      sha256: '8ab42102ac355c952b2fe3565f06089b499f262bf004d41353fd7e696018e1ed',
      executable: true,
    ),
    AiArchiveFile(
      path: 'lib/libavcodec.so.63',
      size: 15425120,
      sha256: '169251597214d9720718f2f1659558d019dbfa03bb13e96a70d224b51d840891',
    ),
    AiArchiveFile(
      path: 'lib/libavdevice.so.63',
      size: 31432,
      sha256: 'ac1337eda836a862b0f1d0b27f12ee88d5a5df3234f4ddfe11fa8f84ee34e584',
    ),
    AiArchiveFile(
      path: 'lib/libavfilter.so.12',
      size: 1192240,
      sha256: 'd9bbf7c323758326d619f5d96b7cd78ab11c5612ede4e53279415480ded1dfe1',
    ),
    AiArchiveFile(
      path: 'lib/libavformat.so.63',
      size: 1096944,
      sha256: '28d791b58cb4b9c5f5c5c18943f9404ab258d498f56dd5f5e42d817410b58521',
    ),
    AiArchiveFile(
      path: 'lib/libavutil.so.61',
      size: 1031656,
      sha256: 'afdb751cf36b5a8a71fc3033ea675bfe541ddfa8c2fe8db809791c4cc9ce0095',
    ),
    AiArchiveFile(
      path: 'lib/libswresample.so.7',
      size: 129104,
      sha256: 'f163e14407da0f5a6490abc0cbacc24f50e5b04af7b1853ace1378d4a4a85756',
    ),
    AiArchiveFile(
      path: 'lib/libswscale.so.10',
      size: 1195496,
      sha256: 'fe6a95ca8a01351aa22c5a4e606fcb0c5908c6a5564708e94adf6ed584a9faa8',
    ),
    AiArchiveFile(
      path: 'lib/libva-drm.so.2',
      size: 17896,
      sha256: '3c74dba832a29d23fa63211d0f1dc56d800773e6796fe0238f28318c2dbe96ba',
    ),
    AiArchiveFile(
      path: 'lib/libva.so.2',
      size: 237416,
      sha256: 'f671881265952b8cf8665558f6f99796d8ec29d4f7c407901a867a55ba1c2cb1',
    ),
    AiArchiveFile(
      path: 'licenses/FFmpeg-COPYING.LGPLv2.1.txt',
      size: 26517,
      sha256: '246041b6ecf9bc32d718a62c57877c78b5eb397b6467e74ed7ae2626ab189c30',
    ),
    AiArchiveFile(
      path: 'licenses/FFmpeg-IJG.txt',
      size: 1961,
      sha256: '9fd403421481cb9f88141c852b259da5a0f65fc15017405862b6370e2df1347c',
    ),
    AiArchiveFile(
      path: 'licenses/FFmpeg-LICENSE.md',
      size: 4346,
      sha256: '2e1d16c72fd74e12063776371da757322f8b77589386532f4fd8634bde7de1af',
    ),
    AiArchiveFile(
      path: 'licenses/FFmpeg-SOURCE.txt',
      size: 675,
      sha256: 'fc8c8971342fe3386551f6b6817a99df429e31a93bf1a2a8b931c8d00a03dd5d',
    ),
    AiArchiveFile(
      path: 'licenses/PATENTS-NOTE.md',
      size: 992,
      sha256: '2524b8924ad94c944c966f33567ade71302c3d04306dc561f96a0dc92232f35a',
    ),
    AiArchiveFile(
      path: 'licenses/README.md',
      size: 4804,
      sha256: '1524f0da7d2c4106a2a8ac92e6eff9325ee04c913b96cd3a2dd18c89489b40dd',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-LICENSE-BSD2.md',
      size: 1316,
      sha256: 'c582fcbeb9cf972a60d298bfaf41dc5adff2dd14208946edcb9bb56a281e8438',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-LICENSE.md',
      size: 1709,
      sha256: '0acc2fcb27472bdc9aaf8b71f37055bbdac4f54671b7d922f241bd7fcd0dd3e6',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-PATENTS.md',
      size: 5767,
      sha256: '20678ab10402659106dc4c147c97b2a6e94b5c0695415e15a8f195ebc3547922',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-fastfeat-LICENSE.txt',
      size: 1506,
      sha256: '043dcfd059386f9facd376351b2bd79325778744aa442177390cdfcca54babed',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-safestringlib-LICENSE.txt',
      size: 2247,
      sha256: 'c0f99a208799ca20c9ccf31a30533d49334eb458dca5a3d14f9afe3e884e5d7d',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-vector-MIT.txt',
      size: 1084,
      sha256: '0baa179c776937c84107ce35bb0bb3d036ed6e5289215241e72701bfc48126d9',
    ),
    AiArchiveFile(
      path: 'licenses/dav1d-COPYING.txt',
      size: 1317,
      sha256: 'dd92c3c2247c5651606fc23a5e2d6a1ebc5ace9a3e49cbde0e12f05ad1cb1ee5',
    ),
    AiArchiveFile(
      path: 'licenses/dav1d-x86inc-ISC.txt',
      size: 1162,
      sha256: '1c20545ce9b2407beccfcf88f33fd0588e8988afaeef31bed7acc30803d2204c',
    ),
    AiArchiveFile(
      path: 'licenses/immuch360-run-MIT.txt',
      size: 1156,
      sha256: 'e1ca99633c8cb8df3e8189b0c4b804e91b6dca413ae4022ea3d905e0f94ef191',
    ),
    AiArchiveFile(
      path: 'licenses/libva-COPYING.txt',
      size: 1130,
      sha256: 'c86a782ee845b52472dae9b9d79fb915d333628ac0efe49cdce63644814931de',
    ),
    AiArchiveFile(
      path: 'licenses/zimg-COPYING.txt',
      size: 484,
      sha256: '7637386b5f81e8a719ca336233149005e5fa28b5e6054ea7b67de49355b0ad40',
    ),
    AiArchiveFile(
      path: 'licenses/zlib-LICENSE.txt',
      size: 1002,
      sha256: 'e32ff4e00d9d94930537635291da39e7e612703334bf6fde8c7f1686fe8a45a2',
    ),
  ],
);

/// The FFmpeg program for macOS 12 and later, arm64 and x86_64 in one, signed ad hoc
const ffmpegMacComponent = AiComponent(
  id: 'ffmpeg-lgpl-macos-universal',
  name: 'FFmpeg program',
  version: '9.0.2-2',
  kind: AiComponentKind.archive,
  platforms: {AiPlatform.macosArm64, AiPlatform.macosX64},
  assetName: 'Immuch360-ffmpeg-9.0.2-2-macos-universal.zip',
  installPath: 'engines/ffmpeg-lgpl-macos-universal',
  size: 14608564,
  sha256: 'b0d76f497d989283dd5d77c1076792e02371a7df092899f2a8d12857c65cf6b7',
  compression: AiCompression.none,
  licence: 'LGPL-2.1-or-later',
  licenceUrl: _ffmpegLicenceUrl,
  features: {AiFeature.stereoVideo},
  releaseTag: ffmpegProgramReleaseTag,
  releaseRepository: ffmpegProgramRepository,
  archiveFiles: [
    AiArchiveFile(
      path: 'BUILD-INFO.txt',
      size: 5923,
      sha256: '3931c61b6143d164d633ab6e9cb73b52182adf1750d6e1b38c371f193632bdc5',
    ),
    AiArchiveFile(
      path: 'SHA256SUMS.txt',
      size: 2396,
      sha256: '6b903bc2ece030a410490d4fe7988df8ad95275aa5a759ed150842648909af72',
    ),
    AiArchiveFile(
      path: 'bin/ffmpeg',
      size: 937728,
      sha256: '2c695271cf34b303f9d240c03476f32a8d6eb2b2502ef0adad37dbbb49da943d',
      executable: true,
    ),
    AiArchiveFile(
      path: 'bin/ffprobe',
      size: 467824,
      sha256: 'b75ecf315b3551975c5f64429fc93a70617141b1f249fe77b0b37df002cb1c91',
      executable: true,
    ),
    AiArchiveFile(
      path: 'lib/libavcodec.63.dylib',
      size: 26382784,
      sha256: 'b8ecf37e774754da870edc7ea62a4bf620288f2350e7ad4bcd9272b472db4316',
    ),
    AiArchiveFile(
      path: 'lib/libavdevice.63.dylib',
      size: 124944,
      sha256: 'a9ff5552be34044575adeab2473cb6cff3c8ad910f622774eb623f4b026e64c9',
    ),
    AiArchiveFile(
      path: 'lib/libavfilter.12.dylib',
      size: 1546368,
      sha256: '29b056c513426a06e57627c498c7e80267991c70025f4dde21a725034230ff6b',
    ),
    AiArchiveFile(
      path: 'lib/libavformat.63.dylib',
      size: 2059056,
      sha256: '71dbc12d6b96f2c9b89fad880df06228097cb4eab6d4a128037d5367ea9dd143',
    ),
    AiArchiveFile(
      path: 'lib/libavutil.61.dylib',
      size: 1645472,
      sha256: '081ec2e1ab165784c38a2584e5926e813dcb6ec75bc3d8b9496db79cf602d7f0',
    ),
    AiArchiveFile(
      path: 'lib/libswresample.7.dylib',
      size: 318352,
      sha256: 'edf8cc1afe2d7bc2ea3833e3cf682ddc843e8ce36e801dd0e83ad9d7250cf7e3',
    ),
    AiArchiveFile(
      path: 'lib/libswscale.10.dylib',
      size: 2890720,
      sha256: 'c2f14cb3257a650ad26047f224d13e400e801c7406d6ba4f3e58861044508158',
    ),
    AiArchiveFile(
      path: 'licenses/FFmpeg-COPYING.LGPLv2.1.txt',
      size: 26517,
      sha256: '246041b6ecf9bc32d718a62c57877c78b5eb397b6467e74ed7ae2626ab189c30',
    ),
    AiArchiveFile(
      path: 'licenses/FFmpeg-IJG.txt',
      size: 1961,
      sha256: '9fd403421481cb9f88141c852b259da5a0f65fc15017405862b6370e2df1347c',
    ),
    AiArchiveFile(
      path: 'licenses/FFmpeg-LICENSE.md',
      size: 4346,
      sha256: '2e1d16c72fd74e12063776371da757322f8b77589386532f4fd8634bde7de1af',
    ),
    AiArchiveFile(
      path: 'licenses/FFmpeg-SOURCE.txt',
      size: 675,
      sha256: 'fc8c8971342fe3386551f6b6817a99df429e31a93bf1a2a8b931c8d00a03dd5d',
    ),
    AiArchiveFile(
      path: 'licenses/PATENTS-NOTE.md',
      size: 992,
      sha256: '2524b8924ad94c944c966f33567ade71302c3d04306dc561f96a0dc92232f35a',
    ),
    AiArchiveFile(
      path: 'licenses/README.md',
      size: 4804,
      sha256: '1524f0da7d2c4106a2a8ac92e6eff9325ee04c913b96cd3a2dd18c89489b40dd',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-LICENSE-BSD2.md',
      size: 1316,
      sha256: 'c582fcbeb9cf972a60d298bfaf41dc5adff2dd14208946edcb9bb56a281e8438',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-LICENSE.md',
      size: 1709,
      sha256: '0acc2fcb27472bdc9aaf8b71f37055bbdac4f54671b7d922f241bd7fcd0dd3e6',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-PATENTS.md',
      size: 5767,
      sha256: '20678ab10402659106dc4c147c97b2a6e94b5c0695415e15a8f195ebc3547922',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-fastfeat-LICENSE.txt',
      size: 1506,
      sha256: '043dcfd059386f9facd376351b2bd79325778744aa442177390cdfcca54babed',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-safestringlib-LICENSE.txt',
      size: 2247,
      sha256: 'c0f99a208799ca20c9ccf31a30533d49334eb458dca5a3d14f9afe3e884e5d7d',
    ),
    AiArchiveFile(
      path: 'licenses/SVT-AV1-vector-MIT.txt',
      size: 1084,
      sha256: '0baa179c776937c84107ce35bb0bb3d036ed6e5289215241e72701bfc48126d9',
    ),
    AiArchiveFile(
      path: 'licenses/dav1d-COPYING.txt',
      size: 1317,
      sha256: 'dd92c3c2247c5651606fc23a5e2d6a1ebc5ace9a3e49cbde0e12f05ad1cb1ee5',
    ),
    AiArchiveFile(
      path: 'licenses/dav1d-x86inc-ISC.txt',
      size: 1162,
      sha256: '1c20545ce9b2407beccfcf88f33fd0588e8988afaeef31bed7acc30803d2204c',
    ),
    AiArchiveFile(
      path: 'licenses/zimg-COPYING.txt',
      size: 484,
      sha256: '7637386b5f81e8a719ca336233149005e5fa28b5e6054ea7b67de49355b0ad40',
    ),
    AiArchiveFile(
      path: 'licenses/zlib-LICENSE.txt',
      size: 1002,
      sha256: 'e32ff4e00d9d94930537635291da39e7e612703334bf6fde8c7f1686fe8a45a2',
    ),
  ],
);

// ai-components-6: the runtime of the graphics card of the 3D videos on Windows (lot ai-360-3d-51), made by
// .github/desktop/ai/publish_ai_components.py from the package Microsoft.ML.OnnxRuntime.DirectML 1.24.4; where the
// app finds it: ai_gpu_runtime_manifest.dart

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

// ai-components-7: the components of "Enhance (AI)" (lots E1 to E3 of release 51; which level takes which:
// ai_enhance_manifest.dart and desktop/ai/enhance/enhance_files.dart)

const _gib = 1024 * 1024 * 1024;

const _seedVr2Licence = 'https://huggingface.co/ByteDance-Seed/SeedVR2-3B';
const _seedVr2Revision = 'https://huggingface.co/Comfy-Org/SeedVR2/resolve/df48879708206a403d2a61acd55578c2e80fd233';
const _vosrLicence =
    'https://huggingface.co/moonbox-dev/VOSR-ONNX/blob/46811283f2b767d9d634cdd3d8e465594712df61/LICENSE';
const _vosrRevision = 'https://huggingface.co/moonbox-dev/VOSR-ONNX/resolve/46811283f2b767d9d634cdd3d8e465594712df61';

const _gpuSystems = {AiPlatform.windowsX64, AiPlatform.linuxX64};
const _vosrSystems = {AiPlatform.windowsX64, AiPlatform.linuxX64, AiPlatform.macosArm64};

/// SeedVR2 3B, int8 convrot (3,458,259,704 bytes): the DiT of Rebuild details
const seedVr2DitComponent = AiComponent(
  id: 'seedvr2-3b-int8-convrot',
  name: 'SeedVR2 3B (int8)',
  version: 'df488797',
  kind: AiComponentKind.model,
  platforms: _gpuSystems,
  assetName: 'seedvr2_3b_int8_convrot.safetensors',
  installPath: 'models/seedvr2/seedvr2_3b_int8_convrot.safetensors',
  size: 3458259704,
  sha256: 'c3dec8bcc5916843a8a858572970597462e1f2dc598d6dfd818f6cd40f53a157',
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: _seedVr2Licence,
  features: {},
  releaseTag: aiComponentsEnhanceReleaseTag,
  officialUrls: ['$_seedVr2Revision/diffusion_models/seedvr2_3b_int8_convrot.safetensors'],
  parts: [
    AiComponentPart(
      assetName: 'seedvr2_3b_int8_convrot.safetensors.001',
      size: 2039480320,
      sha256: 'fb7ada88ecaf1ba03f53d913ae4ca13a6a8b33b4c76f92ec5822998b76cb3843',
    ),
    AiComponentPart(
      assetName: 'seedvr2_3b_int8_convrot.safetensors.002',
      size: 1418779384,
      sha256: '51e7c59c254dea0a0d362aba225917c095cb215450d93056b96df174697a3a8b',
    ),
  ],
  minGraphicsMemory: 6 * _gib,
);

/// The VAE of SeedVR2 in fp16 (501,324,814 bytes)
const seedVr2VaeComponent = AiComponent(
  id: 'seedvr2-ema-vae-fp16',
  name: 'SeedVR2 VAE',
  version: 'df488797',
  kind: AiComponentKind.model,
  platforms: _gpuSystems,
  assetName: 'seedvr2_ema_vae_fp16.safetensors',
  installPath: 'models/seedvr2/seedvr2_ema_vae_fp16.safetensors',
  size: 501324814,
  sha256: '20678548f420d98d26f11442d3528f8b8c94e57ee046ef93dbb7633da8612ca1',
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: _seedVr2Licence,
  features: {},
  releaseTag: aiComponentsEnhanceReleaseTag,
  officialUrls: ['$_seedVr2Revision/vae/seedvr2_ema_vae_fp16.safetensors'],
);

/// stable-diffusion.cpp at 0d71f963 on Vulkan for Windows x64, the engine of Rebuild details: pending the run of our CI
/// that builds and signs it (no size, no sum, no files: never offered before)
const sdCppSeedVr2WindowsComponent = AiComponent(
  id: 'sd-cpp-seedvr2-vulkan-win-x64',
  name: 'stable-diffusion.cpp for SeedVR2 (Vulkan)',
  version: '0d71f96-1',
  kind: AiComponentKind.archive,
  platforms: {AiPlatform.windowsX64},
  assetName: 'sd-cpp-seedvr2-vulkan-win-x64.zip',
  installPath: 'engines/sd-cpp-seedvr2-vulkan-win-x64',
  size: 32008928,
  sha256: '2a9aaebf1edacbeabb537f20551169ac13783e9a35b00310c0791e5d4005cf63',
  compression: AiCompression.none,
  licence: 'MIT',
  licenceUrl: 'https://github.com/leejet/stable-diffusion.cpp/blob/0d71f963af9c94941f4a67e8ea145935651dd756/LICENSE',
  features: {},
  releaseTag: aiComponentsEnhanceReleaseTag,
  archiveFiles: [
    AiArchiveFile(
      path: 'BUILD-INFO.txt',
      size: 866,
      sha256: 'c01236e410bf31a60957592d75be9dc0279200de38c95a035a6195cc337a0722',
    ),
    AiArchiveFile(
      path: 'ggml-base.dll',
      size: 757576,
      sha256: 'c63a10665f6dc5fba7e1e0642715f5aebb8022fe1d217f90461848c09d09b5c6',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-alderlake.dll',
      size: 1011016,
      sha256: 'f72e6cc46e8f92b2c19af0e5fdbc22ef4fe4577aa7f2265368e72cca5f02734d',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-cannonlake.dll',
      size: 1056584,
      sha256: '3346f1561bab7089725fa86738b08ced611e6f89b6578a28dbe642e3fae5fd32',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-cascadelake.dll',
      size: 1057608,
      sha256: '0527db0b3f13f5d7587d5fe57188e0ba6171289a868db96df6af0b94b8d9a853',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-haswell.dll',
      size: 1012040,
      sha256: '823379f82508907ef8dad06bbe3878e70e1e4f8b2b0a1d084f640fb57f7e46ae',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-icelake.dll',
      size: 1057608,
      sha256: '407b415a2f28f29a710307abdcc1c01751c7c95389ceb95901242a2ae63f8319',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-sandybridge.dll',
      size: 1033032,
      sha256: '56d765c57f70632aeb14b384175289772a3c2237fa059fe0bcfcdef99e3c9dd6',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-skylakex.dll',
      size: 1056584,
      sha256: '1c0406d7903f8c6dbb8554e9eb96fb570c243bc79c1bed1cf6d860223d800376',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-sse42.dll',
      size: 870728,
      sha256: 'f758c7caf3d0c58b1aef340223eab6b18f5168f84598af308b275c0bb5225dff',
    ),
    AiArchiveFile(
      path: 'ggml-cpu-x64.dll',
      size: 871752,
      sha256: 'e3d28a1d340968c709e7b937cab81d27bf2896c2996c1eed4b588fe5434d662c',
    ),
    AiArchiveFile(
      path: 'ggml-vulkan.dll',
      size: 40779080,
      sha256: '187780065ef79cf3704ef61415d06f708fe858ba67cfbfc37a8c7a1048e281d0',
    ),
    AiArchiveFile(
      path: 'ggml.dll',
      size: 76104,
      sha256: '89d886a95ed58f577fc8cc66b7208eb5ac8e4cbd25479471b9349ca5a5679e41',
    ),
    AiArchiveFile(
      path: 'licenses/README.md',
      size: 1185,
      sha256: '26f980b88d5210da2e6024efbd56d3d2ca77de7010bc73989b660187ce53528a',
    ),
    AiArchiveFile(
      path: 'licenses/THIRD-PARTY.md',
      size: 6968,
      sha256: '0d58c599729e84498452fce4fbafa819cc6529683d0711c60b3a965132444b70',
    ),
    AiArchiveFile(
      path: 'licenses/darts-clone-LICENSE.txt',
      size: 1491,
      sha256: 'ed8437dc7358a40ef10afd3635ac1cd43c88fbaaaf6cd27c414f8ada5d68f447',
    ),
    AiArchiveFile(
      path: 'licenses/ggml-LICENSE.txt',
      size: 1099,
      sha256: 'bcd8ec749126d45cb06737d0690295d73df4b6e7e194205bcf91190368f27285',
    ),
    AiArchiveFile(
      path: 'licenses/oniguruma-COPYING.txt',
      size: 1366,
      sha256: '0dff717fb611b9c9bd9776a5df9c4e029030f8dbc023b77f3678cf495495b933',
    ),
    AiArchiveFile(
      path: 'licenses/stable-diffusion.cpp-LICENSE.txt',
      size: 1082,
      sha256: '4e76049398df734a97db46f3bd4b5cbc460cb5f6bfaf737cdc3d6fbb8ab3de27',
    ),
    AiArchiveFile(
      path: 'licenses/utf8proc-LICENSE.md',
      size: 5218,
      sha256: '767edbcafb23016d7f203aaf2cbdef5690ad58bcede52ee241427dcb816cd644',
    ),
    AiArchiveFile(
      path: 'msvcp140.dll',
      size: 557728,
      sha256: '0f885b509a685d2bbfa652fed26b5fb31d88fbdab0a978c641d1c7b8aa460aa9',
    ),
    AiArchiveFile(
      path: 'msvcp140_codecvt_ids.dll',
      size: 31872,
      sha256: 'f2069a52880ec885ee7f0511186100eb7fada0411a2b4948fafea7735b878a18',
    ),
    AiArchiveFile(
      path: 'sd-cli.exe',
      size: 623944,
      sha256: '749934f4449beb4c625e74a4b09c29609689868a90b6ca9a20e47e1283b2e47b',
      executable: true,
    ),
    AiArchiveFile(
      path: 'stable-diffusion.dll',
      size: 38794056,
      sha256: '12428bbcbd4fd4868254933927a152e7d279dce35c7a442579006702044797c0',
    ),
    AiArchiveFile(
      path: 'vcruntime140.dll',
      size: 124544,
      sha256: 'd5e4d9a3e835fa679450145d6a7d94e36573a509317111904d9b3712c30d9066',
    ),
    AiArchiveFile(
      path: 'vcruntime140_1.dll',
      size: 49792,
      sha256: '1f2d41c4aa5db0bc33ebf7b66d72943a817d7ce6cbe880502a9403823633093f',
    ),
  ],
);

/// The same for Linux x64, with the launcher immuch360-run
const sdCppSeedVr2LinuxComponent = AiComponent(
  id: 'sd-cpp-seedvr2-vulkan-linux-x64',
  name: 'stable-diffusion.cpp for SeedVR2 (Vulkan)',
  version: '0d71f96-1',
  kind: AiComponentKind.archive,
  platforms: {AiPlatform.linuxX64},
  assetName: 'sd-cpp-seedvr2-vulkan-linux-x64.zip',
  installPath: 'engines/sd-cpp-seedvr2-vulkan-linux-x64',
  size: 37741231,
  sha256: '62ae653e2d3e49ba4c9e62741adb69e3c43e18d35a85bf2f13397ef8c798cf29',
  compression: AiCompression.none,
  licence: 'MIT',
  licenceUrl: 'https://github.com/leejet/stable-diffusion.cpp/blob/0d71f963af9c94941f4a67e8ea145935651dd756/LICENSE',
  features: {},
  releaseTag: aiComponentsEnhanceReleaseTag,
  archiveFiles: [
    AiArchiveFile(
      path: 'BUILD-INFO.txt',
      size: 816,
      sha256: '37a9b1833e914dffc9ac6aa86d1bab2a72bf0deae3dc80cdbd32b137fffa8cd4',
    ),
    AiArchiveFile(
      path: 'immuch360-run',
      size: 16552,
      sha256: '779dfe821cc14fbbd8e6f7420ccba3f08509a5802f89d18a5f5a606b2dd79a7b',
      executable: true,
    ),
    AiArchiveFile(
      path: 'libggml-base.so.1',
      size: 1002488,
      sha256: '3aad50895abdb6caab6b14d10256cb697f968629df05d07f418b85b2b0eb19e1',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-alderlake.so',
      size: 1299000,
      sha256: 'e039ace50f89eaee5278aa935b05a20c169dae6f53c260f086367fefa284f988',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-cannonlake.so',
      size: 1381032,
      sha256: '3da6ac901d6d775c556f93442251284e4c61eb9818e56a34a7b5506be6d5f2e2',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-cascadelake.so',
      size: 1397120,
      sha256: 'bea3e369404f8cc4312b3cd40a953181babab888471283161a0f60b69126a9b6',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-cooperlake.so',
      size: 1397120,
      sha256: '1cea9ebd9d93ff4dc21ad56522355ede08eceafb5c438ffb72413c01edba2f95',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-haswell.so',
      size: 1303096,
      sha256: '719969d9ba782813e24e0474865440fcf766caedb9d41f5336f6a377e9074e3d',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-icelake.so',
      size: 1397120,
      sha256: 'e791c694f05b474d430bad437a843c1525ffc0377a4cf0bbf17283883fb4c260',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-ivybridge.so',
      size: 1235880,
      sha256: 'd1441f9e8b7424d95427c10b75e1dbe53bc11e3bed6f414709fa597c8873cc91',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-piledriver.so',
      size: 1235880,
      sha256: 'b3b3a7c2315f7d9eddca2526451d45b29706753a731a7a205ed2a9f0957299ec',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-sandybridge.so',
      size: 1248328,
      sha256: 'b7c1b0904ea3610f9935600eddd7a9b78fc36bad096b48d6fc14b0db31a0b050',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-sapphirerapids.so',
      size: 1697448,
      sha256: '9010d4153ea9114b7b18bbc23568cf9a7d7ff4f2650c6ada07d3c071d74856a8',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-skylakex.so',
      size: 1381032,
      sha256: '820ba034c7ff3bda86dae8bdc89ebd66273ab87464b98e096d4e1954ca513c5c',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-sse42.so',
      size: 985408,
      sha256: '80112abb0da4e1b9d2132b2e816771096971433c6f3ef6c85d18071408905064',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-x64.so',
      size: 985536,
      sha256: '282377079ea2dfacaf467074db1527ec8abbba2ee22b8a70e5938d1090eda3b9',
    ),
    AiArchiveFile(
      path: 'libggml-cpu-zen4.so',
      size: 1397120,
      sha256: 'cc1c5f7a291f2d4a3280b9e59bdd06c6ca14627bb01ec82866d2bb46e5e3b405',
    ),
    AiArchiveFile(
      path: 'libggml-vulkan.so',
      size: 41424648,
      sha256: 'e9344c1e8614afa15cc9c922490d5bf59ec7114cfb93729d8b99919ca774d181',
    ),
    AiArchiveFile(
      path: 'libggml.so.1',
      size: 51040,
      sha256: '6a6b8efcaed753fd4c30e89be56846376aeef0726db59d380a97520452f0ca39',
    ),
    AiArchiveFile(
      path: 'libstable-diffusion.so',
      size: 45861728,
      sha256: '6bce5e93470f3360f63ee5c4df17578f8c996c7664e13816a6f78ad60aaf42b8',
    ),
    AiArchiveFile(
      path: 'licenses/README.md',
      size: 1169,
      sha256: 'dfc8ee008f776c77648f9c6692fce332ad190a2479653c6399bc2873b5d7e8be',
    ),
    AiArchiveFile(
      path: 'licenses/THIRD-PARTY.md',
      size: 6862,
      sha256: 'de31b8552d1bdb1765a3b75781df6763f576d8762fc9a58d652a4d4733bcf70b',
    ),
    AiArchiveFile(
      path: 'licenses/darts-clone-LICENSE.txt',
      size: 1481,
      sha256: '155f59997298ee336602c49f9c1110f268ac394ca2197eb02647a3555935ad52',
    ),
    AiArchiveFile(
      path: 'licenses/ggml-LICENSE.txt',
      size: 1078,
      sha256: '94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d',
    ),
    AiArchiveFile(
      path: 'licenses/oniguruma-COPYING.txt',
      size: 1366,
      sha256: '0dff717fb611b9c9bd9776a5df9c4e029030f8dbc023b77f3678cf495495b933',
    ),
    AiArchiveFile(
      path: 'licenses/stable-diffusion.cpp-LICENSE.txt',
      size: 1062,
      sha256: 'b53fa08f515cb5a6fff7b9fd8fcd0961a4b80df29d74372d25e1f9171aa042ee',
    ),
    AiArchiveFile(
      path: 'licenses/utf8proc-LICENSE.md',
      size: 5218,
      sha256: '767edbcafb23016d7f203aaf2cbdef5690ad58bcede52ee241427dcb816cd644',
    ),
    AiArchiveFile(
      path: 'sd-cli',
      size: 1185464,
      sha256: '5199f72285d63c2999d7d00b2866d6e7e1de579dab9e1c7533c01d1323276bed',
      executable: true,
    ),
  ],
);

/// VOSR 2.0 1.4B int8, DINOv2-L: a graph of Natural
const vosrImageEncoderComponent = AiComponent(
  id: 'vosr2-1.4b-int8-image-encoder',
  name: 'VOSR 2.0 1.4B int8 (DINOv2-L)',
  version: '46811283',
  kind: AiComponentKind.model,
  platforms: _vosrSystems,
  assetName: 'vosr2-int8-image_encoder.onnx',
  installPath: 'models/vosr2-int8/image_encoder/model.onnx',
  size: 460494444,
  sha256: '991f96af4a0dedf5da19d5a69a8c77f106138cacffdc82fadeef2397dd3c37cd',
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: _vosrLicence,
  features: {},
  releaseTag: aiComponentsEnhanceReleaseTag,
  officialUrls: ['$_vosrRevision/int8/image_encoder/model.onnx'],
);

/// VOSR 2.0 1.4B int8, VAE encoder: a graph of Natural
const vosrVaeEncoderComponent = AiComponent(
  id: 'vosr2-1.4b-int8-vae-encoder',
  name: 'VOSR 2.0 1.4B int8 (VAE encoder)',
  version: '46811283',
  kind: AiComponentKind.model,
  platforms: _vosrSystems,
  assetName: 'vosr2-int8-vae_encoder.onnx',
  installPath: 'models/vosr2-int8/vae_encoder/model.onnx',
  size: 38701657,
  sha256: 'c3efac4d5f173692c45002aa90d79f155898697db73cfcef1fb90a56d07ea161',
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: _vosrLicence,
  features: {},
  releaseTag: aiComponentsEnhanceReleaseTag,
  officialUrls: ['$_vosrRevision/int8/vae_encoder/model.onnx'],
);

/// VOSR 2.0 1.4B int8, transformer: a graph of Natural
const vosrTransformerComponent = AiComponent(
  id: 'vosr2-1.4b-int8-transformer',
  name: 'VOSR 2.0 1.4B int8 (transformer)',
  version: '46811283',
  kind: AiComponentKind.model,
  platforms: _vosrSystems,
  assetName: 'vosr2-int8-transformer.onnx',
  installPath: 'models/vosr2-int8/transformer/model.onnx',
  size: 1409190442,
  sha256: 'e38ab963051515bdc39fb1a096d8eb3ee895355cdc1b658bbd7ce9fa3af8bd62',
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: _vosrLicence,
  features: {},
  releaseTag: aiComponentsEnhanceReleaseTag,
  officialUrls: ['$_vosrRevision/int8/transformer/model.onnx'],
);

/// VOSR 2.0 1.4B int8, VAE decoder: a graph of Natural
const vosrVaeDecoderComponent = AiComponent(
  id: 'vosr2-1.4b-int8-vae-decoder',
  name: 'VOSR 2.0 1.4B int8 (VAE decoder)',
  version: '46811283',
  kind: AiComponentKind.model,
  platforms: _vosrSystems,
  assetName: 'vosr2-int8-vae_decoder.onnx',
  installPath: 'models/vosr2-int8/vae_decoder/model.onnx',
  size: 50689496,
  sha256: '3ca755f97a8d57ad5f793c757f0d3a65200067d98528f110d765b4b28ef989ba',
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: _vosrLicence,
  features: {},
  releaseTag: aiComponentsEnhanceReleaseTag,
  officialUrls: ['$_vosrRevision/int8/vae_decoder/model.onnx'],
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
  mogeGeometryComponent,
  lamaInpaintComponent,
  miganInpaintComponent,
  sdCppWindowsComponent,
  sdCppLinuxComponent,
  fluxTransformerComponent,
  qwenTextEncoderComponent,
  fluxVaeComponent,
  panoramaLoraComponent,
  upscalerComponent,
  av2DecoderWindowsComponent,
  av2DecoderLinuxComponent,
  av2DecoderMacComponent,
  colmapWindowsComponent,
  colmapLinuxComponent,
  brushWindowsComponent,
  brushLinuxComponent,
  videoDepthModelComponent,
  ffmpegWindowsComponent,
  ffmpegLinuxComponent,
  ffmpegMacComponent,
  onnxRuntimeDirectMlComponent,
  seedVr2DitComponent,
  seedVr2VaeComponent,
  sdCppSeedVr2WindowsComponent,
  sdCppSeedVr2LinuxComponent,
  vosrImageEncoderComponent,
  vosrVaeEncoderComponent,
  vosrTransformerComponent,
  vosrVaeDecoderComponent,
];

/// The components [platform] needs for [feature] (the 3D photo when not given), the runtimes first, then the
/// archives, then the models; none where the feature is not offered. Of a component and its variants, one only: the
/// one a card of [graphicsMemory] bytes takes with the most memory, else the one that asks for the least (the gate
/// then refuses with its reason), the main entry when the memory is unknown. [catalogue] only in the tests.
List<AiComponent> aiComponentsFor(
  AiPlatform platform, {
  AiFeature feature = AiFeature.stereoPhoto,
  int? graphicsMemory,
  List<AiComponent> catalogue = aiComponents,
}) {
  if (!feature.platforms.contains(platform)) {
    return const [];
  }
  final serving = catalogue
      .where((component) => component.platforms.contains(platform) && component.features.contains(feature))
      .toList();
  final chosen = <String, AiComponent>{};
  for (final component in serving) {
    final family = component.variantOf ?? component.id;
    final kept = chosen[family];
    chosen[family] = kept == null ? component : _betterVariant(kept, component, graphicsMemory);
  }
  return [
    for (final kind in const [AiComponentKind.runtime, AiComponentKind.archive, AiComponentKind.model])
      ...serving.where(
        (component) => component.kind == kind && identical(chosen[component.variantOf ?? component.id], component),
      ),
  ];
}

/// Of two variants of one component, the one for a card of [memory] bytes (see aiComponentsFor)
AiComponent _betterVariant(AiComponent a, AiComponent b, int? memory) {
  if (memory == null) {
    return a.variantOf == null ? a : b;
  }
  bool fits(AiComponent component) => (component.minGraphicsMemory ?? 0) <= memory;
  int need(AiComponent component) => component.minGraphicsMemory ?? 0;
  if (fits(a) != fits(b)) {
    return fits(a) ? a : b;
  }
  if (fits(a)) {
    return need(b) > need(a) ? b : a;
  }
  return need(b) < need(a) ? b : a;
}

/// The groups the app does not offer yet, whatever their catalogue says. The 360° panoramas were held here until their
/// components were published: ai-components-3 is out (D6) and FreeKC gave his go for build 32, so they ship as an
/// experimental feature, behind the gate of the graphics card and with their honesty texts. The author's own judgement
/// of their quality in a headset is pending; the release notes report it. A group put back here is no longer offered:
/// not listed in the dialog, refused by the gate as not in this version.
///
/// The splat scenes were held here from 1 November 2026 until ai-components-4 was made (plan 2026-11-01, lot SP14):
/// FreeKC asked on 4 November 2026 for the release of everything done, the splat scenes with it, as an experimental
/// feature behind the gate of the graphics card (a dedicated card, Windows only). Their components come from
/// ai-components-4 like the others from theirs; put the group back here if that release is not published.
///
/// The 3D videos were held here until the screens of their lot (feat-video3d-49) offered them, ai-components-5 and the
/// release ffmpeg-lgpl-20261118-9 of the FFmpeg program published (video3d-plan.md, section 4.1): nothing is held now.
const aiHeldFeatureGroups = <AiFeatureGroup>{};

/// The components of each group of features on [platform], in the order of [AiFeatureGroup]; a group left out when
/// none of its features is offered here, one of its components is incomplete, or it is [held] (never offered). The
/// groups of the AI unless [only] names others: the AV2 decoder is asked for by name, by the video settings.
List<AiGroupComponents> aiComponentGroupsFor(
  AiPlatform platform, {
  int? graphicsMemory,
  List<AiComponent> catalogue = aiComponents,
  Set<AiFeatureGroup> held = aiHeldFeatureGroups,
  Set<AiFeatureGroup>? only,
}) {
  final groups = <AiGroupComponents>[];
  final earlier = <String>{};
  for (final group in AiFeatureGroup.values) {
    if (held.contains(group) || !(only?.contains(group) ?? group.isAi)) {
      continue;
    }
    final all = <AiComponent>[];
    for (final feature in group.features) {
      for (final component in aiComponentsFor(
        platform,
        feature: feature,
        graphicsMemory: graphicsMemory,
        catalogue: catalogue,
      )) {
        if (!all.any((kept) => kept.id == component.id)) {
          all.add(component);
        }
      }
    }
    if (all.isEmpty || all.any((component) => !component.isComplete)) {
      continue;
    }
    groups.add(
      AiGroupComponents(
        group: group,
        all: all,
        own: [
          for (final component in all)
            if (!earlier.contains(component.id)) component,
        ],
      ),
    );
    earlier.addAll(all.map((component) => component.id));
  }
  return groups;
}

/// What a group of features asks for on one system
class AiGroupComponents {
  const AiGroupComponents({required this.group, required this.all, required this.own});

  final AiFeatureGroup group;

  /// Every component its features need, the shared ones included
  final List<AiComponent> all;

  /// Those an earlier group does not already list: what the screens show under it and count in its size
  final List<AiComponent> own;
}

/// The component of [id], null for an id this version does not know (an installed.json of a newer version)
AiComponent? aiComponentById(String id) {
  for (final component in aiComponents) {
    if (component.id == id) {
      return component;
    }
  }
  return null;
}
