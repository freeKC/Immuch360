// Why this file exists: the preview of a 3D scene on a computer ("Preview in 3D", design-final 2026-10-27, section 2.7)
// reads the scene a photo of Immuch360 carries after its JPEG, and Dart had no reader of it. This is the reader of
// glb-layers-v1 (section 8.2) and of nothing else, the twin of GlbReader.kt of the Quest: the same rules, the same
// refusals, the same cases in its tests (glb_reader_test.dart against GlbReaderTest.kt), so that a scene the headset
// opens is one the computer previews, and the other way round. No glTF package: the format is ours and small.
//
// glb-layers-v1, as make_scene_fixture.py writes it and this reader takes it:
// 1. glTF 2.0 in a glb of version 2 (a JSON chunk, then a binary chunk holding the one buffer),
//    extras.immuch360.format "glb-layers-v1"; a later "glb-layers-vN" is a newer format of ours, anything else is not
//    a scene of ours;
// 2. at most 8 meshes, each one primitive of triangles (mode 4) of at most 65 535 vertices: POSITION float32 VEC3 and
//    TEXCOORD_0 float32 VEC2 (0, 0 at the top left of the texture), packed, finite, indices uint32 under the vertex
//    count; no sparse accessor;
// 3. a material per primitive, opaque (alphaMode OPAQUE or none), unlit for us whatever it says, whose base colour
//    texture (texture coordinates 0) is a JPEG held in the buffer; the sampler is left aside;
// 4. the nodes move nothing: positions are in metres in the frame of the camera of the photo, x right, y up, looking
//    towards -z;
// 5. the layer of a mesh is told by its image: the photo is images[0], and every mesh that shows it belongs to the
//    photo layer, the near one; a mesh that shows another image belongs to the background layer. A layer of more than
//    65 535 vertices comes cut in bands of rows, several meshes showing the same image;
// 6. only the extensions KHR_materials_unlit and KHR_xmp_json_ld may be required; one only used is left aside.
//
// extras.immuch360 also holds the safe zone, the scale and the field of view, read here as the file says them; the
// packet at the head of the file is what the preview goes by.

import 'dart:convert';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// Why a glb cannot be shown
enum GlbProblem {
  /// Not a glTF of our subset: "Not a scene made by Immuch360"
  notOurs,

  /// A later format of ours (glb-layers-v2 or above): "Made by a newer version of Immuch360"
  newerFormat,
}

class GlbException implements Exception {
  const GlbException(this.problem, this.message);

  final GlbProblem problem;
  final String message;

  @override
  String toString() => 'GlbException(${problem.name}: $message)';
}

/// The layer a mesh belongs to: the photo (near), or the filled background behind its breaks
enum SceneLayer { photo, background }

/// A JPEG texture of the scene: its bytes, a view into the glb, and its size in pixels read from its frame
class GlbTexture {
  const GlbTexture({required this.bytes, required this.width, required this.height});

  final Uint8List bytes;
  final int width;
  final int height;
}

/// One mesh as the glb holds it: x, y, z of each vertex in metres in the frame of the camera (looking towards -z), u, v
/// of each vertex, three indices per triangle (counter clockwise seen from the camera), the index of its texture in
/// [GlbScene.textures], and its layer
class GlbMesh {
  const GlbMesh({
    required this.positions,
    required this.uvs,
    required this.indices,
    required this.texture,
    required this.layer,
  });

  final Float32List positions;
  final Float32List uvs;
  final Uint32List indices;
  final int texture;
  final SceneLayer layer;

  int get vertexCount => positions.length ~/ 3;

  int get triangleCount => indices.length ~/ 3;
}

/// A scene read from its glb: its [meshes], the [textures] they show in the order they first show them, and what
/// extras.immuch360 says of it (null when the file does not say it)
class GlbScene {
  const GlbScene({
    required this.meshes,
    required this.textures,
    required this.format,
    this.safe,
    this.scale,
    this.fovDegrees,
    this.generator,
  });

  final List<GlbMesh> meshes;
  final List<GlbTexture> textures;
  final String format;
  final SceneSafeZone? safe;
  final double? scale;
  final double? fovDegrees;
  final String? generator;

  int get vertices => meshes.fold(0, (sum, mesh) => sum + mesh.vertexCount);

  int get triangles => meshes.fold(0, (sum, mesh) => sum + mesh.triangleCount);

  /// The texture of the photo layer, the photo itself; null for a scene without one
  int? get photoTexture {
    for (final mesh in meshes) {
      if (mesh.layer == SceneLayer.photo) {
        return mesh.texture;
      }
    }
    return null;
  }
}

