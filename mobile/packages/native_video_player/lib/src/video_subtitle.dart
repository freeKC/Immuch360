// Immuch360: a side file of subtitles the player loads next to the video (patch 3 of IMMUCH360-NOTE.md)

/// A file of subtitles outside the video (a sidecar, served by the app's media bridge), which the player lists as one
/// more subtitle track, off until the user picks it. Android hands it to Media3 as a `MediaItem.SubtitleConfiguration`;
/// iOS leaves it out.
class VideoSubtitle {
  const VideoSubtitle({required this.uri, required this.mimeType, this.language, this.label, this.id});

  /// Where the player reads it: an http URL of the app's media bridge
  final String uri;

  /// Its format as a MIME type, "application/x-subrip" for SubRip
  final String mimeType;

  /// Its language code, null when unknown
  final String? language;

  /// Its name in the menu, null for the player's own (from the language)
  final String? label;

  /// What Media3 puts in the Format.id of its track, so that the app tells it among the tracks of the file; Media3
  /// prefixes it with its period ("1:immuch-sub-3")
  final String? id;

  /// What the platform is sent
  Map<String, Object?> toMap() => {'uri': uri, 'mimeType': mimeType, 'language': language, 'label': label, 'id': id};

  @override
  bool operator ==(Object other) =>
      other is VideoSubtitle &&
      other.uri == uri &&
      other.mimeType == mimeType &&
      other.language == language &&
      other.label == label &&
      other.id == id;

  @override
  int get hashCode => Object.hash(uri, mimeType, language, label, id);

  @override
  String toString() => 'VideoSubtitle($id $mimeType $language $label)';
}
