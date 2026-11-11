// What a media server tells of the audio and subtitle tracks of a film it serves (a Plex server): their names in the
// menus of the players, and what to do once the user picks one (write the choice back to the server). The players
// know their tracks by their own indexes; a track is handed to the server side by its place among the tracks of its
// kind inside the file, or by the id of the side file the app loaded next to the film.

/// The kinds of track a server names
enum VideoTrackKind { audio, subtitle }

/// The start of the id of every side file of subtitles the app gives a player (VideoSubtitle.id); Media3 prefixes the
/// ids of the tracks it merges with their period ("1:immuch-sub-12"), so a track is told by [sidecarIdOfTrack]
const videoSidecarIdPrefix = 'immuch-sub-';

/// The id of the side file [trackId] (the id the player reports for a track) comes from, null for a track inside the
/// file
String? sidecarIdOfTrack(String? trackId) {
  if (trackId == null) {
    return null;
  }
  final at = trackId.indexOf(videoSidecarIdPrefix);
  return at < 0 ? null : trackId.substring(at);
}

/// A track of a player as the server side sees it: the [ordinal]th track of its [kind] inside the file (0 based, in
/// the order the player lists them), or the side file of [sidecarId]. [language] is the code the player reports, for
/// a check against the server's own list.
class VideoTrackRef {
  const VideoTrackRef({required this.kind, this.ordinal, this.sidecarId, this.language});

  final VideoTrackKind kind;
  final int? ordinal;
  final String? sidecarId;
  final String? language;

  bool get isSidecar => sidecarId != null;

  @override
  bool operator ==(Object other) =>
      other is VideoTrackRef &&
      other.kind == kind &&
      other.ordinal == ordinal &&
      other.sidecarId == sidecarId &&
      other.language == language;

  @override
  int get hashCode => Object.hash(kind, ordinal, sidecarId, language);

  @override
  String toString() => 'VideoTrackRef(${kind.name} ${sidecarId ?? ordinal} $language)';
}

/// The names a server gives the tracks of the film that plays, and its hook for a pick. The menus keep the player's
/// own label where [labelOf] gives null.
abstract interface class VideoTrackNaming {
  /// The line of [track] in its menu, null to keep the player's own
  String? labelOf(VideoTrackRef track);

  /// The user picked [track] of [kind] in a menu; null for subtitles off
  void picked(VideoTrackKind kind, VideoTrackRef? track);
}
