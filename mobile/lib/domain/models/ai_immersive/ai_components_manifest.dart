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
// The entries of the scenes carry the sums measured by M2 (phase23/m2-measures-2026-10-27.md, section 10): our export of
// MoGe-2 ViT-S, and LaMa, which fills the hidden bands of every scene. MI-GAN fills the seam of a panorama only, so it
// travels with the panoramas. The entries of the panoramas carry the files M3 measured (Q4_0 of the transformer, the
// one that holds in 8 GB) and wait for P2 (the archives of stable-diffusion.cpp, built and signed by our CI) and for the
// verdict of M3 before ai-components-3 is published: an entry without its size or sum is never offered.
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
enum AiFeature {
  stereoPhoto([..._computers, AiPlatform.questArm64]),
  scene(_computers),
  panorama([AiPlatform.windowsX64, AiPlatform.linuxX64]),
  stereoPanorama(_computers);

  const AiFeature(this.platforms);

  /// Where the feature is offered: the generated panorama waits for a lot of its own on the Macs (design 4.7, point
  /// 7), and the headset computes only the 3D photo
  final List<AiPlatform> platforms;
}

const _computers = [AiPlatform.windowsX64, AiPlatform.linuxX64, AiPlatform.macosArm64, AiPlatform.macosX64];

/// The groups the screens show the components in (design 7.1, point 7): the 3D photos, with the 3D version of a 360°
/// photo, which needs nothing more; the 3D scenes; the 360° panoramas. Each is installed, sized and removed as a whole.
enum AiFeatureGroup {
  photos({AiFeature.stereoPhoto, AiFeature.stereoPanorama}),
  scenes({AiFeature.scene}),
  panoramas({AiFeature.panorama});

  const AiFeatureGroup(this.features);

  final Set<AiFeature> features;
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

/// The groups the app does not offer yet, whatever their catalogue says. Empty on this branch of lot V3, made only to
/// build an app that offers the 360° panoramas from the local mirror of ai-components-3 for the essays on a PC with a
/// graphics card: never merged; the publication of ai-components-3 (D6) lifts the hold the same way
const aiHeldFeatureGroups = <AiFeatureGroup>{};

/// The components of each group of features on [platform], in the order of [AiFeatureGroup]; a group left out when
/// none of its features is offered here, one of its components is incomplete, or it is [held] (never offered)
List<AiGroupComponents> aiComponentGroupsFor(
  AiPlatform platform, {
  int? graphicsMemory,
  List<AiComponent> catalogue = aiComponents,
  Set<AiFeatureGroup> held = aiHeldFeatureGroups,
}) {
  final groups = <AiGroupComponents>[];
  final earlier = <String>{};
  for (final group in AiFeatureGroup.values) {
    if (held.contains(group)) {
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
