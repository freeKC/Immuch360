// The words of the stereo quad of the Meta Quest for the flat 3D photos (design-final 2026-10-26, sections 3.6, 3.8
// and 4.5), translated here and sent with the other labels of the immersive viewer when a photo opens on the quad
// (see stereoPhotoViewerLabels): the 2D button of a photo whose left eye is the original itself, the honesty label of
// a relief estimated by AI, what previous and next say on such a photo, and for a relief the headset makes, its
// stages, its Stop relief button, why it left a photo flat and its 2.5D view on the 3D button; and the words of a 3D
// scene (design-final 2026-10-27, section 3); and the words of a flat 3D media told by its file name (see
// flat3dViewerLabels) and of the flat screens (see flatScreenViewerLabels). The viewer has their English texts for a
// key it does not get (StereoComposer.label), and puts the message of a failure where {reason} is.

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
  'sceneZone': t.ai_immersive_scene_zone(size: '{size}'),
  'sceneHidden': t.ai_immersive_hidden_filled(percent: '{percent}'),
  'sceneTooHeavy': t.ai_immersive_scene_too_heavy(triangles: '{triangles}', max: '{max}'),
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

/// Translated labels of a flat 3D media told by its file name (a photo of the stereo quad, a video of the flat video
/// screen, see Flat3dRequest), under the keys StereoComposer reads: what passes once when one first shows,
/// experimental, and what previous and next say on a video
Map<String, String> flat3dViewerLabels(Translations t) => {
  'flat3dNotice': t.immersive_flat_3d_notice,
  'flat3dNoNavigation': t.immersive_flat_3d_no_navigation,
};

/// Translated labels of the flat screens of the immersive viewer (a photo of the stereo quad, a video of the flat video
/// screen), under the keys StereoComposer reads: what passes once when the first one the compositor filters shows
/// (Sharper flat screens, experimental), and what previous and next say on a photo or a video opened with View on a
/// big screen
Map<String, String> flatScreenViewerLabels(Translations t) => {
  'sharpScreensNotice': t.immersive_sharp_screens_notice,
  'bigScreenNoNavigation': t.immersive_big_screen_no_navigation,
};

/// Translated labels of the immersive viewer for a photo of the stereo quad, and a video of the flat video screen:
/// those of every opening (see [sphereViewerLabels]), those of the flat 3D photos (see [aiImmersiveViewerLabels]),
/// those of the 3D scenes (see [sceneViewerLabels]), those of the media told 3D by their file name (see
/// [flat3dViewerLabels]) and those of the flat screens (see [flatScreenViewerLabels])
Map<String, String> stereoPhotoViewerLabels(Translations t) => {
  ...sphereViewerLabels(t),
  ...aiImmersiveViewerLabels(t),
  ...sceneViewerLabels(t),
  ...flat3dViewerLabels(t),
  ...flatScreenViewerLabels(t),
};
