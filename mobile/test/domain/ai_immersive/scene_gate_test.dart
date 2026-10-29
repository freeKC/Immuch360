// The gate of the 3D scenes read in the packet at the head of the file (design-final 2026-10-27, section 3.5): the
// caps of SceneGate.kt by headset, the version, a scene format not ours, a packet that misses a part of the request,
// and the request the headset gets, the one of the stereoPair contract for the sample of the design.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/ai_immersive/scene_gate.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';

void main() {
  final sample = File('test/fixtures/ai_immersive/xmp_v1_scene_sample.xmp').readAsStringSync();
  final contract =
      jsonDecode(File('test/fixtures/ai_immersive/stereo_pair_contract_v1.json').readAsStringSync())
          as Map<String, dynamic>;
  final designRequest = ((contract['volumetricScene'] as List).first as Map<String, dynamic>)['request'];

  /// The sample with each of [fields] written as given
  SceneXmp sampleWith([Map<String, String> fields = const {}]) {
    var text = sample;
    fields.forEach((name, value) {
      final pattern = RegExp('Immuch360:$name="[^"]*"');
      expect(pattern.hasMatch(text), isTrue, reason: 'no $name in the sample');
      text = text.replaceFirst(pattern, 'Immuch360:$name="$value"');
    });
    return ImmersiveXmp.parse(text)! as SceneXmp;
  }

  test('the scene of the design opens on every headset, with the request of the contract', () {
    for (final device in [null, 'eureka', 'panther', 'hollywood', 'seacliff', 'some-new-headset']) {
      final verdict = sceneGateOf(sampleWith(), device: device, fileSize: 9 * 1024 * 1024);

      expect(verdict.isOpen, isTrue, reason: '$device');
      expect(verdict.refusal, isNull);
      expect(jsonDecode(StereoPhotoRequest.scene(verdict.request!).toImmersiveJson()), designRequest);
    }
  });

  test('the Quest 3, the 3S and a headset not known take 400 000 triangles and 200 000 vertices', () {
    for (final device in [null, 'eureka', 'panther', 'some-new-headset']) {
      expect(sceneCapsFor(device), same(sceneCurrentHeadsets));
    }
    expect(sceneGateOf(sampleWith({'SceneTriangles': '400000'})).isOpen, isTrue);
    expect(
      sceneGateOf(sampleWith({'SceneTriangles': '400001'})),
      const SceneGateVerdict.refused(SceneRefusal.tooHeavy, triangles: 400001, maxTriangles: 400000),
    );
    expect(sceneGateOf(sampleWith({'SceneVertices': '200000'})).isOpen, isTrue);
    expect(
      sceneGateOf(sampleWith({'SceneVertices': '200001'})),
      const SceneGateVerdict.refused(SceneRefusal.tooHeavy),
      reason: 'only the triangles are said with their numbers',
    );
  });

  test('the Quest 2 and the Quest Pro take half of it', () {
    for (final device in ['hollywood', 'seacliff']) {
      expect(sceneCapsFor(device), same(sceneOlderHeadsets));
      expect(sceneGateOf(sampleWith({'SceneTriangles': '200000'}), device: device).isOpen, isTrue);
      expect(
        sceneGateOf(sampleWith({'SceneTriangles': '200001'}), device: device),
        const SceneGateVerdict.refused(SceneRefusal.tooHeavy, triangles: 200001, maxTriangles: 200000),
      );
      expect(sceneGateOf(sampleWith({'SceneVertices': '100001'}), device: device).refusal, SceneRefusal.tooHeavy);
    }
  });

  test('a texture beyond 4096 px or a file beyond 64 MiB is too heavy for every headset', () {
    expect(sceneGateOf(sampleWith({'SceneTextureMax': '4097'})).refusal, SceneRefusal.tooHeavy);
    expect(sceneGateOf(sampleWith(), fileSize: 64 * 1024 * 1024).isOpen, isTrue);
    expect(sceneGateOf(sampleWith(), fileSize: 64 * 1024 * 1024 + 1).refusal, SceneRefusal.tooHeavy);
    expect(sceneGateOf(sampleWith()).isOpen, isTrue, reason: 'a size not known is left to the headset');
  });

  test('a newer version of the packet or of the scene format is said to be newer, another format not ours', () {
    expect(sceneGateOf(sampleWith({'FormatVersion': '2'})).refusal, SceneRefusal.newerVersion);
    expect(sceneGateOf(sampleWith({'SceneFormat': 'glb-layers-v2'})).refusal, SceneRefusal.newerVersion);
    expect(sceneGateOf(sampleWith({'SceneFormat': 'splat-v1'})).refusal, SceneRefusal.notOurs);
    // The version first, as the headset reads it
    expect(
      sceneGateOf(sampleWith({'FormatVersion': '2', 'SceneTriangles': '900000'})).refusal,
      SceneRefusal.newerVersion,
    );
  });

  test('a packet that misses a part of the request says the scene data is missing', () {
    for (final field in ['SceneLength', 'SceneSha256', 'SceneTriangles', 'SafeLateral', 'FieldOfView']) {
      expect(sceneGateOf(sampleWith({field: ''})).refusal, SceneRefusal.missing, reason: field);
    }
    expect(sceneGateOf(sampleWith({'SceneSha256': 'ABC'})).refusal, SceneRefusal.missing);
  });
}
