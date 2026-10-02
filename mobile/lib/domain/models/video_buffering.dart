// The native video players (360° and Spatial 2.5D) show how far the buffer is filled while a video read over the
// network loads: "Buffering 42%". They fill in the percentage themselves.

import 'package:immich_mobile/generated/translations.g.dart';

/// Translated label of the buffering indicator of the native video players, under the key they read. They fall back
/// to the English text for a missing key. "{percent}" stays as it is: the players fill it in.
Map<String, String> videoBufferingLabels(Translations t) => {'buffering': t.video_buffering(percent: '{percent}')};
