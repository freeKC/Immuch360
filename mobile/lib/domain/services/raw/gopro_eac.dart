// The raw .360 videos of the GoPro MAX and MAX 2: two video tracks of equi-angular cube map (EAC) faces, three faces
// per track. Each track is W x H with faces of F = H pixels: a split face, the whole middle face, then another split
// face, the two halves of a split face sharing (W - 3H) / 2 columns of overlap that blend into each other. The first
// track holds the left, front and right faces, the second the bottom, back and top ones. No calibration: the geometry
// comes from the size of the tracks, and the face table from max2-reframe-resolve (proto/eac.py, MIT).
//
// Checked on a real GoPro MAX file (4096 x 1344 tracks, docs/18-design-projections-and-parsers.md, section 10.1): every
// face joins its neighbours, and the MAX needs a quarter turn about the front axis that the table of the MAX 2 does not
// have. No MAX 2 file was at hand.
//
// Pure Dart: the resolver of raw videos and the CPU reference stitcher use it, and the shaders of the native players
// follow the same steps (section 4.2 of that document).

import 'dart:math' as math;

import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

/// A face of the EAC layout: the track that holds it ([texture]), its slot in the track (0 left split, 1 whole middle,
/// 2 right split), and its axes in the camera frame (x right, y up, z forward): the direction it faces, then the
/// directions of its columns and its rows
typedef GoProEacFace = ({int texture, int slot, Vec3 forward, Vec3 right, Vec3 down});

/// One read of a track: which track, where (continuous pixels of its declared size, top left origin), and the share of
/// the output pixel (the shares of a pixel add up to 1)
typedef GoProEacSample = ({int texture, double x, double y, double weight});

/// The layout of the two EAC tracks of a GoPro .360 of [trackWidth] x [trackHeight] pixels each
class GoProEacGeometry {
  const GoProEacGeometry({required this.trackWidth, required this.trackHeight});

  final int trackWidth;
  final int trackHeight;

  /// Side of a face: 1344 on the MAX, 1920 on the MAX 2
  int get face => trackHeight;

  /// Columns of a track beyond its three faces: the overlaps of its two split faces
  int get extra => trackWidth - 3 * trackHeight;

  /// Columns each split face repeats in its two halves (32, 64 or 96)
  int get overlap => extra ~/ 2;

  /// Width of each half of a split face slot
  int get half => face ~/ 2 + extra ~/ 4;

  /// Column where the whole middle face starts
  int get middle => 2 * half;

  /// Column where the right split face starts
  int get right => middle + face;

  /// Whether tracks of [width] x [height] pixels have this layout: W >= 3H, W - 3H a multiple of 4 and at most 256, H
  /// even and positive. 4096 x 1344 (MAX), 5888 x 1920 and 5952 x 1920 (MAX 2, 8 and 10 bit) fit; 3840 x 3840 and
  /// 5760 x 2880 do not.
  static bool fits(int width, int height) {
    if (height <= 0 || height.isOdd) {
      return false;
    }
    final extra = width - 3 * height;
    return extra >= 0 && extra % 4 == 0 && extra <= 256;
  }

  /// The faces of max2-reframe-resolve proto/eac.py (texture, slot, forward, right, down), camera frame x right, y up,
  /// z forward
  static const List<GoProEacFace> faces = [
    // Left
    (texture: 0, slot: 0, forward: (x: -1, y: 0, z: 0), right: (x: 0, y: 0, z: 1), down: (x: 0, y: -1, z: 0)),
    // Front
    (texture: 0, slot: 1, forward: (x: 0, y: 0, z: 1), right: (x: 1, y: 0, z: 0), down: (x: 0, y: -1, z: 0)),
    // Right
    (texture: 0, slot: 2, forward: (x: 1, y: 0, z: 0), right: (x: 0, y: 0, z: -1), down: (x: 0, y: -1, z: 0)),
    // Bottom
    (texture: 1, slot: 0, forward: (x: 0, y: -1, z: 0), right: (x: 0, y: 0, z: -1), down: (x: -1, y: 0, z: 0)),
    // Back
    (texture: 1, slot: 1, forward: (x: 0, y: 0, z: -1), right: (x: 0, y: 1, z: 0), down: (x: -1, y: 0, z: 0)),
    // Top
    (texture: 1, slot: 2, forward: (x: 0, y: 1, z: 0), right: (x: 0, y: 0, z: 1), down: (x: -1, y: 0, z: 0)),
  ];

