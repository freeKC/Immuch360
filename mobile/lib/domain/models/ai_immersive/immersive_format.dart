// The words of the 3D photos Immuch360 makes from a single 2D photo: the XMP namespace and its values, the name of the
// file, the settings of relief-v1 and the model behind it. Shared by the computers, which write the files, and the
// Meta Quest, which reads them and computes the same relief itself, so that both sides agree on every value
// (design-final 2026-10-26, sections 2.4 and 4.1).

/// The XMP namespace of the files Immuch360 makes, after the com.aprogsys identity of the app (an XMP namespace does
/// not have to answer on the web)
const immuch360XmpNamespace = 'http://ns.aprogsys.com/immuch360/1.0/';

/// The prefix written for [immuch360XmpNamespace]; a reader follows the prefix a file binds to the namespace instead
const immuch360XmpPrefix = 'Immuch360';

/// The FormatVersion this build writes and reads in full; a file with a larger one is shown flat, "made by a newer
/// version"
const immersiveFormatVersion = 1;

/// What a file of Immuch360 holds (Immuch360:Kind). Only [stereoPhoto] is made in phase 1; the others are reserved.
enum ImmersiveKind {
  stereoPhoto('StereoPhoto'),
  panorama360('Panorama360'),
  stereoPanorama360('StereoPanorama360'),
  volumetricScene('VolumetricScene');

  const ImmersiveKind(this.xmp);

  /// The value of Immuch360:Kind
  final String xmp;

  static ImmersiveKind? fromXmp(String? value) => _byXmp(values, value, (kind) => kind.xmp);
}

/// How the two eyes share the frame: each eye at its full width side by side, or both squeezed into the width of one
enum StereoEyes {
  full('SideBySideFull', 'full'),
  half('SideBySideHalf', 'half');

  const StereoEyes(this.xmp, this.json);

  /// The value of Immuch360:StereoLayout
  final String xmp;

  /// The value of "eyes" in the stereoPair JSON of the immersive viewer
  final String json;

  static StereoEyes? fromXmp(String? value) => _byXmp(values, value, (eyes) => eyes.xmp);

  static StereoEyes? fromJson(Object? value) => _byXmp(values, value, (eyes) => eyes.json);
}

/// Which eye is on the left half of the frame
enum EyeOrder {
  leftRight('LeftRight', 'leftRight'),
  rightLeft('RightLeft', 'rightLeft');

  const EyeOrder(this.xmp, this.json);

  /// The value of Immuch360:EyeOrder
  final String xmp;

  /// The value of "layout" in the stereoPair JSON
  final String json;

  static EyeOrder? fromXmp(String? value) => _byXmp(values, value, (order) => order.xmp);

  static EyeOrder? fromJson(Object? value) => _byXmp(values, value, (order) => order.json);
}

/// Where the content of a file comes from: [estimatedDepth] for a relief estimated by AI from one photo,
/// [generatedContent] for a panorama invented beyond the edges of the photo, [reconstructedFromPhoto] for a 3D scene
/// rebuilt from one photo (its hidden areas filled in), [unknown] for a 3D photo of another tool, which says nothing of
/// how it was made
enum ImmersiveOrigin {
  estimatedDepth('EstimatedDepth', 'estimatedDepth'),
  generatedContent('GeneratedContent', 'generatedContent'),
  reconstructedFromPhoto('ReconstructedFromPhoto', 'reconstructedFromPhoto'),
  unknown('Unknown', 'unknown');

  const ImmersiveOrigin(this.xmp, this.json);

  /// The value of Immuch360:Origin
  final String xmp;

  /// The value of "origin" in the stereoPair JSON
  final String json;

  static ImmersiveOrigin? fromXmp(String? value) => _byXmp(values, value, (origin) => origin.xmp);

  static ImmersiveOrigin? fromJson(Object? value) => _byXmp(values, value, (origin) => origin.json);
}

