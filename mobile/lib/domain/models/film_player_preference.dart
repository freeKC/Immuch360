/// Which player plays a film, as the user asks in the video page's menu and in Settings, Advanced (see
/// film_player_choice.dart)
enum FilmPlayerPreference {
  /// The app chooses from the film's streams
  automatic,

  /// The device's own player, whatever the streams
  device,

  /// libmpv, where the build has it
  mpv,
}
