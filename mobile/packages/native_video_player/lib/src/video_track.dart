// Immuch360: the audio and subtitle tracks of a video, as the Android player reports them

/// The kind of a [NativeVideoTrack]
enum NativeVideoTrackType {
  audio,

  /// Subtitles and captions
  text,
}

/// An audio or subtitle track of the video a player plays: the [trackIndex]th track of the [groupIndex]th group of
/// the player's tracks (the address [NativeVideoPlayerController.selectTrack] needs), with what the file tells of it
class NativeVideoTrack {
  const NativeVideoTrack({
    required this.type,
    required this.groupIndex,
    required this.trackIndex,
    this.language,
    this.languageName,
    this.label,
    this.channels = 0,
    this.selected = false,
    this.isDefault = false,
    this.isForced = false,
  });

  /// A track as the platform sends it, null for one that does not read
  static NativeVideoTrack? fromMap(Map<Object?, Object?> map) {
    final type = switch (map['type']) {
      'audio' => NativeVideoTrackType.audio,
      'text' => NativeVideoTrackType.text,
      _ => null,
    };
    final group = map['group'];
    final track = map['track'];
    if (type == null || group is! int || track is! int) {
      return null;
    }
    return NativeVideoTrack(
      type: type,
      groupIndex: group,
      trackIndex: track,
      language: map['language'] as String?,
      languageName: map['languageName'] as String?,
      label: map['label'] as String?,
      channels: map['channels'] as int? ?? 0,
      selected: map['selected'] as bool? ?? false,
      isDefault: map['isDefault'] as bool? ?? false,
      isForced: map['isForced'] as bool? ?? false,
    );
  }

  final NativeVideoTrackType type;
  final int groupIndex;
  final int trackIndex;

  /// Its language code, null when the file names none
  final String? language;

  /// The name of [language] in the language asked for ("Français"), null without a language
  final String? languageName;

  /// Its name in the file ("Commentary"), null when it has none
  final String? label;

  /// Audio channels, 0 when unknown or for subtitles
  final int channels;

  /// Whether it plays now
  final bool selected;

  /// Whether the file marks it as its default track
  final bool isDefault;

  /// Whether the file marks it as forced (subtitles for the parts in another language)
  final bool isForced;

  @override
  bool operator ==(Object other) =>
      other is NativeVideoTrack &&
      other.type == type &&
      other.groupIndex == groupIndex &&
      other.trackIndex == trackIndex &&
      other.language == language &&
      other.languageName == languageName &&
      other.label == label &&
      other.channels == channels &&
      other.selected == selected &&
      other.isDefault == isDefault &&
      other.isForced == isForced;

  @override
  int get hashCode => Object.hash(
        type,
        groupIndex,
        trackIndex,
        language,
        languageName,
        label,
        channels,
        selected,
        isDefault,
        isForced,
      );

  @override
  String toString() => 'NativeVideoTrack($type $groupIndex/$trackIndex $language $label'
      '${selected ? ' selected' : ''})';
}
