// The Direct3D 11 video decoder profiles the app knows, by GUID: the codec each decodes (as a MIME type, the names the
// phones' decoders page uses), the profile in the codec's own words, and the bit depth and chroma of the frames. The
// GUIDs are those of d3d11.h (Windows SDK 10.0.26100), written out here so that the table does not depend on the SDK
// a build uses. A profile not in this table is still reported by the probe, with its GUID only.
//
// Only the bitstream decoding modes (VLD) are listed: the motion compensation, IDCT and post processing modes of the
// first DXVA decoders leave the bitstream to the CPU, and FFmpeg never asks for them.

/// A codec as a MIME type, as the decoders page groups them
abstract final class VideoMime {
  static const avc = 'video/avc';
  static const hevc = 'video/hevc';
  static const av1 = 'video/av01';
  static const vp9 = 'video/x-vnd.on2.vp9';
  static const vp8 = 'video/x-vnd.on2.vp8';
  static const mpeg2 = 'video/mpeg2';
  static const mpeg4 = 'video/mp4v-es';
  static const vc1 = 'video/wvc1';
}

/// What a decoder profile of [guid] decodes: [codec] (a [VideoMime]), [name] in the codec's words ("Main 10"),
/// frames of up to [bitDepth] bits in [chroma] ("4:2:0")
class D3D11ProfileInfo {
  const D3D11ProfileInfo(this.guid, this.codec, this.name, {this.bitDepth = 8, this.chroma = '4:2:0'});

  final String guid;
  final String codec;
  final String name;
  final int bitDepth;
  final String chroma;

  @override
  String toString() => 'D3D11ProfileInfo($codec $name, $bitDepth bit $chroma)';
}

/// The profiles the app knows, GUIDs in lower case without braces as the probe writes them
const d3d11Profiles = [
  // H.264: the VLD modes decode Constrained Baseline, Main and High, 8 bit 4:2:0 only; no DXVA mode takes High 10,
  // 4:2:2 or 4:4:4. FFmpeg tries the film grain mode first, then the plain one, then Intel's (dxva2.c, dxva_modes).
  D3D11ProfileInfo('1b81be68-a0c7-11d3-b984-00c04f2e73c5', VideoMime.avc, 'High'),
  D3D11ProfileInfo('1b81be69-a0c7-11d3-b984-00c04f2e73c5', VideoMime.avc, 'High, film grain'),
  // Intel's own H.264 mode (DXVADDI_Intel_ModeH264_E), which FFmpeg tries after the two above
  D3D11ProfileInfo('604f8e68-4951-4c54-88fe-abd25c15b3d6', VideoMime.avc, 'High, Intel'),
  D3D11ProfileInfo('d5f04ff9-3418-45d8-9561-32a76aae2ddd', VideoMime.avc, 'Baseline with FMO and ASO'),
  D3D11ProfileInfo('d79be8da-0cf1-4c81-b82a-69a4e236f43d', VideoMime.avc, 'Stereo High, progressive'),
  D3D11ProfileInfo('f9aaccbb-c2b6-4cfc-8779-5707b1760552', VideoMime.avc, 'Stereo High'),
  D3D11ProfileInfo('705b9d82-76cf-49d6-b7e6-ac8872db013c', VideoMime.avc, 'Multiview High'),
  // HEVC
  D3D11ProfileInfo('5b11d51b-2f4c-4452-bcc3-09f2a1160cc0', VideoMime.hevc, 'Main'),
  D3D11ProfileInfo('107af0e0-ef1a-4d19-aba8-67a163073d13', VideoMime.hevc, 'Main 10', bitDepth: 10),
  D3D11ProfileInfo('1a72925f-0c2c-4f15-96fb-b17d1473603f', VideoMime.hevc, 'Main 12', bitDepth: 12),
  D3D11ProfileInfo(
    '0bac4fe5-1532-4429-a854-f84de04953db',
    VideoMime.hevc,
    'Main 4:2:2 10',
    bitDepth: 10,
    chroma: '4:2:2',
  ),
  D3D11ProfileInfo(
    '55bcac81-f311-4093-a7d0-1cbc0b849bee',
    VideoMime.hevc,
    'Main 4:2:2 12',
    bitDepth: 12,
    chroma: '4:2:2',
  ),
  D3D11ProfileInfo('4008018f-f537-4b36-98cf-61af8a2c1a33', VideoMime.hevc, 'Main 4:4:4', chroma: '4:4:4'),
  D3D11ProfileInfo('9cc55490-e37c-4932-8684-4920f9f6409c', VideoMime.hevc, 'Main 10 extended', bitDepth: 10),
  D3D11ProfileInfo(
    '0dabeffa-4458-4602-bc03-0795659d617c',
    VideoMime.hevc,
    'Main 4:4:4 10',
    bitDepth: 10,
    chroma: '4:4:4',
  ),
  D3D11ProfileInfo(
    '9798634d-fe9d-48e5-b4da-dbec45b3df01',
    VideoMime.hevc,
    'Main 4:4:4 12',
    bitDepth: 12,
    chroma: '4:4:4',
  ),
  D3D11ProfileInfo(
    'a4fbdbb0-a113-482b-a232-635cc0697f6d',
    VideoMime.hevc,
    'Main 4:4:4 16',
    bitDepth: 16,
    chroma: '4:4:4',
  ),
  D3D11ProfileInfo('0685b993-3d8c-43a0-8b28-d74c2d6899a4', VideoMime.hevc, 'Monochrome', chroma: '4:0:0'),
  D3D11ProfileInfo(
    '142a1d0f-69dd-4ec9-8591-b12ffcb91a29',
    VideoMime.hevc,
    'Monochrome 10',
    bitDepth: 10,
    chroma: '4:0:0',
  ),
  // AV1: profile 0 (Main) takes 8 and 10 bit 4:2:0; the formats of the probe tell which of the two a GPU writes
  D3D11ProfileInfo('b8be4ccb-cf53-46ba-8d59-d6b8a6da5d2a', VideoMime.av1, 'Main', bitDepth: 10),
  D3D11ProfileInfo('6936ff0f-45b1-4163-9cc1-646ef6946108', VideoMime.av1, 'High', bitDepth: 10, chroma: '4:4:4'),
  D3D11ProfileInfo(
    '0c5f2aa1-e541-4089-bb7b-98110a19d7c8',
    VideoMime.av1,
    'Professional',
    bitDepth: 10,
    chroma: '4:2:2',
  ),
  D3D11ProfileInfo(
    '17127009-a00f-4ce1-994e-bf4081f6f3f0',
    VideoMime.av1,
    'Professional 12 bit',
    bitDepth: 12,
    chroma: '4:4:4',
  ),
  D3D11ProfileInfo('2d80bed6-9cac-4835-9e91-327bbc4f9ee8', VideoMime.av1, 'Professional 12 bit 4:2:0', bitDepth: 12),
  // VP9 and VP8
  D3D11ProfileInfo('463707f8-a1d0-4585-876d-83aa6d60b89e', VideoMime.vp9, 'Profile 0'),
  D3D11ProfileInfo('a4c749ef-6ecf-48aa-8448-50a7a1165ff7', VideoMime.vp9, 'Profile 2', bitDepth: 10),
  D3D11ProfileInfo('90b899ea-3a62-4705-88b3-8df04b2744e7', VideoMime.vp8, 'VP8'),
  // Older codecs, for the decoders page
  D3D11ProfileInfo('ee27417f-5e28-4e65-beea-1d26b508adc9', VideoMime.mpeg2, 'Main'),
  D3D11ProfileInfo('86695f12-340e-4f04-9fd3-9253dd327460', VideoMime.mpeg2, 'Main, MPEG-1 too'),
  D3D11ProfileInfo('1b81bea3-a0c7-11d3-b984-00c04f2e73c5', VideoMime.vc1, 'Advanced'),
  D3D11ProfileInfo('1b81bea4-a0c7-11d3-b984-00c04f2e73c5', VideoMime.vc1, 'Advanced, 2010'),
  D3D11ProfileInfo('efd64d74-c9e8-41d7-a5e9-e9b0e39fa319', VideoMime.mpeg4, 'Simple'),
  D3D11ProfileInfo('ed418a9f-010d-4eda-9ae3-9a65358d8d2e', VideoMime.mpeg4, 'Advanced Simple'),
  D3D11ProfileInfo('ab998b5b-4258-44a9-9feb-94e597a6baae', VideoMime.mpeg4, 'Advanced Simple with GMC'),
];

