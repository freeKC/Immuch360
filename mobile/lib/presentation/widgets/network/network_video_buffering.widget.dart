import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/video_details.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_loading_line.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';

/// "Buffering…" with a spinner over the video of a network share while it loads or stalls, for the player of
/// [videoPlayerProvider] under [playerKey]. A stall is a position that does not move for [stallDelay] while the video
/// plays, or the native player waiting; the indicator hides as soon as the position moves again, or when the video
/// pauses or ends. [loading] shows it too, before the native player is ready. With the [link] of the player (see
/// VideoLinkView): what the share brings against what the video needs, that it will pause now and then when the share
/// is too slow for it, and that the share stopped sending, the video playing on by itself once it answers. Where the
/// player tells nothing of its link (iOS), that nothing played for a minute.
class NetworkVideoBufferingIndicator extends ConsumerStatefulWidget {
  const NetworkVideoBufferingIndicator({super.key, required this.playerKey, this.loading = false, this.link});

  /// How long the position may stay still while the video plays before the indicator shows
  static const stallDelay = Duration(milliseconds: 700);

  /// How often the position is checked while the video plays
  static const _checkInterval = Duration(milliseconds: 100);

  final String playerKey;
  final bool loading;
  final ValueListenable<VideoLinkView?>? link;

  @override
  ConsumerState<NetworkVideoBufferingIndicator> createState() => _NetworkVideoBufferingIndicatorState();
}

class _NetworkVideoBufferingIndicatorState extends ConsumerState<NetworkVideoBufferingIndicator> {
  Timer? _timer;

  /// Whether the position moved since the last check
  bool _moved = false;

  /// Time spent without a move of the position while the video plays
  Duration _still = Duration.zero;
  bool _stalled = false;

  @override
  void initState() {
    super.initState();
    _follow(ref.read(videoPlayerProvider(widget.playerKey)).status);
  }

  @override
  void didUpdateWidget(NetworkVideoBufferingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playerKey != widget.playerKey) {
      _follow(ref.read(videoPlayerProvider(widget.playerKey)).status);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static bool _isPlaying(VideoPlaybackStatus status) =>
      status == VideoPlaybackStatus.playing || status == VideoPlaybackStatus.buffering;

  /// Checks the position while the video plays, and forgets any stall otherwise
  void _follow(VideoPlaybackStatus status) {
    _moved = false;
    _still = Duration.zero;
    if (!_isPlaying(status)) {
      _timer?.cancel();
      _timer = null;
      _setStalled(false);
      return;
    }
    _timer ??= Timer.periodic(NetworkVideoBufferingIndicator._checkInterval, (_) => _check());
  }

  void _check() {
    if (_moved) {
      _moved = false;
      _still = Duration.zero;
      return;
    }
    _still += NetworkVideoBufferingIndicator._checkInterval;
    if (_still >= NetworkVideoBufferingIndicator.stallDelay) {
      _setStalled(true);
    }
  }

  void _onPositionChanged() {
    _moved = true;
    _still = Duration.zero;
    _setStalled(false);
  }

  void _setStalled(bool stalled) {
    if (_stalled != stalled && mounted) {
      setState(() => _stalled = stalled);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = videoPlayerProvider(widget.playerKey);
    ref.listen(provider.select((state) => state.status), (previous, status) => _follow(status));
    ref.listen(provider.select((state) => state.position), (previous, position) => _onPositionChanged());
    final status = ref.watch(provider.select((state) => state.status));

    final link = widget.link;
    if (link == null) {
      return _box(context, status, null);
    }
    return ValueListenableBuilder<VideoLinkView?>(
      valueListenable: link,
      builder: (context, view, _) => _box(context, status, view),
    );
  }

  Widget _box(BuildContext context, VideoPlaybackStatus status, VideoLinkView? view) {
    final failure = status == VideoPlaybackStatus.failed
        ? ref.read(videoPlayerProvider(widget.playerKey).notifier).failure?.kind
        : null;
    final dead = failure == VideoFailureKind.dead || (status == VideoPlaybackStatus.failed && (view?.dead ?? false));
    // Nothing played for a minute where the player tells nothing of its link (iOS): said here too, the page has no
    // other word for it (review of 1 November 2026: a still picture with no word)
    final stalled = failure == VideoFailureKind.stalled;
    final visible =
        dead ||
        stalled ||
        widget.loading ||
        status == VideoPlaybackStatus.buffering ||
        (_stalled && _isPlaying(status));
    if (!visible) {
      return const SizedBox.shrink();
    }
    final t = context.t;
    final locale = context.locale.toLanguageTag();
    final lines = <String>[
      if (dead) ...[
        t.video_link_stopped_share,
        t.video_link_resumes_share,
      ] else if (stalled) ...[
        t.video_stalled_title,
        t.video_stalled_no_progress,
      ] else
        '${t.video_buffering_simple}…',
      if (!dead && !stalled) ?videoLoadingText(view, t, locale: locale),
      if (!dead &&
          !stalled &&
          view != null &&
          view.slow &&
          view.bitsPerSecond != null &&
          view.neededBitsPerSecond != null)
        t.video_slow_share(
          got: formatBitRate(view.bitsPerSecond!, t, locale: locale),
          need: formatBitRate(view.neededBitsPerSecond!, t, locale: locale),
        ),
    ];
    return Center(
      child: DecoratedBox(
        key: const Key('network_video_buffering'),
        decoration: const BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.all(Radius.circular(12))),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Colors.white70),
                for (final (index, line) in lines.indexed) ...[
                  SizedBox(height: index == 0 ? 12 : 8),
                  Text(
                    line,
                    textAlign: TextAlign.center,
                    style: index == 0
                        ? const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)
                        : const TextStyle(color: Colors.white70),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
