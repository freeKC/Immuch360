// The binary glTF of a scene, in the format glb-layers-v1 (design-final 2026-10-27, section 8.2, point 3; lot S1), as
// the docstring of .github/desktop/ai/make_scene_fixture.py writes it and GlbReader.kt reads it:
//  1. one root node "camera" at the centre of the camera of the photo (x right, y up, looking towards -z), one child
//     node per mesh, no node with a transformation; at most 8 meshes, each of at most 65 535 vertices;
//  2. per mesh one primitive of triangles: POSITION float32 VEC3 with its min and max, TEXCOORD_0 float32 VEC2 (0, 0
//     the top left of the texture), indices uint32 only, one material;
//  3. materials opaque and KHR_materials_unlit, each showing one JPEG of the buffer; the photo is images[0], so every
//     mesh that shows it is the photo layer and the others the background (the rule of the readers);
//  4. asset.generator names the app and scene-v1; extras.immuch360 holds the format, the zone, the comfort scale and
//     the field of view; KHR_xmp_json_ld holds the packet of the photo as JSON-LD, but for SceneLength and
//     SceneSha256, which are those of this very glb.
// It passes the glTF-Validator of Khronos (a step of immuch360-desktop.yml) without error nor warning.

import 'dart:convert';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';

/// The constants of glTF this writer uses
abstract final class _Gltf {
  static const float = 5126;
  static const unsignedInt = 5125;
  static const arrayBuffer = 34962;
  static const elementArrayBuffer = 34963;
  static const triangles = 4;
  static const linear = 9729;
  static const clampToEdge = 33071;
  static const jsonChunk = 0x4E4F534A;
  static const binChunk = 0x004E4942;
}

/// The namespaces of the JSON-LD packet
const _rdfNamespace = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#';

/// Thrown when a scene does not fit the format
class GlbLayersException implements Exception {
  const GlbLayersException(this.message);

  final String message;

  @override
  String toString() => 'GlbLayersException: $message';
}

/// The glb of [meshes] showing [textures] (JPEG bytes, the photo first), with the zone [safe], the comfort [scale],
/// the horizontal field of view [fovDegrees], the maker [generator] ("Immuch360 Desktop 3.4.0 scene-v1") and the
/// packet [xmp] of the photo. Throws [GlbLayersException] for more meshes or vertices than the format takes.
Uint8List writeGlbLayers({
  required List<SceneMeshData> meshes,
  required List<Uint8List> textures,
  required SceneSafeZone safe,
  required double scale,
  required double fovDegrees,
  required String generator,
  required SceneXmp xmp,
}) {
  if (meshes.isEmpty || meshes.length > SceneV1.maxMeshes) {
    throw GlbLayersException('${meshes.length} meshes: 1 to ${SceneV1.maxMeshes}');
  }
  if (textures.isEmpty) {
    throw const GlbLayersException('A scene shows at least the photo');
  }
  final binary = BytesBuilder(copy: false);
  var length = 0;
  final views = <Map<String, Object>>[];
  final accessors = <Map<String, Object>>[];

  int view(Uint8List data, {int? target}) {
    final padding = (4 - length % 4) % 4;
    if (padding > 0) {
      binary.add(Uint8List(padding));
      length += padding;
    }
    views.add({'buffer': 0, 'byteOffset': length, 'byteLength': data.length, 'target': ?target});
    binary.add(data);
    length += data.length;
    return views.length - 1;
  }

  final images = [
    for (final texture in textures) {'bufferView': view(texture), 'mimeType': 'image/jpeg'},
  ];
  final gltfMeshes = <Map<String, Object>>[];
  final nodes = <Map<String, Object>>[
    {'name': 'camera', 'children': <int>[]},
  ];
  for (final mesh in meshes) {
    if (mesh.vertices > SceneV1.maxMeshVertices) {
      throw GlbLayersException('A mesh of ${mesh.vertices} vertices: ${SceneV1.maxMeshVertices} at most');
    }
    if (mesh.texture < 0 || mesh.texture >= textures.length) {
      throw GlbLayersException('A mesh shows the texture ${mesh.texture} of ${textures.length}');
    }
    final min = [double.infinity, double.infinity, double.infinity];
    final max = [double.negativeInfinity, double.negativeInfinity, double.negativeInfinity];
    for (var i = 0; i < mesh.positions.length; i++) {
      final value = mesh.positions[i];
      if (!value.isFinite) {
        throw const GlbLayersException('A position that is not a finite number');
      }
      min[i % 3] = value < min[i % 3] ? value : min[i % 3];
      max[i % 3] = value > max[i % 3] ? value : max[i % 3];
    }
    for (final index in mesh.indices) {
      if (index >= mesh.vertices) {
        throw GlbLayersException('An index $index over ${mesh.vertices} vertices');
      }
    }
    final positions = view(_littleEndian(mesh.positions), target: _Gltf.arrayBuffer);
    accessors.add({
      'bufferView': positions,
      'componentType': _Gltf.float,
      'count': mesh.vertices,
      'type': 'VEC3',
      'min': min,
      'max': max,
    });
    final uvs = view(_littleEndian(mesh.uvs), target: _Gltf.arrayBuffer);
    accessors.add({'bufferView': uvs, 'componentType': _Gltf.float, 'count': mesh.vertices, 'type': 'VEC2'});
    final indices = view(_littleEndian(mesh.indices), target: _Gltf.elementArrayBuffer);
    accessors.add({
      'bufferView': indices,
      'componentType': _Gltf.unsignedInt,
      'count': mesh.indices.length,
      'type': 'SCALAR',
    });
    final first = accessors.length - 3;
    gltfMeshes.add({
      'primitives': [
        {
          'attributes': {'POSITION': first, 'TEXCOORD_0': first + 1},
          'indices': first + 2,
          'material': mesh.texture,
          'mode': _Gltf.triangles,
        },
      ],
    });
    (nodes.first['children']! as List<int>).add(nodes.length);
    nodes.add({'mesh': gltfMeshes.length - 1});
  }
  final padding = (4 - length % 4) % 4;
  if (padding > 0) {
    binary.add(Uint8List(padding));
    length += padding;
  }
  final document = {
    'asset': {
      'version': '2.0',
      'generator': generator,
      'extensions': {
        'KHR_xmp_json_ld': {'packet': 0},
      },
    },
    'extensionsUsed': ['KHR_materials_unlit', 'KHR_xmp_json_ld'],
    'extensions': {
      'KHR_xmp_json_ld': {
        'packets': [sceneJsonLd(xmp)],
      },
    },
    'scene': 0,
    'scenes': [
      {
        'nodes': [0],
      },
    ],
    'nodes': nodes,
    'meshes': gltfMeshes,
    'materials': [
      for (var i = 0; i < textures.length; i++)
        {
          'pbrMetallicRoughness': {
            'baseColorTexture': {'index': i},
            'metallicFactor': 0.0,
          },
          'extensions': {'KHR_materials_unlit': <String, Object>{}},
        },
    ],
    'textures': [
      for (var i = 0; i < textures.length; i++) {'sampler': 0, 'source': i},
    ],
    'samplers': [
      {'magFilter': _Gltf.linear, 'minFilter': _Gltf.linear, 'wrapS': _Gltf.clampToEdge, 'wrapT': _Gltf.clampToEdge},
    ],
    'images': images,
    'accessors': accessors,
    'bufferViews': views,
    'buffers': [
      {'byteLength': length},
    ],
    'extras': {
      'immuch360': {'format': SceneV1.format, 'safe': safe.toJson(), 'scale': scale, 'fovDegrees': fovDegrees},
    },
  };
  final json = utf8.encode(jsonEncode(document));
  final jsonLength = json.length + (4 - json.length % 4) % 4;
  final total = 12 + 8 + jsonLength + 8 + length;
  final out = Uint8List(total);
  final words = ByteData.sublistView(out);
  words
    ..setUint32(0, glbMagicValue, Endian.little)
    ..setUint32(4, 2, Endian.little)
    ..setUint32(8, total, Endian.little)
    ..setUint32(12, jsonLength, Endian.little)
    ..setUint32(16, _Gltf.jsonChunk, Endian.little);
  out.setRange(20, 20 + json.length, json);
  out.fillRange(20 + json.length, 20 + jsonLength, 0x20);
  words
    ..setUint32(20 + jsonLength, length, Endian.little)
    ..setUint32(24 + jsonLength, _Gltf.binChunk, Endian.little);
  out.setRange(28 + jsonLength, total, binary.takeBytes());
  return out;
}

