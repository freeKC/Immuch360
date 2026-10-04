// The video decoders of the device and their limits, opened from Settings > Advanced: what tells why a large 360°
// video stutters or does not play, and what the players check before they pick the original of a video (see
// chooseVideoSource). The copy button puts a plain text report on the clipboard, for a bug report.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';

const _separator = '  •  ';

/// Every video decoder of the device (see [videoDecodersProvider]), grouped by codec: its name, whether it is a
/// hardware decoder, its largest frame, and the frame rate it reaches at that size when the system tells.
class VideoDecodersPage extends ConsumerWidget {
  const VideoDecodersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final decoders = ref.watch(videoDecodersProvider);
    final listed = decoders.valueOrNull;
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        title: Text(context.t.video_decoders_title),
        centerTitle: false,
        actions: [
          if (listed != null && listed.isNotEmpty)
            TextButton.icon(
              onPressed: () => unawaited(_copy(context, listed)),
              icon: const Icon(Icons.copy_rounded),
              label: Text(context.t.video_decoders_copy),
            ),
        ],
      ),
      body: decoders.when(
        data: (decoders) => decoders.isEmpty
            ? Center(child: Text(context.t.no_results))
            : _DecoderList(groups: groupVideoDecoders(decoders)),
        // An iPhone without the check, or a failure of the system: nothing to list
        error: (_, _) => Center(child: Text(context.t.errors.something_went_wrong)),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  Future<void> _copy(BuildContext context, List<DecoderInfo> decoders) async {
    final report = videoDecodersReport(
      decoders,
      system: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    );
    await Clipboard.setData(ClipboardData(text: report));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.t.video_decoders_copied)));
  }
}

class _DecoderList extends StatelessWidget {
  const _DecoderList({required this.groups});

  final List<(String, List<DecoderInfo>)> groups;

  @override
  Widget build(BuildContext context) {
    final secondary = context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary);
    return ListView(
      padding: const EdgeInsets.only(bottom: 48),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(context.t.video_decoders_subtitle, style: secondary),
        ),
        for (final (codec, decoders) in groups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
            child: Text(
              [videoCodecName(codec), if (videoCodecName(codec) != codec) codec].join(_separator),
              style: context.textTheme.titleSmall?.copyWith(color: context.primaryColor),
            ),
          ),
          for (final decoder in decoders)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: Icon(decoder.hardware ? Icons.memory_rounded : Icons.code_rounded),
              title: Text(decoder.name, style: context.textTheme.labelLarge),
              subtitle: Text(
                [
                  decoder.hardware ? context.t.video_decoders_hardware : context.t.video_decoders_software,
                  context.t.video_decoders_max(width: '${decoder.maxWidth}', height: '${decoder.maxHeight}'),
                  if (decoder.maxFrameRate > 0) '${formatFrameRate(decoder.maxFrameRate)} fps',
                ].join(_separator),
                style: secondary,
              ),
            ),
        ],
      ],
    );
  }
}

/// [decoders] grouped by the codec they decode, the codecs and the decoders of each in the order the system lists
/// them: its preferred decoder first
@visibleForTesting
List<(String, List<DecoderInfo>)> groupVideoDecoders(List<DecoderInfo> decoders) {
  final groups = <String, List<DecoderInfo>>{};
  for (final decoder in decoders) {
    (groups[decoder.codec] ??= []).add(decoder);
  }
  return [for (final MapEntry(:key, :value) in groups.entries) (key, value)];
}

/// The decoders as plain text, for a bug report: not translated, like the logs. [system] names the system they come
/// from, when given.
@visibleForTesting
String videoDecodersReport(List<DecoderInfo> decoders, {String? system}) {
  final lines = ['Video decoders${system == null ? '' : ' ($system)'}'];
  for (final (codec, group) in groupVideoDecoders(decoders)) {
    lines.add('${videoCodecName(codec)} ($codec)');
    for (final decoder in group) {
      lines.add(
        [
          '  ${decoder.name}: ${decoder.hardware ? 'hardware' : 'software'}',
          'up to ${decoder.maxWidth} x ${decoder.maxHeight}',
          if (decoder.maxFrameRate > 0) '${formatFrameRate(decoder.maxFrameRate)} fps',
        ].join(', '),
      );
    }
  }
  return lines.join('\n');
}
