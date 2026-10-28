# Licences of the AI components of Immuch360

Date: 2026-10-28. Written by `.github/desktop/ai/publish_ai_components.py` from the files of the prereleases
`ai-components-1` (3D photos), `ai-components-2` (3D scenes) and `ai-components-3` (360° panoramas):
https://github.com/freeKC/Immuch360/releases

The app downloads a component only when the user asks for it, checks its SHA-256 against the catalogue built
into the app, and copies its licence next to it (`ai-components/licenses/`). When two pages disagree on a
licence, the more restrictive one applies.

<!-- ai-components-1 -->
## ai-components-1: 3D photos

https://github.com/freeKC/Immuch360/releases/tag/ai-components-1. The depth model is Apache-2.0, ONNX Runtime is MIT. ONNX
Runtime has other libraries built in, each under its own licence, listed in its notices (below): mostly BSD,
Apache-2.0, MIT, Boost, zlib or public domain, and Eigen under MPL-2.0, a weak copyleft licence. The notices
cover the whole ONNX Runtime project, not only what these builds hold. The libraries are redistributed as
Microsoft built them, unmodified, with those notices.

### Depth model: Depth Anything V2 Small, Apache-2.0

| File | For | Size (bytes) | SHA-256 | Official source, pinned revision |
| --- | --- | --- | --- | --- |
| `depth_anything_v2_small.onnx` | the computers (Windows, Linux, macOS), fp32 ONNX | 99060839 | `afb6a5c28f3b6bf1618c6e43f02073ef9dfdc70e937502d51603e57b0a1df10c` | https://huggingface.co/onnx-community/depth-anything-v2-small, revision `4472b736` |
| `depth_anything_v2_small.tflite` | the Meta Quest, fp32 LiteRT | 99530468 | `651415f1774e02d06de946eccf2e6dbbc5f499a9e932d9de7ada3d59637d2e8e` | https://huggingface.co/litert-community/depth-anything-v2-small, revision `178427e4` |

