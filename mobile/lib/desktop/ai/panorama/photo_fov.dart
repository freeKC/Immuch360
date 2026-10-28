// The field of view of the photo a 360° panorama is generated around, pano-v1 (design-final 2026-10-27, section 4.3,
// point 2; lot P3). The photo is placed at the centre of the sphere through a pinhole of this field, its horizon level:
//  1. the focal length equivalent to 35 mm of its EXIF (FocalLengthIn35mmFilm): the diagonal of the 24 x 36 frame,
//     43.27 mm, split into the width and the height of the frame of the photo, gives the two fields;
//  2. else the focal length MoGe-2 finds for the photo (recover_focal_shift on its points, focal_shift.dart, the same
//     model and rule as the 3D scenes), relative to the half diagonal of the view plane;
//  3. else 65° across, as measure M3 guessed for its photos without EXIF.
// The last two raise the flag fovGuessed. A field beyond what a pinhole can show (a fisheye's EXIF, a model gone
// astray) is kept within 5° and 150° across.

import 'dart:math' as math;

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart' show fitEye;
import 'package:immich_mobile/desktop/ai/scene/focal_shift.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_textures.dart' show nchwOf;

/// Where the field of view of a photo comes from
enum PhotoFovSource { exif, model, guess }

/// The fields of view of a photo, in degrees
class PhotoFov {
  const PhotoFov({required this.hfov, required this.vfov, required this.source});

  final double hfov;
  final double vfov;
  final PhotoFovSource source;

  /// fovGuessed: the EXIF did not tell
  bool get guessed => source != PhotoFovSource.exif;

  @override
  String toString() => 'PhotoFov(${hfov.toStringAsFixed(2)}° x ${vfov.toStringAsFixed(2)}°, ${source.name})';
}

/// The horizontal field M3 guessed for a photo without a focal length
const photoFovGuessDegrees = 65.0;

/// The fields of view are kept within these, across
const photoFovMinDegrees = 5.0;
const photoFovMaxDegrees = 150.0;

double _degrees(double radians) => radians * (180 / math.pi);
double _radians(double degrees) => degrees * (math.pi / 180);

/// The two fields of a photo of [width] x [height] whose view plane, at distance [focal], spans [spanX] and [spanY]
/// on each side of its centre; the horizontal one kept within the bounds, the vertical one following it
PhotoFov _fov(double spanX, double spanY, double focal, PhotoFovSource source) {
  final hfov = _degrees(2 * math.atan(spanX / focal)).clamp(photoFovMinDegrees, photoFovMaxDegrees);
  final t = math.tan(_radians(hfov) / 2);
  return PhotoFov(hfov: hfov, vfov: _degrees(2 * math.atan(t * spanY / spanX)), source: source);
}

/// The fields of a photo of [width] x [height] from the focal length equivalent to 35 mm of its EXIF, [focal35]; null
/// when there is none
PhotoFov? photoFovOfExif(int width, int height, num? focal35) {
  if (focal35 == null || !(focal35 > 0) || width < 1 || height < 1) {
    return null;
  }
  final diagonal = math.sqrt(width * width + height * height);
  // The half width and the half height of the 35 mm frame cut to the proportions of the photo
  final spanX = halfDiagonal35mm * width / diagonal;
  final spanY = halfDiagonal35mm * height / diagonal;
  return _fov(spanX, spanY, focal35.toDouble(), PhotoFovSource.exif);
}

/// The fields of a photo of [width] x [height] from the focal length MoGe-2 found, relative to the half diagonal
PhotoFov photoFovOfModel(int width, int height, double focal) {
  final spans = viewPlaneSpans(width, height);
  return _fov(spans.x, spans.y, focal, PhotoFovSource.model);
}

/// The fields M3 guessed: 65° across
PhotoFov photoFovGuess(int width, int height) {
  final t = math.tan(_radians(photoFovGuessDegrees) / 2);
  return PhotoFov(
    hfov: photoFovGuessDegrees,
    vfov: _degrees(2 * math.atan(t * height / width)),
    source: PhotoFovSource.guess,
  );
}

/// The focal length of [photo] as MoGe-2 ([geometry]) sees it, relative to the half diagonal: the photo reduced to the
/// input of the model, its points, then recover_focal_shift. Throws [BackendException].
double modelFocalOf(SbsDecoded photo, GeometryBackend geometry) {
  final side = geometry.inputLongSide;
  final map = fitEye(photo, maxWidth: side, maxHeight: side);
  final maps = geometry.estimate(nchwOf(map), width: map.width, height: map.height);
  final samples = FocalShiftSamples.ofMap(maps.points, maps.mask, map.width, map.height);
  return recoverFocalShift(samples).focal;
}
