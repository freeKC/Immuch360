import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// Pure Dart, already in the lock through maplibre_gl, as in lib/desktop/library/local_image_codec.dart
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/services/ai_immersive/scene_container.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';

void main() {
  final file = File('test/fixtures/ai_immersive/tiny_scene3D.jpg').readAsBytesSync();
  final xmp = ImmersiveXmp.findIn(file)! as SceneXmp;

  Future<Uint8List> Function(int offset, int length) reader(Uint8List bytes) =>
      (offset, length) async => Uint8List.sublistView(bytes, offset, offset + length);

  group('the tiny scene of make_scene_fixture.py', () {
    test('its packet is the one the Dart writer gives: Python writes our format', () {
      final text = latin1.decode(file);
      final start = text.indexOf('<?xpacket begin');
      final end = text.indexOf('<?xpacket end="w"?>\n') + '<?xpacket end="w"?>\n'.length;

      expect(utf8.decode(file.sublist(start, end)), xmp.toXml());
      expect(xmp.kind, ImmersiveKind.volumetricScene);
      expect(xmp.isReadableScene, isTrue);
      expect(xmp.sceneMeshes, 2);
      expect(xmp.sceneVertices, 13);
      expect(xmp.sceneTriangles, 10);
      expect(xmp.sceneTextureMax, 32);
      expect(xmp.request, isNotNull);
    });

    test('its preview is a photo any viewer decodes, and the probe of phase 1 shows it flat', () {
      final preview = img.decodeJpg(file)!;

      expect([preview.width, preview.height], [32, 24]);
      expect(
        decideStereoPhoto(name: 'tiny_scene3D.jpg', width: 32, height: 24, xmp: StereoPhotoXmp.findIn(file)),
        isNull,
      );
    });

    test('its tail is the scene the packet names: a binary glTF of version 2, its sum right', () async {
      final check = await checkSceneTail(reader(file), fileLength: file.length, xmp: xmp, chunk: 1000);
      final scene = sceneBytesOf(file, xmp)!;

      expect(check.isOk, isTrue, reason: '$check');
      expect(check.tail, SceneTail(offset: file.length - xmp.sceneLength!, length: xmp.sceneLength!));
      expect(scene.length, xmp.sceneLength);
      expect(ascii.decode(scene.sublist(0, 4)), 'glTF');
      final json =
          jsonDecode(utf8.decode(scene.sublist(20, 20 + ByteData.sublistView(scene).getUint32(12, Endian.little))))
              as Map<String, dynamic>;
      expect(json['extensionsUsed'], ['KHR_materials_unlit', 'KHR_xmp_json_ld']);
      expect((json['extras'] as Map)['immuch360']['format'], glbLayersV1);
      expect(json['meshes'], hasLength(2));
    });
  });

  group('a tail that does not read', () {
    test('cut off by a program that saved the JPEG again: missing', () async {
      final eoi = file.length - xmp.sceneLength!;
      final resaved = Uint8List.sublistView(file, 0, eoi);

      expect((await checkSceneTail(reader(resaved), fileLength: resaved.length, xmp: xmp)).problem, isNot(isNull));
      expect(sceneBytesOf(resaved, xmp), isNull);
    });

    test('a byte changed in the scene: the sum is wrong', () async {
      final damaged = Uint8List.fromList(file);
      damaged[damaged.length - 1] ^= 0xff;

      expect(
        (await checkSceneTail(reader(damaged), fileLength: damaged.length, xmp: xmp)).problem,
        SceneTailProblem.wrongSum,
      );
      // Without the sum, the header alone still reads
      expect(
        (await checkSceneTail(reader(damaged), fileLength: damaged.length, xmp: xmp, verifySum: false)).isOk,
        isTrue,
      );
      expect(sceneBytesOf(damaged, xmp), isNull);
    });

    test('a sum in capitals: wrong, as the request of the headset refuses it', () async {
      final upper = SceneXmp.parse(xmp.toXml().replaceAll(xmp.sceneSha256!, xmp.sceneSha256!.toUpperCase()))!;

      expect(upper.sceneSha256, isNot(xmp.sceneSha256));
      expect(upper.request, isNull);
      expect(
        (await checkSceneTail(reader(file), fileLength: file.length, xmp: upper)).problem,
        SceneTailProblem.wrongSum,
      );
      expect(sceneBytesOf(file, upper), isNull);
    });

    test('bytes appended after the scene: not a glTF where the packet says it starts', () async {
      final longer = Uint8List.fromList([...file, 0, 0, 0, 0]);

      expect(
        (await checkSceneTail(reader(longer), fileLength: longer.length, xmp: xmp)).problem,
        SceneTailProblem.notGltf,
      );
    });

    test('a header of another version or length', () {
      final header = Uint8List.fromList(
        file.sublist(file.length - xmp.sceneLength!, file.length - xmp.sceneLength! + 12),
      );
      final data = ByteData.sublistView(header);

      expect(checkSceneHeader(header, sceneLength: xmp.sceneLength!), isNull);
      expect(checkSceneHeader(header, sceneLength: xmp.sceneLength! + 1), SceneTailProblem.wrongLength);
      data.setUint32(4, 3, Endian.little);
      expect(checkSceneHeader(header, sceneLength: xmp.sceneLength!), SceneTailProblem.wrongVersion);
      expect(checkSceneHeader(Uint8List(4), sceneLength: 4), SceneTailProblem.missing);
    });

    test('a packet that names no scene, or more than the file holds', () async {
      const none = SceneXmp();
      final longer = SceneXmp.parse(xmp.toXml().replaceAll('SceneLength="${xmp.sceneLength}"', 'SceneLength="99999"'))!;

      expect(sceneTailOf(fileLength: file.length, xmp: none), isNull);
      expect(
        (await checkSceneTail(reader(file), fileLength: file.length, xmp: longer)).problem,
        SceneTailProblem.missing,
      );
    });
  });
}
