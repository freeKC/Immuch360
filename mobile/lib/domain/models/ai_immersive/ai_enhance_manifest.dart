// The components of "Enhance (AI)" (lots E1 to E3 of release 51, store/m2/ai-enhance-2026-11-22), in the prerelease
// ai-components-7 of freeKC/Immuch360; their entries are in the catalogue of ai_components_manifest.dart, made and
// checked by publish_ai_components.py like the other families. Their files are the ones the probe of 23 November 2026
// downloaded and measured (probe-e0.md, section 1), equal to the ones Hugging Face publishes at the pinned revisions.
//
//  - Sharpen needs nothing new: the sd-cli of the 360° panoramas and Real-ESRGAN x4plus (sdCppWindowsComponent,
//    sdCppLinuxComponent, upscalerComponent of ai-components-3).
//  - Rebuild details: SeedVR2 3B int8 convrot and its VAE (Comfy-Org/SeedVR2 at df488797, Apache-2.0; ByteDance-Seed
//    SeedVR2-3B, Apache-2.0, trained from scratch, no inherited base model), the DiT in two parts of 1945 MiB and the
//    rest (GitHub refuses an asset of 2 GiB or more), its official file at the pinned revision tried after the release;
//    and a second archive of stable-diffusion.cpp at 0d71f963 (MIT), built by the jobs sdcpp-seedvr2-windows and
//    sdcpp-seedvr2-linux of our CI from sd_cpp_seedvr2.lock.json and signed for Windows by the release workflow
//    (with_sdcpp_seedvr2), beside the archive of the panoramas so that their measured build stays as it is.
//  - Natural: VOSR 2.0 1.4B int8, the ONNX export of moonbox-dev (Apache-2.0) at 46811283 of the checkpoints of CSWRY
//    (Apache-2.0; its VAE under the Apache-2.0 of Wan2.1 and Qwen-Image, DINOv2 Apache-2.0), four files under 2 GiB, run
//    by the ONNX Runtime of the 3D photos (onnxRuntime*Component of ai-components-1).

import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';

export 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart'
    show
        aiComponentsEnhanceReleaseTag,
        sdCppSeedVr2LinuxComponent,
        sdCppSeedVr2WindowsComponent,
        seedVr2DitComponent,
        seedVr2VaeComponent,
        vosrImageEncoderComponent,
        vosrTransformerComponent,
        vosrVaeDecoderComponent,
        vosrVaeEncoderComponent;

/// Whether ai-components-7 is published and its entries are in the catalogue of ai_components_manifest.dart: true
/// since release 51 (published on 24 November 2026). Set back to false, a level that needs one of these components is
/// "not in this version yet" (enhance_files.dart), the developer override aside; Sharpen takes components of
/// ai-components-3 and is never held by it.
const aiEnhanceComponentsPublished = true;

/// Whether the Metal archive of stable-diffusion.cpp for Apple silicon ([sdCppSeedVr2MacArmComponent], release 53) is
/// published in ai-components-7: true since 26 November 2026 (the artifact of run 45677228907, uploaded as
/// sd-cpp-seedvr2-metal-macos-arm64.zip). Set back to false, Sharpen and Rebuild details on a Mac are "not in this
/// version yet" (enhance_files.dart); Natural on a Mac does not need it.
const aiEnhanceMacEnginePublished = true;

/// Whether Rebuild details is offered on a Mac with an Apple chip once its engine is published: false until one run on
/// a real Apple chip has succeeded (review of 25 November 2026). The only Metal GPU it ran on, the paravirtual one of
/// GitHub's macOS runner, failed in its VAE stage ("buffer is nil", then a crash of sd-cli), and a real Mac takes
/// another path (the DiT on the GPU), which no run went through. Publishing the archive offers Sharpen only; Rebuild
/// details then says it is not on a Mac in this version (enhance_plan.dart) and downloads nothing (enhance_files.dart).
const aiEnhanceMacRebuildOffered = false;

/// stable-diffusion.cpp at 0d71f963 on Metal for Apple silicon, the engine of Sharpen and Rebuild details on a Mac
/// (release 53, store/m2/release-53/enhance-mac-2026-11-25.md): built by the job sdcpp-seedvr2-macos of our CI from
/// sd_cpp_seedvr2.lock.json (the macos-arm64 options: SD_METAL, the Metal shaders embedded, everything static), one
/// program signed ad hoc (no Developer ID yet), with the licences and BUILD-INFO.txt. In the list aiComponents of
/// ai_components_manifest.dart already, held without its size and sum (load() of the service skips such an entry, the
/// cleanup of unused files keeps its folder), but defined here, outside what publish_ai_components.py reads, until that
/// script handles a macOS engine; its size, sum and files are those of the artifact of the CI run the report names. Sharpen takes it too on a Mac, with Real-ESRGAN x4plus of
/// ai-components-3: the sd-cli of the panoramas has no Mac build. Its programs start through immuch360-run of the app
/// (Contents/MacOS), as every program of the AI features on macOS.
const sdCppSeedVr2MacArmComponent = AiComponent(
  id: 'sd-cpp-seedvr2-metal-macos-arm64',
  name: 'stable-diffusion.cpp for SeedVR2 (Metal)',
  version: '0d71f96-1',
  kind: AiComponentKind.archive,
  platforms: {AiPlatform.macosArm64},
  assetName: 'sd-cpp-seedvr2-metal-macos-arm64.zip',
  installPath: 'engines/sd-cpp-seedvr2-metal-macos-arm64',
  size: 18223800,
  sha256: 'c86fbae15d35b91bc56ccf905bc8849065e7433c53cb61980eb3b9809a1e93a0',
  compression: AiCompression.none,
  licence: 'MIT',
  licenceUrl: 'https://github.com/leejet/stable-diffusion.cpp/blob/0d71f963af9c94941f4a67e8ea145935651dd756/LICENSE',
  features: {},
  releaseTag: aiComponentsEnhanceReleaseTag,
  archiveFiles: [
    AiArchiveFile(
      path: 'BUILD-INFO.txt',
      size: 873,
      sha256: 'bc557f74654e27e38bc683010b1ffe40c30055f42caf948de7da9b21e1fe9a14',
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
      size: 50863280,
      sha256: '9a69aafa79e1eef4a635b90d46e2b970c8ac5b129f9f313e1ecc134d2fb01248',
      executable: true,
    ),
  ],
);

/// The graphs of VOSR in the order the pipeline runs them
const vosrComponents = <AiComponent>[
  vosrImageEncoderComponent,
  vosrVaeEncoderComponent,
  vosrTransformerComponent,
  vosrVaeDecoderComponent,
];

/// Every new component of "Enhance (AI)", for the publication of ai-components-7
const aiEnhanceComponents = <AiComponent>[
  seedVr2DitComponent,
  seedVr2VaeComponent,
  sdCppSeedVr2WindowsComponent,
  sdCppSeedVr2LinuxComponent,
  ...vosrComponents,
];

/// The components of "Enhance (AI)" for Apple silicon, outside the publication of ai-components-7 by its script yet
/// (release 53)
const aiEnhanceMacComponents = <AiComponent>[sdCppSeedVr2MacArmComponent];
