import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/video_track_naming.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:native_video_player/native_video_player.dart';

/// The audio track and subtitle menus of the flat video player of the phones, TVs and headsets, in the controls of the
/// viewer and of the share video page, for the player of [videoPlayerProvider] under [playerKey]: the audio menu for a
/// video with two audio tracks or more, the subtitle menu, with Off, for a video with subtitles. Reached with the
/// remote like the other buttons of the controls. Nothing where the player lists no tracks (iOS); the computers have
/// their own audio track menu (DesktopAudioTrackButton). A film of a media server shows the names the server gives
/// its tracks, and the server hears of each pick ([naming]).
class VideoTrackButtons extends ConsumerStatefulWidget {
  const VideoTrackButtons({super.key, required this.playerKey, this.shadows, this.naming});

  final String playerKey;
  final List<Shadow>? shadows;

  /// The names a media server gives the tracks and its hook for a pick, null for the player's own names
  final VideoTrackNaming? naming;

  @override
  ConsumerState<VideoTrackButtons> createState() => _VideoTrackButtonsState();
}

class _VideoTrackButtonsState extends ConsumerState<VideoTrackButtons> {
  List<NativeVideoTrack> _tracks = const [];

  /// What tells that the tracks may have changed, see [VideoPlayerNotifier.tracksChanged]
  ValueListenable<int>? _changes;

  /// The language of the app, the one the languages of the tracks are named in
  String? _locale;

  /// Bumped by each listing, so that an older one that ends late is dropped
  int _listing = 0;

  VideoPlayerNotifier get _notifier => ref.read(videoPlayerProvider(widget.playerKey).notifier);

  @override
  void initState() {
    super.initState();
    // The controls show again: the menus are there at once, the native player confirms the tracks after
    _tracks = _notifier.lastTracks;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listen();
    final locale = Localizations.localeOf(context).toLanguageTag();
    if (locale != _locale) {
      _locale = locale;
      unawaited(_refresh());
    }
  }

  @override
  void didUpdateWidget(covariant VideoTrackButtons oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playerKey != widget.playerKey) {
      _listen();
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _changes?.removeListener(_onChanged);
    super.dispose();
  }

  void _listen() {
    final changes = _notifier.tracksChanged;
    if (identical(changes, _changes)) {
      return;
    }
    _changes?.removeListener(_onChanged);
    _changes = changes..addListener(_onChanged);
  }

  void _onChanged() => unawaited(_refresh());

  Future<void> _refresh() async {
    final listing = ++_listing;
    final tracks = await _notifier.tracks(locale: _locale);
    if (mounted && listing == _listing && !listEquals(tracks, _tracks)) {
      setState(() => _tracks = tracks);
    }
  }

  /// Plays [track] (null: subtitles off), then tells the media server, if any, which track of [kind] that is ([ref])
  Future<void> _pick(VideoTrackKind kind, NativeVideoTrack? track, VideoTrackRef? ref) async {
    if (track == null) {
      await _notifier.disableTracks(NativeVideoTrackType.text);
    } else {
      await _notifier.selectTrack(track);
    }
    widget.naming?.picked(kind, ref);
  }

  /// The lines of [tracks], the names of [naming] first where it gives one
  List<String> _labels(Translations t, List<NativeVideoTrack> tracks, List<VideoTrackRef> refs) {
    final naming = widget.naming;
    return [for (final (index, label) in videoTrackLabels(t, tracks).indexed) naming?.labelOf(refs[index]) ?? label];
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final audio = _tracks.where((track) => track.type == NativeVideoTrackType.audio).toList();
    final subtitles = _tracks.where((track) => track.type == NativeVideoTrackType.text).toList();
    final subtitlesOn = subtitles.any((track) => track.selected);
    final audioRefs = videoTrackRefs(audio);
    final subtitleRefs = videoTrackRefs(subtitles);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (audio.length >= 2)
          PopupMenuButton<int>(
            key: const Key('video_audio_tracks'),
            tooltip: t.video_audio_track,
            iconSize: 28,
            padding: const EdgeInsets.all(12),
            icon: Icon(Icons.audiotrack_outlined, color: Colors.white, shadows: widget.shadows),
            onSelected: (index) => unawaited(_pick(VideoTrackKind.audio, audio[index], audioRefs[index])),
            itemBuilder: (context) => [
              for (final (index, label) in _labels(t, audio, audioRefs).indexed)
                _trackItem(index, label, checked: audio[index].selected),
            ],
          ),
        if (subtitles.isNotEmpty)
          PopupMenuButton<int>(
            key: const Key('video_subtitles'),
            tooltip: t.video_subtitles,
            iconSize: 28,
            padding: const EdgeInsets.all(12),
            icon: Icon(
              subtitlesOn ? Icons.subtitles : Icons.subtitles_outlined,
              color: Colors.white,
              shadows: widget.shadows,
            ),
            onSelected: (index) => unawaited(
              index < 0
                  ? _pick(VideoTrackKind.subtitle, null, null)
                  : _pick(VideoTrackKind.subtitle, subtitles[index], subtitleRefs[index]),
            ),
            itemBuilder: (context) => [
              _trackItem(-1, t.video_subtitles_off, checked: !subtitlesOn),
              for (final (index, label) in _labels(t, subtitles, subtitleRefs).indexed)
                _trackItem(index, label, checked: subtitles[index].selected),
            ],
          ),
      ],
    );
  }
}

