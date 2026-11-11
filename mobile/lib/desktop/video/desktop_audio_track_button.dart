// The audio track menu of the flat player on the computers, in the existing controls of the viewer and of the network
// page (VideoControls, NetworkVideoControls): shown only for a video with two tracks or more, as the phones' 360°
// players show theirs, with the same labels (video_audio_track.dart). The language picked is chosen first for the
// next videos of the session. A film of a media server shows the names the server gives its tracks, and the server
// hears of each pick (VideoTrackNaming).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/domain/models/video_track_naming.dart';
import 'package:immich_mobile/generated/translations.g.dart';

class DesktopAudioTrackButton extends StatelessWidget {
  const DesktopAudioTrackButton({super.key, this.shadows, this.controller, this.naming});

  final List<Shadow>? shadows;

  /// The player whose tracks are listed; by default the one that played or loaded last
  final MediaKitVideoPlayerController? controller;

  /// The names a media server gives the tracks and its hook for a pick, null for the player's own names
  final VideoTrackNaming? naming;

  @override
  Widget build(BuildContext context) {
    final given = controller;
    if (given != null) {
      return _TrackMenu(controller: given, shadows: shadows, naming: naming);
    }
    return ValueListenableBuilder<MediaKitVideoPlayerController?>(
      valueListenable: activeDesktopVideo,
      builder: (context, active, _) =>
          active == null ? const SizedBox.shrink() : _TrackMenu(controller: active, shadows: shadows, naming: naming),
    );
  }
}

class _TrackMenu extends StatelessWidget {
  const _TrackMenu({required this.controller, this.shadows, this.naming});

  final MediaKitVideoPlayerController controller;
  final List<Shadow>? shadows;
  final VideoTrackNaming? naming;

  /// Plays the track [id] of [tracks], then tells the media server, if any
  Future<void> _pick(List<DesktopAudioTrack> tracks, String id) async {
    await controller.selectAudioTrack(id);
    final index = tracks.indexWhere((track) => track.id == id);
    if (index >= 0) {
      naming?.picked(VideoTrackKind.audio, desktopAudioTrackRef(tracks[index], index));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<DesktopAudioTrack>>(
      valueListenable: controller.audioTracks,
      builder: (context, tracks, _) {
        if (tracks.length < 2) {
          return const SizedBox.shrink();
        }
        return ValueListenableBuilder<String?>(
          valueListenable: controller.audioTrack,
          builder: (context, current, _) => PopupMenuButton<String>(
            key: const Key('desktop_audio_track'),
            tooltip: context.t.video_audio_track,
            icon: Icon(Icons.audiotrack_outlined, color: Colors.white, shadows: shadows),
            onSelected: (id) => unawaited(_pick(tracks, id)),
            itemBuilder: (context) => [
              for (final (index, track) in tracks.indexed)
                CheckedPopupMenuItem<String>(
                  value: track.id,
                  checked: track.id == current,
                  child: Text(
                    naming?.labelOf(desktopAudioTrackRef(track, index)) ?? audioTrackLabel(context.t, track, index),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// [track], the [index]th audio track of the file, as a media server knows it (VideoTrackNaming)
VideoTrackRef desktopAudioTrackRef(DesktopAudioTrack track, int index) =>
    VideoTrackRef(kind: VideoTrackKind.audio, ordinal: index, language: track.language);

/// The line of [track], the [index]th of the file, in the menu: its title, else its language, else its number; then
/// its channels and whether the file marks it as the default
String audioTrackLabel(Translations t, DesktopAudioTrack track, int index) {
  final title = track.title?.trim();
  final language = track.language?.trim();
  final name = title != null && title.isNotEmpty
      ? title
      : language != null && language.isNotEmpty && language != 'und'
      ? language.toUpperCase()
      : t.video_audio_track_number(track: index + 1);
  final channels = switch (track.channels) {
    null || <= 0 => null,
    1 => t.video_audio_track_mono,
    2 => t.video_audio_track_stereo,
    final count => t.video_audio_track_channels(channels: count),
  };
  return [name, ?channels, if (track.isDefault ?? false) t.video_audio_track_default].join(' · ');
}