The weights: Apache-2.0 for the Small model (https://github.com/DepthAnything/Depth-Anything-V2#license,
https://huggingface.co/depth-anything/Depth-Anything-V2-Small). The ONNX export of onnx-community and the
LiteRT export of litert-community: Apache-2.0
(https://huggingface.co/onnx-community/depth-anything-v2-small,
https://huggingface.co/litert-community/depth-anything-v2-small/blob/main/LICENSE). The files are those of the
official sources, byte for byte. Licence text: https://www.apache.org/licenses/LICENSE-2.0

### ONNX Runtime, MIT

| File | Component | Installed file | Size (bytes) | SHA-256 | Download (bytes) | Official archive | Archive SHA-256 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `onnxruntime-1.31.0-win-x64.dll.gz` | `onnxruntime-1.31.0-win-x64` | `onnxruntime.dll` | 17253176 | `0c42dc4e278f0968fdf9ebf1b1e54a74c657a9942e70803e453c91993451cf4c` | 6308414 | https://github.com/microsoft/onnxruntime/releases/download/v1.31.0/onnxruntime-win-x64-1.31.0.zip | `3958d8a44984160692c1b4ffd0de3cb48f8c39f9d34bb31e433db06e30b82195` |
| `onnxruntime-1.31.0-linux-x64.so.gz` | `onnxruntime-1.31.0-linux-x64` | `libonnxruntime.so.1.31.0` | 29345384 | `469849977cb60744ea160927e1a3a0643fd4c55c0aff743251c6d293402e334e` | 11112796 | https://github.com/microsoft/onnxruntime/releases/download/v1.31.0/onnxruntime-linux-x64-1.31.0.tgz | `cc5c72baf5ae5c8238a6841f0897227be2d02826b9cf98eaf02fdefaeeb03a57` |
| `onnxruntime-1.31.0-osx-arm64.dylib.gz` | `onnxruntime-1.31.0-osx-arm64` | `libonnxruntime.1.31.0.dylib` | 44830288 | `2a50a63e7f41f8d4d551d3ee47248df3864f6540109fce8ad520ca3b51af4b70` | 12524281 | https://github.com/microsoft/onnxruntime/releases/download/v1.31.0/onnxruntime-osx-arm64-1.31.0.tgz | `1031b36dd3bdaa8d976a6130d9cf2a05e9be320b93ae804f8427b91dc3432afc` |
| `onnxruntime-1.23.2-osx-x86_64.dylib.gz` | `onnxruntime-1.23.2-osx-x86_64` | `libonnxruntime.1.23.2.dylib` | 39742608 | `8c9c78de65ea3786f987c0d980e9c1b13a3a5fbc6b3e2965ba05b450e6e4c054` | 11437397 | https://github.com/microsoft/onnxruntime/releases/download/v1.23.2/onnxruntime-osx-x86_64-1.23.2.tgz | `d10359e16347b57d9959f7e80a225a5b4a66ed7d7e007274a15cae86836485a6` |

Each library is the one of the official archive of ONNX Runtime, as it is (the Authenticode signature of
`onnxruntime.dll` kept), gzip compressed for the download; the app unpacks it and checks the SHA-256 of the
installed file. Licence: MIT (https://github.com/microsoft/onnxruntime/blob/v1.31.0/LICENSE, the same text in
1.23.2). The licence and the notices of the libraries built into ONNX Runtime, as each version gives them: the
app holds the text of the licence, and downloads the notices with the library.

| File | Size (bytes) | SHA-256 |
| --- | --- | --- |
| `onnxruntime-1.23.2-LICENSE.txt` | 1073 | `2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c` |
| `onnxruntime-1.23.2-ThirdPartyNotices.txt` | 326866 | `e9e90971a8e75a9a8ac0c6412e29c1202d079998389915aa485f46c816c3b4cc` |
| `onnxruntime-1.31.0-LICENSE.txt` | 1073 | `2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c` |
| `onnxruntime-1.31.0-ThirdPartyNotices.txt` | 338088 | `143764b952fdb1a7c69ce653bfba74a7744d6a8a573bfb73e235fba356c83de3` |

### Telemetry of ONNX Runtime, turned off

The official builds of ONNX Runtime 1.31.0 send telemetry to Microsoft by default
(https://github.com/microsoft/onnxruntime/blob/v1.31.0/docs/Privacy.md). The libraries for Linux and
macOS carry the 1DS SDK: at their first session they write a device id and queue events for
https://mobile.events.data.microsoft.com/OneCollector/1.0/. The Windows DLL reports through ETW
(provider `Microsoft.ML.ONNXRuntime`). Immuch360 turns both off: it sets `ORT_DISABLE_TELEMETRY=1` in its
process before it opens the library, so that 1DS never starts, and calls `DisableTelemetryEvents` on each
environment it makes, which stops the ETW events. On Windows, ONNX Runtime may write one start event to
ETW before that call; ETW events leave the computer only through the diagnostic data of Windows, under its
own setting. 1.23.2 for the Intel Macs has no telemetry.

### LiteRT 2.3.0, Apache-2.0 (in the quest APK, not downloaded)

`com.google.ai.edge.litert:litert`, `litert-api` and `litert-gpu` 2.3.0 run the depth model on the Meta
Quest. They are built into the APK of the quest flavour only; the phone APKs and the computers do not have
them. Licence: Apache-2.0, https://github.com/google-ai-edge/LiteRT/blob/main/LICENSE. The notices of the
libraries LiteRT is built from (`THIRD_PARTY_NOTICE.txt` of its packages, 1960672 bytes, SHA-256
`db6e1ff4b16c11eb01c45f135928527a50a05282739054686793ec70f442f119`) ship in the quest APK and are shown on
its licence page. Its native libraries carry XNNPACK, pthreadpool and cpuinfo (BSD), and FP16 and FXdiv
(MIT); the notices also list Eigen 3 under MPL-2.0, a weak copyleft licence, which its CPU code may hold.
The notices cover the whole LiteRT build, not only what these libraries hold. Left out of the APK:
`com.google.android.play:ai-delivery` 0.1.1-alpha01 (Play Core Software Development Kit Terms of Service),
which `litert-api` brings for Play for On-device AI and which the app never calls. Brought in by
`litert-api`, quest flavour only, all Apache-2.0: `androidx.lifecycle:lifecycle-runtime` 2.10.0,
`com.google.guava:guava` 33.5.0-android and `org.jetbrains.kotlinx:kotlinx-coroutines-guava` 1.8.0.

<!-- ai-components-2 -->
## ai-components-2: 3D scenes

https://github.com/freeKC/Immuch360/releases/tag/ai-components-2

| File | Component | Size (bytes) | SHA-256 | Licence | Source, pinned revision |
| --- | --- | --- | --- | --- | --- |
| `moge_2_vits_normal_immuch360.onnx` | `moge-2-vits-normal-onnx-immuch360` | 140852051 | `24eacb5dc7a2c54c7bc98f7de085ffbed79ad006ea5b664c2c2cdc02ff3a52f0` | MIT | our export of https://huggingface.co/Ruicheng/moge-2-vits-normal, revision `26b477f4`, `model.pt` |
| `lama_fp32.onnx` | `lama-onnx` | 208044816 | `1faef5301d78db7dda502fe59966957ec4b79dd64e16f03ed96913c7a4eb68d6` | Apache-2.0 | https://huggingface.co/Carve/LaMa-ONNX, revision `c3c0c9e4`, `lama_fp32.onnx` |

Our export of MoGe-2 ViT-S: the MIT weights of https://huggingface.co/Ruicheng/moge-2-vits-normal at revision
`26b477f41595707c5db6770294c0d1721e8ed4ed` (`model.pt`, 140550416 bytes, SHA-256
`79a16621928c2bf0ed04659218c55c01075e950507f40bb3332fb4c873d3e1dc`) through the export method of
https://github.com/microsoft/MoGe at `74fbce054ebed49800de42d0ad0e83495065719a` (`docs/onnx.md`), opset 14, by
`.github/desktop/ai/export_moge_onnx.py` with PyTorch 2.7.0 for the processor. The result is byte for byte
`model.onnx` of https://huggingface.co/Ruicheng/moge-2-vits-normal-onnx at revision
`e50ffda41565591092adea54c6ac83d6212e1e23`, a repository without a card nor a licence, which is therefore
not used as a source. MoGe: MIT, Copyright (c) Microsoft Corporation; its DINOv2 backbone: Apache-2.0
(https://github.com/facebookresearch/dinov2/blob/main/LICENSE).

LaMa: Apache-2.0 (https://github.com/advimman/lama), trained by its authors on Places2, a research dataset;
the ONNX export of Carve (`lama_fp32.onnx`, Apache-2.0 on its card), not `lama.onnx` of the same revision,
which ONNX Runtime 1.31.0 refuses to load.

<!-- ai-components-3 -->
## ai-components-3: 360° panoramas

https://github.com/freeKC/Immuch360/releases/tag/ai-components-3

| File | Component | Size (bytes) | SHA-256 | Licence | Source, pinned revision |
| --- | --- | --- | --- | --- | --- |
| `migan_pipeline_v2.onnx` | `migan-512-places2-onnx` | 28079181 | `6f1f3530a1a2324b19752018ce756088b07973cda8d7d890034ace5c8a48c40b` | MIT | https://huggingface.co/andraniksargsyan/migan, revision `406830d0`, `migan_pipeline_v2.onnx` |
| `flux-2-klein-base-4b-Q4_0.gguf` | `flux2-klein-base-4b-q4_0` | 2460378560 | `c3a2854510677b7aa37dd7547d908c54889a76c6d6aa3ffe902fcaa092d1328b` | Apache-2.0 | https://huggingface.co/leejet/FLUX.2-klein-base-4B-GGUF, revision `d1267112`, `flux-2-klein-base-4b-Q4_0.gguf` |
| `Qwen3-4B-Q4_K_M.gguf` | `qwen3-4b-q4_k_m` | 2497281312 | `f6f851777709861056efcdad3af01da38b31223a3ba26e61a4f8bf3a2195813a` | Apache-2.0 | https://huggingface.co/unsloth/Qwen3-4B-GGUF, revision `22c9fc8a`, `Qwen3-4B-Q4_K_M.gguf` |
| `flux2-klein-base-4b-vae.safetensors` | `flux2-vae` | 168120878 | `ca70d2202afe6415bdbcb8793ba8cd99fd159cfe6192381504d6c4d3036e0f04` | Apache-2.0 | https://huggingface.co/black-forest-labs/FLUX.2-klein-base-4B, revision `a3b4f484`, `vae/diffusion_pytorch_model.safetensors` |
| `flux-2-klein-4B-360-erp-outpaint-lora_V1.safetensors` | `flux2-klein-4b-360-erp-lora-v1` | 46224184 | `567cc22de03800d2c9d4309e0cf6f971cc00da6b39fb26b0311031f2563de166` | Apache-2.0 | https://huggingface.co/nomadoor/flux-2-klein-4B-360-erp-outpaint-lora, revision `124129f3`, `flux-2-klein-4B-360-erp-outpaint-lora_V1.safetensors` |
| `RealESRGAN_x4plus.pth` | `realesrgan-x4plus` | 67040989 | `4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1` | BSD-3-Clause | https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.1.0, revision `v0.1.0`, `RealESRGAN_x4plus.pth` |

The files of 2 GiB or more are in parts (GitHub refuses a larger asset), put end to end by the app, which
checks the sum of each part and of the whole:

| Part | Of | Size (bytes) | SHA-256 |
| --- | --- | --- | --- |
| `flux-2-klein-base-4b-Q4_0.gguf.001` | 1 of 2 of `flux-2-klein-base-4b-Q4_0.gguf` | 2039480320 | `c1b9bb49b725bd8b6f958cfcf48d27026d9dd53bc54a83b0604e91630c2003cc` |
| `flux-2-klein-base-4b-Q4_0.gguf.002` | 2 of 2 of `flux-2-klein-base-4b-Q4_0.gguf` | 420898240 | `b84cb446ad7f881c4c2eccdd20829a51c6419e2939b33804ba40d0c41f913bb1` |
| `Qwen3-4B-Q4_K_M.gguf.001` | 1 of 2 of `Qwen3-4B-Q4_K_M.gguf` | 2039480320 | `ab33d061bb101f87505c5e13bec02b39da4d310f1bcde1a5a916691230183ad3` |
| `Qwen3-4B-Q4_K_M.gguf.002` | 2 of 2 of `Qwen3-4B-Q4_K_M.gguf` | 457800992 | `ed05d20e6c453c59371bac0e35f3f6dc3fbc551088e6628a8e79f94db3512a51` |

`sd-cpp-vulkan-win-x64`: pending, written by lot P2 from the signed artifacts of our CI.

`sd-cpp-vulkan-linux-x64`: pending, written by lot P2 from the signed artifacts of our CI.

FLUX.2 klein base 4B: Apache-2.0 (https://huggingface.co/black-forest-labs/FLUX.2-klein-base-4B), as GGUF by
leejet (Apache-2.0); the Q4_0 file, the one that holds in a graphics card of 8 GB (measure M3). Its VAE: the
`vae/` folder of the same model. Qwen3 4B: Apache-2.0 (https://huggingface.co/Qwen/Qwen3-4B), as GGUF by
unsloth (Apache-2.0). The 360 ERP Outpaint LoRA of nomadoor: Apache-2.0 on its card, trained on images
under CC0 and in the public domain, with a part under CC BY (its card and `TRAINING_NOTES.md`); the
attribution of that part comes with a later version of this file. MI-GAN: MIT, code and weights, Copyright (c)
2024 Picsart AI Research (PAIR), trained on Places2, a research dataset. Real-ESRGAN x4plus: BSD-3-Clause,
Copyright (c) 2021, Xintao Wang. stable-diffusion.cpp and ggml: MIT
(https://github.com/leejet/stable-diffusion.cpp/blob/master/LICENSE,
https://github.com/ggml-org/ggml/blob/master/LICENSE), built and signed by our CI at the commits of
`.github/desktop/ai/sd_cpp.lock.json`, run by the app as a child process. No CUDA: the graphics card is
reached through Vulkan only.

<!-- end of the releases -->
## Not used

These were looked at and left out, because of their licence:

* Depth Anything V2 Base, Large and Giant: CC-BY-NC-4.0, https://github.com/DepthAnything/Depth-Anything-V2#license
* DirectML.dll: Microsoft proprietary licence, https://www.nuget.org/packages/Microsoft.AI.DirectML/1.15.4/License
* dxil.dll of the DirectX Shader Compiler: LICENSE-MS.txt, Microsoft software licence terms, https://github.com/microsoft/DirectXShaderCompiler/releases/tag/v1.9.2609
* Qualcomm QNN: Qualcomm licence, https://softwarecenter.qualcomm.com/api/download/software/licenses/ai_model_hub/v1/LICENSE.pdf
* SHARP of Apple, the weights: apple-amlr, research only, https://github.com/apple/ml-sharp/blob/main/LICENSE_MODEL
* FlashWorld, the weights: CC-BY-NC-SA-4.0, https://huggingface.co/imlixinyang/FlashWorld
* Lyra 1 and 2 of NVIDIA: NVIDIA Open Model License, internal research licence, https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license
* HY World 2.0, WorldMirror, HunyuanWorld: does not apply in the European Union, https://github.com/Tencent-Hunyuan/HY-World-2.0/blob/main/License.txt
* VGGT, Depth Anything 3 Giant and Nested: CC-BY-NC, https://github.com/facebookresearch/vggt/blob/main/LICENSE.txt
* EdgeConnect, MAT, 3D Ken Burns: CC-BY-NC (SA), https://github.com/knazeri/edge-connect/blob/master/LICENSE.md
* FLUX.1 dev, Fill, Kontext and Krea; FLUX.2 klein 9B and its 360 LoRA; FLUX.2 dev: non commercial licences of Black Forest Labs, https://huggingface.co/black-forest-labs/FLUX.1-Fill-dev
* FLUX.3 Image Klein: FLUX Kommunity License: a revenue cap and imposed filters, https://bfl.ai/blog/flux-3-image-klein
* Stable Diffusion 3.5; SDXL and its 360 LoRA: Stability community licence; OpenRAIL++, https://huggingface.co/stabilityai/stable-diffusion-3.5-medium
* Qwen Image 2.1: qwen-research, https://huggingface.co/Qwen/Qwen-Image-2.1
* HiDream, Lumina Image 2.0, Sana: their Llama 3.1 or Gemma 2 encoders, https://huggingface.co/meta-llama/Llama-3.1-8B-Instruct
* CUDA, cuDNN and the nvidia-* wheels: NVIDIA EULA, https://docs.nvidia.com/cuda/eula/index.html
* ComfyUI: GPL-3.0: never shipped, only called when the user installed it, https://github.com/Comfy-Org/ComfyUI
* The splat module of the Meta Spatial SDK: Meta Platform Technologies SDK License, waiting for a decision
