# Licences of the AI components of Immuch360

Date: 2026-11-04. Written by `.github/desktop/ai/publish_ai_components.py` from the files of the prereleases
`ai-components-1` (3D photos), `ai-components-2` (3D scenes), `ai-components-3` (360° panoramas) and `ai-components-4`
(splat scenes):
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
| `sd-cpp-vulkan-win-x64.zip` | `sd-cpp-vulkan-win-x64` | 30853245 | `6aacb8a7831c8b43bc66f177f3961169df345ed55d80ff4519db4f73aed35d57` | MIT | built and signed by our CI |
| `sd-cpp-vulkan-linux-x64.zip` | `sd-cpp-vulkan-linux-x64` | 35817545 | `5e7052dc93eec36ad156974e7f56bd7fa13df3482b412935848319680cb5d535` | MIT | built and signed by our CI |

The files of 2 GiB or more are in parts (GitHub refuses a larger asset), put end to end by the app, which
checks the sum of each part and of the whole:

| Part | Of | Size (bytes) | SHA-256 |
| --- | --- | --- | --- |
| `flux-2-klein-base-4b-Q4_0.gguf.001` | 1 of 2 of `flux-2-klein-base-4b-Q4_0.gguf` | 2039480320 | `c1b9bb49b725bd8b6f958cfcf48d27026d9dd53bc54a83b0604e91630c2003cc` |
| `flux-2-klein-base-4b-Q4_0.gguf.002` | 2 of 2 of `flux-2-klein-base-4b-Q4_0.gguf` | 420898240 | `b84cb446ad7f881c4c2eccdd20829a51c6419e2939b33804ba40d0c41f913bb1` |
| `Qwen3-4B-Q4_K_M.gguf.001` | 1 of 2 of `Qwen3-4B-Q4_K_M.gguf` | 2039480320 | `ab33d061bb101f87505c5e13bec02b39da4d310f1bcde1a5a916691230183ad3` |
| `Qwen3-4B-Q4_K_M.gguf.002` | 2 of 2 of `Qwen3-4B-Q4_K_M.gguf` | 457800992 | `ed05d20e6c453c59371bac0e35f3f6dc3fbc551088e6628a8e79f94db3512a51` |

`sd-cpp-vulkan-win-x64.zip` holds, unpacked into `engines/sd-cpp-vulkan-win-x64`:

| File | Size (bytes) | SHA-256 | Program |
| --- | --- | --- | --- |
| `BUILD-INFO.txt` | 866 | `b0ecfcf53275bed6db8468f9bb5b38a678bb1e7052377149abbaf029ddf93664` | no |
| `ggml-base.dll` | 697160 | `0e93bda5087456fbcfef7fada22e1a6ffd44463ebe1c002d4e9968ffdc2ba30a` | no |
| `ggml-cpu-alderlake.dll` | 1016648 | `24d18be3806be9f11172b5fa91f790c686baf65c3d00a84a35d269b35fc5fbeb` | no |
| `ggml-cpu-cannonlake.dll` | 1062216 | `e2a640523f66bc1b14782027ce1c356e2037cfec8ec2fb78c43095452effda85` | no |
| `ggml-cpu-cascadelake.dll` | 1060680 | `2a6463b9acf1a87a516e638fdc59ea2dbf76054b7f92ad6d541a6c71d2e50815` | no |
| `ggml-cpu-haswell.dll` | 1017672 | `48c7c4483b46e1c5041fc54e4aa4c12892d3f072dd60be9b8a138c45919fc061` | no |
| `ggml-cpu-icelake.dll` | 1060680 | `fff19b695e5c0d2b599bcd22be03f81e057faeff691046aa66b826fb4a4c45c1` | no |
| `ggml-cpu-sandybridge.dll` | 1046344 | `f5d8821452620b645d761528f61ee2661a62413175122bae87d1091acd073ed6` | no |
| `ggml-cpu-skylakex.dll` | 1062216 | `aeeb1df73493ba54ed5225c2c99b940f590daba35339df5b600b5307cd51a003` | no |
| `ggml-cpu-sse42.dll` | 883016 | `2abb813018268da1853849812867c5abf8b3008cd53c6663885b3ff15dbc8094` | no |
| `ggml-cpu-x64.dll` | 885064 | `89d0aabc54fddf30040656654238ac78844950a1f90c978ec9b2fc27767db8e9` | no |
| `ggml-vulkan.dll` | 40152904 | `781624a958dacf56c4c354c86aaacd7cbfc56ac04ed2d4e86b3cd33cac5f4ce9` | no |
| `ggml.dll` | 76104 | `9549c8c214d97e3fb0ab95606e7be3d52ed730e06b42e7e447948a141953948f` | no |
| `licenses/README.md` | 1185 | `26f980b88d5210da2e6024efbd56d3d2ca77de7010bc73989b660187ce53528a` | no |
| `licenses/THIRD-PARTY.md` | 6968 | `0d58c599729e84498452fce4fbafa819cc6529683d0711c60b3a965132444b70` | no |
| `licenses/darts-clone-LICENSE.txt` | 1491 | `ed8437dc7358a40ef10afd3635ac1cd43c88fbaaaf6cd27c414f8ada5d68f447` | no |
| `licenses/ggml-LICENSE.txt` | 1099 | `bcd8ec749126d45cb06737d0690295d73df4b6e7e194205bcf91190368f27285` | no |
| `licenses/oniguruma-COPYING.txt` | 1366 | `0dff717fb611b9c9bd9776a5df9c4e029030f8dbc023b77f3678cf495495b933` | no |
| `licenses/stable-diffusion.cpp-LICENSE.txt` | 1082 | `4e76049398df734a97db46f3bd4b5cbc460cb5f6bfaf737cdc3d6fbb8ab3de27` | no |
| `licenses/utf8proc-LICENSE.md` | 5218 | `767edbcafb23016d7f203aaf2cbdef5690ad58bcede52ee241427dcb816cd644` | no |
| `msvcp140.dll` | 557728 | `0f885b509a685d2bbfa652fed26b5fb31d88fbdab0a978c641d1c7b8aa460aa9` | no |
| `msvcp140_codecvt_ids.dll` | 31872 | `f2069a52880ec885ee7f0511186100eb7fada0411a2b4948fafea7735b878a18` | no |
| `sd-cli.exe` | 801096 | `d33481cef0001920f878ede5101dfeef4fa05df50bd6201048cb45a51b88ba1d` | yes |
| `stable-diffusion.dll` | 36008776 | `ad6b904bdbda24a347db9c84a70249980d500b2831e6615c0430b8b9939d85ff` | no |
| `vcruntime140.dll` | 124544 | `d5e4d9a3e835fa679450145d6a7d94e36573a509317111904d9b3712c30d9066` | no |
| `vcruntime140_1.dll` | 49792 | `1f2d41c4aa5db0bc33ebf7b66d72943a817d7ce6cbe880502a9403823633093f` | no |

