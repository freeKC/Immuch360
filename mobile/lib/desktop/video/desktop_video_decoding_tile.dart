// "Video decoding" in the details of a video on the computers, in the style of the Video source line: how mpv decodes
// the video playing in the viewer (its own decoder, with a copy, or the processor) and on which graphics card, and,
// when the app runs on the power saving card of a computer that has a high performance one, where Windows chooses the
// card for a 4K or 8K video to play smoothly (video_gpu.dart). While the server's copy of a video plays because its
// original is beyond this computer, that advice is about the original: on the high performance card, the original
// would play. Nothing on the phones, nor while no video plays here: one video plays at a time on the computers
// (activeDesktopVideo), the one of the page on screen.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/gpu_decoders.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/desktop/video/video_gpu.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/sheet_tile.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
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

/// The frame of the original of a server video while the server's copy plays in its place because the original is
/// beyond this computer ([chosen], what the player chose: the copy, with the notice that it switched, which holds the
/// original's size as its probe read it); null while the original plays, and when the settings or the user chose the
/// copy, since another card would not play the original then
VideoFrameSize? originalInPlaceOfCopy(ChosenVideoSource? chosen) {
  final notice = chosen?.notice;
  return chosen?.kind == VideoSourceKind.transcoded && notice != null && notice.kind == VideoSourceNoticeKind.switched
      ? (width: notice.width, height: notice.height)
      : null;
}

/// The lines of the tile: how [decoding] decodes on [machine], and what to do when another card suits it better, for
/// the [original] while the server's copy plays in its place (never larger than its original), else for the frame that
/// plays; null while mpv has not said how it decodes
({String decoder, String? advice})? videoDecodingLines(
  Translations t,
  VideoDecoding decoding,
  VideoMachine machine, {
  VideoFrameSize? original,
}) {
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
  final size = original ?? decoding.size;
  final choice = size == null ? null : chooseVideoGpu(machine, width: size.width, height: size.height);
  final better = choice?.advice == VideoGpuAdvice.useHighPerformanceCard ? choice?.card : null;
  return (decoder: decoder, advice: better == null ? null : t.video_decoding_use_high_performance(gpu: better.name));
}

class DesktopVideoDecodingTile extends StatefulWidget {
  const DesktopVideoDecodingTile({super.key, this.asset, this.decoding, this.machine});

  /// The video of the details: what the player chose for it (chosenVideoSourcesProvider) tells when the server's copy
  /// plays in place of its original
  final BaseAsset? asset;

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
    final videoId = widget.asset?.remoteId;
    if (videoId == null) {
      return _playing(null);
    }
    return Consumer(
      builder: (context, ref, _) =>
          _playing(originalInPlaceOfCopy(ref.watch(chosenVideoSourcesProvider.select((sources) => sources[videoId])))),
    );
  }

  Widget _playing(VideoFrameSize? original) {
    final given = widget.decoding;
    if (given != null) {
      return _tile(given, original);
    }
    return ValueListenableBuilder<MediaKitVideoPlayerController?>(
      valueListenable: activeDesktopVideo,
      builder: (context, active, _) => active == null ? const SizedBox.shrink() : _tile(active.decoding, original),
    );
  }

  Widget _tile(ValueListenable<VideoDecoding> decoding, VideoFrameSize? original) => FutureBuilder<VideoMachine>(
    future: _machine,
    builder: (context, machine) => ValueListenableBuilder<VideoDecoding>(
      valueListenable: decoding,
      builder: (context, value, _) {
        final lines = videoDecodingLines(
          context.t,
          value,
          machine.data ?? (inUse: null, gpus: null),
          original: original,
        );
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
