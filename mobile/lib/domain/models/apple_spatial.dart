// Apple spatial media: photos holding two views (a HEIC stereo pair) and videos holding two layers (MV-HEVC). The
// server says nothing about them, the app reads their files (docs 18-design-build19-sources-and-spatial.md, section
// 5). Every device shows them in 2D, one eye; the Meta Quest also shows the photos in 3D.

import 'package:immich_mobile/domain/services/apple_spatial/heic_stereo_probe.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/generated/translations.g.dart';

export 'package:immich_mobile/domain/services/apple_spatial/heic_stereo_probe.dart' show HeicStereoPair;
export 'package:immich_mobile/domain/services/spherical_probe.dart' show MultiviewInfo;

enum AppleSpatialKind { stereoPhoto, multiviewVideo }

/// What makes a media an Apple spatial one: the pair of a photo, or the layers of a video
class AppleSpatialInfo {
  const AppleSpatialInfo.photo(HeicStereoPair this.photo) : kind = AppleSpatialKind.stereoPhoto, video = null;

  const AppleSpatialInfo.video(MultiviewInfo this.video) : kind = AppleSpatialKind.multiviewVideo, photo = null;

  final AppleSpatialKind kind;

  /// The two eyes of a spatial photo, null for a video
  final HeicStereoPair? photo;

  /// The two eyes of a spatial video, null for a photo
  final MultiviewInfo? video;

  @override
  bool operator ==(Object other) =>
      other is AppleSpatialInfo && other.kind == kind && other.photo == photo && other.video == video;

  @override
  int get hashCode => Object.hash(kind, photo, video);

  @override
  String toString() => 'AppleSpatialInfo($kind, photo: $photo, video: $video)';
}

final _heifName = RegExp(r'\.(heic|heif|hif)$', caseSensitive: false);

/// Whether a photo named [name] may be a spatial photo: a HEIF file, as an iPhone or a Vision Pro writes them
bool isHeifName(String name) => _heifName.hasMatch(name);

/// Translated labels of the stereo photo mode of the immersive viewer, under the keys it reads (see
/// sphereViewerLabels): its 3D and 2D control, and what it tells when previous or next are pressed, or when the second
/// eye could not be decoded. The viewer falls back to their English texts for a missing key.
Map<String, String> appleSpatialViewerLabels(Translations t) => {
  'spatial3d': t.apple_spatial_3d,
  'spatial2d': t.apple_spatial_2d,
  'spatialNoNavigation': t.apple_spatial_no_navigation,
  'spatialSecondEyeFailed': t.apple_spatial_second_eye_failed,
};

/// A length in millimetres from [micrometres]: whole millimetres when that is what it is, else one decimal, the
/// separator of the language aside (the details show plain digits)
String formatMillimetres(int micrometres) {
  final millimetres = micrometres / 1000;
  return millimetres == millimetres.roundToDouble() ? millimetres.round().toString() : millimetres.toStringAsFixed(1);
}

/// An angle in degrees, to the degree
String formatDegrees(double degrees) => degrees.round().toString();

/// The row of the technical details for [info]: its title, and its subtitle of what the file tells (the field of view
/// of a photo; the eye shown in 2D, the baseline and the field of view of a video), null when it tells none of it
({String title, String? subtitle}) appleSpatialDetails(AppleSpatialInfo info, Translations t) {
  final photo = info.photo;
  if (photo != null) {
    final fov = photo.horizontalFovDegrees;
    return (
      title: t.apple_spatial_details_photo(width: '${photo.width}', height: '${photo.height}'),
      subtitle: fov == null ? null : t.apple_spatial_fov(deg: formatDegrees(fov)),
    );
  }
  final video = info.video;
  final hero = switch (video?.heroEye) {
    1 => t.apple_spatial_hero_left,
    2 => t.apple_spatial_hero_right,
    _ => null,
  };
  final baseline = video?.baselineMicrometres;
  final fov = video?.horizontalFovDegrees;
  final parts = [
    ?hero,
    if (baseline != null && baseline > 0) t.apple_spatial_baseline(mm: formatMillimetres(baseline)),
    if (fov != null && fov > 0) t.apple_spatial_fov(deg: formatDegrees(fov)),
  ];
  return (title: t.apple_spatial_details_video, subtitle: parts.isEmpty ? null : parts.join(', '));
}
