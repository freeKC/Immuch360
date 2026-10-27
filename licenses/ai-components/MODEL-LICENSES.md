# Licences of the AI components of Immuch360

Date: 2026-10-27. Written by `.github/desktop/ai/publish_ai_components.py` from the files of the prerelease
`ai-components-1`: https://github.com/freeKC/Immuch360/releases/tag/ai-components-1

The app downloads a component only when the user asks for it, checks its SHA-256 against the catalogue built
into the app, and copies its licence next to it (`ai-components/licenses/`). The depth model is Apache-2.0,
ONNX Runtime is MIT. ONNX Runtime has other libraries built in, each under its own licence, listed in
its notices (below): mostly BSD, Apache-2.0, MIT, Boost, zlib or public domain, and Eigen under MPL-2.0,
a weak copyleft licence. The notices cover the whole ONNX Runtime project, not only what these builds
hold. The libraries are redistributed as Microsoft built them, unmodified, with those notices. When two
pages disagree on a licence, the more restrictive one applies.

## Depth model: Depth Anything V2 Small, Apache-2.0

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

## ONNX Runtime, MIT

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

## Telemetry of ONNX Runtime, turned off

The official builds of ONNX Runtime 1.31.0 send telemetry to Microsoft by default
(https://github.com/microsoft/onnxruntime/blob/v1.31.0/docs/Privacy.md). The libraries for Linux and
macOS carry the 1DS SDK: at their first session they write a device id and queue events for
https://mobile.events.data.microsoft.com/OneCollector/1.0/. The Windows DLL reports through ETW
(provider `Microsoft.ML.ONNXRuntime`). Immuch360 turns both off: it sets `ORT_DISABLE_TELEMETRY=1` in its
process before it opens the library, so that 1DS never starts, and calls `DisableTelemetryEvents` on each
environment it makes, which stops the ETW events. On Windows, ONNX Runtime may write one start event to
ETW before that call; ETW events leave the computer only through the diagnostic data of Windows, under its
own setting. 1.23.2 for the Intel Macs has no telemetry.

## Not used

These were looked at and left out, because of their licence:

* Depth Anything V2 Base, Large and Giant: CC-BY-NC-4.0, https://github.com/DepthAnything/Depth-Anything-V2#license
* DirectML.dll: Microsoft proprietary licence, https://www.nuget.org/packages/Microsoft.AI.DirectML/1.15.4/License
* dxil.dll of the DirectX Shader Compiler: LICENSE-MS.txt, Microsoft software licence terms, https://github.com/microsoft/DirectXShaderCompiler/releases/tag/v1.9.2609
* Qualcomm QNN: Qualcomm licence, https://softwarecenter.qualcomm.com/api/download/software/licenses/ai_model_hub/v1/LICENSE.pdf