/// "glTF" as the first word of a glb
const glbMagicValue = 0x46546C67;

/// The packet [xmp] as the JSON-LD of KHR_xmp_json_ld: the same names and values as in the XMP of the photo, but for
/// SceneLength and SceneSha256 (the length and the sum of the glb that holds it)
Map<String, Object> sceneJsonLd(SceneXmp xmp) {
  const ours = immuch360XmpPrefix;
  final fields = <String, Object>{
    'xmp:CreatorTool': ?xmp.creatorTool,
    '$iptcExtensionPrefix:DigitalSourceType': ?xmp.digitalSourceType,
    '$ours:FormatVersion': '${xmp.formatVersion}',
    '$ours:Kind': xmp.kind.xmp,
    '$ours:Origin': ?xmp.origin?.xmp,
    '$ours:Pipeline': ?xmp.pipeline,
    for (final (name, value) in xmp.kindFields)
      if (name != 'SceneLength' && name != 'SceneSha256') '$ours:$name': value,
    '$ours:DerivativeId': ?xmp.derivativeId,
    '$ours:SourceName': ?xmp.sourceName,
    '$ours:SourceSize': ?xmp.sourceSize?.toString(),
    '$ours:SourceSha1': ?xmp.sourceSha1,
    '$ours:SourceQuarterTurns': ?xmp.sourceQuarterTurns?.toString(),
    '$ours:QualityFlags': qualityFlagsToXmp(xmp.qualityFlags),
    '$ours:Created': ?xmp.created,
    if (xmp.description case final description?)
      'dc:description': {
        '@type': 'rdf:Alt',
        'rdf:_1': {'@language': 'x-default', '@value': description},
      },
  };
  return {
    '@context': {
      'dc': dublinCoreNamespace,
      'xmp': xmpBasicNamespace,
      'rdf': _rdfNamespace,
      iptcExtensionPrefix: iptcExtensionNamespace,
      ours: immuch360XmpNamespace,
    },
    '@id': '',
    ...fields,
  };
}

Uint8List _littleEndian(TypedData data) {
  // The computers the app runs on are little endian, as glTF: the bytes of the list as they are
  return Uint8List.fromList(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
}
