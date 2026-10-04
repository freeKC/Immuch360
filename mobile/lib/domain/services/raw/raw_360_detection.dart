// Which files are the raw 360° files of a dual fisheye camera, which the app stitches itself: Insta360 .insp photos
// (a JPEG with both fisheye circles side by side) and .insv videos whose frame holds both circles side by side. Neither
// the server nor the file says so in a way the rest of the app reads: the name tells, or the trailer the camera writes
// at the end of the file (see readInsta360Trailer). See docs/16-dual-fisheye-spec.md, sections 1 and 6.

import 'dart:convert';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart' show insta360TrailerMagic;
import 'package:immich_mobile/domain/services/spherical_probe.dart';

/// How a raw 360° file holds the pictures of its two lenses
enum Raw360Layout {
  /// Both fisheye circles side by side in one picture or one video frame, lens 0 on the left: the app stitches it
  dualFisheye,

  /// One lens per file (the _00_ and _10_ files of a split recording) or per video track: not shown in 360° yet
  separateLenses,
}

final _rawPhotoName = RegExp(r'\.insp$', caseSensitive: false);
final _rawVideoName = RegExp(r'\.insv$', caseSensitive: false);

/// Whether [name] is the name of a raw Insta360 photo (.insp)
bool isRawPhotoName(String name) => _rawPhotoName.hasMatch(name);

/// Whether [name] is the name of a raw Insta360 video (.insv)
bool isRawVideoName(String name) => _rawVideoName.hasMatch(name);

/// Whether a frame of [width] x [height] pixels holds two squares side by side (within 1 percent); null when its size
/// is unknown
bool? isSideBySideFrame(int? width, int? height) {
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  return (width / height / 2 - 1).abs() <= 0.01;
}

/// How a raw video whose first video track has frames of [width] x [height] pixels holds its lenses: side by side in
/// a 2:1 frame, else one lens in a square frame, the file of a split pair or the first of two tracks. Taken as side by
/// side while the frame size is unknown: the player then finds out.
Raw360Layout rawVideoLayout(int? width, int? height) =>
    isSideBySideFrame(width, height) == false ? Raw360Layout.separateLenses : Raw360Layout.dualFisheye;

/// What the file named [name] is, by its name and, for a video, its frame of [width] x [height] pixels: null for a
/// file that is no raw 360° file by name (see [hasInsta360Trailer] for the ones renamed)
Raw360Layout? raw360LayoutOf({required String name, required bool isVideo, int? width, int? height}) {
  if (!isVideo) {
    return isRawPhotoName(name) ? Raw360Layout.dualFisheye : null;
  }
  return isRawVideoName(name) ? rawVideoLayout(width, height) : null;
}

/// The frame of a raw video: the size of its first video track as the file declares it ([probe]), else the size the
/// server or the device gives ([width] x [height]); null when neither is known
({int width, int height})? rawVideoFrameSize({SphericalProbe? probe, int? width, int? height}) {
  final codedWidth = probe?.codedWidth;
  final codedHeight = probe?.codedHeight;
  if (codedWidth != null && codedHeight != null && codedWidth > 0 && codedHeight > 0) {
    return (width: codedWidth, height: codedHeight);
  }
  if (width != null && height != null && width > 0 && height > 0) {
    return (width: width, height: height);
  }
  return null;
}

/// How the viewers show a raw 360° media once stitched: one picture over the whole sphere. Its name or its 2:1 shape
/// may look like a 3D or VR180 media; the stitch is neither.
const SphereView raw360SphereView = (
  layout: StereoLayout.mono,
  coverage: SphereCoverage.full,
  coverageGuess: SphereCoverage.full,
);

// The fixed tail of a version 3 trailer: 32 reserved bytes, the size, the version, the magic
const _tailLength = 72;
const _versionOffset = 36;
const _magicOffset = 40;
const _trailerVersion = 3;

/// Whether the file of [fileSize] bytes that [read] reads ends with the trailer of an Insta360 camera (version 3):
/// reads its last 72 bytes only, so that a photo renamed from .insp is still found raw. Errors of [read] are not
/// caught.
Future<bool> hasInsta360Trailer(ByteRangeReader read, int fileSize) async {
  if (fileSize < _tailLength) {
    return false;
  }
  final tail = await read(fileSize - _tailLength, _tailLength);
  if (tail.length != _tailLength) {
    return false;
  }
  final magic = ascii.encode(insta360TrailerMagic);
  for (var i = 0; i < magic.length; i++) {
    if (tail[_magicOffset + i] != magic[i]) {
      return false;
    }
  }
  return ByteData.sublistView(tail).getUint32(_versionOffset, Endian.little) == _trailerVersion;
}

/// A raw video of one lens per file or per track, which no viewer shows in 360° yet: the app tells the user so
class RawVideoUnsupportedException implements Exception {
  const RawVideoUnsupportedException(this.name);

  /// Name of the video
  final String name;

  @override
  String toString() => 'RawVideoUnsupportedException: $name holds one lens per file or per track';
}