`sd-cpp-vulkan-linux-x64.zip` holds, unpacked into `engines/sd-cpp-vulkan-linux-x64`:

| File | Size (bytes) | SHA-256 | Program |
| --- | --- | --- | --- |
| `BUILD-INFO.txt` | 816 | `1549479c0023cb2ea02dfbcbcc9e1773e682f2308fdf70b5261069d2f809545d` | no |
| `immuch360-run` | 16552 | `779dfe821cc14fbbd8e6f7420ccba3f08509a5802f89d18a5f5a606b2dd79a7b` | yes |
| `libggml-base.so.0` | 905856 | `724d0388655f31af515a16a06e89852529286936bc3905fb0fc000391f06af09` | no |
| `libggml-cpu-alderlake.so` | 1306432 | `db8a29641675ad642fc7056932568f20bc3216224eaf9b803b5ae15df9725f25` | no |
| `libggml-cpu-cannonlake.so` | 1384360 | `66d26b13e9c989dc898be445a894916a9923eab34b328871a73163c98d056e57` | no |
| `libggml-cpu-cascadelake.so` | 1400448 | `204de1f7d965852dc2122fb4a0b00240af20f234efe55416cd989e0330b5a3d8` | no |
| `libggml-cpu-cooperlake.so` | 1400448 | `68d763f49d062b0b74bde1afaae488bafae2f52da04874b0eba730b61ae0de0a` | no |
| `libggml-cpu-haswell.so` | 1306432 | `9d597a3d4fe9cc4257fce0bfd634850f037ed9f54647c0403ed1c0088c347666` | no |
| `libggml-cpu-icelake.so` | 1400448 | `7e1da9f4a14883fd0ae7771d31f228efc9d6ae92cd9c5341a09e74edd40bc4cf` | no |
| `libggml-cpu-ivybridge.so` | 1235152 | `757283c265130c252eb1a2b411eca6139579417151e0f764f6163bbdb7049867` | no |
| `libggml-cpu-piledriver.so` | 1231056 | `f459112286127171de81c29978aa7e1ac150fa73bf8d0964c871ff10bcd83858` | no |
| `libggml-cpu-sandybridge.so` | 1255752 | `6873b28211bdaa720a7d79c7605fa10a933db7ab6de07df59501695b0037eafd` | no |
| `libggml-cpu-sapphirerapids.so` | 1696688 | `d696cdc358c7cc3135e7ea8b2ef721a9d292ca31482791817e84a1b2ed792ce6` | no |
| `libggml-cpu-skylakex.so` | 1384360 | `2aa0285fca0986a124071e5c2f0e9d722615a113e698d913730cb7c29b5b1979` | no |
| `libggml-cpu-sse42.so` | 984640 | `c2adef8dff8e2ee42a2029de496161601b7bd6c536ba8c8df2f6efb84689f6d4` | no |
| `libggml-cpu-x64.so` | 980680 | `4138dcbf8b45b21880c92fd7248c14eb0f8deb1f796a6f0c1bf595ac7e91a8b2` | no |
| `libggml-cpu-zen4.so` | 1400448 | `712d67cbda8490241de13934a1c6a6c1f0a2c359ff41eab9706d60a9211998ce` | no |
| `libggml-vulkan.so` | 40829024 | `655e8a3ac90e029a12d8a29fe73b4be2ad55d389e161ac87c12a4e95b5ecdef7` | no |
| `libggml.so.0` | 51040 | `f7edd32a571306f777f380ca868af8728a89d21a3abcc8b97a7e4f738ab40c0a` | no |
| `libstable-diffusion.so` | 41639088 | `a0d2134f6f82bd97f7c56376cad7aea0d3b6fdc950f8a31b3a8e55698492500d` | no |
| `licenses/README.md` | 1169 | `dfc8ee008f776c77648f9c6692fce332ad190a2479653c6399bc2873b5d7e8be` | no |
| `licenses/THIRD-PARTY.md` | 6862 | `de31b8552d1bdb1765a3b75781df6763f576d8762fc9a58d652a4d4733bcf70b` | no |
| `licenses/darts-clone-LICENSE.txt` | 1481 | `155f59997298ee336602c49f9c1110f268ac394ca2197eb02647a3555935ad52` | no |
| `licenses/ggml-LICENSE.txt` | 1078 | `94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d` | no |
| `licenses/oniguruma-COPYING.txt` | 1366 | `0dff717fb611b9c9bd9776a5df9c4e029030f8dbc023b77f3678cf495495b933` | no |
| `licenses/stable-diffusion.cpp-LICENSE.txt` | 1062 | `b53fa08f515cb5a6fff7b9fd8fcd0961a4b80df29d74372d25e1f9171aa042ee` | no |
| `licenses/utf8proc-LICENSE.md` | 5218 | `767edbcafb23016d7f203aaf2cbdef5690ad58bcede52ee241427dcb816cd644` | no |
| `sd-cli` | 1368216 | `6d8f92b3cb97c27cfc6b2a8e97a76b09bcedf3a68f2358df0b72e288105d715e` | yes |

