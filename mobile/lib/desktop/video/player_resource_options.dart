// The mpv options some resources open with, beyond those of every open (DesktopPlayerOptions.forOpen), while they are
// served: the y4m of an AV2 companion registers its demuxer, its cache and its colours here (av2_playback.dart), and
// the players read them at each open (DesktopPlayer.open), taking them back at the next open that does not have them.
// A file of its own so that the players and the companion need not know each other.

/// The extra mpv options of each resource served now, by resource (a URL)
final desktopResourceOptions = <String, Map<String, String>>{};
