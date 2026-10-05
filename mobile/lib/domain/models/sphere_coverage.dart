// VR180 media cover the front half of the sphere only: longitudes from -90° to +90°, all latitudes, one 180° x 180°
// image per eye. Like for the stereo layout, nothing the server indexes tells them apart from 360° media, so the
// viewers guess the coverage from the file (its spherical metadata, its GPano crop, its name), and the user can
// change it in every viewer. That choice is remembered for the asset, on the device only.

import 'dart:convert';
import 'dart:ui';

import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart';

export 'package:immich_mobile/platform/spherical_video_api.g.dart' show SphereCoverage;

/// The whole sphere, as a GPano crop
const fullSphereCrop = Rect.fromLTWH(0, 0, 1, 1);

/// The part of the full sphere a half sphere media covers, normalised to [0, 1] like a GPano crop: longitudes from
/// -90° to +90°, all latitudes
const halfSphereCrop = Rect.fromLTWH(0.25, 0, 0.5, 1);

/// Whether a GPano [crop] leaves part of the sphere out. Many cameras write the crop tags on full spheres too, 3D
/// ones included: within 1%, such a crop is no partial panorama.
bool isPartialSphere(Rect crop) =>
    crop.left.abs() > 0.01 || crop.top.abs() > 0.01 || (crop.width - 1).abs() > 0.01 || (crop.height - 1).abs() > 0.01;

// "vr180", "180x180" and "180_3d" anywhere, and 180 on its own after an underscore, a dash, a dot or a space
// ("trip_180.mp4", "clip-180-sbs.mp4"), but not as the start of a longer number or word ("IMG_1801.JPG", "-180a").
final _halfSphereFileName = RegExp(r'vr180|180x180|180[_\- ]3d|[_\-. ]180(?![a-z0-9])', caseSensitive: false);

/// Guesses whether a 360° photo or video covers the full sphere, or the front half only (VR180), from what tells:
/// - what the file declares ([probe], see [probeSphericalMetadata]): a projection cropped to half the width, or a
///   mesh projection;
/// - its GPano crop ([gpanoCrop], normalised to [0, 1]): about half the full width (0.45 to 0.55) and all of its
///   height (more than 0.9);
/// - its eyes, laid out as [layout] in a frame of [width] x [height] pixels: about square (aspect ratio 0.9 to 1.1)
///   for a 3D layout, where each eye of a full sphere is twice as wide as high;
/// - its [fileName], in any case: "vr180", "180x180", "180_3d", or 180 alone after an underscore, a dash, a dot or a
///   space ("trip_180.mp4").
///
/// Any of them makes it a half sphere; else it is a full sphere.
SphereCoverage guessSphereCoverage({
  required String? fileName,
  required int? width,
  required int? height,
  StereoLayout layout = StereoLayout.mono,
  Rect? gpanoCrop,
  SphericalProbe? probe,
}) {
  if (probe?.halfSphere ?? false) {
    return SphereCoverage.half;
  }
  if (probe?.halfSphere == false) {
    // The file says full sphere (spherical metadata with full bounds): a side by side 360° video squeezed into a
    // 2:1 frame has square eyes too, so the shape and the name do not get a say
    return SphereCoverage.full;
  }
  if (gpanoCrop != null && gpanoCrop.width >= 0.45 && gpanoCrop.width <= 0.55 && gpanoCrop.height > 0.9) {
    return SphereCoverage.half;
  }
  if (_hasSquareEyes(layout, width, height)) {
    return SphereCoverage.half;
  }
  if (fileName != null && _halfSphereFileName.hasMatch(fileName)) {
    return SphereCoverage.half;
  }
  return SphereCoverage.full;
}

bool _hasSquareEyes(StereoLayout layout, int? width, int? height) {
  if (layout == StereoLayout.mono || width == null || height == null || width <= 0 || height <= 0) {
    return false;
  }
  final eye = layout.leftEyeRect;
  final aspectRatio = width * eye.width / (height * eye.height);
  return aspectRatio >= 0.9 && aspectRatio <= 1.1;
}

/// How a viewer shows a 360° media: the [layout] of its eyes, and the [coverage] of the sphere, with the
/// [coverageGuess] it has when the user picked none.
typedef SphereView = ({StereoLayout layout, SphereCoverage coverage, SphereCoverage coverageGuess});

/// How the viewers show a 360° media of [width] x [height] pixels named [fileName], with its GPano crop
/// ([gpanoCrop], normalised to [0, 1]) for a photo and what the file declares ([probe]) for a video.
///
/// The coverage is the one the user picked ([chosenCoverage]), else the guess of [guessSphereCoverage]. The layout is
/// the one the user picked ([chosenLayout]), else the one the file declares, else the guess of [guessStereoLayout]
/// for that coverage: two 180° eyes side by side make a 2:1 frame, like a mono 360° media.
SphereView resolveSphereView({
  required String? fileName,
  required int? width,
  required int? height,
  Rect? gpanoCrop,
  SphericalProbe? probe,
  StereoLayout? chosenLayout,
  SphereCoverage? chosenCoverage,
}) {
  final hasGPanoCrop = gpanoCrop != null && isPartialSphere(gpanoCrop);
  final knownLayout = chosenLayout ?? probe?.stereo;
  final coverageGuess = guessSphereCoverage(
    fileName: fileName,
    width: width,
    height: height,
    layout: knownLayout ?? guessStereoLayout(width: width, height: height, hasGPanoCrop: hasGPanoCrop),
    gpanoCrop: gpanoCrop,
    probe: probe,
  );
  final coverage = chosenCoverage ?? coverageGuess;
  final layout =
      knownLayout ?? guessStereoLayout(width: width, height: height, hasGPanoCrop: hasGPanoCrop, coverage: coverage);
  return (layout: layout, coverage: coverage, coverageGuess: coverageGuess);
}