/// What the left eye is: the original photo untouched (the "2D (original)" mode then shows the original exactly), or
/// unknown for another tool's file
enum LeftEyeSource {
  original('Original', 'original'),
  unknown('Unknown', 'unknown');

  const LeftEyeSource(this.xmp, this.json);

  /// The value of Immuch360:LeftEye
  final String xmp;

  /// The value of "leftEye" in the stereoPair JSON
  final String json;

  static LeftEyeSource? fromXmp(String? value) => _byXmp(values, value, (eye) => eye.xmp);

  static LeftEyeSource? fromJson(Object? value) => _byXmp(values, value, (eye) => eye.json);
}

/// The warnings relief-v1 raises on a photo, shown on the line of the job and written in Immuch360:QualityFlags
enum ReliefQualityFlag {
  /// Little depth found: the relief may be weak
  lowRelief('lowRelief'),

  /// More than 5 % of the right eye was filled in
  hiddenAreas('hiddenAreas'),

  /// A dark photo: the relief may be wrong
  dark('dark');

  const ReliefQualityFlag(this.xmp);

  /// The token in Immuch360:QualityFlags
  final String xmp;

  static ReliefQualityFlag? fromXmp(String? value) => _byXmp(values, value, (flag) => flag.xmp);
}

/// The flags of [text] (Immuch360:QualityFlags, tokens separated by commas or spaces), the unknown ones left out
List<ReliefQualityFlag> qualityFlagsFromXmp(String? text) => [
  for (final token in (text ?? '').split(RegExp(r'[\s,]+'))) ?ReliefQualityFlag.fromXmp(token),
];

/// [flags] as Immuch360:QualityFlags writes them: in the order of [ReliefQualityFlag], separated by commas
String qualityFlagsToXmp(Iterable<ReliefQualityFlag> flags) {
  final set = flags.toSet();
  return [
    for (final flag in ReliefQualityFlag.values)
      if (set.contains(flag)) flag.xmp,
  ].join(',');
}

/// The format of the 3D scene a photo carries after its JPEG (Immuch360:SceneFormat, "format" of the volumetricScene
/// JSON): a binary glTF of our meshes and their textures (design-final 2026-10-27, section 8.2)
const glbLayersV1 = 'glb-layers-v1';

/// How far the eye may go from where it started in a 3D scene before the scene flattens, in metres, after the comfort
/// scale (design-final 2026-10-27, section 2.4): Immuch360:SafeLateral, SafeVertical, SafeForward and SafeBackward,
/// and "safe" in the volumetricScene JSON
class SceneSafeZone {
  const SceneSafeZone({required this.lateral, required this.vertical, required this.forward, required this.backward});

  final double lateral;
  final double vertical;
  final double forward;
  final double backward;

  Map<String, double> toJson() => {'lateral': lateral, 'vertical': vertical, 'forward': forward, 'backward': backward};

  /// The zone [json] holds, null when a side is missing, not a number or negative
  static SceneSafeZone? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    double? side(String key) => switch (json[key]) {
      final num value when value.isFinite && value >= 0 => value.toDouble(),
      _ => null,
    };
    final lateral = side('lateral');
    final vertical = side('vertical');
    final forward = side('forward');
    final backward = side('backward');
    if (lateral == null || vertical == null || forward == null || backward == null) {
      return null;
    }
    return SceneSafeZone(lateral: lateral, vertical: vertical, forward: forward, backward: backward);
  }

  @override
  bool operator ==(Object other) =>
      other is SceneSafeZone &&
      other.lateral == lateral &&
      other.vertical == vertical &&
      other.forward == forward &&
      other.backward == backward;

  @override
  int get hashCode => Object.hash(lateral, vertical, forward, backward);

  @override
  String toString() => 'SceneSafeZone($lateral, $vertical, $forward, $backward)';
}

/// What follows the name of the original in the name of a full side by side 3D photo. "_LRF_Full_SBS" is what SKYBOX,
/// DeoVR and Pigasus read (iw3's README); the app itself decides from the XMP, never from the name.
const sbsFullNameSuffix = '_3D_LRF_Full_SBS';

