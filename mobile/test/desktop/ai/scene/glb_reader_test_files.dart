// The photo that carries a scene of the fixtures, tiny_scene3D.jpg (written by
// .github/desktop/ai/make_scene_fixture.py), and the means to change it, for the Dart reader of glb-layers-v1 and the
// preview of the computers: its glb taken apart into its JSON and its binary chunk, a JSON edited at a path, a glb
// packed again, a glb made from meshes of a chosen size (the writer of the script, in Dart). The same helpers as
// SceneTestFiles.kt of the Quest, so that both readers are held to the same files; never the output of the reader.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const tinyScenePath = 'test/fixtures/ai_immersive/tiny_scene3D.jpg';

/// The bytes of tiny_scene3D.jpg
Uint8List tinySceneFile() => File(tinyScenePath).readAsBytesSync();

/// Where the glb of [file] starts: the last "glTF" of the file
int glbOffsetOf(Uint8List file) {
  for (var at = file.length - 12; at >= 0; at--) {
    if (file[at] == 0x67 && file[at + 1] == 0x6C && file[at + 2] == 0x54 && file[at + 3] == 0x46) {
      return at;
    }
  }
  throw StateError('no glTF in the file');
}

/// The glb of the fixture
Uint8List tinyGlb() {
  final file = tinySceneFile();
  return Uint8List.fromList(file.sublist(glbOffsetOf(file)));
}

/// The JPEG preview of the fixture, its packet included, without the scene
Uint8List tinyPreview() {
  final file = tinySceneFile();
  return Uint8List.fromList(file.sublist(0, glbOffsetOf(file)));
}

String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();

/// The JSON chunk and the binary chunk of [glb]
(Map<String, Object?>, Uint8List) splitGlb(Uint8List glb) {
  final words = ByteData.sublistView(glb);
  final jsonLength = words.getUint32(12, Endian.little);
  final json = jsonDecode(utf8.decode(glb.sublist(20, 20 + jsonLength))) as Map<String, Object?>;
  final binLength = words.getUint32(20 + jsonLength, Endian.little);
  return (json, Uint8List.fromList(glb.sublist(28 + jsonLength, 28 + jsonLength + binLength)));
}

/// A glb of [json] and [bin] (no binary chunk when null), each chunk padded to 4 bytes as the format asks
Uint8List packGlb(Map<String, Object?> json, Uint8List? bin, {int version = 2}) {
  final text = [...utf8.encode(jsonEncode(json))];
  while (text.length % 4 != 0) {
    text.add(0x20);
  }
  final binary = bin == null ? null : [...bin];
  while (binary != null && binary.length % 4 != 0) {
    binary.add(0);
  }
  final total = 12 + 8 + text.length + (binary == null ? 0 : 8 + binary.length);
  final out = ByteData(total)
    ..setUint32(0, 0x46546C67, Endian.little)
    ..setUint32(4, version, Endian.little)
    ..setUint32(8, total, Endian.little)
    ..setUint32(12, text.length, Endian.little)
    ..setUint32(16, 0x4E4F534A, Endian.little);
  final bytes = out.buffer.asUint8List();
  bytes.setAll(20, text);
  if (binary != null) {
    out
      ..setUint32(20 + text.length, binary.length, Endian.little)
      ..setUint32(24 + text.length, 0x004E4942, Endian.little);
    bytes.setAll(28 + text.length, binary);
  }
  return bytes;
}

/// [root] with the value at [path] (object keys and list indices) replaced by [value], or removed when [remove]
Object? editJson(Object? root, List<Object> path, Object? value, {bool remove = false}) {
  if (path.isEmpty) {
    return value;
  }
  final key = path.first;
  final rest = path.sublist(1);
  if (key is String) {
    final map = Map<String, Object?>.of(root! as Map<String, Object?>);
    if (rest.isEmpty && remove) {
      map.remove(key);
    } else {
      map[key] = editJson(map[key] ?? <String, Object?>{}, rest, value, remove: remove);
    }
    return map;
  }
  final list = List<Object?>.of(root! as List<Object?>);
  list[key as int] = editJson(list[key], rest, value, remove: remove);
  return list;
}

/// The glb of the fixture with the value at [path] set to [value], or removed when [remove]
Uint8List tinyGlbWith(List<Object> path, Object? value, {bool remove = false}) {
  final (json, bin) = splitGlb(tinyGlb());
  return packGlb(editJson(json, path, value, remove: remove)! as Map<String, Object?>, bin);
}

/// One mesh of a glb: its positions, texture coordinates, triangle indices and the image its material shows
class MeshData {
  const MeshData(this.positions, this.uvs, this.indices, this.image);

  final List<double> positions;
  final List<double> uvs;
  final List<int> indices;
  final int image;
}