/// See the top of this file
abstract final class GlbReader {
  /// The most meshes of a scene, and the most vertices of one mesh (16 bit indices)
  static const maxMeshes = SceneV1.maxMeshes;
  static const maxMeshVertices = SceneV1.maxMeshVertices;

  /// The format this build reads, extras.immuch360.format
  static const format = glbLayersV1;

  static const _magic = 0x46546C67;
  static const _chunkJson = 0x4E4F534A;
  static const _chunkBin = 0x004E4942;
  static const _float = 5126;
  static const _unsignedInt = 5125;
  static const _triangles = 4;
  static const _knownExtensions = {'KHR_materials_unlit', 'KHR_xmp_json_ld'};
  static final _formatName = RegExp(r'^glb-layers-v([0-9]+)$');

  /// The version N of a format "glb-layers-vN", null for another text
  static int? formatVersionOf(String? format) {
    final match = format == null ? null : _formatName.firstMatch(format);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// The scene [glb] holds; a [GlbException] when it is not one this build reads
  static GlbScene read(Uint8List glb) {
    final bytes = ByteData.sublistView(glb);
    if (glb.length < 20 ||
        bytes.getUint32(0, Endian.little) != _magic ||
        bytes.getUint32(4, Endian.little) != 2 ||
        bytes.getUint32(8, Endian.little) != glb.length) {
      throw _notOurs('not a glb of version 2 of ${glb.length} bytes');
    }
    final jsonLength = bytes.getUint32(12, Endian.little);
    if (jsonLength == 0 || bytes.getUint32(16, Endian.little) != _chunkJson || 20 + jsonLength + 8 > glb.length) {
      throw _notOurs('no JSON chunk followed by a binary chunk');
    }
    final binStart = 20 + jsonLength + 8;
    final binLength = bytes.getUint32(20 + jsonLength, Endian.little);
    if (bytes.getUint32(24 + jsonLength, Endian.little) != _chunkBin || binStart + binLength > glb.length) {
      throw _notOurs('no binary chunk');
    }
    final Object? root;
    try {
      root = jsonDecode(utf8.decode(Uint8List.sublistView(glb, 20, 20 + jsonLength)));
    } on FormatException {
      throw _notOurs('the JSON chunk is not JSON');
    }
    if (root is! Map<String, Object?>) {
      throw _notOurs('the JSON chunk is not a JSON object');
    }
    return _Document(root, glb, bytes, binStart, binLength).read();
  }

  /// The width and height of the JPEG in [data] from [offset], [length] bytes long, read from its frame header (any SOF
  /// but the DHT, JPG and DAC markers); null when it is not a JPEG or no frame comes before the first scan
  static (int, int)? jpegSize(Uint8List data, int offset, int length) {
    int byte(int at) => data[offset + at];
    if (length < 4 || byte(0) != 0xFF || byte(1) != 0xD8) {
      return null;
    }
    var at = 2;
    while (at + 4 <= length) {
      if (byte(at) != 0xFF) {
        return null;
      }
      final marker = byte(at + 1);
      // Fill bytes before a marker
      if (marker == 0xFF) {
        at += 1;
        continue;
      }
      // Markers without a segment
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        at += 2;
        continue;
      }
      if (marker == 0xD9 || marker == 0xDA) {
        return null;
      }
      final segment = (byte(at + 2) << 8) | byte(at + 3);
      if (segment < 2) {
        return null;
      }
      if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
        if (at + 9 > length) {
          return null;
        }
        final height = (byte(at + 5) << 8) | byte(at + 6);
        final width = (byte(at + 7) << 8) | byte(at + 8);
        return width > 0 && height > 0 ? (width, height) : null;
      }
      at += 2 + segment;
    }
    return null;
  }
}

GlbException _notOurs(String why) => GlbException(GlbProblem.notOurs, why);

/// The integer of [key] when it is a JSON integer
int? _integer(Map<String, Object?> parent, String key) => switch (parent[key]) {
  final int value => value,
  _ => null,
};

/// The finite number of [key] when it is a JSON number
double? _finite(Map<String, Object?>? parent, String key) => switch (parent?[key]) {
  final num value when value.isFinite => value.toDouble(),
  _ => null,
};

String? _string(Map<String, Object?>? parent, String key) => switch (parent?[key]) {
  final String value => value,
  _ => null,
};

/// One glb being read: its JSON [root], and its binary chunk at [binStart] in [glb], [binLength] bytes long
class _Document {
  _Document(this.root, this.glb, this.bytes, this.binStart, this.binLength);

  final Map<String, Object?> root;
  final Uint8List glb;
  final ByteData bytes;
  final int binStart;
  final int binLength;