/// The extension of every 3D photo Immuch360 writes
const sbsFileExtension = '.jpg';

/// The name of an original without its extension: "salon" for "salon.jpg", "archive.tar" for "archive.tar.gz", the
/// whole name when it has no extension or starts with its only dot
String fileStem(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

/// The name of the full side by side 3D photo of [originalName]: "salon.jpg" gives "salon_3D_LRF_Full_SBS.jpg". The
/// computers then pass it through their safe file name and take "name (1)" when it is taken.
String sbsFileNameFor(String originalName) => '${fileStem(originalName)}$sbsFullNameSuffix$sbsFileExtension';

/// The settings and constants of relief-v1, the right eye made from one photo and its estimated depth. The algorithm
/// is written once, in .github/desktop/ai/make_relief_golden.py, and its golden fixture
/// (test/fixtures/ai_immersive/relief_golden_v1.json) holds the Dart of the computers and the Kotlin of the Quest.
abstract final class ReliefV1 {
  /// Immuch360:Pipeline
  static const pipeline = 'relief-v1';

  /// The whole parallax, as a fraction of the width of an eye: 2 %, the one degree rule on the 48° quad
  static const parallax = 0.02;

  /// The depth that stays in the plane of the screen: the middle, so the nearest comes out and the farthest goes in
  static const convergence = 0.5;

  /// Two neighbours of a row stay linked when their depths differ by this much at most; beyond, a hole opens
  static const linkThreshold = 0.04;

  /// The side of the window of the dilation of the foreground, at the resolution of the model
  static const dilationWindow = 5;

  /// The percentiles the depth is normalised between
  static const lowPercentile = 2;
  static const highPercentile = 98;

  /// lowRelief when p98 - p2 is under this fraction of p98
  static const lowReliefRatio = 0.1;

  /// hiddenAreas when more than this fraction of the right eye was filled in
  static const hiddenAreasRatio = 0.05;

  /// dark when the mean Rec. 709 luma of the photo is under this, out of 255
  static const darkLuma = 20.0;

  /// The widest eye made: the pair then fits in 16384 pixels, the largest texture of ANGLE and Metal
  static const maxEyeWidth = 8192;
}

/// The width and the height of the input of the depth model, the fixed input of the LiteRT export, kept on the
/// computers so that both sides draw the same map from the same photo
const depthModelInputWidth = 686;
const depthModelInputHeight = 518;

/// Immuch360:DepthModel
const depthModelName = 'depth-anything-v2-small';

/// SHA-256 of the fp32 ONNX export the computers run (onnx-community, revision 4472b736), 99 060 839 bytes
const depthModelOnnxSha256 = 'afb6a5c28f3b6bf1618c6e43f02073ef9dfdc70e937502d51603e57b0a1df10c';

/// SHA-256 of the fp32 LiteRT export the Quest runs (litert-community, revision 178427e4), 99 530 468 bytes
const depthModelTfliteSha256 = '651415f1774e02d06de946eccf2e6dbbc5f499a9e932d9de7ada3d59637d2e8e';

/// The identifier of a model file in the cache key and the stereoPair JSON: its name and the first 8 hexadecimal
/// digits of its SHA-256, "depth-anything-v2-small@651415f1"
String depthModelId(String sha256, {String name = depthModelName}) => '$name@${sha256.substring(0, 8).toLowerCase()}';

/// The English description written in the XMP, which tells SKYBOX, DeoVR, the Explorer or Immich what the file is
const stereoPhotoDescription =
    'Stereoscopic 3D photo made by Immuch360 from a single 2D photo. The relief is estimated by AI; areas hidden in '
    'the photo are filled in.';

T? _byXmp<T extends Enum>(List<T> values, Object? value, String Function(T) name) {
  for (final candidate in values) {
    if (name(candidate) == value) {
      return candidate;
    }
  }
  return null;
}
