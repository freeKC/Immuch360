// The 3D scene a photo of Immuch360 carries after the end of its JPEG (design-final 2026-10-27, section 8.2): its
// last SceneLength bytes are a binary glTF of the glb-layers-v1 format, the header "glTF", version 2 and a total
// length equal to SceneLength, checked by SceneSha256. Read here once, for the gate of the Dart side (the state of the
// "Explore the 3D scene" button before the scene downloads), the details of the phones and the preview of the
// computers; the Kotlin of the Quest reads the same tail with its own reader (SceneFile.kt). Image viewers stop at the
// end of the JPEG and never see the tail; a program that saves the JPEG again drops it, which reads here as "missing".

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

/// "glTF" read as a little endian 32 bit number, the first word of a binary glTF
const glbMagic = 0x46546C67;

/// The version of glTF of the header
const glbVersion = 2;

/// The bytes of the header: magic, version, total length
const glbHeaderLength = 12;

/// Why the scene of a file cannot be read
enum SceneTailProblem {
  /// The packet names no scene, or the file is shorter than the scene it names
  missing,

  /// The bytes where the scene should start are not a binary glTF (the JPEG was saved again by another program)
  notGltf,

  /// A binary glTF of another version
  wrongVersion,

  /// The header gives another length than the packet
  wrongLength,

  /// The bytes are not those the packet sums
  wrongSum,
}

/// The place of the scene in its file: its first byte and its length
class SceneTail {
  const SceneTail({required this.offset, required this.length});

  final int offset;
  final int length;

  @override
  bool operator ==(Object other) => other is SceneTail && other.offset == offset && other.length == length;

  @override
  int get hashCode => Object.hash(offset, length);

  @override
  String toString() => 'SceneTail($offset, $length)';
}

/// What the check of a tail found: the [tail] when it reads, else its [problem]
class SceneTailCheck {
  const SceneTailCheck.ok(SceneTail this.tail) : problem = null;

  const SceneTailCheck.failed(SceneTailProblem this.problem) : tail = null;

  final SceneTail? tail;
  final SceneTailProblem? problem;

  bool get isOk => problem == null;

  @override
  String toString() => isOk ? 'SceneTailCheck($tail)' : 'SceneTailCheck(${problem!.name})';
}

/// Where the scene of [xmp] lies in a file of [fileLength] bytes, null when the packet names none or the file is too
/// short to hold it
SceneTail? sceneTailOf({required int fileLength, required SceneXmp xmp}) {
  final length = xmp.sceneLength;
  if (length == null || length < glbHeaderLength || length > fileLength) {
    return null;
  }
  return SceneTail(offset: fileLength - length, length: length);
}

/// What the [header] of a scene of [sceneLength] bytes tells: null when it is a binary glTF of version 2 of that
/// length, its problem otherwise. [header] holds at least the 12 first bytes of the scene.
SceneTailProblem? checkSceneHeader(Uint8List header, {required int sceneLength}) {
  if (header.length < glbHeaderLength) {
    return SceneTailProblem.missing;
  }
  final words = ByteData.sublistView(header, 0, glbHeaderLength);
  if (words.getUint32(0, Endian.little) != glbMagic) {
    return SceneTailProblem.notGltf;
  }
  if (words.getUint32(4, Endian.little) != glbVersion) {
    return SceneTailProblem.wrongVersion;
  }
  if (words.getUint32(8, Endian.little) != sceneLength) {
    return SceneTailProblem.wrongLength;
  }
  return null;
}

/// Checks the scene of a file of [fileLength] bytes read by [read], whose head holds [xmp]: its place, its header and,
/// with [verifySum], its SHA-256 (the whole tail read, in chunks of [chunk] bytes; about 30 ms for 8 MB)
Future<SceneTailCheck> checkSceneTail(
  ByteRangeReader read, {
  required int fileLength,
  required SceneXmp xmp,
  bool verifySum = true,
  int chunk = 1 << 20,
}) async {
  final tail = sceneTailOf(fileLength: fileLength, xmp: xmp);
  if (tail == null) {
    return const SceneTailCheck.failed(SceneTailProblem.missing);
  }
  final header = await read(tail.offset, glbHeaderLength);
  final problem = checkSceneHeader(header, sceneLength: tail.length);
  if (problem != null) {
    return SceneTailCheck.failed(problem);
  }
  if (verifySum) {
    final expected = xmp.sceneSha256;
    if (expected == null) {
      return const SceneTailCheck.failed(SceneTailProblem.missing);
    }
    final output = _DigestSink();
    final input = sha256.startChunkedConversion(output);
    for (var offset = 0; offset < tail.length; offset += chunk) {
      final bytes = await read(tail.offset + offset, math.min(chunk, tail.length - offset));
      input.add(bytes);
    }
    input.close();
    if (output.value.toString() != expected.toLowerCase()) {
      return const SceneTailCheck.failed(SceneTailProblem.wrongSum);
    }
  }
  return SceneTailCheck.ok(tail);
}

/// The scene of the whole file [file], whose head holds [xmp], when its place, header and sum are right; null
/// otherwise
Uint8List? sceneBytesOf(Uint8List file, SceneXmp xmp) {
  final tail = sceneTailOf(fileLength: file.length, xmp: xmp);
  if (tail == null) {
    return null;
  }
  final bytes = Uint8List.sublistView(file, tail.offset);
  if (checkSceneHeader(bytes, sceneLength: tail.length) != null) {
    return null;
  }
  final expected = xmp.sceneSha256;
  if (expected == null || sha256.convert(bytes).toString() != expected.toLowerCase()) {
    return null;
  }
  return bytes;
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
