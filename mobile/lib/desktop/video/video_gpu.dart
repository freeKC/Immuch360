// Which graphics card plays a video on a computer that has two, and how mpv decodes it there (design 2.7; the 8K
// stutter reported on 2 November 2026).
//
// The card is chosen for the whole process, once, before anything draws: Windows' graphics preference for the app,
// else the high performance card the runner asks the drivers for (NvOptimusEnablement and
// AmdPowerXpressRequestHighPerformance, windows/runner/main.cpp), else the card that drives the main display. Flutter's
// ANGLE, the Direct3D 11 device and ANGLE display of media_kit_video and mpv's decoder all take that card, so a video
// is decoded where it is drawn and its frames never leave the card (hwdec auto-safe, d3d11va without a copy). Nothing
// here moves a video to another card: its frames would have to go through the computer's memory twice. Measured on an
// i9-13980HX laptop with an Intel UHD and an RTX 4060 Laptop, with an 8K HEVC video from a Samsung S24+ (7680 x 4320,
// 30 fps, 80 Mbit/s), libmpv drawing in its own window on the Intel: d3d11va without a copy dropped none of 450
// frames; the copy back of the Intel's decoder (d3d11va-copy) dropped 166 of 271 and played at 0.6 times the speed;
// the RTX's decoder copied to the Intel (nvdec-copy) kept up but took 1.1 processor cores and a third of the Intel's 3D
// engine, which the app's own drawing already filled. In the app, the Intel's 3D engine was full (95 to 100 %): up to
// 22 of 150 frames dropped and whole black frames; on the RTX none of either.
//
// So what is left to choose is said, not done: when the app runs on the power saving card of a computer that has a high
// performance one, for a video of 4K or more, the video details tell where Windows chooses the card for the app.

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immuch_desktop_video/immuch_desktop_video.dart';

/// What the app knows of the cards: [inUse], the card the app runs on (the decoder probe's default adapter), and
/// [gpus], the cards of the computer; either null where nothing tells it (Linux and macOS for now, a probe that failed)
typedef VideoMachine = ({GpuAdapter? inUse, GpuList? gpus});

/// What the choice says to the user
enum VideoGpuAdvice {
  /// Nothing: the card in use suits the video, or the computer has no other
  none,

  /// The app runs on the power saving card while the computer has a high performance one, and the video is 4K or more:
  /// Windows' graphics setting for the app chooses the card (Settings, System, Display, Graphics)
  useHighPerformanceCard,
}

/// The card that suits a video ([card], null when no card is known), whether the app runs on it ([onIt]), the hwdec
/// its player gets, and what to tell the user
@immutable
class VideoGpuChoice {
  const VideoGpuChoice({required this.card, required this.onIt, required this.hwdec, required this.advice});

  final GpuAdapter? card;
  final bool onIt;
  final String hwdec;
  final VideoGpuAdvice advice;

  @override
  bool operator ==(Object other) =>
      other is VideoGpuChoice &&
      other.card == card &&
      other.onIt == onIt &&
      other.hwdec == hwdec &&
      other.advice == advice;

  @override
  int get hashCode => Object.hash(card, onIt, hwdec, advice);

  @override
  String toString() => 'VideoGpuChoice(${card?.name}, ${onIt ? 'in use' : 'not in use'}, $hwdec, ${advice.name})';
}

/// The pixels of a frame from which the card matters: 4K (3840 x 2160), with a tenth of margin for the crops of the
/// cameras. The 8K video of the report, four times as many pixels, filled the 3D engine of the test laptop's Intel UHD;
/// from 4K on, a video is close enough to that edge for the high performance card to be worth suggesting.
const heavyFramePixels = 3840 * 2160 * 9 ~/ 10;

/// Whether [a] and [b] are the same card: by LUID when both have one (two cards of one model differ there), else by
/// model, driver and name
bool sameGpu(GpuAdapter a, GpuAdapter b) =>
    a.luid.isNotEmpty && b.luid.isNotEmpty ? a.luid == b.luid : a.key == b.key && a.name == b.name;

/// The high performance card of [gpus] when it is another than [inUse] and better suited to a large video: Windows'
/// own answer (IDXGIFactory6) when it gives one, else a card with memory of its own beside an integrated card in use.
/// Null when the card in use is the best the computer has, or when nothing tells.
GpuAdapter? _betterCard(GpuAdapter inUse, GpuList gpus) {
  if (!inUse.integrated) {
    return null;
  }
  final named = gpus.byLuid(gpus.highPerformance);
  final candidates = named != null
      ? [named]
      : [
          for (final gpu in gpus.adapters)
            if (!gpu.integrated) gpu,
        ];
  for (final gpu in candidates) {
    if (!gpu.software && !gpu.integrated && !sameGpu(gpu, inUse)) {
      return gpu;
    }
  }
  return null;
}

/// The card for a video of [width] x [height] on [machine], and the player's hwdec (see the top of this file):
/// - a video of 4K or more ([heavyFramePixels]) suits the high performance card of a computer that has two; the app
///   runs on it when Windows' preference or the drivers put it there, else the user is told where Windows chooses;
/// - any other video, or a computer with one card, suits the card in use;
/// - the hwdec is the app's (DesktopPlayerOptions.hwdec) in every case: mpv decodes on the card in use without a copy
///   when that card has a decoder for the video, and falls back by itself to a copy or to the processor otherwise.
VideoGpuChoice chooseVideoGpu(VideoMachine machine, {required int width, required int height}) {
  final inUse = machine.inUse;
  final gpus = machine.gpus;
  final heavy = width * height >= heavyFramePixels;
  final better = inUse == null || gpus == null || !heavy ? null : _betterCard(inUse, gpus);
  return VideoGpuChoice(
    card: better ?? inUse,
    onIt: better == null && inUse != null,
    hwdec: DesktopPlayerOptions.hwdec,
    advice: better == null ? VideoGpuAdvice.none : VideoGpuAdvice.useHighPerformanceCard,
  );
}

/// How mpv decodes a video, from its hwdec-current
enum VideoDecodingKind {
  /// By the card's video decoder, the frames drawn where they are decoded (d3d11va, nvdec, vaapi, videotoolbox)
  hardware,

  /// By the card's video decoder, each frame copied back to the computer's memory before it is drawn (d3d11va-copy,
  /// nvdec-copy, ...)
  hardwareCopy,

  /// By the processor (FFmpeg's software decoders)
  software,
}

/// The kind of [hwdecCurrent] (mpv's hwdec-current: "no" or nothing for software), null while mpv has not said
VideoDecodingKind? videoDecodingKind(String? hwdecCurrent) {
  final value = hwdecCurrent?.trim() ?? '';
  if (value.isEmpty) {
    return null;
  }
  if (value == 'no') {
    return VideoDecodingKind.software;
  }
  return value.endsWith('-copy') ? VideoDecodingKind.hardwareCopy : VideoDecodingKind.hardware;
}
