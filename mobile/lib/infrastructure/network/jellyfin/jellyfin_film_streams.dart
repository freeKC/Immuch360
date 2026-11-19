// The streams of a Jellyfin or Emby film's file that choose its player (film_player_choice.dart), in the names the
// choice uses, which are Plex's: read from the media source the listing already has, nothing more asked of the server.
// Both products name their codecs as ffmpeg does, as Plex does, but for DTS ("dts", Plex "dca"); their profiles are
// as ffmpeg prints them ("DTS-HD MA", "Main 10"), lower case in the choice, DTS-HD Master Audio being "ma".

import 'package:immich_mobile/domain/services/film_player/film_player_choice.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';

String? _lower(String? value) {
  final trimmed = value?.trim().toLowerCase();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// A codec in the names of the choice
String? jellyfinCodecToPlex(String? codec) => switch (_lower(codec)) {
  'dts' => 'dca',
  final other => other,
};

/// A profile in the names of the choice: "DTS-HD MA" is "ma", "DTS-HD HRA" "hra", the others lower case
String? jellyfinProfileToPlex(String? profile) => switch (_lower(profile)) {
  'dts-hd ma' => 'ma',
  'dts-hd hra' => 'hra',
  final other => other,
};

/// The container of [source] in the names of the choice: the one the server tells, or the extension of [fileName]
/// when it tells a list ("mov,mp4,m4a,3gp,3g2,mj2" for any file of that family)
String? jellyfinContainer(JellyfinMediaSource source, {String? fileName}) {
  final container = _lower(source.container);
  if (container != null && !container.contains(',')) {
    return container == 'matroska' ? 'mkv' : container;
  }
  final name = fileName ?? source.path;
  final dot = name?.lastIndexOf('.') ?? -1;
  final extension = dot < 0 ? null : _lower(name!.substring(dot + 1));
  return switch (extension) {
    'm4v' => 'mp4',
    null => container?.split(',').first,
    final other => other,
  };
}

/// What [source] holds, in the terms of the choice: its container, its first video stream, the audio track that plays
/// (the default one, else the first) and the others
FilmStreams filmStreamsOfJellyfinSource(JellyfinMediaSource source, {String? fileName}) {
  final video = source.streams.where((stream) => stream.isVideo).firstOrNull;
  final audios = source.streams.where((stream) => stream.isAudio).toList();
  final byIndex = source.defaultAudioStreamIndex;
  final audio =
      audios.where((stream) => byIndex != null && stream.index == byIndex).firstOrNull ??
      audios.where((stream) => stream.isDefault).firstOrNull ??
      audios.firstOrNull;
  return FilmStreams(
    container: jellyfinContainer(source, fileName: fileName),
    videoCodec: jellyfinCodecToPlex(video?.codec),
    videoProfile: _lower(video?.profile),
    audioCodec: jellyfinCodecToPlex(audio?.codec),
    audioProfile: jellyfinProfileToPlex(audio?.profile),
    otherAudioCodecs: [
      for (final other in audios)
        if (jellyfinCodecToPlex(other.codec) case final String codec when !identical(other, audio)) codec,
    ],
  );
}
