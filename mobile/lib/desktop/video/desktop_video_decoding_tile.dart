// "Video decoding" in the details of a video on the computers, in the style of the Video source line: how mpv decodes
// the video playing in the viewer (its own decoder, with a copy, or the processor) and on which graphics card, and,
// when the app runs on the power saving card of a computer that has a high performance one, where Windows chooses the
// card for a 4K or 8K video to play smoothly (video_gpu.dart). Nothing on the phones, nor while no video plays here:
// one video plays at a time on the computers (activeDesktopVideo), the one of the page on screen.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/gpu_decoders.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/desktop/video/video_gpu.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/sheet_tile.widget.dart';
import 'package:immuch_desktop_video/immuch_desktop_video.dart';

/// How a video plays: mpv's hwdec-current and the size of its frames (MediaKitVideoPlayerController.decoding)
typedef VideoDecoding = ({String? hwdec, VideoFrameSize? size});

const _separator = '  •  ';

/// NVIDIA's PCI vendor id: the card of mpv's CUDA decoders
const _nvidia = 0x10DE;

/// The card that decodes with [hwdec] on [machine]: NVIDIA's for mpv's CUDA decoders, which reach it whichever card
/// the app runs on, else the card in use
GpuAdapter? _decodingCard(String hwdec, VideoMachine machine) {
  if (hwdec.startsWith('nvdec') || hwdec.startsWith('cuda')) {
    for (final gpu in machine.gpus?.adapters ?? const <GpuAdapter>[]) {
      if (gpu.vendorId == _nvidia && !gpu.software) {
        return gpu;
      }
    }
  }
  return machine.inUse;
}

/// The lines of the tile: how [decoding] decodes on [machine], and what to do when another card suits it better; null
/// while mpv has not said how it decodes
({String decoder, String? advice})? videoDecodingLines(Translations t, VideoDecoding decoding, VideoMachine machine) {
  final hwdec = decoding.hwdec?.trim() ?? '';
  final kind = videoDecodingKind(hwdec);
  if (kind == null) {
    return null;
  }
  final String decoder;
  if (kind == VideoDecodingKind.software) {
    decoder = t.video_decoding_software;
  } else {
    final card = _decodingCard(hwdec, machine);
    decoder = [
      card == null ? t.video_decoding_hardware_unknown : t.video_decoding_hardware(gpu: card.name),
      if (kind == VideoDecodingKind.hardwareCopy) t.video_decoding_copied,
      hwdec,
    ].join(_separator);
  }
  final size = decoding.size;
  final choice = size == null ? null : chooseVideoGpu(machine, width: size.width, height: size.height);
  final better = choice?.advice == VideoGpuAdvice.useHighPerformanceCard ? choice?.card : null;
  return (decoder: decoder, advice: better == null ? null : t.video_decoding_use_high_performance(gpu: better.name));
}

class DesktopVideoDecodingTile extends StatefulWidget {
  const DesktopVideoDecodingTile({super.key, this.decoding, this.machine});

  /// How the video shown decodes; by default that of the player that played or loaded last (activeDesktopVideo)
  final ValueListenable<VideoDecoding>? decoding;

  /// The cards of the computer, read once per run by default (DesktopGpuDecoders.machine)
  final Future<VideoMachine> Function()? machine;

  @override
  State<DesktopVideoDecodingTile> createState() => _DesktopVideoDecodingTileState();
}

class _DesktopVideoDecodingTileState extends State<DesktopVideoDecodingTile> {
  late final Future<VideoMachine> _machine = (widget.machine ?? DesktopGpuDecoders.machine)();

  @override
  Widget build(BuildContext context) {
    final given = widget.decoding;
    if (given != null) {
      return _tile(given);
    }
    return ValueListenableBuilder<MediaKitVideoPlayerController?>(
      valueListenable: activeDesktopVideo,
      builder: (context, active, _) => active == null ? const SizedBox.shrink() : _tile(active.decoding),
    );
  }

  Widget _tile(ValueListenable<VideoDecoding> decoding) => FutureBuilder<VideoMachine>(
    future: _machine,
    builder: (context, machine) => ValueListenableBuilder<VideoDecoding>(
      valueListenable: decoding,
      builder: (context, value, _) {
        final lines = videoDecodingLines(context.t, value, machine.data ?? (inUse: null, gpus: null));
        if (lines == null) {
          return const SizedBox.shrink();
        }
        final titleStyle = context.textTheme.labelLarge;
        return Column(
          key: const Key('desktop_video_decoding'),
          children: [
            const SizedBox(height: 16),
            SheetTile(
              title: context.t.video_decoding_title,
              titleStyle: titleStyle,
              leading: Icon(Icons.memory_rounded, size: 24, color: titleStyle?.color),
              subtitle: [lines.decoder, ?lines.advice].join('\n'),
              subtitleStyle: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary),
            ),
          ],
        );
      },
    ),
  );
}
