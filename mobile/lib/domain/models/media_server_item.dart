// A film, a series, a season or an episode of a media server that indexes them (a Jellyfin or Emby server, release
// 49), as the film and series page shows it: what the server tells, nothing of its API. Not stored: it lives as long
// as the page that read it.

import 'dart:typed_data';

enum MediaServerItemKind { film, series, season, episode, other }

class MediaServerItem {
  const MediaServerItem({
    required this.id,
    required this.kind,
    required this.title,
    this.year,
    this.durationMs,
    this.overview,
    this.positionMs,
    this.played = false,
    this.seasonNumber,
    this.episodeNumber,
    this.seriesId,
    this.videoCodec,
    this.videoHeight,
    this.audio = const [],
    this.stereo,
    this.versions = 1,
  });

  final String id;
  final MediaServerItemKind kind;
  final String title;
  final int? year;
  final int? durationMs;
  final String? overview;

  /// Where the server's user stopped (its own apps included), null or 0 when not started
  final int? positionMs;
  final bool played;

  /// The season number of a season or an episode, the episode number of an episode
  final int? seasonNumber;
  final int? episodeNumber;
  final String? seriesId;

  // The file's streams, for the line of the page ("HEVC 2160p, TrueHD 7.1, 3 audio tracks, half side by side 3D")

  /// Lower case as the server names it: "hevc", "h264"
  final String? videoCodec;
  final int? videoHeight;

  /// The audio tracks, the default one first
  final List<({String codec, int? channels})> audio;

  /// The 3D layout the server read (HalfSideBySide, FullSideBySide, HalfTopAndBottom, FullTopAndBottom, MVC), null for
  /// a flat film
  final String? stereo;

  /// How many files of the film the server has (the first plays in this release)
  final int versions;
}

/// A share whose server has pages of its films and series (a Jellyfin or Emby server, see JellyfinFileSystem)
abstract interface class MediaServerItemSource {
  /// The id of the film or series at [path] of a listing, whose page opens on a tap; null for any other entry
  String? itemPageAt(String path);

  /// The film, series or episode [itemId] with what its page shows
  Future<MediaServerItem> itemDetails(String itemId);

  /// The seasons of the series [seriesId], in their order
  Future<List<MediaServerItem>> seasonsOf(String seriesId);

  /// The episodes of a season, in their order
  Future<List<MediaServerItem>> episodesOf(String seriesId, String seasonId);

  /// The episode to watch next of the series [seriesId], null when the server has none
  Future<MediaServerItem?> nextEpisodeOf(String seriesId);

  /// The path of the file of the item [itemId], which the video page opens
  Future<String> pathOfItem(String itemId);

  /// The picture of [itemId] (a poster) about [size] pixels high, null when it has none
  Future<Uint8List?> itemPicture(String itemId, int size);
}
