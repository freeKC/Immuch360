// The mpv options of the app's players (DesktopPlayerOptions) that were measured, kept from changing unnoticed:
// - the players on screen stay in mpv's "dumb mode" (media_kit's bilinear scaling, nothing that needs an intermediate
//   pass): leaving it doubled the GPU memory of a 5.7K video on the Intel UHD, for no faster frame (REV-GPU of 2a);
// - the caches stay in memory and bounded, and no file is opened next to the video.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';

void main() {
  // The options of mpv's renderer that turn its dumb mode off (video/out/gpu/video.c, check_dumb_mode)
  const leaveDumbMode = [
    'dscale',
    'scale',
    'cscale',
    'correct-downscaling',
    'linear-downscaling',
    'linear-upscaling',
    'sigmoid-upscaling',
    'interpolation',
    'blend-subtitles',
    'deband',
    'gpu-dumb-mode',
  ];

  for (final kind in PlayerKind.values) {
    test('${kind.name}: no option takes mpv out of its dumb mode', () {
      final options = {
        ...DesktopPlayerOptions.common(kind),
        ...DesktopPlayerOptions.forOpen(kind, streamed: false),
        ...DesktopPlayerOptions.forOpen(kind, streamed: true),
      };
      expect(options.keys.where(leaveDumbMode.contains), isEmpty);
    });
  }

  test('the cache stays in memory, bounded, and nothing is opened next to the video', () {
    for (final kind in PlayerKind.values) {
      final common = DesktopPlayerOptions.common(kind);
      expect(common['cache-on-disk'], 'no');
      expect(common['ytdl'], 'no');
      expect(common['sub-auto'], 'no');
      expect(common['audio-file-auto'], 'no');
      for (final streamed in [false, true]) {
        final open = DesktopPlayerOptions.forOpen(kind, streamed: streamed);
        expect(int.parse(open['demuxer-max-bytes']!), lessThanOrEqualTo(DesktopPlayerOptions.streamedMaxBytes));
      }
    }
  });
}