/// A line of a track menu, with a check mark when [checked]; the menu opens with the remote on that line. Not a
/// CheckedPopupMenuItem: its ListTile is a focus stop of its own under the remote control layout (where controls
/// without an action stay focusable), so that Down from a line landed on that tile, which OK does not pick, and the
/// menu stayed open.
PopupMenuItem<int> _trackItem(int value, String label, {required bool checked}) => PopupMenuItem<int>(
  value: value,
  child: _FocusWhenOpen(
    focus: checked,
    child: Row(
      spacing: 12,
      children: [
        SizedBox.square(dimension: 24, child: checked ? const Icon(Icons.check, size: 24) : null),
        Flexible(child: Text(label)),
      ],
    ),
  ),
);

/// Gives the focus to the menu line around it once it is built, when [focus]: the line of the track that plays
class _FocusWhenOpen extends StatefulWidget {
  const _FocusWhenOpen({required this.focus, required this.child});

  final bool focus;
  final Widget child;

  @override
  State<_FocusWhenOpen> createState() => _FocusWhenOpenState();
}

class _FocusWhenOpenState extends State<_FocusWhenOpen> {
  @override
  void initState() {
    super.initState();
    if (widget.focus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Focus.maybeOf(context)?.requestFocus();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// [tracks], all of one kind, as a media server knows them (VideoTrackNaming): an audio track by its place among the
/// audio tracks; a subtitle track from a side file the app gave the player by the id of that file (sidecarIdOfTrack),
/// one of the file by its place among the subtitle tracks of the file, the side files left out of the count
List<VideoTrackRef> videoTrackRefs(List<NativeVideoTrack> tracks) {
  var ordinal = 0;
  return [
    for (final track in tracks)
      if (track.type == NativeVideoTrackType.text && sidecarIdOfTrack(track.id) != null)
        VideoTrackRef(kind: VideoTrackKind.subtitle, sidecarId: sidecarIdOfTrack(track.id), language: track.language)
      else
        VideoTrackRef(
          kind: track.type == NativeVideoTrackType.audio ? VideoTrackKind.audio : VideoTrackKind.subtitle,
          ordinal: ordinal++,
          language: track.language,
        ),
  ];
}

/// The lines of [tracks], all of one kind, in their menu: the name of the language of each, its name in the file when
/// it says more, its channels, Forced for forced subtitles, and Default for the one track the file marks so (many
/// files mark them all, which tells nothing); "Track 2" for a track with neither language nor name. As the native 360°
/// players name them (AudioTrackChooser.kt).
List<String> videoTrackLabels(Translations t, List<NativeVideoTrack> tracks) {
  final defaults = tracks.where((track) => track.isDefault).length;
  return [
    for (final (index, track) in tracks.indexed)
      _trackLabel(t, track, index + 1, markDefault: defaults == 1 && track.isDefault),
  ];
}

String _trackLabel(Translations t, NativeVideoTrack track, int number, {required bool markDefault}) {
  final parts = <String>[];
  final language = track.languageName ?? track.language?.toUpperCase();
  if (language != null) {
    parts.add(language);
  }
  final label = track.label?.trim();
  if (label != null && label.isNotEmpty && label.toLowerCase() != language?.toLowerCase()) {
    parts.add(label);
  }
  if (parts.isEmpty) {
    parts.add(t.video_audio_track_number(track: number));
  }
  final channels = switch (track.channels) {
    <= 0 => null,
    1 => t.video_audio_track_mono,
    2 => t.video_audio_track_stereo,
    6 => '5.1',
    8 => '7.1',
    final count => t.video_audio_track_channels(channels: count),
  };
  if (channels != null) {
    parts.add(channels);
  }
  if (track.isForced) {
    parts.add(t.video_subtitles_forced);
  }
  if (markDefault) {
    parts.add(t.video_audio_track_default);
  }
  return parts.join(', ');
}
