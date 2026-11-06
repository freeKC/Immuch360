// The last step of a splat scene (store/m2/splat-maker-2026-11-01/plan-2026-11-01.md, section 2.2 "Écriture", lot
// SP3): the export of Brush read in any order, its scale set (splat_scale.dart), an object set upright on the plane it
// stands on first (lot SPF2: every gaussian turned, splat_turn.dart), the SPZ version 2 and, when asked ("Also save a
// .ply for other 3D apps"), the whole scene as a PLY in the order of 3D Gaussian Splatting, each into the path the
// engine gives (its .part files, renamed by the caller).
//
// The copy for the headset (lot Q1): the gaussians around an object whose whole scene the headset would open as a place
// (splatObjectCrop, review of lot SPF2), then at most SplatV1.headsetGaussians of them, the strongest by the score of
// the reducers of the headset (opacity times volume, splat_reducer.dart), in their order. For Headset the .spz is that
// copy (trained to 150 000, so the crop alone acts); for Detailed and Maximum the .spz holds the whole scene, for the
// computers and the phones, and the copy goes beside it ([headsetPath]): a place of Detailed holds 750 000 gaussians,
// which the Quest would get otherwise. The PLY always holds the whole scene. In an isolate: 150 000 gaussians of degree
// 3 (35 MB of PLY) in under 3 s on the computer of the measure.

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/splat/splat_scale.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_turn.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/splat/splat_cloud.dart';
import 'package:immich_mobile/domain/models/splat/splat_reducer.dart';
import 'package:immich_mobile/domain/models/splat/spz_v2_writer.dart';

/// What [writeSplatFiles] wrote: [gaussians] in the SPZ (those of the export but the [dropped] ones, which held a NaN
/// or an infinity; for Headset, but those the copy for the headset left out, which the PLY keeps), the degree of the
/// harmonics of the SPZ, the [scale] set, the bytes of each file, and the copy for the headset: [headsetGaussians] of
/// the [sceneGaussians], [crop] around an object, and [headsetBytes] when it is a file of its own
final class SplatFilesWritten {
  const SplatFilesWritten({
    required this.gaussians,
    required this.dropped,
    required this.shDegree,
    required this.scale,
    required this.spzBytes,
    this.plyBytes,
    this.crop,
    int? sceneGaussians,
    int? headsetGaussians,
    this.headsetBytes,
  }) : sceneGaussians = sceneGaussians ?? gaussians,
       headsetGaussians = headsetGaussians ?? gaussians;

  final int gaussians;
  final int dropped;
  final int shDegree;
  final SplatScale scale;
  final int spzBytes;
  final int? plyBytes;

  /// The gaussians the copy for the headset of an object kept, null when it holds the whole scene
  final SplatCrop? crop;

  /// The gaussians of the whole scene, those of the PLY
  final int sceneGaussians;

  /// The gaussians of the copy for the headset
  final int headsetGaussians;

  /// The bytes of the copy for the headset beside the SPZ; null when the SPZ is that copy
  final int? headsetBytes;

  /// Whether the copy for the headset is a file of its own
  bool get hasHeadsetCopy => headsetBytes != null;

  /// The gaussians of the scene the copy for the headset left out by the crop, 0 when none
  int get cropped => crop == null ? 0 : crop!.total - crop!.count;

  /// The gaussians of the scene the copy for the headset left out, by the crop and by the cap
  int get leftOut => sceneGaussians - headsetGaussians;
}

/// Reads the PLY Brush exported ([brushPly]), sets the scale for what was filmed ([subject]) from the gaussians, the
/// centres of the [cameras] and where they look ([axes]; x y z of each, in the frame of the export), an object turned
/// upright on the plane it stands on when one is found, then writes the SPZ version 2 of degree [shDegree] at most to
/// [spzPath]: the copy for the headset (see the top of this file), or with [headsetPath] the whole scene, the copy
/// for the headset going to [headsetPath]; with [plyPath], the PLY of the whole scene there; in an isolate of its own.
/// Throws a SplatFormatException when the export is not one the headset could read once written (more than
/// [maxGaussians], a degree past 3, rows cut short, no gaussian), a FileSystemException when a file cannot be read or
/// written
Future<SplatFilesWritten> writeSplatFiles({
  required String brushPly,
  required String spzPath,
  String? plyPath,
  String? headsetPath,
  required SplatSubject subject,
  Float64List? cameras,
  Float64List? axes,
  int shDegree = SplatV1.shDegree,
  int maxGaussians = SplatV1.maxGaussians,
  int headsetGaussians = SplatV1.headsetGaussians,
}) => Isolate.run(
  () => writeSplatFilesNow(
    brushPly: brushPly,
    spzPath: spzPath,
    plyPath: plyPath,
    headsetPath: headsetPath,
    subject: subject,
    cameras: cameras,
    axes: axes,
    shDegree: shDegree,
    maxGaussians: maxGaussians,
    headsetGaussians: headsetGaussians,
  ),
  debugName: 'splat files',
);

