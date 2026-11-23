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
