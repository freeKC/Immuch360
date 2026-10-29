// The photo that carries a scene, <name>_scene3D.jpg (design-final 2026-10-27, sections 8.1 and 8.2; lot S1): the
// JPEG of the preview (the photo seen from the start, 2 048 pixels at most, quality 85) with a minimal EXIF, our XMP
// (Kind VolumetricScene, SceneLength, SceneSha256, the IPTC of a file made with generative AI) and the ICC profile of
// the photo, then, after its end, the glb of the scene (glb_writer.dart), SceneLength bytes summed by SceneSha256.
// Image viewers stop at the end of the JPEG; scene_container.dart and SceneFile.kt find the scene in the last
// SceneLength bytes. No Container namespace nor MotionPhoto: nothing may take the tail for a video.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/scene/glb_writer.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_textures.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';

/// What a scene is made of before it is written
class SceneParts {
  const SceneParts({
    required this.meshes,
    required this.textures,
    required this.safe,
    required this.scale,
    required this.gridStep,
    required this.fieldOfView,
    required this.fieldOfViewSource,
    required this.hiddenFraction,
    required this.qualityFlags,
    required this.geometryModel,
    required this.geometryModelSha256,
    required this.inpaintModel,
    required this.inpaintModelSha256,
  });

  final List<SceneMeshData> meshes;

  /// The JPEG of the photo first, then that of the background when there is one
  final List<Uint8List> textures;

  final SceneSafeZone safe;
  final double scale;
  final int gridStep;
  final double fieldOfView;
  final FieldOfViewSource fieldOfViewSource;
  final double hiddenFraction;
  final List<ReliefQualityFlag> qualityFlags;
  final String geometryModel;
  final String geometryModelSha256;
  final String inpaintModel;
  final String inpaintModelSha256;

  int get vertices => meshes.fold(0, (total, mesh) => total + mesh.vertices);
  int get triangles => meshes.fold(0, (total, mesh) => total + mesh.triangles);
}

/// The original of a scene, as its packet names it
class SceneOriginal {
  const SceneOriginal({required this.name, required this.size, required this.sha1, required this.quarterTurns});

  final String name;
  final int size;
  final String sha1;
  final int quarterTurns;
}

/// A file written: its bytes, the glb at its end, its packet, the codec of its preview
class SceneFileBytes {
  const SceneFileBytes({required this.bytes, required this.glb, required this.xmp, required this.encoder});

  final Uint8List bytes;
  final Uint8List glb;
  final SceneXmp xmp;
  final String encoder;
}

/// "Immuch360 Desktop 3.4.0 scene-v1": the maker of the glb, from the xmp:CreatorTool of the file without its system
String sceneGenerator(String creatorTool) =>
    '${creatorTool.replaceFirst(RegExp(r' \([^)]*\)$'), '')} ${SceneV1.pipeline}';

/// The packet of a scene of [parts] made from [original]; [sceneLength] and [sceneSha256] are those of its glb
SceneXmp sceneXmpOf(
  SceneParts parts,
  SceneOriginal original, {
  required int sceneLength,
  required String sceneSha256,
  required int textureMax,
  required String derivativeId,
  required String created,
  required String creatorTool,
}) => SceneXmp.reconstructed(
  sceneLength: sceneLength,
  sceneSha256: sceneSha256,
  sceneMeshes: parts.meshes.length,
  sceneVertices: parts.vertices,
  sceneTriangles: parts.triangles,
  sceneTextureMax: textureMax,
  sceneScale: parts.scale,
  gridStep: parts.gridStep,
  safe: parts.safe,
  fieldOfView: parts.fieldOfView,
  fieldOfViewSource: parts.fieldOfViewSource,
  geometryModel: parts.geometryModel,
  geometryModelSha256: parts.geometryModelSha256,
  inpaintModel: parts.inpaintModel,
  inpaintModelSha256: parts.inpaintModelSha256,
  hiddenFraction: parts.hiddenFraction,
  sourceName: original.name,
  sourceSize: original.size,
  sourceSha1: original.sha1,
  sourceQuarterTurns: original.quarterTurns,
  created: created,
  creatorTool: creatorTool,
  derivativeId: derivativeId,
  qualityFlags: parts.qualityFlags,
);

/// The photo that carries the scene of [parts]: [preview] encoded by the first of [codecs] that writes it, with
/// [exif] (an APP1 payload from "Exif\0\0" on) and the packet, then the glb. [textureMax] is the longest side of the
/// largest texture. Throws GlbLayersException for a scene the format does not take, SbsCodecException when the
/// preview cannot be written.
SceneFileBytes writeSceneFile({
  required SceneParts parts,
  required SceneOriginal original,
  required SbsDecoded preview,
  required List<SbsCodec> codecs,
  required int textureMax,
  required String derivativeId,
  required String created,
  required String creatorTool,
  Uint8List? exif,
}) {
  SceneXmp packet({required int length, required String sum}) => sceneXmpOf(
    parts,
    original,
    sceneLength: length,
    sceneSha256: sum,
    textureMax: textureMax,
    derivativeId: derivativeId,
    created: created,
    creatorTool: creatorTool,
  );

  final glb = writeGlbLayers(
    meshes: parts.meshes,
    textures: parts.textures,
    safe: parts.safe,
    scale: parts.scale,
    fovDegrees: parts.fieldOfView,
    generator: sceneGenerator(creatorTool),
    // The JSON-LD of the glb leaves its own length and sum out
    xmp: packet(length: 0, sum: ''),
  );
  final xmp = packet(length: glb.length, sum: sha256.convert(glb).toString());
  final (jpeg, encoder) = encodeScenePicture(
    codecs,
    preview,
    quality: SceneV1.previewQuality,
    exif: exif,
    xmp: xmp.toXml(),
  );
  final bytes = Uint8List(jpeg.length + glb.length)
    ..setRange(0, jpeg.length, jpeg)
    ..setRange(jpeg.length, jpeg.length + glb.length, glb);
  return SceneFileBytes(bytes: bytes, glb: glb, xmp: xmp, encoder: encoder);
}
