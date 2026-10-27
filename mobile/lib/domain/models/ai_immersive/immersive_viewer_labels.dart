// The words of the stereo quad of the Meta Quest for the flat 3D photos (design-final 2026-10-26, sections 3.8 and
// 4.5), translated here and sent with the other labels of the immersive viewer when a photo opens on the quad (see
// stereoPhotoViewerLabels): the 2D button of a photo whose left eye is the original itself, the honesty label of a
// relief estimated by AI, and what previous and next say on such a photo. The viewer has their English texts for a
// key it does not get (StereoComposer.label).

import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// Translated labels of the flat 3D photos on the stereo quad, under the keys the immersive viewer reads
Map<String, String> aiImmersiveViewerLabels(Translations t) => {
  'ai2dOriginal': t.ai_immersive_2d_original,
  'aiReliefEstimated': t.ai_immersive_relief_estimated,
  'aiNoNavigation': t.ai_immersive_no_navigation,
};

/// Translated labels of the immersive viewer for a photo of the stereo quad: those of every opening (see
/// [sphereViewerLabels]) and those of the flat 3D photos (see [aiImmersiveViewerLabels])
Map<String, String> stereoPhotoViewerLabels(Translations t) => {
  ...sphereViewerLabels(t),
  ...aiImmersiveViewerLabels(t),
};
