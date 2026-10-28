// The words of the stereo quad of the Meta Quest for the flat 3D photos (design-final 2026-10-26, sections 3.6, 3.8
// and 4.5), translated here and sent with the other labels of the immersive viewer when a photo opens on the quad
// (see stereoPhotoViewerLabels): the 2D button of a photo whose left eye is the original itself, the honesty label of
// a relief estimated by AI, what previous and next say on such a photo, and for a relief the headset makes, its
// stages, its Stop relief button, why it left a photo flat and its 2.5D view on the 3D button; and the words of a 3D
// scene (design-final 2026-10-27, section 3). The viewer has their English texts for a key it does not get
// (StereoComposer.label), and puts the message of a failure where {reason} is.

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

// The numbers of the translations that are typed as numbers ({size}, {max}): a number no text holds stands for each,
// then gives way to its place, where the headset puts the value it reads in the file
const _sizeMark = 918273645;
const _maxMark = 918273646;

String _placeOf(String text, int mark, String place) => text.replaceAll('$mark', place);

/// Translated labels of a 3D scene in the headset (design-final 2026-10-27, sections 3.3, 3.5 and 3.7), under the keys
/// SceneTexts reads: its panel (Reset, the photo or the scene on the 3D button, its controller mapping, the room to move,
/// the areas filled, the flags of the file), its passing texts (the honesty sentence, the edge of the zone) and why it
/// stays flat. The viewer has their English texts too, and puts the numbers where {triangles}, {max}, {size},
/// {percent} and {reason} are.
Map<String, String> sceneViewerLabels(Translations t) => {
  'sceneHonesty': t.ai_immersive_scene_honesty,
  'scenePreparing': t.ai_immersive_scene_preparing,
  'sceneEdge': t.ai_immersive_scene_edge,
  'sceneReset': t.ai_immersive_scene_reset,
  'scenePhoto2d': t.ai_immersive_scene_photo_2d,
  'scene3d': t.ai_immersive_type_scene,
  'sceneHint': t.ai_immersive_scene_hint,
  'sceneZone': _placeOf(t.ai_immersive_scene_zone(size: _sizeMark), _sizeMark, '{size}'),
  'sceneHidden': t.ai_immersive_hidden_filled(percent: '{percent}'),
  'sceneTooHeavy': _placeOf(t.ai_immersive_scene_too_heavy(triangles: '{triangles}', max: _maxMark), _maxMark, '{max}'),
  'sceneTooHeavyPlain': t.ai_immersive_scene_too_heavy_plain,
  'sceneNewer': t.ai_immersive_newer_version,
  'sceneNotOurs': t.ai_immersive_scene_not_ours,
  'sceneNoMemory': t.ai_immersive_scene_no_memory,
  'sceneTooWarm': t.ai_immersive_unavailable_too_warm,
  'sceneMissing': t.ai_immersive_scene_missing,
  'sceneFailed': t.ai_immersive_scene_failed(reason: '{reason}'),
  'sceneFlag_lowRelief': t.ai_immersive_quality_flat,
  'sceneFlag_hiddenAreas': t.ai_immersive_quality_hidden,
  'sceneFlag_dark': t.ai_immersive_quality_dark,
  'sceneFlag_sky': t.ai_immersive_quality_sky,
  'sceneFlag_fovGuessed': t.ai_immersive_quality_fov,
  'sceneFlag_smallZone': t.ai_immersive_quality_small_zone,
};

/// Translated labels of the immersive viewer for a photo of the stereo quad: those of every opening (see
/// [sphereViewerLabels]), those of the flat 3D photos (see [aiImmersiveViewerLabels]) and those of the 3D scenes (see
/// [sceneViewerLabels])
Map<String, String> stereoPhotoViewerLabels(Translations t) => {
  ...sphereViewerLabels(t),
  ...aiImmersiveViewerLabels(t),
  ...sceneViewerLabels(t),
};
