// The engines of the kinds of phases 2 and 3 as the queue is given them (conversionEnginesProvider of
// desktop_conversion_tools.dart), with the fakes of lot C0: each one with the key of the settings the files of its fake
// carry, so that the queue finds the versions they wrote, and the panorama with its generator and its steps.

import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';

import 'fake_panorama_engine.dart';
import 'fake_scene_engine.dart';
import 'fake_stereo_panorama_engine.dart';

/// The generator and the steps of the fake panoramas
const fakePanoramaGenerator = 'flux2-klein-base-4b-q4_0';
const fakePanoramaSteps = 20;

/// The key of the settings of a scene of the fake engine with [turns]: the models and the grid of the fixture
String fakeSceneSettingsKey(int turns) {
  final scene = FakeSceneTail.fixture.xmp;
  return SceneXmp(
    pipeline: SceneV1.pipeline,
    geometryModelSha256: scene.geometryModelSha256,
    inpaintModelSha256: scene.inpaintModelSha256,
    gridStep: scene.gridStep,
    sourceQuarterTurns: turns & 3,
  ).settingsKey!;
}

/// The key of the settings of a panorama of the fake engine with [turns]; the seed is not part of it
String fakePanoramaSettingsKey(int turns, {int steps = fakePanoramaSteps}) => PanoramaXmp(
  pipeline: PanoV1.pipeline,
  generatorSha256: fakeGeneratorSha256,
  generatorLoraSha256: fakeLoraSha256,
  steps: steps,
  sourceQuarterTurns: turns & 3,
).settingsKey!;

/// The key of the settings of a 360° 3D panorama of the fake engine with [turns]
String fakeStereoPanoramaSettingsKey(int turns) => StereoPanoramaXmp(
  pipeline: Relief360V1.pipeline,
  depthModelSha256: depthModelOnnxSha256,
  maxShiftDegrees: Relief360V1.maxShiftDegrees,
  sourceQuarterTurns: turns & 3,
).settingsKey!;

/// The engines of [scene], [panorama] and [stereoPanorama], those given only
Map<ConversionKind, ConversionEngine> fakeConversionEngines({
  FakeSceneEngine? scene,
  FakePanoramaEngine? panorama,
  FakeStereoPanoramaEngine? stereoPanorama,
}) => {
  if (scene != null)
    ConversionKind.sceneFromPhoto: ConversionEngine(
      engine: scene,
      settingsKey: (source, turns) => fakeSceneSettingsKey(turns),
    ),
  if (panorama != null)
    ConversionKind.panoramaFromPhoto: ConversionEngine(
      engine: panorama,
      settingsKey: (source, turns) => fakePanoramaSettingsKey(turns),
      generator: fakePanoramaGenerator,
      steps: fakePanoramaSteps,
    ),
  if (stereoPanorama != null)
    ConversionKind.stereoPanoramaFromPanorama: ConversionEngine(
      engine: stereoPanorama,
      settingsKey: (source, turns) => fakeStereoPanoramaSettingsKey(turns),
    ),
};
