// The Dart reader of glb-layers-v1 (design-final 2026-10-27, sections 2.7 and 8.2), against the scene of
// tiny_scene3D.jpg written by make_scene_fixture.py, then against glbs a field away from it: the reader takes our
// subset and only it, tells "Not a scene made by Immuch360" of anything else and "Made by a newer version" of a later
// format of ours, and tells the layers as GlbReader.kt of the Quest does (the photo is images[0]), so that the
// preview of a computer and the headset flatten the same layers. The cases are those of GlbReaderTest.kt.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/scene/glb_reader.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

import 'glb_reader_test_files.dart';

GlbProblem _refused(Uint8List glb) {
  try {
    GlbReader.read(glb);
  } on GlbException catch (error) {
    return error.problem;
  }
  fail('read a glb the reader must refuse');
}

void _notOurs(Uint8List glb, String what) => expect(_refused(glb), GlbProblem.notOurs, reason: what);

double _f32(double value) => (Float32List(1)..[0] = value)[0];

/// A grid of 3 x 3 vertices at 2 m showing the photo, changed by [change]
Uint8List _gridWith(MeshData Function(MeshData mesh) change) => glbOf([change(gridMesh(3, 3, 2, 0))], tinyImages());

void main() {
  test('reads the two layers of the fixture, their textures and what the scene says of itself', () {
    final scene = GlbReader.read(tinyGlb());

    expect(scene.meshes, hasLength(2));
    expect(scene.vertices, 13);
    expect(scene.triangles, 10);
    final [front, back] = scene.meshes;
    expect(front.vertexCount, 9);
    expect(front.layer, SceneLayer.photo);
    expect(front.texture, 0);
    expect(back.vertexCount, 4);
    expect(back.layer, SceneLayer.background);
    expect(back.texture, 1);
    // The front layer: 3 x 3 vertices over a field of view of 60 degrees, 2 m deep at the top to 2.5 m at the bottom
    final halfWidth = math.tan(60 * math.pi / 180 / 2);
    final halfHeight = halfWidth / (32 / 24);
    expect(front.positions.sublist(0, 3), [_f32(-halfWidth * 2), _f32(halfHeight * 2), -2]);
    expect(front.positions.sublist(24, 27), [_f32(halfWidth * 2.5), _f32(-halfHeight * 2.5), -2.5]);
    expect(front.uvs.sublist(8, 10), [0.5, 0.5]);
    expect(front.indices.sublist(0, 6), [0, 3, 1, 1, 3, 4]);
    expect(front.indices, hasLength(24));
    expect(back.indices, [0, 2, 1, 1, 2, 3]);
    expect([for (var k = 0; k < 4; k++) back.positions[3 * k + 2]], everyElement(-3));
    // The textures: JPEGs in the buffer, their size read from their frame
    expect([for (final texture in scene.textures) (texture.width, texture.height)], [(32, 24), (16, 16)]);
    for (final texture in scene.textures) {
      expect(texture.bytes.sublist(0, 2), [0xFF, 0xD8]);
      expect(texture.bytes.last, 0xD9);
    }
    expect(scene.textures[1].bytes, tinyImages()[1]);
    expect(scene.format, glbLayersV1);
    expect(scene.safe, const SceneSafeZone(lateral: 0.15, vertical: 0.09, forward: 0.3, backward: 0.075));
    expect(scene.scale, 1.0);
    expect(scene.fovDegrees, 60.0);
    expect(scene.generator, 'Immuch360 make_scene_fixture.py scene-v1');
  });

  test('reads up to 8 meshes of up to 65 535 vertices, and refuses a ninth mesh or a 65 536th vertex', () {
    final images = tinyImages();
    // 255 x 257 = 65 535 vertices, the most a mesh may hold, then 7 more small meshes
    final largest = gridMesh(255, 257, 2, 0);
    final eight = [largest, for (var i = 0; i < 7; i++) gridMesh(2, 2, 3, 1)];
    final scene = GlbReader.read(glbOf(eight, images));
    expect(scene.meshes, hasLength(8));
    expect(scene.meshes[0].vertexCount, 65535);
    expect(scene.vertices, 65535 + 7 * 4);
    expect(scene.triangles, 2 * 254 * 256 + 7 * 2);
    expect(scene.meshes[0].indices.reduce(math.max), 65534);

    _notOurs(glbOf([...eight, gridMesh(2, 2, 3, 1)], images), 'nine meshes');
    _notOurs(glbOf([gridMesh(256, 256, 2, 0)], images), '65 536 vertices');
  });

  test('a later format of ours is newer, any other glTF is not ours', () {
    expect(_refused(tinyGlbWith(['extras', 'immuch360', 'format'], 'glb-layers-v2')), GlbProblem.newerFormat);
    _notOurs(tinyGlbWith(['extras'], null, remove: true), 'no extras');
    _notOurs(tinyGlbWith(['extras', 'immuch360', 'format'], null, remove: true), 'no format');
    _notOurs(tinyGlbWith(['extras', 'immuch360', 'format'], 'glb'), 'format');
    _notOurs(tinyGlbWith(['extras', 'immuch360', 'format'], 'glb-layers-v0'), 'format v0');
    _notOurs(tinyGlbWith(['asset', 'version'], '1.0'), 'glTF 1.0');
    expect(GlbReader.formatVersionOf('glb-layers-v12'), 12);
    expect(GlbReader.formatVersionOf('glb-layers-v'), isNull);
    expect(GlbReader.formatVersionOf(null), isNull);
  });

  test('only the extensions of the format may be required', () {
    _notOurs(tinyGlbWith(['extensionsRequired'], ['KHR_draco_mesh_compression']), 'Draco required');
    expect(GlbReader.read(tinyGlbWith(['extensionsRequired'], ['KHR_materials_unlit'])).meshes, hasLength(2));
    // An extension only used, not required, is left aside as glTF allows
    expect(
      GlbReader.read(tinyGlbWith(['extensionsUsed'], ['KHR_materials_unlit', 'EXT_something_new'])).meshes,
      hasLength(2),
    );
  });

  test('the geometry must be float32 positions and texture coordinates and uint32 indices, packed', () {
    _notOurs(glbOf([gridMesh(3, 3, 2, 0)], tinyImages(), indexType: 5123), 'uint16');
    _notOurs(tinyGlbWith(['accessors', 0, 'componentType'], 5123), 'short');
    _notOurs(tinyGlbWith(['accessors', 0, 'type'], 'VEC4'), 'VEC4');
    _notOurs(tinyGlbWith(['accessors', 1, 'type'], 'VEC3'), 'uv VEC3');
    _notOurs(tinyGlbWith(['accessors', 1, 'count'], 8), 'uv count');
    _notOurs(tinyGlbWith(['accessors', 2, 'count'], 23), 'not triangles');
    _notOurs(tinyGlbWith(['accessors', 0, 'normalized'], true), 'normalized');
    _notOurs(tinyGlbWith(['accessors', 0, 'sparse'], {'count': 1}), 'sparse');
    _notOurs(tinyGlbWith(['bufferViews', 2, 'byteStride'], 16), 'stride');
    _notOurs(tinyGlbWith(['meshes', 0, 'primitives', 0, 'attributes', 'TEXCOORD_0'], null, remove: true), 'uv');
    _notOurs(tinyGlbWith(['meshes', 0, 'primitives', 0, 'indices'], null, remove: true), 'no indices');
    _notOurs(tinyGlbWith(['accessors', 0, 'count'], 9.0), 'a count that is no integer');
    // A packed stride is the same as none
    expect(GlbReader.read(tinyGlbWith(['bufferViews', 2, 'byteStride'], 12)).vertices, 13);
  });

  test('an index past the vertices, or a position that is not a number, is refused', () {
    _notOurs(_gridWith((m) => MeshData(m.positions, m.uvs, [...m.indices]..[5] = 9, 0)), 'index 9 of 9');
    _notOurs(_gridWith((m) => MeshData([...m.positions]..[4] = double.nan, m.uvs, m.indices, 0)), 'NaN');
    _notOurs(_gridWith((m) => MeshData(m.positions, [...m.uvs]..[0] = double.infinity, m.indices, 0)), 'infinite uv');
  });

  test('views and accessors must lie within the buffer', () {
    _notOurs(tinyGlbWith(['bufferViews', 4, 'byteLength'], 4000), 'view past');
    _notOurs(tinyGlbWith(['bufferViews', 4, 'byteOffset'], 1040), 'view end');
    _notOurs(tinyGlbWith(['accessors', 0, 'count'], 10), 'accessor past');
    _notOurs(tinyGlbWith(['accessors', 0, 'byteOffset'], 4), 'offset past');
    _notOurs(tinyGlbWith(['bufferViews', 4, 'byteOffset'], -4), 'negative');
    _notOurs(tinyGlbWith(['accessors', 0, 'bufferView'], 42), 'no view');
    _notOurs(tinyGlbWith(['buffers', 0, 'uri'], 'scene.bin'), 'external buffer');
    _notOurs(tinyGlbWith(['buffers', 0, 'byteLength'], 2048), 'buffer past');
  });

  test('the materials must be opaque, show a JPEG of the buffer, and the nodes move nothing', () {
    _notOurs(tinyGlbWith(['materials', 0, 'alphaMode'], 'BLEND'), 'blend');
    _notOurs(tinyGlbWith(['images', 0, 'mimeType'], 'image/png'), 'png');
    _notOurs(tinyGlbWith(['images', 0, 'uri'], 'photo.jpg'), 'image uri');
    _notOurs(tinyGlbWith(['images', 0, 'bufferView'], 2), 'not a JPEG');
    _notOurs(tinyGlbWith(['materials', 1, 'pbrMetallicRoughness'], null, remove: true), 'no texture');
    _notOurs(tinyGlbWith(['materials', 1, 'pbrMetallicRoughness', 'baseColorTexture', 'texCoord'], 1), 'second uv set');
    _notOurs(tinyGlbWith(['meshes', 1, 'primitives', 0, 'material'], null, remove: true), 'no material');
    _notOurs(tinyGlbWith(['meshes', 1, 'primitives', 0, 'material'], 5), 'material 5');
    _notOurs(tinyGlbWith(['nodes', 1, 'translation'], [1.0, 1.0, 1.0]), 'moved node');
    _notOurs(tinyGlbWith(['nodes', 0, 'rotation'], [0.5, 0.5, 0.5, 0.5]), 'turned root');
    // OPAQUE written, and the mode of triangles left to its default, read the same
    expect(GlbReader.read(tinyGlbWith(['materials', 0, 'alphaMode'], 'OPAQUE')).meshes, hasLength(2));
    expect(GlbReader.read(tinyGlbWith(['meshes', 0, 'primitives', 0, 'mode'], null, remove: true)).triangles, 10);
  });

  test('one primitive of triangles per mesh', () {
    _notOurs(tinyGlbWith(['meshes', 0, 'primitives', 0, 'mode'], 1), 'lines');
    final (json, bin) = splitGlb(tinyGlb());
    final primitive = (((json['meshes']! as List)[0] as Map)['primitives'] as List)[0];
    _notOurs(
      packGlb(editJson(json, ['meshes', 0, 'primitives'], [primitive, primitive])! as Map<String, Object?>, bin),
      'two primitives',
    );
    _notOurs(tinyGlbWith(['meshes'], <Object?>[]), 'no mesh');
  });

  test('the layer of a mesh is told by its image, the photo being the first', () {
    final images = tinyImages();
    // The photo layer cut in two bands, then the background: the two bands share the photo, its texture is read once
    final scene = GlbReader.read(glbOf([gridMesh(3, 2, 2, 0), gridMesh(3, 2, 2.2, 0), gridMesh(2, 2, 3, 1)], images));
    expect([for (final mesh in scene.meshes) mesh.layer], [SceneLayer.photo, SceneLayer.photo, SceneLayer.background]);
    expect([for (final mesh in scene.meshes) mesh.texture], [0, 0, 1]);
    expect(scene.textures, hasLength(2));
    // An image no mesh shows is not a texture of the scene
    final photoOnly = GlbReader.read(glbOf([gridMesh(3, 3, 2, 0)], images));
    expect([for (final texture in photoOnly.textures) (texture.width, texture.height)], [(32, 24)]);
  });

  test('the photo is images 0 whichever mesh comes first, and a texture is counted among the images shown', () {
    final [photo, wall] = tinyImages();
    // The background first, then the photo: the layer follows the image, not the order of the meshes
    final backFirst = GlbReader.read(glbOf([gridMesh(2, 2, 3, 1), gridMesh(3, 3, 2, 0)], [photo, wall]));
    expect([for (final mesh in backFirst.meshes) mesh.layer], [SceneLayer.background, SceneLayer.photo]);
    // The textures in the order the meshes first show them: the wall, then the photo
    expect([for (final texture in backFirst.textures) (texture.width, texture.height)], [(16, 16), (32, 24)]);
    expect([for (final mesh in backFirst.meshes) mesh.texture], [0, 1]);
    expect(backFirst.photoTexture, 1);
    // Image 1 shown by no mesh: the wall, image 2, is the second texture, not the third
    final skipped = GlbReader.read(glbOf([gridMesh(3, 3, 2, 0), gridMesh(2, 2, 3, 2)], [photo, photo, wall]));
    expect([for (final mesh in skipped.meshes) mesh.texture], [0, 1]);
    expect([for (final texture in skipped.textures) (texture.width, texture.height)], [(32, 24), (16, 16)]);
    expect([for (final mesh in skipped.meshes) mesh.layer], [SceneLayer.photo, SceneLayer.background]);
    expect(skipped.photoTexture, 0);
    // A scene of the background alone has no photo texture
    expect(GlbReader.read(glbOf([gridMesh(2, 2, 3, 1)], [photo, wall])).photoTexture, isNull);
  });

  test('what extras says of the scene is read as the file says it', () {
    expect(GlbReader.read(tinyGlbWith(['extras', 'immuch360', 'scale'], 1.25)).scale, 1.25);
    expect(GlbReader.read(tinyGlbWith(['extras', 'immuch360', 'scale'], null, remove: true)).scale, isNull);
    expect(GlbReader.read(tinyGlbWith(['extras', 'immuch360', 'safe', 'forward'], 'far')).safe, isNull);
  });

  test('a glb cut short or with chunks out of place is not ours', () {
    final glb = tinyGlb();
    _notOurs(Uint8List.fromList(glb.sublist(0, glb.length - 8)), 'cut');
    _notOurs(Uint8List.fromList(glb.sublist(0, 16)), 'header only');
    _notOurs(Uint8List.fromList(glb)..[0] = 0x47, 'magic');
    // Bytes after the length its header gives
    _notOurs(Uint8List.fromList([...glb, 0, 0, 0, 0]), 'longer than its header says');
    _notOurs(Uint8List.fromList(glb)..[4] = 1, 'version 1');
    _notOurs(Uint8List.fromList(glb)..[16] = 0x58, 'JSON chunk type');
    final (json, bin) = splitGlb(glb);
    _notOurs(packGlb(json, null), 'no binary chunk');
    _notOurs(packGlb(json, bin)..[20] = 0x5B, 'not JSON');
    _notOurs(packGlb({'asset': 'no object'}, bin), 'asset not an object');
  });

  test('the size of a JPEG is read from its frame, baseline or progressive', () {
    final texture = tinyImages()[0];
    expect(GlbReader.jpegSize(texture, 0, texture.length), (32, 24));
    // The same frame marked progressive (SOF2)
    var sof = 2;
    while (!(texture[sof] == 0xFF && texture[sof + 1] == 0xC0)) {
      sof++;
    }
    final progressive = Uint8List.fromList(texture)..[sof + 1] = 0xC2;
    expect(GlbReader.jpegSize(progressive, 0, progressive.length), (32, 24));
    // No frame before the scan, a frame of no width or no height, a PNG, nothing at all
    expect(GlbReader.jpegSize(Uint8List.fromList(texture)..[sof + 1] = 0xC4, 0, texture.length), isNull);
    final noWidth = Uint8List.fromList(texture)
      ..[sof + 7] = 0
      ..[sof + 8] = 0;
    expect(GlbReader.jpegSize(noWidth, 0, texture.length), isNull);
    final noHeight = Uint8List.fromList(texture)
      ..[sof + 5] = 0
      ..[sof + 6] = 0;
    expect(GlbReader.jpegSize(noHeight, 0, texture.length), isNull);
    expect(GlbReader.jpegSize(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]), 0, 4), isNull);
    expect(GlbReader.jpegSize(Uint8List(0), 0, 0), isNull);
  });
}
