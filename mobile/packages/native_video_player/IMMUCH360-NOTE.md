Copy of `native_video_player` 1.3.1 (MIT, Copyright (c) 2021 albemala, see `LICENSE`) as Immich's fork has it,
https://github.com/immich-app/native_video_player at commit `cdf621bdb7edaf996e118a58a48f6441187d79c6`, the git ref
of the dependency in `mobile/pubspec.yaml`. Used through `dependency_overrides` there, so that the dependency line
stays the one of upstream Immich and an upstream bump shows in a merge.

Left out: `example/`, `screenshots/`, `test/`, `scripts/`, `.github/`, the README (its links), and the dev
dependencies of `pubspec.yaml` (build_runner, json_serializable, very_good_analysis: the generated `*.g.dart` files
are in `lib/`). `pubspec.yaml`: `publish_to: none`, version `1.3.1+immuch360`. The code is unchanged but for
punctuation (the headers of the two generated files and one `fatalError` message of
`ios/Classes/NativeVideoPlayerView.swift` had a spaced hyphen, the fork's texts having none) and for the patch below;
the iOS side has no other change.

What differs from upstream, to apply again when a newer commit is copied here (every change is marked `Immuch360`):

1. Audio and subtitle tracks on Android (23 October 2026). The flat player of the viewers, a bare ExoPlayer, had no
   track API and drew no subtitles: a film with several audio languages played the default one, and its subtitles
   never showed.
   - `android/.../VideoTracks.kt` (new): lists the audio and text tracks of `Player.getCurrentTracks()` with their
     group and track indexes, language code and language name (in the locale asked for), name, channels, and the
     selected, default and forced flags; selects one with a `TrackSelectionOverride` (an audio track also becomes the
     preferred audio language of the player); turns a track type off (subtitles off); gives a new player its first
     parameters (`initialParameters`: the preferred audio language, and the default flag of subtitle tracks ignored,
     so that subtitles start off but for forced ones and those of the caption settings of the device).
   - `NativeVideoPlayerViewController.kt`: a `SubtitleView` over the picture, inside the aspect ratio frame, styled
     with the caption settings of the device, fed by `onCues`; `onTracksChanged` tells Dart; each new player starts
     with `VideoTracks.initialParameters` and `NativeVideoPlayerPlugin.preferredAudioLanguage`, and an audio track
     picked goes to
     `NativeVideoPlayerPlugin.onAudioLanguageChosen`.
   - `NativeVideoPlayerPlugin.kt`: those two hooks, set by the app (`MainActivity.registerPlugins`), which keeps the
     language with the one of the 360° and Spatial players (`AudioTrackChooser`).
   - `platform_interface/NativeVideoPlayerApi.kt`: the methods `getTracks` (argument: a BCP 47 locale tag or null),
     `selectTrack` (`type`, `group`, `track`; false when the tracks changed since), `disableTracks` (`type`), and the
     callback `onTracksChanged`.
   - Dart: `lib/src/video_track.dart` (new, exported): `NativeVideoTrack` and `NativeVideoTrackType`;
     `NativeVideoPlayerApi` and `NativeVideoPlayerController`: `getTracks`, `selectTrack`, `disableTracks`,
     `onTracksChanged`. Where the platform has no such methods (iOS answers "not implemented"), the controller lists
     no track and selects nothing.
