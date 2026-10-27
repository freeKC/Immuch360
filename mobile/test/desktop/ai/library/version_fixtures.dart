// The XMP of the versions made from an original, as the conversions write it, for the tests of the library: what makes
// a file a version, whatever its name. A 3D photo of phase 1, and the 3D scene, the 360° panorama and the 360° 3D
// panorama of phases 2 and 3, each in a real small file the scan, the badges and the versions read back.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

import '../fakes/fake_panorama_engine.dart' show fakeGeneratorSha256, fakeLoraSha256;
import '../fakes/fake_scene_engine.dart';

/// The SHA-1 of [bytes] in base64, as the checksum column of the library and Immich write it
String sha1Base64(List<int> bytes) => base64.encode(crypto.sha1.convert(bytes).bytes);

const _created = '2026-10-27T10:12:00+01:00';
const _creatorTool = 'Immuch360 Desktop 3.3.0 (linux)';

/// The packet of a version of the original whose bytes are [original]
StereoPhotoXmp versionXmp(List<int> original, {String name = 'salon.jpg', int quarterTurns = 0}) =>
    StereoPhotoXmp.estimated(
      eyeWidth: 8,
      eyeHeight: 6,
      depthModelSha256: depthModelOnnxSha256,
      sourceName: name,
      sourceSize: original.length,
      sourceSha1: sha1Base64(original),
      sourceQuarterTurns: quarterTurns,
      created: _created,
      creatorTool: _creatorTool,
    );

/// The packet of a 3D scene made from the original whose bytes are [original], around the scene of
/// test/fixtures/ai_immersive/tiny_scene3D.jpg
SceneXmp sceneVersionXmp(List<int> original, {String name = 'salon.jpg', int quarterTurns = 0}) {
  final tail = FakeSceneTail.fixture;
  final scene = tail.xmp;
  return SceneXmp.reconstructed(
    sceneLength: tail.glb.length,
    sceneSha256: scene.sceneSha256!,
    sceneMeshes: scene.sceneMeshes!,
    sceneVertices: scene.sceneVertices!,
    sceneTriangles: scene.sceneTriangles!,
    sceneTextureMax: scene.sceneTextureMax!,
    sceneScale: scene.sceneScale!,
    gridStep: scene.gridStep!,
    safe: scene.safe!,
    fieldOfView: scene.fieldOfView!,
    fieldOfViewSource: FieldOfViewSource.model,
    geometryModel: scene.geometryModel!,
    geometryModelSha256: scene.geometryModelSha256!,
    inpaintModel: scene.inpaintModel!,
    inpaintModelSha256: scene.inpaintModelSha256!,
    hiddenFraction: scene.hiddenFraction!,
    sourceName: name,
    sourceSize: original.length,
    sourceSha1: sha1Base64(original),
    sourceQuarterTurns: quarterTurns,
    created: _created,
    creatorTool: _creatorTool,
  );
}

/// The packet of a 360° panorama generated around the original whose bytes are [original], 32 x 16
PanoramaXmp panoramaVersionXmp(List<int> original, {String name = 'salon.jpg'}) => PanoramaXmp.generated(
  width: 32,
  height: 16,
  region: const PhotoRegion(yaw: 0, pitch: 0, hfov: 65.4, vfov: 50.6),
  sourceCoverage: 0.08,
  generator: 'flux2-klein-base-4b-q8_0',
  generatorSha256: fakeGeneratorSha256,
  generatorLora: 'flux2-klein-4b-360-erp-lora-v1',
  generatorLoraSha256: fakeLoraSha256,
  seed: 7,
  steps: 28,
  upscaler: 'realesrgan-x4plus',
  sourceName: name,
  sourceSize: original.length,
  sourceSha1: sha1Base64(original),
  sourceQuarterTurns: 0,
  created: _created,
  creatorTool: _creatorTool,
);

/// The packet of the 3D version of a panorama, 32 x 32 (the eyes stacked): of [parent], a panorama generated from the
/// original whose bytes are [original], or, without it, of [original] itself, a 360° photo of the user
StereoPanoramaXmp stereoPanoramaVersionXmp(List<int> original, {String name = 'salon.jpg', PanoramaXmp? parent}) =>
    StereoPanoramaXmp.estimated(
      width: 32,
      height: 32,
      depthModelSha256: depthModelOnnxSha256,
      sourceName: name,
      sourceSize: original.length,
      sourceSha1: sha1Base64(original),
      sourceQuarterTurns: 0,
      created: _created,
      creatorTool: _creatorTool,
      parent: parent,
    );

/// The file of the version [xmp], as the engines write it: a JPEG with the packet (16 x 12 for a scene, the frame the
/// packet gives for a panorama), and for a scene its glb after the end of the JPEG
Uint8List versionFileOf(ImmersiveXmp xmp) => switch (xmp) {
  SceneXmp() => Uint8List.fromList([
    ...fakeJpegWithXmp(xmp.toXml(), width: 16, height: 12),
    ...FakeSceneTail.fixture.glb,
  ]),
  PanoramaXmp(:final width?, :final height?) ||
  StereoPanoramaXmp(:final width?, :final height?) => fakeJpegWithXmp(xmp.toXml(), width: width, height: height),
  _ => fakeJpegWithXmp(xmp.toXml(), width: 16, height: 6),
};