/// [writeSplatFiles] in the calling isolate
SplatFilesWritten writeSplatFilesNow({
  required String brushPly,
  required String spzPath,
  String? plyPath,
  String? headsetPath,
  required SplatSubject subject,
  Float64List? cameras,
  Float64List? axes,
  int shDegree = SplatV1.shDegree,
  int maxGaussians = SplatV1.maxGaussians,
  int headsetGaussians = SplatV1.headsetGaussians,
}) {
  final read = readSplatPly(File(brushPly).readAsBytesSync(), maxGaussians: maxGaussians);
  final scale = splatScaleOf(subject: subject, positions: read.positions, cameras: cameras, axes: axes);
  final turn = scale.turn;
  final cloud = (turn == null ? read : turnedSplatCloud(read, turn)).scaled(scale.factor);
  final crop = splatObjectCrop(cloud.positions, scale);
  final headset = splatHeadsetCopyOf(cloud, crop: crop, keep: headsetGaussians);
  final spz = writeSpzV2(headsetPath == null ? headset : cloud, shDegree: shDegree);
  File(spzPath).writeAsBytesSync(spz, flush: true);
  int? headsetBytes;
  if (headsetPath != null) {
    final copy = writeSpzV2(headset, shDegree: shDegree);
    File(headsetPath).writeAsBytesSync(copy, flush: true);
    headsetBytes = copy.length;
  }
  int? plyBytes;
  if (plyPath != null) {
    final ply = writeSplatPly(cloud, comments: splatScenePlyComments(read.comments, scale.note));
    File(plyPath).writeAsBytesSync(ply, flush: true);
    plyBytes = ply.length;
  }
  return SplatFilesWritten(
    gaussians: headsetPath == null ? headset.count : cloud.count,
    dropped: read.dropped,
    shDegree: math.min(shDegree, cloud.shDegree),
    scale: scale,
    spzBytes: spz.length,
    plyBytes: plyBytes,
    crop: crop,
    sceneGaussians: cloud.count,
    headsetGaussians: headset.count,
    headsetBytes: headsetBytes,
  );
}

/// The copy for the headset of [cloud]: the gaussians [crop] kept around an object (all without one), then the [keep]
/// strongest of them (splatStrengths), in their order; [cloud] itself when nothing is left out
SplatCloud splatHeadsetCopyOf(SplatCloud cloud, {SplatCrop? crop, int keep = SplatV1.headsetGaussians}) {
  final cropped = crop == null ? cloud : _keptOf(cloud, crop);
  if (cropped.count <= keep) {
    return cropped;
  }
  final strongest = selectStrongest(splatStrengths(cropped), keep);
  return _rowsOf(cropped, strongest.count, (i) => strongest[i]);
}

/// The score of each gaussian of [cloud] as the reducers of the headset and of the viewers give it
/// (splat_reducer.dart): ln(opacity) plus its three log scales, the opacity the sigmoid of the logit the rows hold, at
/// least 1e-6; as 32 bit floats
Float32List splatStrengths(SplatCloud cloud) {
  final out = Float32List(cloud.count);
  final stride = cloud.stride;
  final opacityAt = cloud.opacityAt;
  final scaleAt = cloud.scaleAt;
  final rows = cloud.rows;
  final logMin = math.log(1e-6);
  for (var i = 0; i < cloud.count; i++) {
    final at = i * stride;
    final o = rows[at + opacityAt];
    // ln(sigmoid(o)), steady for a large negative o
    final logAlpha = o > -30 ? -math.log(1 + math.exp(-o)) : o;
    out[i] = math.max(logAlpha, logMin) + rows[at + scaleAt] + rows[at + scaleAt + 1] + rows[at + scaleAt + 2];
  }
  return out;
}

/// The gaussians of [cloud] that [crop] kept, in their order
SplatCloud _keptOf(SplatCloud cloud, SplatCrop crop) => _rowsOf(cloud, crop.count, (i) => crop.kept[i] != 0);

/// The [count] gaussians of [cloud] that [kept] says, in their order
SplatCloud _rowsOf(SplatCloud cloud, int count, bool Function(int index) kept) {
  final stride = cloud.stride;
  final rows = Float32List(count * stride);
  var at = 0;
  for (var i = 0; i < cloud.count; i++) {
    if (kept(i)) {
      rows.setRange(at, at + stride, cloud.rows, i * stride);
      at += stride;
    }
  }
  return SplatCloud(
    count: count,
    shDegree: cloud.shDegree,
    rows: rows,
    comments: cloud.comments,
    dropped: cloud.dropped,
  );
}
