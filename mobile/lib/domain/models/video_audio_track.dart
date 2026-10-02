// A video may hold several audio tracks: languages, a commentary. The native video players (360° and Spatial 2.5D)
// show an audio track button for such a video, list its tracks by language, name and channels, and remember the
// language picked, on the device, for the next videos. They name the tracks themselves, with the labels below.

import 'dart:ui';

import 'package:immich_mobile/generated/translations.g.dart';

/// Translated labels of the audio track control of the native video players, under the keys they read. They fall
/// back to their English texts for a missing key. "Track {track}" and "{channels} channels" keep their placeholder,
/// which the players fill in. [locale] is the language of the app: the players write the names of the track
/// languages in it ("Anglais" rather than "English" in French).
Map<String, String> audioTrackLabels(Translations t, Locale locale) => {
  'audioTrack': t.video_audio_track,
  'audioTrackDefault': t.video_audio_track_default,
  'audioTrackNumber': t.video_audio_track_number(track: '{track}'),
  'audioTrackMono': t.video_audio_track_mono,
  'audioTrackStereo': t.video_audio_track_stereo,
  'audioTrackChannels': t.video_audio_track_channels(channels: '{channels}'),
  'audioTrackLocale': locale.toLanguageTag(),
};
