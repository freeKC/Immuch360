// The streams of a Plex film's file that choose its player (film_player_choice.dart): read from the part the film
// page and the video page already have (PlexFilmPart, /library/metadata/{ratingKey}), nothing asked of the server.

import 'package:immich_mobile/domain/services/film_player/film_player_choice.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';

/// What [part] holds, in the terms of the choice: its container, its first video stream, the audio track that plays
/// (the one the account picked, else the default one, else the first) and the subtitles picked. [container] is the one
/// of its media when the part does not tell it.
FilmStreams filmStreamsOfPlexPart(PlexFilmPart part, {String? container}) {
  String? lower(String? value) {
    final trimmed = value?.trim().toLowerCase();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  final video = part.streamsOf(PlexStreamType.video).firstOrNull;
  final audios = part.streamsOf(PlexStreamType.audio);
  final audio =
      audios.where((stream) => stream.selected).firstOrNull ??
      audios.where((stream) => stream.isDefault).firstOrNull ??
      audios.firstOrNull;
  final subtitle = part.streamsOf(PlexStreamType.subtitle).where((stream) => stream.selected).firstOrNull;
  return FilmStreams(
    container: lower(part.container ?? container),
    videoCodec: lower(video?.codec),
    videoProfile: lower(video?.profile),
    audioCodec: lower(audio?.codec),
    audioProfile: lower(audio?.profile),
    subtitleCodec: lower(subtitle?.codec),
  );
}

/// The places of the file [partId] among the versions of [details] and the files of its version, as the conversion
/// asks them (mediaIndex, partIndex); the first file when it is not found
({int mediaIndex, int partIndex}) plexPartPlace(PlexFilmDetails details, int? partId) {
  for (final (mediaIndex, media) in details.medias.indexed) {
    for (final (partIndex, part) in media.parts.indexed) {
      if (part.id == partId) {
        return (mediaIndex: mediaIndex, partIndex: partIndex);
      }
    }
  }
  return (mediaIndex: 0, partIndex: 0);
}
