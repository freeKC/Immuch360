// The scene of a splat photo (plan of 3 November 2026, sections 2.2 and 5.2): the last SplatLength bytes of the file,
// never "the bytes after the EOI" (a program that writes a title grows the head, the tail keeps its place from the
// end). Checked on the way: the place (a scene longer than the file, or than the format allows, is missing), the first
// bytes against SplatVersion (1F 8B, the gzip of versions 1 to 3; NGSP, the clear header of version 4), the head of
// the SPZ against the packet (when they differ, the SPZ wins and the difference is logged), and the SHA-256 of every
// byte. A file whose tail fails was saved again by another program: its copy on the server is read next.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_writer.dart';

/// Why the scene of a splat photo cannot be read
enum SplatPhotoProblem {
  /// The packet names no scene that fits: a field missing, a length past the file or the format
  missing,

  /// The bytes where the scene starts are no SPZ of the packet's version (the photo was saved again by another
  /// program, or a trailer was added after the scene)
  notSpz,

  /// The bytes are not those the packet sums
  wrongSum,

  /// Made by a newer version of the app: a FormatVersion past 1, another payload, an SPZ past version 4
  newer,

  /// The file is shorter than its scene and its head: another program saved the photo again
  lost,
}

/// Where the scene of a file lies: its first byte and its length
class SplatTailPlace {
  const SplatTailPlace({required this.offset, required this.length});

  final int offset;
  final int length;

  @override
  bool operator ==(Object other) => other is SplatTailPlace && other.offset == offset && other.length == length;

  @override
  int get hashCode => Object.hash(offset, length);

  @override
  String toString() => 'SplatTailPlace($offset, $length)';
}

/// The place of the scene [xmp] names in a file of [fileLength] bytes, null when it names none that fits
SplatTailPlace? splatPhotoTailOf({required int fileLength, required SplatPhotoXmp xmp}) {
  final length = xmp.splatLength;
  if (!xmp.isComplete || length == null || length > fileLength) {
    return null;
  }
  return SplatTailPlace(offset: fileLength - length, length: length);
}

/// What the packet [xmp] says of a file of [fileLength] bytes before any byte of its scene is read: null when the scene
/// may be there, else [SplatPhotoProblem.newer], [SplatPhotoProblem.missing] or [SplatPhotoProblem.lost] (a file
/// shorter than its scene: the size Immich gives, or the length of the copy on the device, is enough to tell)
SplatPhotoProblem? splatPhotoProblemOf(SplatPhotoXmp xmp, {int? fileLength}) {
  if (xmp.isNewer) {
    return SplatPhotoProblem.newer;
  }
  if (!xmp.isComplete) {
    return SplatPhotoProblem.missing;
  }
  if (fileLength != null && fileLength < xmp.splatLength! + 4) {
    return SplatPhotoProblem.lost;
  }
  return null;
}

/// Whether [first], the first bytes of a scene, start an SPZ of [version]: 1F 8B for versions 1 to 3, NGSP for 4
bool startsAsSpz(List<int> first, int version) {
  if (version >= 1 && version <= 3) {
    return first.length >= 2 && first[0] == 0x1F && first[1] == 0x8B;
  }
  if (version == 4) {
    return first.length >= 4 && first[0] == 0x4E && first[1] == 0x47 && first[2] == 0x53 && first[3] == 0x50;
  }
  return false;
}

/// What the check of a scene found
class SplatPhotoTailCheck {
  const SplatPhotoTailCheck.ok(SplatTailPlace this.place, SplatHead this.head, {required this.headMatches})
    : problem = null;

  const SplatPhotoTailCheck.failed(SplatPhotoProblem this.problem) : place = null, head = null, headMatches = false;

  final SplatTailPlace? place;

  /// The head the SPZ itself gives, which wins over the packet
  final SplatHead? head;

  /// Whether the SPZ's head says what the packet said
  final bool headMatches;
  final SplatPhotoProblem? problem;

  bool get isOk => problem == null;

  @override
  String toString() => isOk
      ? 'SplatPhotoTailCheck($place, $head${headMatches ? '' : ', head differs'})'
      : 'SplatPhotoTailCheck(${problem!.name})';
}

/// Whether the SPZ head [head] says what [xmp] said
bool splatHeadMatches(SplatHead head, SplatPhotoXmp xmp) =>
    head.format == SplatFormat.spz &&
    head.formatVersion == xmp.splatVersion &&
    head.gaussians == xmp.splatGaussians &&
    head.shDegree == xmp.splatShDegree;

/// The head of the scene from its first bytes [first] (64 KiB at most), [xmp] telling its version and its length;
/// null when they are no SPZ the packet names
SplatHead? splatTailHeadOf(Uint8List first, SplatPhotoXmp xmp) {
  final version = xmp.splatVersion;
  if (version == null || !startsAsSpz(first, version)) {
    return null;
  }
  final probe = probeSplatHead(first, xmp.splatLength);
  return probe is SplatHead && probe.format == SplatFormat.spz ? probe : null;
}

/// Checks the scene of a file of [fileLength] bytes read by [read], whose head holds [xmp] (see the top of this file):
/// with [verifySum], every byte of it read in chunks of [chunk] bytes for its SHA-256
Future<SplatPhotoTailCheck> checkSplatPhotoTail(
  Future<List<int>> Function(int offset, int length) read, {
  required int fileLength,
  required SplatPhotoXmp xmp,
  bool verifySum = true,
  int chunk = splatPhotoChunk,
}) async {
  final before = splatPhotoProblemOf(xmp, fileLength: fileLength);
  if (before != null) {
    return SplatPhotoTailCheck.failed(before);
  }
  final place = splatPhotoTailOf(fileLength: fileLength, xmp: xmp);
  if (place == null) {
    return const SplatPhotoTailCheck.failed(SplatPhotoProblem.missing);
  }
  final first = Uint8List.fromList(await read(place.offset, math.min(splatHeadBytes, place.length)));
  if (!startsAsSpz(first, xmp.splatVersion!)) {
    return const SplatPhotoTailCheck.failed(SplatPhotoProblem.notSpz);
  }
  // The sum before the head: a scene whose bytes are those the writer summed was probed by the writer, and a byte
  // changed in a small scene would fail the probe of its gzip stream before the sum could say what happened
  if (verifySum) {
    final sum = SplatSha256();
    for (var offset = 0; offset < place.length; offset += chunk) {
      final want = math.min(chunk, place.length - offset);
      final bytes = await read(place.offset + offset, want);
      if (bytes.length != want) {
        return const SplatPhotoTailCheck.failed(SplatPhotoProblem.missing);
      }
      sum.add(bytes);
    }
    if (sum.hex() != xmp.splatSha256) {
      return const SplatPhotoTailCheck.failed(SplatPhotoProblem.wrongSum);
    }
  }
  final head = splatTailHeadOf(first, xmp);
  if (head == null) {
    return const SplatPhotoTailCheck.failed(SplatPhotoProblem.notSpz);
  }
  return SplatPhotoTailCheck.ok(place, head, headMatches: splatHeadMatches(head, xmp));
}
