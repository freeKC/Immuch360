// The texts of the immersive viewer of the Meta Quest about the video it plays (lot quest-playback-resilience,
// 30 October 2026): the notices of a video it made play again where it stopped or a little past, the notice of a
// video without picture, and the units of the bit rate in its details line. Sent with every opening, under the keys
// the viewer reads (PlaybackDetails.kt), in the language of the app; the viewer fills in the places in braces.

import 'package:immich_mobile/generated/translations.g.dart';

/// "The video stopped at {position}, it plays again from there"
const playbackRestartedLabelKey = 'playbackRestarted';

/// "The video stopped at {position}, it plays again from {resume}, past the part that failed": after a decoder that
/// failed, the new one starts a few seconds later, on a whole picture
const playbackRestartedLaterLabelKey = 'playbackRestartedLater';

/// "No picture for 3 seconds while the sound plays ({video}). ..."
const playbackNoPictureLabelKey = 'playbackNoPicture';

/// "No picture for 3 seconds from {video}, trying the server playback stream"
const playbackNoPictureSwitchLabelKey = 'playbackNoPictureSwitch';

/// "{value} Mbit/s" and "{value} kbit/s", as the details of a video write them
const playbackMbpsLabelKey = 'playbackMbps';
const playbackKbpsLabelKey = 'playbackKbps';

/// The labels of the video playback of the immersive viewer, in the words of [t], their places left in braces
Map<String, String> immersivePlaybackLabels(Translations t) => {
  playbackRestartedLabelKey: t.immersive_playback_restarted(position: '{position}'),
  playbackRestartedLaterLabelKey: t.immersive_playback_restarted_later(position: '{position}', resume: '{resume}'),
  playbackNoPictureLabelKey: t.immersive_playback_no_picture(video: '{video}'),
  playbackNoPictureSwitchLabelKey: t.immersive_playback_no_picture_switch(video: '{video}'),
  playbackMbpsLabelKey: t.technical_details_bit_rate_mbps(value: '{value}'),
  playbackKbpsLabelKey: t.technical_details_bit_rate_kbps(value: '{value}'),
};