FLUX.2 klein base 4B: Apache-2.0 (https://huggingface.co/black-forest-labs/FLUX.2-klein-base-4B), as GGUF by
leejet (Apache-2.0); the Q4_0 file, the one that holds in a graphics card of 8 GB (measure M3). Its VAE: the
`vae/` folder of the same model. Qwen3 4B: Apache-2.0 (https://huggingface.co/Qwen/Qwen3-4B), as GGUF by
unsloth (Apache-2.0). The 360 ERP Outpaint LoRA of nomadoor: Apache-2.0 on its card, trained on images
under CC0 and in the public domain, with a part under CC BY (its card and `TRAINING_NOTES.md`); the
attribution of that part comes with a later version of this file. MI-GAN: MIT, code and weights, Copyright (c)
2024 Picsart AI Research (PAIR), trained on Places2, a research dataset. Real-ESRGAN x4plus: BSD-3-Clause,
Copyright (c) 2021, Xintao Wang. stable-diffusion.cpp and ggml: MIT
(https://github.com/leejet/stable-diffusion.cpp/blob/be486498eadc29dc3cd234d944c2180ed42b1415/LICENSE,
https://github.com/leejet/ggml/blob/a5915eb0e47adef21c3f25b889a008925ea838c2/LICENSE), built by our CI at the
commits of `.github/desktop/ai/sd_cpp.lock.json` and signed for Windows, run by the app as a child process;
their licences and those of the code built into them (Oniguruma, utf8proc, Darts-clone, JSON for Modern C++,
miniz, stb, llamafile sgemm) are in the `licenses/` folder of each archive, from `licenses/sdcpp/` of the
repository. No CUDA: the graphics card is reached through Vulkan only.

<!-- ai-components-4 -->
## ai-components-4: splat scenes

https://github.com/freeKC/Immuch360/releases/tag/ai-components-4

| File | Component | Size (bytes) | SHA-256 | Licence | Source, pinned revision |
| --- | --- | --- | --- | --- | --- |
| `colmap-cpu-win-x64.zip` | `colmap-cpu-win-x64` | 10090414 | `775fae804f4f4ae4cf3b26045e770a07527f0ff0dc046f5a093fa25ce7fb4e2e` | BSD-3-Clause | built by our CI, not signed |
| `colmap-cpu-linux-x64.zip` | `colmap-cpu-linux-x64` | 25856353 | `e0bcd6f675a6e295f980ced54e3609e061179e09e327809bf24be97fda5f64af` | BSD-3-Clause | built by our CI |
| `brush-vulkan-win-x64.zip` | `brush-vulkan-win-x64` | 16354351 | `875e9308a3ea827cccb412dadf1bb1606ee15abb2d3b41029f522ccff7367202` | Apache-2.0 | built by our CI, not signed |
| `brush-vulkan-linux-x64.zip` | `brush-vulkan-linux-x64` | 17627435 | `1eadf8ff70cc51ea4e7dee211c8b3766ec86927fca9614e76cd6f8e5255e6a72` | Apache-2.0 | built by our CI |

`colmap-cpu-win-x64.zip` holds, unpacked into `engines/colmap-cpu-win-x64`:

| File | Size (bytes) | SHA-256 | Program |
| --- | --- | --- | --- |
| `BUILD-INFO.txt` | 1337 | `6ea120aec1e9b35ed36140aad00b12b5a71f1f0c173bac9aa685b578f4185948` | no |
| `SHA256SUMS.txt` | 11850 | `6f82b744e5069f3181cb0ce50bcc74f733d2c6793d20d89a56263abfdf1625f8` | no |
| `colmap.exe` | 26231296 | `7b475114081e25d316e7d6d0cfa7f9d2c20ec7d7a9fb7f63203ab50720bfb7eb` | yes |
| `licenses/COPYING.txt` | 1942 | `beda69d6c1e7544a470002af34c5d754497f0ad7da168556a9b20852993404c3` | no |
| `licenses/PoissonRecon-LICENSE.txt` | 1096 | `bbcbdc44ed818f009eb4433db9ab5e6509578d0ba43ddcb662b8a0cc9c160fb3` | no |
| `licenses/PoseLib-LICENSE.txt` | 1551 | `f2974dfc7803858e4c3d35c4d5f26291cf072b6607a561caa2fae4758bfc13d2` | no |
| `licenses/README.md` | 3568 | `4538aaaaebf4ab65bb8c21f71bad530a5966837445dfe220c14f341b5099fac9` | no |
| `licenses/THIRD-PARTY.md` | 13063 | `4f98948de029572969568477be74c24d26fe46997e0288bc0aff245fafe1f1cf` | no |
| `licenses/VLFeat-LICENSE.txt` | 1390 | `a31ef034eeab41e1c24e72747608a54c8e72c7e7f6ebcf7391f00c7e63c1495e` | no |
| `licenses/faiss-LICENSE.txt` | 1107 | `f08a94bfb0bdc1d7f1cb59badaf0f8c551b10db871185622dbf1fd036affa9cb` | no |
| `licenses/libf2c-Notice.txt` | 1235 | `cabd9f61080c1d7c155121cb4b7a57dfa0e7482449c640b7eeb633d9d757bacf` | no |
| `licenses/patches/0001-without-cholmod.patch` | 5514 | `a6cc9cc28c9256cee75ca8f62661ccc4262c4bf5f14940aadec272b3a9ac191b` | no |
| `licenses/patches/0002-vcpkg-without-suitesparse.patch` | 1119 | `a916f7ba404eca19298f24031287fd23a3dc8d25807e9bdcc48448d10ca68c2e` | no |
| `licenses/patches/0003-faiss-without-blas.patch` | 2438 | `88f6efa8303509abc27a29b792c674a47834fa34ce122f1c9fba4e28f60f0642` | no |
| `licenses/vcpkg/boost-algorithm.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-align.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-any.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-array.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-assert.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-atomic.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-bimap.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-bind.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-chrono.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-cmake.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-compat.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-concept-check.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-config.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-container-hash.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-container.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-conversion.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-core.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-date-time.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-describe.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-detail.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-dynamic-bitset.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-endian.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-exception.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-foreach.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-function-types.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-function.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-fusion.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-graph.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-headers.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-heap.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-integer.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-intrusive.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-io.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-iterator.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-lambda.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-lexical-cast.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-math.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-move.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-mp11.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-mpl.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-multi-index.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-multiprecision.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-numeric-conversion.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-optional.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-parameter.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-phoenix.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-pool.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-predef.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-preprocessor.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-program-options.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-property-map.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-property-tree.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-proto.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-random.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-range.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-ratio.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-regex.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-serialization.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-smart-ptr.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-spirit.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-static-assert.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-system.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-thread.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-throw-exception.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-tokenizer.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-tti.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-tuple.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-type-index.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-type-traits.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-typeof.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-unordered.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-utility.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-variant.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-variant2.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-winapi.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-xpressive.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/ceres.txt` | 14355 | `765fd9eac4cb827fa5de4304d1f81f4f2c5c332a3f1d6f0f3f7a69a33156729b` | no |
| `licenses/vcpkg/clapack.txt` | 1607 | `23014869214a231525b38c39fdb5f82364fa24154ac80fdcab2a79671460fd09` | no |
| `licenses/vcpkg/eigen3.txt` | 32831 | `ad251846a5a37acfed04407b7eee9161fbd58a91874b20fd949904413c407b2a` | no |
| `licenses/vcpkg/expat.txt` | 1144 | `31b15de82aa19a845156169a17a5488bf597e561b2c318d159ed583139b25e87` | no |
| `licenses/vcpkg/fmt.txt` | 1094 | `a65fcc5a1095fc33cc37e4fff69366e49d7e92f613558a2b95ed1b70e33758b4` | no |
| `licenses/vcpkg/gflags.txt` | 1479 | `90d1f3701813c3cd65eee2dc736746fe46b465918f3f7d6d31463a2018b33fa5` | no |
| `licenses/vcpkg/gklib.txt` | 641 | `81118d7ac02c98ad2d49a8b7d12d24f41e3bef962342f5483bf1b80a79ce1992` | no |
| `licenses/vcpkg/glog.txt` | 1479 | `136d48dea7a681413691f3db3098f6cf5ffaa3119d96d97bb83b8cff3ce38c4a` | no |
| `licenses/vcpkg/imath.txt` | 1497 | `c20236d3b39fd20eba8e3d1fb3b892a5483df2e7d8d61bf43f165d3fac22f601` | no |
| `licenses/vcpkg/libdeflate.txt` | 1078 | `4ad69099cb4374836fd27583d9991e2838cd86b6e4666ab26b2d32582c91e73a` | no |
| `licenses/vcpkg/libjpeg-turbo.txt` | 6077 | `ba6bceebcba0fdd35488477c2cca8c4632ce82c74dbfbc87d886ce6fc4433579` | no |
| `licenses/vcpkg/libpng.txt` | 5345 | `bdb0a645ea18c60507d0368379b1ac5474b92255fcc2d115e07486a7672ba526` | no |
| `licenses/vcpkg/metis.txt` | 641 | `64ab947d7b289ad76e935adff51b31e4ac160df7dfad24480dbaa452e39bbe79` | no |
| `licenses/vcpkg/minizip-ng.txt` | 877 | `675181c03fc1302a1c8554c00f7be9bb420c5dbc9dcc2013433cec144413de03` | no |
| `licenses/vcpkg/openblas.txt` | 1548 | `190b5a9c8d9723fe958ad33916bd7346d96fab3c5ea90832bb02d854f620fcff` | no |
| `licenses/vcpkg/opencolorio.txt` | 1485 | `82a40c52065ee968aa62015735e84378ac11425db7a233e6a2dcd2c83fc24276` | no |
| `licenses/vcpkg/openexr.txt` | 1501 | `84853c91d4c2e0310741d4773469d98bb93e61029608e0ba0882a3fffdf330bd` | no |
| `licenses/vcpkg/openimageio.txt` | 25011 | `7585beae16904f28ee1a32fcc97f108e7717d78ddec927ebb98e09be7c5530d5` | no |
| `licenses/vcpkg/openjph.txt` | 1448 | `5ddf5177863dfc9ab65fa129d587db651241f00e21ed2427b218bea997591f98` | no |
| `licenses/vcpkg/pystring.txt` | 1530 | `f7f060301402ea0b5c507b865b1a9de037d4d7b24f37422a93b70fe9c7a9b78a` | no |
| `licenses/vcpkg/robin-map.txt` | 1102 | `11f2c685ba565a31aef1219f63a7a8845602c97bff70016b9e3278dfe51a2ec5` | no |
| `licenses/vcpkg/sqlite3.txt` | 71 | `3cafdd9b568b924b234b91f4a24649d509f02643ae727eac6a4e33818288c9c4` | no |
| `licenses/vcpkg/tiff.txt` | 2416 | `0e27c2382d7b8147972bbb746e04059a1152c8d0fda9d03ef1399d1a433c4ade` | no |
| `licenses/vcpkg/vcpkg-boost.txt` | 1073 | `1ee376fc340e0aa6ad6a3581c94126e741468705096ac92263048a21daa86460` | no |
| `licenses/vcpkg/vcpkg-cmake-config.txt` | 1096 | `04b60f99a43bfd7fefdc8364b24aac704a2160cef969b75ba6a38b62dc4c4b70` | no |
| `licenses/vcpkg/vcpkg-cmake.txt` | 1073 | `1ee376fc340e0aa6ad6a3581c94126e741468705096ac92263048a21daa86460` | no |
| `licenses/vcpkg/yaml-cpp.txt` | 1061 | `aa6fcc27be034e41e21dd832f9175bfe694a48491d9e14ff0fa278e19ad14f1b` | no |
| `licenses/vcpkg/zlib.txt` | 1002 | `e32ff4e00d9d94930537635291da39e7e612703334bf6fde8c7f1686fe8a45a2` | no |
| `msvcp140.dll` | 557728 | `0f885b509a685d2bbfa652fed26b5fb31d88fbdab0a978c641d1c7b8aa460aa9` | no |
| `msvcp140_2.dll` | 280200 | `3ea06f0ee098b4823cb79599df3780e7f23cce52c19aac31d2a0d47efe33a5e9` | no |
| `vcomp140.dll` | 193152 | `55aba23cdcd6484fbb06f4155b8ca75adfce7a881f10afd0c49457165e677164` | no |
| `vcruntime140.dll` | 124544 | `d5e4d9a3e835fa679450145d6a7d94e36573a509317111904d9b3712c30d9066` | no |
| `vcruntime140_1.dll` | 49792 | `1f2d41c4aa5db0bc33ebf7b66d72943a817d7ce6cbe880502a9403823633093f` | no |

`colmap-cpu-linux-x64.zip` holds, unpacked into `engines/colmap-cpu-linux-x64`:

| File | Size (bytes) | SHA-256 | Program |
| --- | --- | --- | --- |
| `BUILD-INFO.txt` | 1170 | `a646f11158e203f990e32b830f6735459493ab155076f9d04f6fc10a12fc22f7` | no |
| `SHA256SUMS.txt` | 11519 | `ae3a03c5db572f65961226914ce477572edebf7f764aef23e0d72b0fd1cad44a` | no |
| `colmap` | 72599544 | `0e2fdcf3f176d41fe95271c28d5c30eb4626c03871afbdd36f78fd928819ec0b` | yes |
| `immuch360-run` | 16552 | `779dfe821cc14fbbd8e6f7420ccba3f08509a5802f89d18a5f5a606b2dd79a7b` | yes |
| `licenses/COPYING.txt` | 1909 | `ab30dabb4f0a6731f980108f57aa160cc8f5cebae6984e01a5d109df99669233` | no |
| `licenses/PoissonRecon-LICENSE.txt` | 1075 | `addfdacb0d5e30f25641fc2c26cc423c541a60e16624b29d80d3490608ba4956` | no |
| `licenses/PoseLib-LICENSE.txt` | 1522 | `f956d2d12c3a58c72e936bb390071d4c4df8f4da008bdcd617bb0a8a890eda1c` | no |
| `licenses/README.md` | 3531 | `1f37f574c955e08a6add640df92525556c4fe4ec140629440e8e675d78da5f36` | no |
| `licenses/THIRD-PARTY.md` | 12923 | `6d1cc2cad7ce9ae8e756f58116adec5f79923c5aa56e976998d984861ab8ad86` | no |
| `licenses/VLFeat-LICENSE.txt` | 1365 | `33b9f7703327199088d74f884b19997a0084180f984724720095a7cb412c4d89` | no |
| `licenses/faiss-LICENSE.txt` | 1086 | `52412d7bc7ce4157ea628bbaacb8829e0a9cb3c58f57f99176126bc8cf2bfc85` | no |
| `licenses/libf2c-Notice.txt` | 1212 | `44561c447e91203ddc747beeca5cc2794d95ee982c17c578670e4f0408bc3904` | no |
| `licenses/patches/0001-without-cholmod.patch` | 5514 | `a6cc9cc28c9256cee75ca8f62661ccc4262c4bf5f14940aadec272b3a9ac191b` | no |
| `licenses/patches/0002-vcpkg-without-suitesparse.patch` | 1119 | `a916f7ba404eca19298f24031287fd23a3dc8d25807e9bdcc48448d10ca68c2e` | no |
| `licenses/patches/0003-faiss-without-blas.patch` | 2438 | `88f6efa8303509abc27a29b792c674a47834fa34ce122f1c9fba4e28f60f0642` | no |
| `licenses/vcpkg/boost-algorithm.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-align.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-any.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-array.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-assert.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-atomic.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-bimap.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-bind.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-chrono.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-cmake.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-compat.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-concept-check.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-config.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-container-hash.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-container.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-conversion.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-core.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-date-time.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-describe.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-detail.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-dynamic-bitset.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-endian.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-exception.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-foreach.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-function-types.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-function.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-fusion.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-graph.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-headers.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-heap.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-integer.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-intrusive.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-io.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-iterator.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-lambda.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-lexical-cast.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-math.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-move.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-mp11.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-mpl.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-multi-index.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-multiprecision.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-numeric-conversion.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-optional.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-parameter.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-phoenix.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-pool.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-predef.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-preprocessor.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-program-options.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-property-map.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-property-tree.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-proto.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-random.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-range.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-ratio.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-regex.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-serialization.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-smart-ptr.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-spirit.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-static-assert.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-system.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-thread.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-throw-exception.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-tokenizer.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-tti.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-tuple.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-type-index.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-type-traits.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-typeof.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-unordered.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-utility.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-variant.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-variant2.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-winapi.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/boost-xpressive.txt` | 1338 | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` | no |
| `licenses/vcpkg/ceres.txt` | 14355 | `765fd9eac4cb827fa5de4304d1f81f4f2c5c332a3f1d6f0f3f7a69a33156729b` | no |
| `licenses/vcpkg/clapack.txt` | 1607 | `23014869214a231525b38c39fdb5f82364fa24154ac80fdcab2a79671460fd09` | no |
| `licenses/vcpkg/eigen3.txt` | 32154 | `9af2ed6fee290d31684b61774741b985aa2505e246fc28eca403f407262daf77` | no |
| `licenses/vcpkg/expat.txt` | 1144 | `31b15de82aa19a845156169a17a5488bf597e561b2c318d159ed583139b25e87` | no |
| `licenses/vcpkg/fmt.txt` | 1094 | `a65fcc5a1095fc33cc37e4fff69366e49d7e92f613558a2b95ed1b70e33758b4` | no |
| `licenses/vcpkg/gflags.txt` | 1479 | `90d1f3701813c3cd65eee2dc736746fe46b465918f3f7d6d31463a2018b33fa5` | no |
| `licenses/vcpkg/gklib.txt` | 641 | `81118d7ac02c98ad2d49a8b7d12d24f41e3bef962342f5483bf1b80a79ce1992` | no |
| `licenses/vcpkg/glog.txt` | 1479 | `136d48dea7a681413691f3db3098f6cf5ffaa3119d96d97bb83b8cff3ce38c4a` | no |
| `licenses/vcpkg/imath.txt` | 1497 | `c20236d3b39fd20eba8e3d1fb3b892a5483df2e7d8d61bf43f165d3fac22f601` | no |
| `licenses/vcpkg/libdeflate.txt` | 1078 | `4ad69099cb4374836fd27583d9991e2838cd86b6e4666ab26b2d32582c91e73a` | no |
| `licenses/vcpkg/libjpeg-turbo.txt` | 6077 | `ba6bceebcba0fdd35488477c2cca8c4632ce82c74dbfbc87d886ce6fc4433579` | no |
| `licenses/vcpkg/libpng.txt` | 5345 | `bdb0a645ea18c60507d0368379b1ac5474b92255fcc2d115e07486a7672ba526` | no |
| `licenses/vcpkg/metis.txt` | 641 | `64ab947d7b289ad76e935adff51b31e4ac160df7dfad24480dbaa452e39bbe79` | no |
| `licenses/vcpkg/minizip-ng.txt` | 877 | `675181c03fc1302a1c8554c00f7be9bb420c5dbc9dcc2013433cec144413de03` | no |
| `licenses/vcpkg/openblas.txt` | 1548 | `190b5a9c8d9723fe958ad33916bd7346d96fab3c5ea90832bb02d854f620fcff` | no |
| `licenses/vcpkg/opencolorio.txt` | 1485 | `82a40c52065ee968aa62015735e84378ac11425db7a233e6a2dcd2c83fc24276` | no |
| `licenses/vcpkg/openexr.txt` | 1501 | `84853c91d4c2e0310741d4773469d98bb93e61029608e0ba0882a3fffdf330bd` | no |
| `licenses/vcpkg/openimageio.txt` | 24701 | `95b56cf947151b6007f9b458bc9b7da974982715aabd2f5d25b366275f2142fa` | no |
| `licenses/vcpkg/openjph.txt` | 1448 | `5ddf5177863dfc9ab65fa129d587db651241f00e21ed2427b218bea997591f98` | no |
| `licenses/vcpkg/pystring.txt` | 1530 | `f7f060301402ea0b5c507b865b1a9de037d4d7b24f37422a93b70fe9c7a9b78a` | no |
| `licenses/vcpkg/robin-map.txt` | 1102 | `11f2c685ba565a31aef1219f63a7a8845602c97bff70016b9e3278dfe51a2ec5` | no |
| `licenses/vcpkg/sqlite3.txt` | 69 | `1472ec10e27c62157cebd95d9186e8912a75a1a829fe3a612611710da2992ed5` | no |
| `licenses/vcpkg/tiff.txt` | 2416 | `0e27c2382d7b8147972bbb746e04059a1152c8d0fda9d03ef1399d1a433c4ade` | no |
| `licenses/vcpkg/vcpkg-boost.txt` | 1073 | `1ee376fc340e0aa6ad6a3581c94126e741468705096ac92263048a21daa86460` | no |
| `licenses/vcpkg/vcpkg-cmake-config.txt` | 1096 | `04b60f99a43bfd7fefdc8364b24aac704a2160cef969b75ba6a38b62dc4c4b70` | no |
| `licenses/vcpkg/vcpkg-cmake.txt` | 1073 | `1ee376fc340e0aa6ad6a3581c94126e741468705096ac92263048a21daa86460` | no |
| `licenses/vcpkg/yaml-cpp.txt` | 1061 | `aa6fcc27be034e41e21dd832f9175bfe694a48491d9e14ff0fa278e19ad14f1b` | no |
| `licenses/vcpkg/zlib.txt` | 1002 | `e32ff4e00d9d94930537635291da39e7e612703334bf6fde8c7f1686fe8a45a2` | no |

`brush-vulkan-win-x64.zip` holds, unpacked into `engines/brush-vulkan-win-x64`:

| File | Size (bytes) | SHA-256 | Program |
| --- | --- | --- | --- |
| `BUILD-INFO.txt` | 2780 | `b7b172d23685730e1d12f27dd92b84680c9daa6caef3b0e2f0029dbc3f9ef732` | no |
| `brush_app.exe` | 63759872 | `2d10dc03e96f28d885fa699129d28d9271a614e6a53211ef2015f894e3616a05` | yes |
| `licenses/EXTRA-NOTICES.md` | 5935 | `2b18770127e5c1212e88983220ec5a9eb8559df9033bd1b62ec89ef3307ebf31` | no |
| `licenses/README.md` | 4527 | `07d0bba845a345ebfd2ededea5ae022e353262b2b4eab78eb929e25f9fc1ecaf` | no |
| `licenses/THIRD-PARTY.md` | 467291 | `e5d8003e290996831420222a73dc69cee5a0653ed978170d4378db1243d9814a` | no |
| `licenses/brush-LICENSE.txt` | 11358 | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` | no |
| `licenses/patches/0001-immuch360-headless-trainer.patch` | 17608 | `788070930f92eb8922209337429762df0a5748567586cf2bb7e880f5d17be1bf` | no |
| `vcruntime140.dll` | 124544 | `d5e4d9a3e835fa679450145d6a7d94e36573a509317111904d9b3712c30d9066` | no |

`brush-vulkan-linux-x64.zip` holds, unpacked into `engines/brush-vulkan-linux-x64`:

| File | Size (bytes) | SHA-256 | Program |
| --- | --- | --- | --- |
| `BUILD-INFO.txt` | 2463 | `d28be9920f7baa68ddda680a312ea7fde26d0313dd365fa18530dfcee4b5ce32` | no |
| `brush_app` | 66707536 | `659b005f4c1935e53c5d4ec9e33ad27e580a08a2026deef211e8980603722f51` | yes |
| `immuch360-run` | 16552 | `779dfe821cc14fbbd8e6f7420ccba3f08509a5802f89d18a5f5a606b2dd79a7b` | yes |
| `licenses/EXTRA-NOTICES.md` | 5935 | `2b18770127e5c1212e88983220ec5a9eb8559df9033bd1b62ec89ef3307ebf31` | no |
| `licenses/README.md` | 4527 | `07d0bba845a345ebfd2ededea5ae022e353262b2b4eab78eb929e25f9fc1ecaf` | no |
| `licenses/THIRD-PARTY.md` | 430400 | `02effca99500521dd2698ec911518c66a8d86f6897c560c2ea5592a7fce2bc27` | no |
| `licenses/brush-LICENSE.txt` | 11358 | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` | no |
| `licenses/patches/0001-immuch360-headless-trainer.patch` | 17608 | `788070930f92eb8922209337429762df0a5748567586cf2bb7e880f5d17be1bf` | no |

COLMAP 4.2.1: BSD-3-Clause, Copyright (c), ETH Zurich and UNC Chapel Hill
(https://github.com/colmap/colmap/blob/4.2.1/COPYING.txt). Brush 0.3.0: Apache-2.0
(https://github.com/ArthurBrussee/brush/blob/v0.3.0/LICENSE), no NOTICE file. Both are built by our CI from
the sources pinned in `.github/desktop/ai/colmap.lock.json` and `brush.lock.json`, with the patches of
`licenses/colmap/patches/` and `licenses/brush/patches/` (each changed file of Brush says so, Apache-2.0
section 4 b), and run by the app as child processes, without a window and without the network.

COLMAP is built without its GPL and non commercial parts: no graphical interface (Qt), OpenGL nor SiftGPU
(research and non-profit use only), no LSD (AGPL 3), no CGAL, GMP nor MPFR, no CHOLMOD nor any part of
SuiteSparse (Eigen's sparse solvers, MPL-2.0, take over), no CUDA, ONNX Runtime, dense reconstruction,
downloads (curl, OpenSSL) nor vocabulary trees; the CI fails when a file, an import or a string of any of
them is in an archive. The code built into it (VLFeat BSD-2-Clause, PoissonRecon MIT, PoseLib BSD-3-Clause,
faiss MIT, CLAPACK BSD-3-Clause with the notice of libf2c) and the ports of vcpkg, each with the licence its
`vcpkg.spdx.json` gives and every one on our list, are in `licenses/THIRD-PARTY.md` of each archive, their
texts in `licenses/` and the copyright files of the ports in `licenses/vcpkg/`. On Linux, `colmap` needs
`libgomp.so.1` of the system (GPL 3 with the GCC Runtime Library Exception).

Brush is built without its window, its rerun and HTTP clients and its LPIPS loss: the LPIPS weights
(`crates/lpips/burn_mapped.bin`, whose origin is not written) are removed from the sources before the build
and none of their probes is in the program. The crates compiled into it are in `licenses/THIRD-PARTY.md` of
each archive, written by cargo about with the text of each licence (Apache-2.0, MIT, MPL-2.0 for `colored`
and `option-ext` compiled unmodified, CC0-1.0, ISC, Unicode-3.0, Zlib) and the NOTICE files of burn and
cubecl; `licenses/EXTRA-NOTICES.md` holds the copyright lines of the crates published without a licence file.

On Windows the archives hold the runtime DLLs of Visual C++ and OpenMP, redistributable, signed by
Microsoft; on Linux, `immuch360-run`, the launcher of the app (MIT). No model of any kind: neither program
needs one.

The programs of `colmap-cpu-win-x64` and `brush-vulkan-win-x64` are not signed in this release (the runtime DLLs
of Microsoft keep their signature). Linux programs carry no signature. The app checks each archive and each of its
files by its SHA-256 when it installs them.

<!-- end of the releases -->
## The splat module of the Meta Spatial SDK 0.14.0 (in the quest APK, not downloaded)

`com.meta.spatial:meta-spatial-sdk-splat` 0.14.0 shows on a Meta Quest 3 or 3S the Gaussian splat files that
other tools make (`.spz`, `.ply`): no AI of ours, no model downloaded. It is built into the APK of the quest
flavour only (about 1.1 MB). Licence: the Meta Platform Technologies SDK License Agreement, the very text of the
Meta Spatial SDK the APK already ships (its `LICENSE`, SHA-256
`bb9b12db3b92c024458df625acd6f2d8140ea805cc6814bac74613a466731368`, and its `notices.html` are byte for byte those
of `meta-spatial-sdk`, `-toolkit` and `-vr`). Both are in `licenses/meta-spatial-sdk/` and on the licence page of
the app. The same text, but one of its clauses applies here for the first time: the splat API is an Experimental
Feature of the SDK (opt in `SpatialSDKExperimentalSplatAPI`), and article 1.6 keeps an Experimental Feature out of
a production build unless Meta released it in its own production builds or permits it in writing. On 30 October
2026 FreeKC, the maintainer, decided to ship it in the builds of this free hobby app, on GitHub and in the Meta
Horizon Store, labelled experimental, with the words that Meta neither supports nor warrants its API and that any
defect is Immuch360's own; a switch of the app hides it in the store build should Meta object. The decision, its
reading of the clause and what goes with it are in `licenses/meta-spatial-sdk/README.md`.

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