  @override
  bool operator ==(Object other) =>
      other is GoProEacGeometry && other.trackWidth == trackWidth && other.trackHeight == trackHeight;

  @override
  int get hashCode => Object.hash(trackWidth, trackHeight);

  @override
  String toString() =>
      'GoProEacGeometry($trackWidth x $trackHeight: face $face, overlap $overlap, half $half, middle $middle, '
      'right $right)';
}

/// The geometry of a GoPro .360 from its probe: the first two video tracks, of equal declared size, when that size
/// [GoProEacGeometry.fits]; null otherwise. The tracks are taken in moov order among the video tracks, never by stream
/// index: audio and data tracks sit between them (ffprobe numbers them 0 and 5, or 0 and 4 in TimeWarp). Their handler
/// name ("GoPro H.265") is not required.
GoProEacGeometry? goProEacGeometryOf(SphericalProbe probe) {
  final tracks = probe.videoTracks;
  if (tracks.length < 2) {
    return null;
  }
  final [first, second, ...] = tracks;
  final width = first.codedWidth;
  final height = first.codedHeight;
  if (width == null || height == null || second.codedWidth != width || second.codedHeight != height) {
    return null;
  }
  return GoProEacGeometry.fits(width, height) ? GoProEacGeometry(trackWidth: width, trackHeight: height) : null;
}

/// The camera, for the logs: "GoPro MAX" for faces of 1344, "GoPro MAX 2" for 1920, else "GoPro"
String goProCameraName(GoProEacGeometry geometry) => switch (geometry.face) {
  1344 => 'GoPro MAX',
  1920 => 'GoPro MAX 2',
  _ => 'GoPro',
};

/// The rotation from the view frame (x right, y down, z forward) to the camera frame of the face table, row major:
/// [0,1,0, 1,0,0, 0,0,1] for faces of 1344 (the MAX, whose faces put the camera's up along the table's -x: Rz(90) times
/// diag(1, -1, 1), checked on a real file), diag(1, -1, 1) otherwise (the MAX 2, as max2-reframe-resolve fits it to
/// GoPro Player exports). No leveling.
List<double> goProViewToCamera(GoProEacGeometry geometry) => geometry.face == 1344
    ? const [0.0, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]
    : const [1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0];

/// What the two tracks of [geometry] give to the view direction [view] (view frame, unit or not), turned into the
/// camera frame by [viewToCamera] (row major): one sample of the whole middle face, or one or two of a split face, the
/// overlap of its two halves blended linearly. The formulas of max2-reframe-resolve proto/eac.py with pixel centres at
/// half pixels (docs/18-design-projections-and-parsers.md, section 4.2); samples of weight 0 are left out.
List<GoProEacSample> goProEacSamples(GoProEacGeometry geometry, List<double> viewToCamera, Vec3 view) {
  final c = Mat3(viewToCamera).apply(view);
  // The face the direction points at the most; the first in table order on a tie
  var best = -double.infinity;
  var face = GoProEacGeometry.faces.first;
  for (final candidate in GoProEacGeometry.faces) {
    final along = _dot(c, candidate.forward);
    if (along > best) {
      best = along;
      face = candidate;
    }
  }
  if (!(best > 0)) {
    return const [];
  }
  final f = geometry.face.toDouble();
  final half = geometry.half.toDouble();
  final col = (math.atan(_dot(c, face.right) / best) * 4 / math.pi + 1) / 2 * f;
  final row = (math.atan(_dot(c, face.down) / best) * 4 / math.pi + 1) / 2 * f;
  final y = row.clamp(0.5, f - 0.5);
  if (face.slot == 1) {
    final middle = geometry.middle.toDouble();
    return [(texture: face.texture, x: (middle + col).clamp(middle + 0.5, middle + f - 0.5), y: y, weight: 1.0)];
  }
  final base = face.slot == 0 ? 0.0 : geometry.right.toDouble();
  final overlap = geometry.overlap;
  final wb = overlap > 0 ? ((col - 0.5 - (f - half)) / overlap).clamp(0.0, 1.0) : (col >= half ? 1.0 : 0.0);
  final xa = (base + col).clamp(base + 0.5, base + half - 0.5);
  final xb = (base + half + col - (f - half)).clamp(base + half + 0.5, base + 2 * half - 0.5);
  return [
    if (wb < 1) (texture: face.texture, x: xa, y: y, weight: 1 - wb),
    if (wb > 0) (texture: face.texture, x: xb, y: y, weight: wb),
  ];
}

double _dot(Vec3 a, Vec3 b) => a.x * b.x + a.y * b.y + a.z * b.z;
