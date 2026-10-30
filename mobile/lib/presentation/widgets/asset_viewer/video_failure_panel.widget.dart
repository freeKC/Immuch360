import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/native_playback_error.dart';
import 'package:immich_mobile/domain/services/video_details.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

/// What the user reads about a video that does not play: a [title], the [cause] as far as its file and the decoders of
/// the device tell (null when nothing does), and the [advice] lines, what to do next
typedef VideoFailureText = ({String title, String? cause, List<String> advice});

/// Words for [failure], from [details], what the probe of the file and the decoder check found (null while they are
/// not known). A video nothing on the server decodes says so with what to change in Immich; a file beyond the decoders
/// of the device is the cause whatever the player said; an error the native player put in the words of the app (see
/// NativePlaybackError) is said in ours, with the codec and the size of what played; a stall without a cause is the
/// network or the server. The text of Media3 never shows. [fromServer]: the video came from the server, which can
/// make a copy the device plays. [remote]: the remote control layout of a TV, where the viewer has no menu at the top
/// (Info is a key of the remote).
VideoFailureText describeVideoFailure(
  VideoPlaybackFailure failure,
  VideoDecodeDetails? details,
  Translations t, {
  required bool fromServer,
  required String locale,
  bool remote = false,
}) {
  final probe = details?.probe;
  final verdict = details?.verdict;
  final codec = probe?.codec;
  final width = probe?.codedWidth;
  final height = probe?.codedHeight;
  final retry = remote ? t.video_failed_retry_hint_tv : t.video_failed_retry_hint;
  final refusal = failure.refusal;
  if (failure.kind == VideoFailureKind.refused && refusal != null) {
    return (title: t.video_failed_title, cause: refusal.message(t), advice: [retry]);
  }
  if (verdict != null && !verdict.supported && codec != null && width != null && height != null) {
    final name = videoCodecName(codec);
    final cause = verdict.maxWidth > 0 && verdict.maxHeight > 0
        ? t.video_failed_beyond_decoders(
            codec: name,
            width: '$width',
            height: '$height',
            maxWidth: '${verdict.maxWidth}',
            maxHeight: '${verdict.maxHeight}',
          )
        : t.video_failed_no_decoder(codec: name);
    return (title: t.video_failed_title, cause: cause, advice: [if (fromServer) t.video_failed_server_hint, retry]);
  }
  final native = failure.native;
  if (native != null) {
    final nativeCodec = native.codec;
    final known = nativeCodec != null && native.width > 0 && native.height > 0;
    final serverHint = [if (fromServer) t.video_failed_server_hint];
    switch (native.kind) {
      case NativePlaybackErrorKind.noFrame when known:
        return (
          title: t.video_failed_title,
          cause: t.video_error_no_frame(codec: nativeCodec, width: '${native.width}', height: '${native.height}'),
          advice: [...serverHint, retry],
        );
      case NativePlaybackErrorKind.decoder when known:
        return (
          title: t.video_failed_title,
          cause: t.video_error_decoder(codec: nativeCodec, width: '${native.width}', height: '${native.height}'),
          advice: [...serverHint, retry],
        );
      case NativePlaybackErrorKind.stalled:
        break;
      default:
        return (title: t.video_failed_title, cause: null, advice: [retry]);
    }
  }
  if (failure.kind == VideoFailureKind.stalled || native?.kind == NativePlaybackErrorKind.stalled) {
    final bitRate = details?.bitRate;
    final cause = bitRate != null
        ? t.video_stalled_bit_rate(rate: formatBitRate(bitRate.bitsPerSecond, t, locale: locale))
        : t.video_stalled_slow;
    return (title: t.video_stalled_title, cause: cause, advice: [retry]);
  }
  final message = failure.message?.trim();
  final shown = message == null || message.isEmpty || isMedia3StuckText(message) ? null : message;
  return (title: t.video_failed_title, cause: shown, advice: [retry]);
}

/// In place of a video that does not play ([VideoPlaybackStatus.failed]), over its poster: why, and what to do. Not
/// focusable: play, in the controls, tries again, and Info shows the file (see [describeVideoFailure]).
class VideoFailurePanel extends ConsumerWidget {
  const VideoFailurePanel({super.key, required this.asset, required this.failure, required this.fromServer});

  final BaseAsset asset;
  final VideoPlaybackFailure failure;

  /// Whether the video came from the server rather than from a copy on the device
  final bool fromServer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final details = ref.watch(videoDecodeDetailsProvider(asset)).valueOrNull;
    final text = describeVideoFailure(
      failure,
      details,
      context.t,
      fromServer: fromServer,
      locale: context.locale.toLanguageTag(),
      remote: ref.watch(tvModeProvider),
    );
    final textTheme = context.textTheme;
    return Center(
      child: Container(
        key: const Key('video_failure_panel'),
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: const BorderRadius.all(Radius.circular(12)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              failure.kind == VideoFailureKind.stalled ? Icons.hourglass_empty_rounded : Icons.error_outline_rounded,
              color: Colors.white,
              size: 40,
            ),
            const SizedBox(height: 12),
            Text(
              text.title,
              textAlign: TextAlign.center,
              style: textTheme.titleMedium?.copyWith(color: Colors.white),
            ),
            if (text.cause != null) ...[
              const SizedBox(height: 8),
              Text(
                text.cause!,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(color: Colors.white),
              ),
            ],
            for (final line in text.advice) ...[
              const SizedBox(height: 8),
              Text(
                line,
                textAlign: TextAlign.center,
                style: textTheme.bodySmall?.copyWith(color: Colors.white70),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
