// The words of the stereo quad of the Meta Quest for the flat 3D photos (design-final 2026-10-26, sections 3.6, 3.8
// and 4.5), translated here and sent with the other labels of the immersive viewer when a photo opens on the quad
// (see stereoPhotoViewerLabels): the 2D button of a photo whose left eye is the original itself, the honesty label of
// a relief estimated by AI, what previous and next say on such a photo, and for a relief the headset makes, its
// stages, its Stop relief button, why it left a photo flat and its 2.5D view on the 3D button. The viewer has their English texts for a key it does
// not get (StereoComposer.label), and puts the message of a failure where {reason} is.

import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// Translated labels of the flat 3D photos on the stereo quad, under the keys the immersive viewer reads
Map<String, String> aiImmersiveViewerLabels(Translations t) => {
  'ai2dOriginal': t.ai_immersive_2d_original,
  'ai25d': t.ai_immersive_mode_25d,
  'aiReliefEstimated': t.ai_immersive_relief_estimated,
  'aiNoNavigation': t.ai_immersive_no_navigation,
  'aiReliefPreparing': t.ai_immersive_state_preparing,
  'aiReliefEstimating': t.ai_immersive_relief_estimating,
  'aiReliefBuilding': t.ai_immersive_relief_building,
  'aiReliefStop': t.ai_immersive_relief_stop,
  'aiReliefTooWarm': t.ai_immersive_relief_too_warm,
  'aiReliefFailed': t.ai_immersive_relief_failed(reason: '{reason}'),
  'aiReliefNotInVersion': t.ai_immersive_unavailable_build,
  'aiReliefNoMemory': t.ai_immersive_unavailable_memory,
  'aiReliefMissing': t.ai_immersive_unavailable_missing,
  'aiReliefDamaged': t.ai_immersive_unavailable_damaged,
};

/// Translated labels of the immersive viewer for a photo of the stereo quad: those of every opening (see
/// [sphereViewerLabels]) and those of the flat 3D photos (see [aiImmersiveViewerLabels])
Map<String, String> stereoPhotoViewerLabels(Translations t) => {
  ...sphereViewerLabels(t),
  ...aiImmersiveViewerLabels(t),
};