  late final buffers = _objects('buffers');
  late final views = _objects('bufferViews');
  late final accessors = _objects('accessors');
  late final images = _objects('images');
  late final textures = _objects('textures');
  late final materials = _objects('materials');

  // The length of the one buffer, held by the binary chunk
  late final int bufferLength = () {
    if (buffers.length != 1 || buffers[0].containsKey('uri')) {
      throw _notOurs('not one buffer held by the glb');
    }
    final length = _integer(buffers[0], 'byteLength');
    if (length == null || length < 0 || length > binLength) {
      throw _notOurs('a buffer of $length bytes in a chunk of $binLength');
    }
    return length;
  }();

  List<Object?>? _array(Map<String, Object?> parent, String key) => switch (parent[key]) {
    null => null,
    final List<Object?> list => list,
    _ => throw _notOurs('$key is not a list'),
  };

  List<Map<String, Object?>> _objects(String key) => [
    for (final entry in _array(root, key) ?? const [])
      if (entry is Map<String, Object?>) entry else throw _notOurs('an entry of $key is not an object'),
  ];

  Map<String, Object?>? _object(Map<String, Object?>? parent, String key) => switch (parent?[key]) {
    null => null,
    final Map<String, Object?> map => map,
    _ => throw _notOurs('$key is not an object'),
  };

  int _index(Map<String, Object?> parent, String key, int size) {
    final value = _integer(parent, key);
    if (value == null) {
      throw _notOurs('no $key');
    }
    if (value < 0 || value >= size) {
      throw _notOurs('$key $value of $size');
    }
    return value;
  }

  GlbScene read() {
    final asset = _object(root, 'asset');
    if (asset == null) {
      throw _notOurs('no asset');
    }
    if (_string(asset, 'version') != '2.0') {
      throw _notOurs('glTF ${asset['version']}');
    }
    final extras = _object(_object(root, 'extras'), 'immuch360');
    final format = _string(extras, 'format');
    if (format != GlbReader.format) {
      final version = GlbReader.formatVersionOf(format);
      if (version != null && version > 1) {
        throw GlbException(GlbProblem.newerFormat, 'format $format');
      }
      throw _notOurs('format $format');
    }
    for (final required in _array(root, 'extensionsRequired') ?? const []) {
      if (required is! String || !GlbReader._knownExtensions.contains(required)) {
        throw _notOurs('requires $required');
      }
    }
    for (final node in _objects('nodes')) {
      if (const ['matrix', 'translation', 'rotation', 'scale'].any(node.containsKey)) {
        throw _notOurs('a node moves its mesh');
      }
    }
    final meshes = _objects('meshes');
    if (meshes.isEmpty || meshes.length > GlbReader.maxMeshes) {
      throw _notOurs('${meshes.length} meshes');
    }
    // The images the meshes show, in the order they are first shown: the textures of the scene
    final shown = <int>[];
    final read = <GlbMesh>[];
    for (final mesh in meshes) {
      final primitives = _array(mesh, 'primitives');
      if (primitives == null) {
        throw _notOurs('a mesh without primitives');
      }
      if (primitives.length != 1) {
        throw _notOurs('a mesh of ${primitives.length} primitives');
      }
      final primitive = primitives[0];
      if (primitive is! Map<String, Object?>) {
        throw _notOurs('a primitive is not an object');
      }
      if ((_integer(primitive, 'mode') ?? GlbReader._triangles) != GlbReader._triangles) {
        throw _notOurs('not triangles');
      }
      final attributes = _object(primitive, 'attributes');
      if (attributes == null) {
        throw _notOurs('no attributes');
      }
      final positions = _floats(_index(attributes, 'POSITION', accessors.length), 'VEC3', 3);
      final count = positions.length ~/ 3;
      if (count == 0 || count > GlbReader.maxMeshVertices) {
        throw _notOurs('a mesh of $count vertices');
      }
      final uvs = _floats(_index(attributes, 'TEXCOORD_0', accessors.length), 'VEC2', 2);
      if (uvs.length != 2 * count) {
        throw _notOurs('${uvs.length ~/ 2} texture coordinates for $count vertices');
      }
      final indices = _indices(_index(primitive, 'indices', accessors.length), count);
      final image = _imageOf(_index(primitive, 'material', materials.length));
      if (!shown.contains(image)) {
        shown.add(image);
      }
      read.add(
        GlbMesh(
          positions: positions,
          uvs: uvs,
          indices: indices,
          texture: shown.indexOf(image),
          layer: image == 0 ? SceneLayer.photo : SceneLayer.background,
        ),
      );
    }
    return GlbScene(
      meshes: read,
      textures: [for (final image in shown) _texture(image)],
      format: format!,
      safe: SceneSafeZone.fromJson(extras?['safe']),
      scale: _finite(extras, 'scale'),
      fovDegrees: _finite(extras, 'fovDegrees'),
      generator: _string(asset, 'generator'),
    );
  }

