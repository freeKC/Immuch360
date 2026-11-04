// The last step of a splat scene (store/m2/splat-maker-2026-11-01/plan-2026-11-01.md, section 2.2 "Écriture", lot
// SP3): the export of Brush read in any order, its scale set (splat_scale.dart), an object set upright on the plane it
// stands on first (lot SPF2: every gaussian turned, splat_turn.dart), the copy for the headset written as SPZ version 2
// and, when asked ("Also save a .ply for other 3D apps"), the same gaussians as a PLY in the order of 3D Gaussian
// Splatting, each into the path the engine gives (its .part files, renamed by the caller). The copy for the headset of
// an object whose whole scene the headset would open as a place keeps only the gaussians around the object
// (splatObjectCrop, review of lot SPF2), the PLY the whole scene. In an isolate: 150 000 gaussians of degree 3 (35 MB
// of PLY) in under 3 s on the computer of the measure.

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/splat/splat_scale.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_turn.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/splat/splat_cloud.dart';
import 'package:immich_mobile/domain/models/splat/spz_v2_writer.dart';

/// What [writeSplatFiles] wrote: [gaussians] in the SPZ (those of the export but the [dropped] ones, which held a NaN
/// or an infinity, and but those its [crop] left out, which the PLY keeps), the degree of the harmonics of the SPZ,
/// the [scale] set, and the bytes of each file
final class SplatFilesWritten {
  const SplatFilesWritten({
    required this.gaussians,
    required this.dropped,
    required this.shDegree,
    required this.scale,
    required this.spzBytes,
    this.plyBytes,
    this.crop,
  });

  final int gaussians;
  final int dropped;
  final int shDegree;
  final SplatScale scale;
  final int spzBytes;
  final int? plyBytes;

  /// The gaussians the copy for the headset of an object kept, null when it holds the whole scene
  final SplatCrop? crop;

  /// The gaussians of the scene the SPZ left out, 0 when none
  int get cropped => crop == null ? 0 : crop!.total - crop!.count;
}

/// Reads the PLY Brush exported ([brushPly]), sets the scale for what was filmed ([subject]) from the gaussians, the
/// centres of the [cameras] and where they look ([axes]; x y z of each, in the frame of the export), an object turned
/// upright on the plane it stands on when one is found, then writes the SPZ version 2 of degree [shDegree] at most to
/// [spzPath], cropped around an object the headset would otherwise open as a place, and, with [plyPath], the PLY of
/// the whole scene there; in an isolate of its own. Throws a SplatFormatException when the export is not one the
/// headset could read once written (more than [maxGaussians], a degree past 3, rows cut short, no gaussian), a
/// FileSystemException when a file cannot be read or written
Future<SplatFilesWritten> writeSplatFiles({
  required String brushPly,
  required String spzPath,
  String? plyPath,
  required SplatSubject subject,
  Float64List? cameras,
  Float64List? axes,
  int shDegree = SplatV1.shDegree,
  int maxGaussians = SplatV1.maxGaussians,
}) => Isolate.run(
  () => writeSplatFilesNow(
    brushPly: brushPly,
    spzPath: spzPath,
    plyPath: plyPath,
    subject: subject,
    cameras: cameras,
    axes: axes,
    shDegree: shDegree,
    maxGaussians: maxGaussians,
  ),
  debugName: 'splat files',
);

/// [writeSplatFiles] in the calling isolate
SplatFilesWritten writeSplatFilesNow({
  required String brushPly,
  required String spzPath,
  String? plyPath,
  required SplatSubject subject,
  Float64List? cameras,
  Float64List? axes,
  int shDegree = SplatV1.shDegree,
  int maxGaussians = SplatV1.maxGaussians,
}) {
  final read = readSplatPly(File(brushPly).readAsBytesSync(), maxGaussians: maxGaussians);
  final scale = splatScaleOf(subject: subject, positions: read.positions, cameras: cameras, axes: axes);
  final turn = scale.turn;
  final cloud = (turn == null ? read : turnedSplatCloud(read, turn)).scaled(scale.factor);
  final crop = splatObjectCrop(cloud.positions, scale);
  final headset = crop == null ? cloud : _keptOf(cloud, crop);
  final spz = writeSpzV2(headset, shDegree: shDegree);
  File(spzPath).writeAsBytesSync(spz, flush: true);
  int? plyBytes;
  if (plyPath != null) {
    final ply = writeSplatPly(cloud, comments: splatScenePlyComments(read.comments, scale.note));
    File(plyPath).writeAsBytesSync(ply, flush: true);
    plyBytes = ply.length;
  }
  return SplatFilesWritten(
    gaussians: headset.count,
    dropped: read.dropped,
    shDegree: math.min(shDegree, cloud.shDegree),
    scale: scale,
    spzBytes: spz.length,
    plyBytes: plyBytes,
    crop: crop,
  );
}

/// The gaussians of [cloud] that [crop] kept, in their order
SplatCloud _keptOf(SplatCloud cloud, SplatCrop crop) {
  final stride = cloud.stride;
  final rows = Float32List(crop.count * stride);
  var at = 0;
  for (var i = 0; i < cloud.count; i++) {
    if (crop.kept[i] != 0) {
      rows.setRange(at, at + stride, cloud.rows, i * stride);
      at += stride;
    }
  }
  return SplatCloud(
    count: crop.count,
    shDegree: cloud.shDegree,
    rows: rows,
    comments: cloud.comments,
    dropped: cloud.dropped,
  );
}
