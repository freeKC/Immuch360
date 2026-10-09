import 'dart:math';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/colors.dart';
import 'package:immich_mobile/desktop/video/desktop_audio_track_button.dart';
import 'package:immich_mobile/extensions/duration_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/widgets/asset_viewer/animated_play_pause.dart';

const _shadows = [Shadow(color: Colors.black87, blurRadius: 6, offset: Offset(0, 1))];

/// Play, pause and seek for the player of a video of a network share, the one of [videoPlayerProvider] under
/// [playerKey]
class NetworkVideoControls extends ConsumerWidget {
  const NetworkVideoControls({super.key, required this.playerKey, this.playFocusNode});

  final String playerKey;

  /// The focus of the play button, for the page to put the remote there
  final FocusNode? playFocusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = videoPlayerProvider(playerKey);
    final (position, duration, status) = ref.watch(provider.select((v) => (v.position, v.duration, v.status)));
    final notifier = ref.watch(provider.notifier);
    final isPlaying = status == VideoPlaybackStatus.playing || status == VideoPlaybackStatus.buffering;
    final isFinished = status == VideoPlaybackStatus.completed;
    final isLoaded = duration != Duration.zero;

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Row(
            children: [
              IconButton(
                key: const Key('network_video_play_pause'),
                focusNode: playFocusNode,
                iconSize: 32,
                padding: const EdgeInsets.all(12),
                constraints: const BoxConstraints(),
                tooltip: isPlaying ? context.t.pause : context.t.play,
                icon: isFinished
                    ? const Icon(Icons.replay, color: Colors.white, shadows: _shadows)
                    : AnimatedPlayPause(color: Colors.white, playing: isPlaying, shadows: _shadows),
                onPressed: notifier.toggle,
              ),
              // The computers' player lists the audio tracks of a video that has several
              if (CurrentPlatform.isDesktop) const DesktopAudioTrackButton(shadows: _shadows),
              const Spacer(),
              IgnorePointer(
                child: Text(
                  '${position.format()} / ${duration.format()}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                    fontFeatures: [FontFeature.tabularFigures()],
                    shadows: _shadows,
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
          // On a TV the page seeks with left and right: a focused slider would keep the arrows (Flutter issue 54984)
          ExcludeFocus(
            excluding: ref.watch(tvModeProvider),
            child: Slider(
              value: min(position.inMicroseconds.toDouble(), duration.inMicroseconds.toDouble()),
              min: 0,
              max: max(duration.inMicroseconds.toDouble(), 1),
              thumbColor: Colors.white,
              activeColor: Colors.white,
              inactiveColor: whiteOpacity75,
              padding: EdgeInsets.zero,
              onChangeStart: (_) => notifier.hold(),
              onChangeEnd: (_) => notifier.release(),
              onChanged: isLoaded ? (value) => notifier.seekTo(Duration(microseconds: value.toInt())) : null,
            ),
          ),
        ],
      ),
    );
  }
}
