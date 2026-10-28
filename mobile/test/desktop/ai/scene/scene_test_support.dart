// What the tests of the scene engine share: a glb read back as glb-layers-v1 says (a small reader of the tests, so that
// the writer is never checked by itself), photos made on the fly, an EXIF with a focal length, and the models of a
// scene made in the worker from the fakes of lot C0.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Pure Dart, already in the lock through maplibre_gl, as in lib/desktop/library/local_image_codec.dart
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/ai_worker.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/thread_priority.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_engine.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_backends.dart';

/// A glb read back: its JSON, its binary chunk, and the meshes as the readers take them
class GlbView {
  GlbView._(this.json, this.binary);

  /// Reads [glb]; throws [FormatException] when it is not a glb of version 2 with a JSON then a BIN chunk
  factory GlbView.read(Uint8List glb) {
    final data = ByteData.sublistView(glb);
    if (glb.length < 28 || data.getUint32(0, Endian.little) != 0x46546C67 || data.getUint32(4, Endian.little) != 2) {
      throw const FormatException('Not a glb of version 2');
    }
    if (data.getUint32(8, Endian.little) != glb.length) {
      throw FormatException('The header says ${data.getUint32(8, Endian.little)} bytes, the glb has ${glb.length}');
    }
    final jsonLength = data.getUint32(12, Endian.little);
    if (data.getUint32(16, Endian.little) != 0x4E4F534A || jsonLength % 4 != 0) {
      throw const FormatException('No JSON chunk first, or not aligned');
    }
    final json = jsonDecode(utf8.decode(glb.sublist(20, 20 + jsonLength))) as Map<String, dynamic>;
    final binLength = data.getUint32(20 + jsonLength, Endian.little);
    if (data.getUint32(24 + jsonLength, Endian.little) != 0x004E4942 || 28 + jsonLength + binLength != glb.length) {
      throw const FormatException('No BIN chunk at the end');
    }
    return GlbView._(json, Uint8List.sublistView(glb, 28 + jsonLength));
  }

  final Map<String, dynamic> json;
  final Uint8List binary;

  List<Map<String, dynamic>> list(String key) => (json[key] as List).cast<Map<String, dynamic>>();

  Uint8List viewBytes(int index) {
    final view = list('bufferViews')[index];
    final offset = (view['byteOffset'] ?? 0) as int;
    return Uint8List.sublistView(binary, offset, offset + (view['byteLength'] as int));
  }

  ByteData _accessor(int index) {
    final accessor = list('accessors')[index];
    return ByteData.sublistView(viewBytes(accessor['bufferView'] as int));
  }

  /// The floats of the accessor [index]
  Float32List floats(int index) {
    final data = _accessor(index);
    return Float32List.fromList([for (var i = 0; i < data.lengthInBytes; i += 4) data.getFloat32(i, Endian.little)]);
  }

  /// The uint32 indices of the accessor [index]
  Uint32List indices(int index) {
    final data = _accessor(index);
    return Uint32List.fromList([for (var i = 0; i < data.lengthInBytes; i += 4) data.getUint32(i, Endian.little)]);
  }

  /// The primitive of the mesh [index]
  Map<String, dynamic> primitive(int index) =>
      ((list('meshes')[index]['primitives'] as List).single as Map).cast<String, dynamic>();

  /// The image the mesh [index] shows, through its material
  int imageOf(int mesh) {
    final material = list('materials')[primitive(mesh)['material'] as int];
    final texture = ((material['pbrMetallicRoughness'] as Map)['baseColorTexture'] as Map)['index'] as int;
    return list('textures')[texture]['source'] as int;
  }

  /// The JPEG of the image [index]
  Uint8List image(int index) => viewBytes(list('images')[index]['bufferView'] as int);

  Map<String, dynamic> get extras => (json['extras'] as Map)['immuch360'] as Map<String, dynamic>;
}

/// A JPEG of [width] x [height] whose left half is a dark gradient and right half a light one, written in [folder]
String scenePhoto(Directory folder, String name, {int width = 48, int height = 32, Uint8List? exif}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final left = x < width ~/ 2;
      image.setPixelRgb(x, y, left ? 60 + x : 180 + y, left ? 90 + y : 160, left ? 40 : 120 + x);
    }
  }
  var bytes = img.encodeJpg(image, quality: 95);
  if (exif != null) {
    bytes = insertAfterSoi(bytes, exif);
  }
  final path = p.join(folder.path, name);
  File(path).writeAsBytesSync(bytes);
  return path;
}

/// A PNG of [picture]
Uint8List pngOf(SbsDecoded picture) => img.encodePng(
  img.Image.fromBytes(width: picture.width, height: picture.height, bytes: picture.rgba.buffer, numChannels: 4),
);

/// [jpeg] with the APP1 segment of [exif] (from "Exif\0\0" on) right after its SOI
Uint8List insertAfterSoi(Uint8List jpeg, Uint8List exif) {
  final segment = [0xFF, 0xE1, (exif.length + 2) >> 8, (exif.length + 2) & 0xFF, ...exif];
  return Uint8List.fromList([...jpeg.sublist(0, 2), ...segment, ...jpeg.sublist(2)]);
}

