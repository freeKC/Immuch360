// Which way a screenshot of mpv is turned (lot SP5, mpv_frame_source.dart): the libmpv of the Linux distributions
// turns the frames of a video filmed upright before the null output of a player without texture, the app's Windows
// build leaves the rotation to its output and gives them lying (the CI of 1 November 2026: 320 x 180 for a video of
// 180 x 320). The real decoding of both is video_frames_libmpv_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/splat/mpv_frame_source.dart';

void main() {
  int turns(int file, int output, (int, int) decoded, (int, int) shot) => splatScreenshotTurns(
    fileRotation: file,
    outputRotation: output,
    decodedWidth: decoded.$1,
    decodedHeight: decoded.$2,
    shotWidth: shot.$1,
    shotHeight: shot.$2,
  );

  test('a portrait video of a phone: turned already by mpv 0.34 and 0.35, a quarter turn to do on Windows', () {
    // Debian 12 and Ubuntu 22.04: a rotation filter, nothing left to the output, the screenshot upright
    expect(turns(90, 0, (320, 180), (180, 320)), 0);
    // The build of the app on Windows: the rotation left to the output, the screenshot as decoded
    expect(turns(90, 90, (320, 180), (320, 180)), 1);
    // Whatever mpv says it leaves to its output, the size decides
    expect(turns(90, 0, (320, 180), (320, 180)), 1);
    expect(turns(90, 90, (320, 180), (180, 320)), 0);
    expect(turns(270, 270, (1920, 1080), (1920, 1080)), 3);
    expect(turns(270, 0, (1920, 1080), (1080, 1920)), 0);
  });

  test('frames scaled by mpv as they are decoded: the orientation of the screenshot tells, not its size', () {
    // FreeKC's 8K video of 2 November, had it been filmed upright: decoded lying, scaled to 1 600 pixels
    expect(turns(90, 90, (7680, 4320), (1600, 900)), 1, reason: 'the build of the app on Windows');
    expect(turns(90, 0, (7680, 4320), (900, 1600)), 0, reason: 'a libmpv that turned it before its output');
    expect(turns(270, 270, (3840, 2160), (1600, 900)), 3);
    expect(turns(180, 180, (7680, 4320), (1600, 900)), 2);
    expect(turns(0, 0, (7680, 4320), (1600, 900)), 0);
  });

  test('a video over twice the frames written is scaled by mpv as it is decoded, to their long side', () {
    String? scale(int width, int height) =>
        splatDecodeScale(decodedWidth: width, decodedHeight: height, longSide: 1600, maxDecodedSide: 3200);
    expect(scale(7680, 4320), 'lavfi-scale=w=1600:h=-2:flags=area', reason: 'FreeKC\'s 8K video');
    expect(scale(4320, 7680), 'lavfi-scale=w=-2:h=1600:flags=area', reason: 'decoded upright');
    expect(scale(3840, 2160), 'lavfi-scale=w=1600:h=-2:flags=area', reason: '4K');
    expect(scale(5760, 2880), 'lavfi-scale=w=1600:h=-2:flags=area', reason: 'a 360 video of 5.7K, were it taken');
    expect(scale(3200, 1800), isNull, reason: 'twice the frames written at most: as decoded');
    expect(scale(1920, 1080), isNull);
    expect(scale(0, 0), isNull, reason: 'a size mpv did not give');
    expect(MpvSplatFrameSource().maxDecodedSide, 3200);
  });

  test('a half turn and a square video: what mpv leaves to its output', () {
    expect(turns(180, 180, (1920, 1080), (1920, 1080)), 2);
    expect(turns(180, 0, (1920, 1080), (1920, 1080)), 0);
    expect(turns(90, 90, (1080, 1080), (1080, 1080)), 1);
    expect(turns(90, 0, (1080, 1080), (1080, 1080)), 0);
  });

  test('a video without rotation, or with one that is not a quarter turn, is left as it is', () {
    expect(turns(0, 0, (1920, 1080), (1920, 1080)), 0);
    expect(turns(45, 45, (1920, 1080), (1920, 1080)), 0);
    expect(turns(360, 0, (1920, 1080), (1920, 1080)), 0);
  });
}