  /// The bytes of the view [view] in the glb: its first byte, its length, its stride (0 when none)
  (int, int, int) _view(int view) {
    final entry = views[view];
    if ((_integer(entry, 'buffer') ?? -1) != 0) {
      throw _notOurs('a view of another buffer');
    }
    final offset = _integer(entry, 'byteOffset') ?? 0;
    final length = _integer(entry, 'byteLength');
    if (length == null) {
      throw _notOurs('a view without byteLength');
    }
    if (offset < 0 || length < 0 || offset + length > bufferLength) {
      throw _notOurs('a view of $length bytes at $offset in a buffer of $bufferLength');
    }
    return (binStart + offset, length, _integer(entry, 'byteStride') ?? 0);
  }

  /// The place of [accessor] of [count] elements of [size] bytes: its first byte in the glb
  int _place(Map<String, Object?> accessor, int count, int size) {
    if (accessor.containsKey('sparse')) {
      throw _notOurs('a sparse accessor');
    }
    if (accessor['normalized'] == true) {
      throw _notOurs('a normalized accessor');
    }
    final (start, length, stride) = _view(_index(accessor, 'bufferView', views.length));
    if (stride != 0 && stride != size) {
      throw _notOurs('a stride of $stride for elements of $size bytes');
    }
    final offset = _integer(accessor, 'byteOffset') ?? 0;
    if (offset < 0 || count < 0 || offset + count * size > length) {
      throw _notOurs('$count elements of $size bytes at $offset in a view of $length');
    }
    return start + offset;
  }

  Float32List _floats(int accessor, String type, int components) {
    final entry = accessors[accessor];
    if (_integer(entry, 'componentType') != GlbReader._float || _string(entry, 'type') != type) {
      throw _notOurs('accessor $accessor is not float32 $type');
    }
    final count = _integer(entry, 'count');
    if (count == null) {
      throw _notOurs('accessor $accessor without count');
    }
    final start = _place(entry, count, 4 * components);
    final values = Float32List(count * components);
    for (var i = 0; i < values.length; i++) {
      final value = bytes.getFloat32(start + 4 * i, Endian.little);
      if (!value.isFinite) {
        throw _notOurs('accessor $accessor holds $value');
      }
      values[i] = value;
    }
    return values;
  }

  Uint32List _indices(int accessor, int vertices) {
    final entry = accessors[accessor];
    if (_integer(entry, 'componentType') != GlbReader._unsignedInt || _string(entry, 'type') != 'SCALAR') {
      throw _notOurs('indices not uint32');
    }
    final count = _integer(entry, 'count');
    if (count == null) {
      throw _notOurs('indices without count');
    }
    if (count == 0 || count % 3 != 0) {
      throw _notOurs('$count indices, not triangles');
    }
    final start = _place(entry, count, 4);
    final values = Uint32List(count);
    for (var i = 0; i < count; i++) {
      final value = bytes.getUint32(start + 4 * i, Endian.little);
      if (value >= vertices) {
        throw _notOurs('index $value of $vertices vertices');
      }
      values[i] = value;
    }
    return values;
  }

  /// The image [material] shows, checked: opaque, a base colour texture of texture coordinates 0
  int _imageOf(int material) {
    final entry = materials[material];
    final mode = entry['alphaMode'];
    if (entry.containsKey('alphaMode') && mode != 'OPAQUE') {
      throw _notOurs('alphaMode $mode');
    }
    final texture = _object(_object(entry, 'pbrMetallicRoughness'), 'baseColorTexture');
    if (texture == null) {
      throw _notOurs('material $material shows no texture');
    }
    if ((_integer(texture, 'texCoord') ?? 0) != 0) {
      throw _notOurs('a second set of texture coordinates');
    }
    final source = textures[_index(texture, 'index', textures.length)];
    return _index(source, 'source', images.length);
  }

  /// The JPEG of image [image], held in the buffer
  GlbTexture _texture(int image) {
    final entry = images[image];
    if (entry.containsKey('uri') || _string(entry, 'mimeType') != 'image/jpeg') {
      throw _notOurs('image $image not a JPEG of the glb');
    }
    final (start, length, _) = _view(_index(entry, 'bufferView', views.length));
    final size = GlbReader.jpegSize(glb, start, length);
    if (size == null) {
      throw _notOurs('image $image is not a JPEG');
    }
    return GlbTexture(bytes: Uint8List.sublistView(glb, start, start + length), width: size.$1, height: size.$2);
  }
}
