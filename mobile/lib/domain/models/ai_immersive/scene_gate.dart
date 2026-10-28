// The gate of the 3D scenes on the Meta Quest, read in the packet at the head of a photo that carries a scene before
// anything else of it is downloaded (design-final 2026-10-27, section 3.5, spec 8.3 and 10.2): the "Explore the 3D
// scene" and "View the 3D scene" buttons of the 2D panel are offered, or greyed with the reason, from the packet alone.
// The caps are those of SceneGate.kt, which the immersive viewer checks again on the glb, with the free memory of the
// headset and its heat. Until the second session of MQ in the headset they are a hypothesis (section 3.6), as on the
// Kotlin side.

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';

/// What a headset takes: vertices and triangles in all, the longest side of a texture, the bytes of the file
class SceneHeadsetCaps {
  const SceneHeadsetCaps({
    required this.maxVertices,
    required this.maxTriangles,
    this.maxTextureSide = 4096,
    this.maxFileBytes = 64 * 1024 * 1024,
  });

  final int maxVertices;
  final int maxTriangles;
  final int maxTextureSide;
  final int maxFileBytes;
}

/// Quest 3, Quest 3S, and a headset this build does not know (SceneGate.CURRENT_HEADSETS)
const sceneCurrentHeadsets = SceneHeadsetCaps(maxVertices: 200000, maxTriangles: 400000);

/// Quest 2 and Quest Pro (SceneGate.OLDER_HEADSETS), whose textures the viewer decodes at half beyond 2048 px
const sceneOlderHeadsets = SceneHeadsetCaps(maxVertices: 100000, maxTriangles: 200000);

/// Build.DEVICE of the Quest 2 and the Quest Pro
const sceneOlderDevices = {'hollywood', 'seacliff'};

/// The caps of the headset whose Build.DEVICE is [device]; those of the Quest 3 when it is unknown
SceneHeadsetCaps sceneCapsFor(String? device) =>
    sceneOlderDevices.contains(device) ? sceneOlderHeadsets : sceneCurrentHeadsets;

/// Why a scene stays flat in this headset
enum SceneRefusal {
  /// "Made by a newer version of Immuch360: shown flat": a later FormatVersion, or a later glb-layers-vN
  newerVersion,

  /// "Not a scene made by Immuch360": a scene format that is not ours
  notOurs,

  /// "The 3D scene data is missing from this file": the packet misses a part of the request
  missing,

  /// "This scene is too heavy for this headset (N triangles, at most M)", or without the numbers for another limit
  tooHeavy,
}

/// What the gate says of a scene: open with the [request] for the viewer, or refused with its [refusal] (and for too
/// many triangles, their number and the most this headset takes)
class SceneGateVerdict {
  const SceneGateVerdict.open(VolumetricSceneRequest this.request) : refusal = null, triangles = null, maxTriangles = null;

  const SceneGateVerdict.refused(SceneRefusal this.refusal, {this.triangles, this.maxTriangles}) : request = null;

  final VolumetricSceneRequest? request;
  final SceneRefusal? refusal;
  final int? triangles;
  final int? maxTriangles;

  bool get isOpen => request != null;

  @override
  bool operator ==(Object other) =>
      other is SceneGateVerdict &&
      other.request == request &&
      other.refusal == refusal &&
      other.triangles == triangles &&
      other.maxTriangles == maxTriangles;

  @override
  int get hashCode => Object.hash(request, refusal, triangles, maxTriangles);

  @override
  String toString() => isOpen
      ? 'SceneGateVerdict.open(${request!.triangles} triangles)'
      : 'SceneGateVerdict.refused($refusal${triangles == null ? '' : ', $triangles of $maxTriangles'})';
}

final _sceneFormatName = RegExp(r'^glb-layers-v([0-9]+)$');

/// The gate of the scene whose packet is [xmp] on the headset whose Build.DEVICE is [device], for a file of
/// [fileSize] bytes when known. In the order of SceneGate.kt: the version (FormatVersion, then the scene format), the
/// request the packet makes, then the triangles, the vertices, the textures and the file.
SceneGateVerdict sceneGateOf(SceneXmp xmp, {String? device, int? fileSize}) {
  if (xmp.isNewerFormat) {
    return const SceneGateVerdict.refused(SceneRefusal.newerVersion);
  }
  final format = xmp.sceneFormat;
  if (format != null && format.isNotEmpty && format != SceneV1.format) {
    final version = int.tryParse(_sceneFormatName.firstMatch(format)?.group(1) ?? '');
    return SceneGateVerdict.refused(
      version != null && version > 1 ? SceneRefusal.newerVersion : SceneRefusal.notOurs,
    );
  }
  final request = xmp.request;
  if (request == null) {
    return const SceneGateVerdict.refused(SceneRefusal.missing);
  }
  final caps = sceneCapsFor(device);
  if (request.triangles > caps.maxTriangles) {
    return SceneGateVerdict.refused(
      SceneRefusal.tooHeavy,
      triangles: request.triangles,
      maxTriangles: caps.maxTriangles,
    );
  }
  if (request.vertices > caps.maxVertices ||
      request.textureMax > caps.maxTextureSide ||
      (fileSize != null && fileSize > caps.maxFileBytes)) {
    return const SceneGateVerdict.refused(SceneRefusal.tooHeavy);
  }
  return SceneGateVerdict.open(request);
}