/// A glb of glb-layers-v1 holding [meshes] and the JPEG [images], as make_scene_fixture.py writes one: a root node at
/// the centre of the camera, one child per mesh, one material per image, extras.immuch360 with [format]
Uint8List glbOf(
  List<MeshData> meshes,
  List<Uint8List> images, {
  String format = 'glb-layers-v1',
  int indexType = 5125,
}) {
  final binary = <int>[];
  final views = <Map<String, Object?>>[];
  final accessors = <Map<String, Object?>>[];
  int view(List<int> data, int? target) {
    while (binary.length % 4 != 0) {
      binary.add(0);
    }
    views.add({'buffer': 0, 'byteOffset': binary.length, 'byteLength': data.length, 'target': ?target});
    binary.addAll(data);
    return views.length - 1;
  }

  List<int> floats(List<double> values) {
    final data = ByteData(4 * values.length);
    for (var i = 0; i < values.length; i++) {
      data.setFloat32(4 * i, values[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  List<int> ints(List<int> values) {
    final size = indexType == 5123 ? 2 : 4;
    final data = ByteData(size * values.length);
    for (var i = 0; i < values.length; i++) {
      if (size == 2) {
        data.setUint16(2 * i, values[i], Endian.little);
      } else {
        data.setUint32(4 * i, values[i], Endian.little);
      }
    }
    return data.buffer.asUint8List();
  }

  final imageViews = [for (final image in images) view(image, null)];
  final gltfMeshes = <Map<String, Object?>>[];
  for (final mesh in meshes) {
    final count = mesh.positions.length ~/ 3;
    final stored = Float32List.fromList(mesh.positions);
    double bound(int axis, bool max) {
      var value = stored[axis];
      for (var k = 1; k < count; k++) {
        final v = stored[3 * k + axis];
        value = max ? (v > value ? v : value) : (v < value ? v : value);
      }
      return value;
    }

    accessors.add({
      'bufferView': view(floats(mesh.positions), 34962),
      'componentType': 5126,
      'count': count,
      'type': 'VEC3',
      'min': [for (var i = 0; i < 3; i++) bound(i, false)],
      'max': [for (var i = 0; i < 3; i++) bound(i, true)],
    });
    accessors.add({
      'bufferView': view(floats(mesh.uvs), 34962),
      'componentType': 5126,
      'count': mesh.uvs.length ~/ 2,
      'type': 'VEC2',
    });
    accessors.add({
      'bufferView': view(ints(mesh.indices), 34963),
      'componentType': indexType,
      'count': mesh.indices.length,
      'type': 'SCALAR',
    });
    final first = accessors.length - 3;
    gltfMeshes.add({
      'primitives': [
        {
          'attributes': {'POSITION': first, 'TEXCOORD_0': first + 1},
          'indices': first + 2,
          'material': mesh.image,
          'mode': 4,
        },
      ],
    });
  }
  while (binary.length % 4 != 0) {
    binary.add(0);
  }
  final json = <String, Object?>{
    'asset': {'version': '2.0', 'generator': 'glb_reader_test_files.dart'},
    'extensionsUsed': ['KHR_materials_unlit'],
    'scene': 0,
    'scenes': [
      {
        'nodes': [0],
      },
    ],
    'nodes': [
      {
        'name': 'camera',
        'children': [for (var i = 0; i < meshes.length; i++) i + 1],
      },
      for (var i = 0; i < meshes.length; i++) {'mesh': i},
    ],
    'meshes': gltfMeshes,
    'materials': [
      for (var i = 0; i < images.length; i++)
        {
          'pbrMetallicRoughness': {
            'baseColorTexture': {'index': i},
            'metallicFactor': 0.0,
          },
          'extensions': {'KHR_materials_unlit': <String, Object?>{}},
        },
    ],
    'textures': [
      for (var i = 0; i < images.length; i++) {'sampler': 0, 'source': i},
    ],
    'samplers': [
      {'magFilter': 9729, 'minFilter': 9729},
    ],
    'images': [
      for (final view in imageViews) {'bufferView': view, 'mimeType': 'image/jpeg'},
    ],
    'accessors': accessors,
    'bufferViews': views,
    'buffers': [
      {'byteLength': binary.length},
    ],
    'extras': {
      'immuch360': {
        'format': format,
        'safe': {'lateral': 0.2, 'vertical': 0.12, 'forward': 0.4, 'backward': 0.1},
        'scale': 1.0,
        'fovDegrees': 65.0,
      },
    },
  };
  return packGlb(json, Uint8List.fromList(binary));
}

/// A grid of [columns] x [rows] vertices at [depth] metres, all its cells drawn, showing [image]
MeshData gridMesh(int columns, int rows, double depth, int image) {
  final positions = <double>[];
  final uvs = <double>[];
  for (var row = 0; row < rows; row++) {
    for (var column = 0; column < columns; column++) {
      final u = column / (columns - 1);
      final v = row / (rows - 1);
      positions.addAll([(2 * u - 1) * depth, (1 - 2 * v) * depth, -depth]);
      uvs.addAll([u, v]);
    }
  }
  final indices = <int>[];
  for (var row = 0; row < rows - 1; row++) {
    for (var column = 0; column < columns - 1; column++) {
      final a = row * columns + column;
      indices.addAll([a, a + columns, a + 1, a + 1, a + columns, a + columns + 1]);
    }
  }
  return MeshData(positions, uvs, indices, image);
}

/// The two JPEG textures of the fixture: 32 x 24, then 16 x 16
List<Uint8List> tinyImages() {
  final (json, bin) = splitGlb(tinyGlb());
  final views = json['bufferViews']! as List<Object?>;
  return [
    for (final image in json['images']! as List<Object?>)
      () {
        final view = views[(image! as Map<String, Object?>)['bufferView']! as int]! as Map<String, Object?>;
        final offset = view['byteOffset']! as int;
        return Uint8List.fromList(bin.sublist(offset, offset + (view['byteLength']! as int)));
      }(),
  ];
}
