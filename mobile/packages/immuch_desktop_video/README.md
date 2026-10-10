# immuch_desktop_video

Part of Immuch360 Desktop (`docs/20-design-desktop.md` section 2.7 in the research notes, plan 20 phase 2c): what the
hardware video decoder of the computer's GPU takes, so that the app can choose between a video's original and the
server's transcoded stream, and list the decoders on the troubleshooting page, as the phones do through
`VideoDecoderApi`.

- `windows/immuch_desktop_video.cpp`: a DLL with a C interface, called through `dart:ffi`. For the default adapter
  (the GPU the app's video renders and decodes on, which Windows picks from the per app graphics preference) or any
  adapter of DXGI's list, it reads the Direct3D 11 decoder profiles (`ID3D11VideoDevice::GetVideoDecoderProfile`), the
  output formats of each (`CheckVideoDecoderFormat`), whether each given frame size has a decoder configuration with
  a raw bitstream (`GetVideoDecoderConfigCount`, `GetVideoDecoderConfig`: the check FFmpeg's d3d11va makes before it
  decodes), and, where Direct3D 12 answers, the frame rate the driver allows at the largest size
  (`D3D12_FEATURE_VIDEO_DECODE_SUPPORT`; a driver that accepts an impossible rate is taken as not telling). The answer
  is JSON. Each call makes its devices and releases them.
- `lib/src/d3d11_decoders.dart`: the call in a background isolate, and the parsed answer.
- `lib/src/d3d11_profiles.dart`: the decoder profile GUIDs the app knows (codec, profile name, depth, chroma), and the
  profiles FFmpeg tries for a codec and depth.

The rules built on it (software decoding beyond the hardware limits, the measured correction per codec, size and
rate, the decoders page rows) live in the app, `lib/desktop/platform/desktop_video_decoder_api.dart` and
`lib/desktop/video/decoder_measure.dart`. Linux and macOS have no native part yet and answer from the app's static
rule.

Licence: the licence of the app (AGPL-3.0).
