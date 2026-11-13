// The versions of a Plex film (its Media entries: "1080p HEVC, 3.0 GiB" and "2160p HEVC HDR, 52 GiB") for the film
// page and its Download, and what the version choice (film_version_choice.dart) and the Dolby Vision notice read of
// them. Plain Dart over the item the film page already has, nothing asked of the server.

import 'package:immich_mobile/domain/services/film_player/film_audio_choice.dart';
import 'package:immich_mobile/domain/services/film_player/film_player_choice.dart';
import 'package:immich_mobile/domain/services/film_player/film_version_choice.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

/// The versions of [film] that have a file, in the server's order
List<PlexFilmMedia> plexFilmVersions(PlexFilmDetails film) => [
  for (final media in film.medias)
    if (media.parts.isNotEmpty) media,
];

/// The height of the picture of [media] in lines: Plex's resolution ("4k", "1080", "sd"), else its height
int? plexMediaHeight(PlexFilmMedia media) {
  final resolution = media.videoResolution?.trim().toLowerCase();
  return switch (resolution) {
    '4k' => 2160,
    '8k' => 4320,
    'sd' => 480,
    final String digits when int.tryParse(digits) != null => int.parse(digits),
    _ => media.height,
  };
}

/// The size of the files of [media] together, null when the server gives none
int? plexMediaSize(PlexFilmMedia media) {
  final sizes = [
    for (final part in media.parts)
      if (part.size case final int size) size,
  ];
  return sizes.isEmpty ? null : sizes.reduce((a, b) => a + b);
}

/// The first video stream of [media], null when the server lists none
PlexStream? plexMediaVideo(PlexFilmMedia media) => media.parts.first.streamsOf(PlexStreamType.video).firstOrNull;

/// The line of [media] in the choice: "2160p HEVC HDR, 52 GiB", "1080p H264, 3.0 GiB"; "Dolby Vision" for a profile 5
/// stream, which has no HDR10 picture under it
String plexFilmVersionLabel(PlexFilmMedia media) {
  final height = plexMediaHeight(media);
  final video = plexMediaVideo(media);
  final range = video == null
      ? null
      : video.doviProfile == 5
      ? 'Dolby Vision'
      : video.isHdr
      ? 'HDR'
      : null;
  final picture = [
    if (height != null) '${height}p',
    if (media.videoCodec ?? video?.codec case final String codec) codec.toUpperCase(),
    ?range,
  ].join(' ');
  final size = plexMediaSize(media);
  return [
    if (picture.isNotEmpty) picture,
    if (size != null) formatHumanReadableBytes(size, size >= 10 * 1024 * 1024 * 1024 ? 0 : 1),
  ].join(', ');
}

/// What the version choice reads of the versions of [film]; [decodes] tells whether a player of the device decodes the
/// streams of a file (null when it cannot tell: every version counts as decodable)
List<FilmVersion> plexFilmVersionsForChoice(PlexFilmDetails film, {bool Function(FilmStreams streams)? decodes}) => [
  for (final media in plexFilmVersions(film))
    FilmVersion(
      height: plexMediaHeight(media),
      sizeBytes: plexMediaSize(media),
      decodable: decodes == null || decodes(plexVersionStreams(media)),
    ),
];

/// The streams of the first file of [media] for the decoders (FilmDecoders.missing): its video, and its audio tracks
/// with the one that plays first
FilmStreams plexVersionStreams(PlexFilmMedia media) {
  final part = media.parts.first;
  final video = part.streamsOf(PlexStreamType.video).firstOrNull;
  final audios = part.streamsOf(PlexStreamType.audio);
  final audio =
      audios.where((stream) => stream.selected).firstOrNull ??
      audios.where((stream) => stream.isDefault).firstOrNull ??
      audios.firstOrNull;
  String? lower(String? value) => value?.trim().toLowerCase();
  return FilmStreams(
    container: lower(part.container ?? media.container),
    videoCodec: lower(video?.codec ?? media.videoCodec),
    videoProfile: lower(video?.profile),
    audioCodec: lower(audio?.codec ?? media.audioCodec),
    otherAudioCodecs: [
      for (final other in audios)
        if (lower(other.codec) case final String codec when !identical(other, audio)) codec,
    ],
  );
}

/// The audio streams inside [part], in the order of the file (Plex's index), as the players list them
List<PlexStream> plexEmbeddedAudio(PlexFilmPart part) =>
    part.streams.where((stream) => stream.type == PlexStreamType.audio && !stream.isSidecar).toList()
      ..sort((a, b) => (a.index ?? 0).compareTo(b.index ?? 0));

/// The audio tracks inside [part], in the order of the file, for the audio choice (film_audio_choice.dart)
List<FilmAudioTrack> plexFilmAudioTracks(PlexFilmPart part) => [
  for (final stream in plexEmbeddedAudio(part))
    FilmAudioTrack(
      codec: stream.codec?.toLowerCase(),
      language: stream.languageTag ?? stream.languageCode,
      isDefault: stream.isDefault,
    ),
];

/// Whether the video of [part] is Dolby Vision profile 5, whose colours only a player that applies its reshaping shows
/// right (mpv's gpu-next renderer; not the render API of libmpv the app draws with)
bool plexPartIsDolbyVision5(PlexFilmPart part) => part.streamsOf(PlexStreamType.video).firstOrNull?.doviProfile == 5;

/// [label], Plex's line of a track ("French (AC3 5.1)"), for a sentence: "French AC3 5.1"
String plexTrackLabelInSentence(String label) =>
    label.replaceAll(RegExp('[()]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