final _byGuid = {for (final profile in d3d11Profiles) profile.guid: profile};

/// What the profile of [guid] decodes, null for a profile the app does not know
D3D11ProfileInfo? d3d11ProfileInfo(String guid) => _byGuid[guid.toLowerCase().replaceAll(RegExp('[{}]'), '')];

/// The GUIDs FFmpeg tries when it decodes [codec] (a [VideoMime]) at [bitDepth] bits (0 when unknown, taken as 8)
/// with [chroma], each with the profiles it is allowed for (dxva2.c, dxva_modes): empty when no mode of FFmpeg decodes
/// it, which leaves the video to the CPU (H.264 High 10, 4:2:2 and 4:4:4 of any codec, VP8, MPEG-4 part 2)
List<String> ffmpegProfilesFor(String codec, {int bitDepth = 8, String chroma = '4:2:0'}) {
  if (chroma != '4:2:0') {
    return const [];
  }
  final depth = bitDepth <= 0 ? 8 : bitDepth;
  final names = switch (codec) {
    // The stereo and multiview modes decode a second view, which FFmpeg never asks for
    VideoMime.avc when depth <= 8 => const ['High, film grain', 'High', 'High, Intel'],
    // Main 10 is tried for Main 10 streams only, Main for Main ones: FFmpeg checks the stream's profile against each
    VideoMime.hevc when depth <= 8 => const ['Main'],
    VideoMime.hevc when depth <= 10 => const ['Main 10'],
    VideoMime.vp9 when depth <= 8 => const ['Profile 0'],
    VideoMime.vp9 when depth <= 10 => const ['Profile 2'],
    // AV1 Main covers 8 and 10 bit; the output format tells whether the GPU writes 10 bit (P010)
    VideoMime.av1 when depth <= 10 => const ['Main'],
    VideoMime.mpeg2 => const ['Main', 'Main, MPEG-1 too'],
    VideoMime.vc1 => const ['Advanced, 2010', 'Advanced'],
    _ => const <String>[],
  };
  return [
    for (final name in names)
      ...d3d11Profiles
          .where((profile) => profile.codec == codec && profile.name == name)
          .map((profile) => profile.guid),
  ];
}