/// The part of the full sphere an image covers, normalised to [0, 1]: its GPano crop ([gpanoCrop]) when it has one
/// that leaves part of the sphere out, else the front half for a half sphere [coverage], else the whole sphere. The
/// crop maps the image of each eye, for a 3D media.
Rect sphereCrop(SphereCoverage coverage, {Rect? gpanoCrop}) {
  if (gpanoCrop != null && isPartialSphere(gpanoCrop)) {
    return gpanoCrop;
  }
  return switch (coverage) {
    SphereCoverage.full => gpanoCrop ?? fullSphereCrop,
    SphereCoverage.half => halfSphereCrop,
  };
}

/// Translated labels of the coverage control of the native viewers, under the keys they read. They fall back to
/// their English texts for a missing key.
Map<String, String> sphereCoverageLabels(Translations t) => {
  'coverage': t.panorama_coverage,
  'coverage_full': t.panorama_coverage_full,
  'coverage_half': t.panorama_coverage_half,
};

/// Translated labels of the native 360° viewers: their 3D control (see [stereoLayoutLabels]), their coverage control
/// (see [sphereCoverageLabels]) and the stereo photo mode of the immersive viewer (see [appleSpatialViewerLabels])
Map<String, String> sphereViewerLabels(Translations t) => {
  ...stereoLayoutLabels(t),
  ...sphereCoverageLabels(t),
  ...appleSpatialViewerLabels(t),
};

extension SphereCoverageExtension on SphereCoverage {
  /// The coverage the coverage control switches to: the full sphere and the front half, in turn
  SphereCoverage get next => switch (this) {
    SphereCoverage.full => SphereCoverage.half,
    SphereCoverage.half => SphereCoverage.full,
  };

  /// Short name of the coverage, as the coverage control shows it
  String get shortLabel => switch (this) {
    SphereCoverage.full => '360°',
    SphereCoverage.half => '180°',
  };

  /// Name of the coverage, as the coverage control tells it
  String label(Translations t) => switch (this) {
    SphereCoverage.full => t.panorama_coverage_full,
    SphereCoverage.half => t.panorama_coverage_half,
  };

  /// The same coverage, for the immersive viewer of the Meta Quest
  ImmersiveSphereCoverage toImmersive() => switch (this) {
    SphereCoverage.full => ImmersiveSphereCoverage.full,
    SphereCoverage.half => ImmersiveSphereCoverage.half,
  };

  /// The projection of the Spatial 2.5D player for a 360° video of this coverage
  SpatialProjection toSpatialProjection() => switch (this) {
    SphereCoverage.full => SpatialProjection.equirectangular,
    SphereCoverage.half => SpatialProjection.equirectangular180,
  };
}

/// The coverage of a coverage of the immersive viewer
SphereCoverage sphereCoverageOfImmersive(ImmersiveSphereCoverage coverage) => switch (coverage) {
  ImmersiveSphereCoverage.full => SphereCoverage.full,
  ImmersiveSphereCoverage.half => SphereCoverage.half,
};

/// The coverage a projection of the Spatial 2.5D player shows, null for a flat video
SphereCoverage? sphereCoverageOfSpatialProjection(SpatialProjection projection) => switch (projection) {
  SpatialProjection.flat => null,
  SpatialProjection.equirectangular => SphereCoverage.full,
  SpatialProjection.equirectangular180 => SphereCoverage.half,
};

/// Reads the remembered coverages from their JSON form, a map from asset key to coverage name. Unknown names and a
/// damaged value are skipped: the guess then applies.
Map<String, SphereCoverage> decodeSphereCoverages(String? json) {
  if (json == null || json.isEmpty) {
    return {};
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return {};
  }
  if (decoded is! Map) {
    return {};
  }
  final coverages = <String, SphereCoverage>{};
  for (final MapEntry(:key, :value) in decoded.entries) {
    final coverage = SphereCoverage.values.where((coverage) => coverage.name == value).firstOrNull;
    if (key is String && coverage != null) {
      coverages[key] = coverage;
    }
  }
  return coverages;
}

/// The JSON form of [coverages], see [decodeSphereCoverages]. Names rather than indexes, so that the stored value
/// survives a change in the order of the enum.
String encodeSphereCoverages(Map<String, SphereCoverage> coverages) =>
    jsonEncode({for (final MapEntry(:key, :value) in coverages.entries) key: value.name});
