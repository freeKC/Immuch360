// test/fixtures/ai_immersive/tiny_scene3D_dart.jpg: a scene written by the engine of the computers (SceneChain, lot
// S1) with the fakes of lot C0 and the Dart codec, which the Kotlin of the Quest reads in SceneCrossContractTest.kt
// with the readers of lot S2: the contract between the writer and the headset, tested on both sides. This test makes
// it again and compares it with the file of the repository, byte for byte under Linux, where it was written (another
// system may give another last digit to an arc tangent). IMMUCH360_WRITE_SCENE_FIXTURE=1 writes it instead.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_engine.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/services/ai_immersive/scene_container.dart';
import 'package:path/path.dart' as p;

import 'scene_test_support.dart';

const _fixture = 'test/fixtures/ai_immersive/tiny_scene3D_dart.jpg';

/// The scene of the fixture, made in [folder]
Uint8List makeFixtureScene(Directory folder) {
  final path = scenePhoto(folder, 'tiny.jpg');
  final part = p.join(folder.path, 'tiny_scene3D.jpg.part');
  final outcome = SceneChain(models: fakeSceneModels(), codecs: const [DartSbsCodec()]).run(
    sceneJobFor(path, partPath: part, sha1: sha1OfFile(path)),
    ChainOriginal(bytes: File(path).readAsBytesSync()),
    isCancelled: () => false,
  );
  if (!outcome.result.isDone) {
    throw StateError('${outcome.result.error}: ${outcome.result.message}');
  }
  return File(part).readAsBytesSync();
}

void main() {
  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('scene_fixture_test_'));
  tearDown(() => folder.deleteSync(recursive: true));

  test('the engine writes tiny_scene3D_dart.jpg as the repository holds it', () {
    final made = makeFixtureScene(folder);
    if (Platform.environment['IMMUCH360_WRITE_SCENE_FIXTURE'] == '1') {
      File(_fixture).writeAsBytesSync(made);
    }
    final held = File(_fixture).readAsBytesSync();
    final madeXmp = ImmersiveXmp.findIn(made)! as SceneXmp;
    final heldXmp = ImmersiveXmp.findIn(held)! as SceneXmp;

    expect(heldXmp.sceneMeshes, madeXmp.sceneMeshes);
    expect(heldXmp.sceneVertices, madeXmp.sceneVertices);
    expect(heldXmp.sceneTriangles, madeXmp.sceneTriangles);
    expect(heldXmp.safe!.lateral, closeTo(madeXmp.safe!.lateral, 1e-12));
    expect(heldXmp.fieldOfView, closeTo(madeXmp.fieldOfView!, 1e-12));
    if (Platform.isLinux) {
      expect(
        made,
        held,
        reason: 'run with IMMUCH360_WRITE_SCENE_FIXTURE=1 and commit the file when the engine changed',
      );
    }
  });

  test('the fixture is a scene of two layers that its readers take', () {
    final held = File(_fixture).readAsBytesSync();
    final xmp = ImmersiveXmp.findIn(held)! as SceneXmp;
    final glb = GlbView.read(sceneBytesOf(held, xmp)!);

    expect(xmp.isReadableScene, isTrue);
    expect(xmp.sceneMeshes, 2);
    expect(glb.imageOf(0), 0);
    expect(glb.imageOf(1), 1);
    expect(xmp.qualityFlags, contains(ReliefQualityFlag.hiddenAreas));
    expect(xmp.request, isNotNull);
  });
}