/// An EXIF of a little endian TIFF with an Exif IFD whose FocalLengthIn35mmFilm is [focal35] millimetres
Uint8List exifWithFocal35(int focal35) {
  final tiff = ByteData(8 + 2 + 12 + 4 + 2 + 12 + 4);
  tiff
    ..setUint16(0, 0x4949)
    ..setUint16(2, 42, Endian.little)
    ..setUint32(4, 8, Endian.little)
    // IFD0: one entry, the pointer to the Exif IFD
    ..setUint16(8, 1, Endian.little)
    ..setUint16(10, 0x8769, Endian.little)
    ..setUint16(12, 4, Endian.little)
    ..setUint32(14, 1, Endian.little)
    ..setUint32(18, 26, Endian.little)
    ..setUint32(22, 0, Endian.little)
    // The Exif IFD: FocalLengthIn35mmFilm, a SHORT
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 0xA405, Endian.little)
    ..setUint16(30, 3, Endian.little)
    ..setUint32(32, 1, Endian.little)
    ..setUint16(36, focal35, Endian.little)
    ..setUint32(40, 0, Endian.little);
  return Uint8List.fromList([0x45, 0x78, 0x69, 0x66, 0, 0, ...tiff.buffer.asUint8List()]);
}

/// An EXIF of a little endian TIFF whose IFD0 holds the Orientation [orientation] (6: turn a quarter clockwise to see)
Uint8List exifWithOrientation(int orientation) {
  final tiff = ByteData(8 + 2 + 12 + 4);
  tiff
    ..setUint16(0, 0x4949)
    ..setUint16(2, 42, Endian.little)
    ..setUint32(4, 8, Endian.little)
    ..setUint16(8, 1, Endian.little)
    ..setUint16(10, 0x0112, Endian.little)
    ..setUint16(12, 3, Endian.little)
    ..setUint32(14, 1, Endian.little)
    ..setUint16(18, orientation, Endian.little)
    ..setUint32(22, 0, Endian.little);
  return Uint8List.fromList([0x45, 0x78, 0x69, 0x66, 0, 0, ...tiff.buffer.asUint8List()]);
}

/// A scene job for the photo at [path] (or its [bytes]), with the fields the fixtures fix
SceneJob sceneJobFor(
  String path, {
  required String partPath,
  required String sha1,
  int quarterTurns = 0,
  bool asBytes = false,
  String? glbPartPath,
  ImmersiveExif exif = const ImmersiveExif(software: 'Immuch360 Desktop 3.4.0'),
}) {
  final bytes = File(path).readAsBytesSync();
  return SceneJob(
    id: 'scene-${p.basename(path)}',
    sources: [
      ImmersiveSource(
        name: p.basename(path),
        size: bytes.length,
        sha1: sha1,
        path: asBytes ? null : path,
        bytes: asBytes ? bytes : null,
      ),
    ],
    partPath: partPath,
    derivativeId: 'urn:uuid:7a2d3f1b-0000-4000-8000-000000000002',
    creatorTool: 'Immuch360 Desktop 3.4.0 (linux)',
    created: '2026-10-28T10:12:00+01:00',
    quarterTurns: quarterTurns,
    exif: exif,
    glbPartPath: glbPartPath,
  );
}

/// The hidden .part of the scene of [name] in [folder], as the writer names it
String scenePartIn(Directory folder, String name) =>
    p.join(folder.path, '.${p.basenameWithoutExtension(name)}_scene3D.jpg.4242-1.immuch360.part');

/// The models of a scene from the fakes of lot C0, made in the worker: a plain object sent to it
class FakeSceneModelsSpec implements SceneModelsSpec {
  const FakeSceneModelsSpec({this.shape = FakeGeometryShape.step, this.geometryFailure, this.inpaintFailure});

  final FakeGeometryShape shape;
  final ImmersiveErrorCode? geometryFailure;
  final ImmersiveErrorCode? inpaintFailure;

  @override
  SceneModels create(AiWorkerContext context, ComputePriority priority) =>
      fakeSceneModels(shape: shape, geometryFailure: geometryFailure, inpaintFailure: inpaintFailure);
}

/// The fakes as the models of a scene, with the ids of the catalogue
SceneModels fakeSceneModels({
  FakeGeometryShape shape = FakeGeometryShape.step,
  ImmersiveErrorCode? geometryFailure,
  ImmersiveErrorCode? inpaintFailure,
  FakeGeometryBackend? geometry,
  FakeInpaintBackend? inpaint,
}) => SceneModels(
  geometry:
      geometry ??
      FakeGeometryBackend(
        shape: shape,
        failure: geometryFailure == null ? null : BackendException(geometryFailure, 'Scripted ${geometryFailure.name}'),
      ),
  inpaint:
      inpaint ??
      FakeInpaintBackend(
        failure: inpaintFailure == null ? null : BackendException(inpaintFailure, 'Scripted ${inpaintFailure.name}'),
      ),
  geometryModel: mogeGeometryComponent.id,
  inpaintModel: lamaInpaintComponent.id,
);
