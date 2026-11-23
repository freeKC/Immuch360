// The components of "Enhance (AI)" (lots E1 to E3 of release 51, store/m2/ai-enhance-2026-11-22), for the prerelease
// ai-components-7, which is NOT published yet (ai-components-6 is the DirectML runtime of the 3D videos,
// ai_gpu_runtime_manifest.dart). They stay out of the catalogue of ai_components_manifest.dart until that release is
// made: publish_ai_components.py checks every entry of the catalogue against a published release. Their files are the
// ones the probe of 23 November 2026 downloaded and measured, with the sizes and SHA-256 it read (probe-e0.md, section
// 1), equal to the ones Hugging Face publishes at the pinned revisions.
//
//  - Sharpen needs nothing new: the sd-cli of the 360° panoramas and Real-ESRGAN x4plus (sdCppWindowsComponent,
//    sdCppLinuxComponent, upscalerComponent of ai-components-3).
//  - Rebuild details: SeedVR2 3B int8 convrot and its VAE (Comfy-Org/SeedVR2 at df488797, Apache-2.0; ByteDance-Seed
//    SeedVR2-3B, Apache-2.0, trained from scratch, no inherited base model), the DiT in two parts of 1945 MiB and the
//    rest (GitHub refuses an asset of 2 GiB or more), its official file at the pinned revision tried after the release;
//    and a second archive of stable-diffusion.cpp at 0d71f963 (MIT), built by the jobs sdcpp-seedvr2-windows and
//    sdcpp-seedvr2-linux of our CI from sd_cpp_seedvr2.lock.json, beside the archive of the panoramas so that their
//    measured build stays as it is. Its size, sum and files come from the run that builds it: until then the entry is
//    incomplete and Rebuild details is "not in this version yet" (a developer override aside, enhance_files.dart).
//  - Natural: VOSR 2.0 1.4B int8, the ONNX export of moonbox-dev (Apache-2.0) at 46811283 of the checkpoints of CSWRY
//    (Apache-2.0; its VAE under the Apache-2.0 of Wan2.1 and Qwen-Image, DINOv2 Apache-2.0), four files under 2 GiB, run
//    by the ONNX Runtime of the 3D photos (onnxRuntime*Component of ai-components-1).

import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';

/// The prerelease that will host the components of "Enhance (AI)"
const aiComponentsEnhanceReleaseTag = 'ai-components-7';

/// Whether ai-components-7 is published and its entries are in the catalogue of ai_components_manifest.dart. Until
/// then, a level that needs one of these components is "not in this version yet" (enhance_files.dart), the developer
/// override aside: outside the catalogue, the service of the AI components would not keep the .part of an interrupted
/// download (AiComponentsService._cleanTmp) and its settings tile, Move and Remove would not see the files, so nothing
/// of them is downloaded, not even from the official address of a model. Sharpen takes components of ai-components-3
/// and is not held. Set to true in the same change that moves the entries into that catalogue and the tables of
/// publish_ai_components.py, once the release is made.
const aiEnhanceComponentsPublished = false;

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
  size: null,
  sha256: null,
  compression: AiCompression.none,
  licence: 'MIT',
  licenceUrl: 'https://github.com/leejet/stable-diffusion.cpp/blob/0d71f963af9c94941f4a67e8ea145935651dd756/LICENSE',
  features: {},
  releaseTag: aiComponentsEnhanceReleaseTag,
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
  size: null,
  sha256: null,
  compression: AiCompression.none,
  licence: 'MIT',
  licenceUrl: 'https://github.com/leejet/stable-diffusion.cpp/blob/0d71f963af9c94941f4a67e8ea145935651dd756/LICENSE',
  features: {},
  releaseTag: aiComponentsEnhanceReleaseTag,
);

AiComponent _vosr(String part, String name, int size, String sha256) => AiComponent(
  id: 'vosr2-1.4b-int8-${part.replaceAll('_', '-')}',
  name: 'VOSR 2.0 1.4B int8 ($name)',
  version: '46811283',
  kind: AiComponentKind.model,
  platforms: _vosrSystems,
  assetName: 'vosr2-int8-$part.onnx',
  installPath: 'models/vosr2-int8/$part/model.onnx',
  size: size,
  sha256: sha256,
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: _vosrLicence,
  features: const {},
  releaseTag: aiComponentsEnhanceReleaseTag,
  officialUrls: ['$_vosrRevision/int8/$part/model.onnx'],
);

/// The four graphs of VOSR 2.0 1.4B int8: DINOv2-L, the encoder and the decoder of the Qwen-Image VAE, the transformer
final vosrImageEncoderComponent = _vosr(
  'image_encoder',
  'DINOv2-L',
  460494444,
  '991f96af4a0dedf5da19d5a69a8c77f106138cacffdc82fadeef2397dd3c37cd',
);
final vosrVaeEncoderComponent = _vosr(
  'vae_encoder',
  'VAE encoder',
  38701657,
  'c3efac4d5f173692c45002aa90d79f155898697db73cfcef1fb90a56d07ea161',
);
final vosrTransformerComponent = _vosr(
  'transformer',
  'transformer',
  1409190442,
  'e38ab963051515bdc39fb1a096d8eb3ee895355cdc1b658bbd7ce9fa3af8bd62',
);
final vosrVaeDecoderComponent = _vosr(
  'vae_decoder',
  'VAE decoder',
  50689496,
  '3ca755f97a8d57ad5f793c757f0d3a65200067d98528f110d765b4b28ef989ba',
);

/// The graphs of VOSR in the order the pipeline runs them
final vosrComponents = [
  vosrImageEncoderComponent,
  vosrVaeEncoderComponent,
  vosrTransformerComponent,
  vosrVaeDecoderComponent,
];

/// Every new component of "Enhance (AI)", for the publication of ai-components-7
final aiEnhanceComponents = [
  seedVr2DitComponent,
  seedVr2VaeComponent,
  sdCppSeedVr2WindowsComponent,
  sdCppSeedVr2LinuxComponent,
  ...vosrComponents,
];
