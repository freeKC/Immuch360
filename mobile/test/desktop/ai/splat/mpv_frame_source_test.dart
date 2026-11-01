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
