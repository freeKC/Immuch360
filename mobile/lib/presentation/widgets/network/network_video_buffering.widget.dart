import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';

/// "Buffering…" with a spinner over the video of a network share while it loads or stalls, for the player of
/// [videoPlayerProvider] under [playerKey]. The native player reports no buffering state, so a stall is a position
/// that does not move for [stallDelay] while the video plays; the indicator hides as soon as the position moves
/// again, or when the video pauses or ends. [loading] shows it too, before the native player is ready.
class NetworkVideoBufferingIndicator extends ConsumerStatefulWidget {
  const NetworkVideoBufferingIndicator({super.key, required this.playerKey, this.loading = false});

  /// How long the position may stay still while the video plays before the indicator shows
  static const stallDelay = Duration(milliseconds: 700);

  /// How often the position is checked while the video plays
  static const _checkInterval = Duration(milliseconds: 100);

  final String playerKey;
  final bool loading;

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

    final visible = widget.loading || status == VideoPlaybackStatus.buffering || (_stalled && _isPlaying(status));
    if (!visible) {
      return const SizedBox.shrink();
    }
    return Center(
      child: DecoratedBox(
        key: const Key('network_video_buffering'),
        decoration: const BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.all(Radius.circular(12))),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.white70),
              const SizedBox(height: 12),
              Text(
                '${context.t.video_buffering_simple}…',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
