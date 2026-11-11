// The subtitle menu of the flat player on the computers, next to the audio track menu in the controls of the network
// page (NetworkVideoControls): Off, the subtitle tracks of the file, then the side files of subtitles of the video
// (VideoSource.subtitles, served by the media bridge) not read yet. mpv opens no side file by itself (sub-auto): one
// is added to the file the first time it is picked, then shown by its track. Shown for a video with subtitles of
// either kind. A film of a media server shows the names the server gives its tracks, and the server hears of each
// pick (VideoTrackNaming).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/domain/models/video_track_naming.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:native_video_player/native_video_player.dart';

class DesktopSubtitleTrackButton extends StatelessWidget {
  const DesktopSubtitleTrackButton({super.key, this.shadows, this.controller, this.naming});

  final List<Shadow>? shadows;

  /// The player whose subtitles are listed; by default the one that played or loaded last
  final MediaKitVideoPlayerController? controller;

  /// The names a media server gives the tracks and its hook for a pick, null for the player's own names
  final VideoTrackNaming? naming;

  @override
  Widget build(BuildContext context) {
    final given = controller;
    if (given != null) {
      return _SubtitleMenu(controller: given, shadows: shadows, naming: naming);
    }
    return ValueListenableBuilder<MediaKitVideoPlayerController?>(
      valueListenable: activeDesktopVideo,
      builder: (context, active, _) => active == null
          ? const SizedBox.shrink()
          : _SubtitleMenu(controller: active, shadows: shadows, naming: naming),
    );
  }
}

/// A line of the menu: Off (both null), a track of the open file, or a side file not added yet
typedef _Line = ({DesktopSubtitleTrack? track, VideoSubtitle? external, VideoTrackRef? ref, String label});

class _SubtitleMenu extends StatelessWidget {
  const _SubtitleMenu({required this.controller, this.shadows, this.naming});

  final MediaKitVideoPlayerController controller;
  final List<Shadow>? shadows;
  final VideoTrackNaming? naming;

  List<_Line> _lines(Translations t, List<DesktopSubtitleTrack> tracks, List<VideoSubtitle> externals) {
    final naming = this.naming;
    final lines = <_Line>[(track: null, external: null, ref: null, label: t.video_subtitles_off)];
    var ordinal = 0;
    for (final track in tracks) {
      final external = track.isExternal
          ? externals.where((subtitle) => subtitle.uri == track.external).firstOrNull
          : null;
      final String label;
      final VideoTrackRef ref;
      if (external != null) {
        // A side file once added: the same reference and line as before, whatever mpv names it ("external" for a
        // file without a name)
        ref = VideoTrackRef(kind: VideoTrackKind.subtitle, sidecarId: external.id, language: external.language);
        label = naming?.labelOf(ref) ?? externalSubtitleLabel(t, external, lines.length);
      } else {
        ref = track.isExternal
            ? VideoTrackRef(kind: VideoTrackKind.subtitle, language: track.language)
            : VideoTrackRef(kind: VideoTrackKind.subtitle, ordinal: ordinal++, language: track.language);
        label = naming?.labelOf(ref) ?? subtitleTrackLabel(t, track, lines.length);
      }
      lines.add((track: track, external: null, ref: ref, label: label));
    }
    for (final subtitle in externals) {
      if (tracks.any((track) => track.external == subtitle.uri)) {
        continue;
      }
      final ref = VideoTrackRef(kind: VideoTrackKind.subtitle, sidecarId: subtitle.id, language: subtitle.language);
      final label = naming?.labelOf(ref) ?? externalSubtitleLabel(t, subtitle, lines.length);
      lines.add((track: null, external: subtitle, ref: ref, label: label));
    }
    return lines;
  }

  /// Shows the subtitles of [line], then tells the media server, if any
  Future<void> _pick(_Line line) async {
    final external = line.external;
    if (external != null) {
      await controller.selectExternalSubtitle(external);
    } else {
      await controller.selectSubtitleTrack(line.track?.id);
    }
    naming?.picked(VideoTrackKind.subtitle, line.ref);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<VideoSubtitle>>(
      valueListenable: controller.externalSubtitles,
      builder: (context, externals, _) => ValueListenableBuilder<List<DesktopSubtitleTrack>>(
        valueListenable: controller.subtitleTracks,
        builder: (context, tracks, _) {
          if (tracks.isEmpty && externals.isEmpty) {
            return const SizedBox.shrink();
          }
          return ValueListenableBuilder<String?>(
            valueListenable: controller.subtitleTrack,
            builder: (context, current, _) {
              final lines = _lines(context.t, tracks, externals);
              return PopupMenuButton<int>(
                key: const Key('desktop_subtitle_track'),
                tooltip: context.t.video_subtitles,
                icon: Icon(
                  current == null ? Icons.subtitles_outlined : Icons.subtitles,
                  color: Colors.white,
                  shadows: shadows,
                ),
                onSelected: (index) => unawaited(_pick(lines[index])),
                itemBuilder: (context) => [
                  for (final (index, line) in lines.indexed)
                    CheckedPopupMenuItem<int>(
                      value: index,
                      checked: line.external == null && line.track?.id == current,
                      child: Text(line.label),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// The line of [track], a track of the file and the [number]th line of the menu: its title, else its language, else
/// its number; then Forced for forced subtitles
String subtitleTrackLabel(Translations t, DesktopSubtitleTrack track, int number) {
  final title = track.title?.trim();
  final language = track.language?.trim();
  final name = title != null && title.isNotEmpty
      ? title
      : language != null && language.isNotEmpty && language != 'und'
      ? language.toUpperCase()
      : t.video_audio_track_number(track: number);
  return [name, if (track.isForced ?? false) t.video_subtitles_forced].join(' · ');
}

/// The line of [subtitle], a side file of the video and the [number]th line of the menu: its name, else its language,
/// else its number
String externalSubtitleLabel(Translations t, VideoSubtitle subtitle, int number) {
  final label = subtitle.label?.trim();
  final language = subtitle.language?.trim();
  return label != null && label.isNotEmpty
      ? label
      : language != null && language.isNotEmpty
      ? language.toUpperCase()
      : t.video_audio_track_number(track: number);
}
