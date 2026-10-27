// The words of the files Immuch360 makes from a single photo: the XMP namespace and its values, the name of each kind
// of file, the settings of relief-v1 and the model behind it, and those of the kinds of phases 2 and 3: the 3D scene
// (scene-v1), the 360° panorama generated beyond the edges of a photo (pano-v1) and the 3D version of a 360° photo
// (relief-360-v1). Shared by the computers, which write the files, and the Meta Quest, which reads them and computes
// the same relief itself, so that both sides agree on every value (design-final 2026-10-26, sections 2.4 and 4.1;
// design-final 2026-10-27, sections 2, 4.4 and 8).

/// The XMP namespace of the files Immuch360 makes, after the com.aprogsys identity of the app (an XMP namespace does
/// not have to answer on the web)
const immuch360XmpNamespace = 'http://ns.aprogsys.com/immuch360/1.0/';

/// The prefix written for [immuch360XmpNamespace]; a reader follows the prefix a file binds to the namespace instead
const immuch360XmpPrefix = 'Immuch360';

/// The FormatVersion this build writes and reads in full; a file with a larger one is shown flat, "made by a newer
/// version"
const immersiveFormatVersion = 1;

/// What a file of Immuch360 holds (Immuch360:Kind): a side by side 3D photo (phase 1), a 3D scene (phase 2), a 360°
/// panorama generated beyond the edges of a photo and a 360° 3D panorama (phase 3), the last one also the 3D version
/// of a 360° photo of the user.
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

/// The warnings a version carries, shown on the line of the job, in "Versions" and in the panel of the headset, and
/// written in Immuch360:QualityFlags. The name stays that of phase 1, whose flags come first; [qualityFlagsOf] tells
/// which kind raises which.
enum ReliefQualityFlag {
  /// Little depth found: the relief may be weak
  lowRelief('lowRelief'),

  /// More than 5 % of the right eye was filled in (a 3D photo), more than 8 % of the photo hidden behind the near
  /// layer and filled in (a 3D scene)
  hiddenAreas('hiddenAreas'),

  /// A dark photo: the relief may be wrong
  dark('dark'),

  /// More than 15 % of the photo is sky or has no depth: it stays on a far plane
  sky('sky'),

  /// The field of view was estimated by the model: no EXIF, or the focal length of the model differs from that of the
  /// EXIF by more than 25 % of the latter
  fovGuessed('fovGuessed'),

  /// The zone the eye may move in is under 12 cm to each side: the 3D photo may suit the picture better
  smallZone('smallZone'),

  /// The photo has a colour profile other than sRGB: other 3D apps may show duller colours
  wideGamut('wideGamut'),

  /// The left and right edges of the panorama still differ after the seam was joined
  seam('seam'),

  /// More than 90 % of the panorama is invented
  mostlyInvented('mostlyInvented');

  const ReliefQualityFlag(this.xmp);

  /// The token in Immuch360:QualityFlags
  final String xmp;

  static ReliefQualityFlag? fromXmp(String? value) => _byXmp(values, value, (flag) => flag.xmp);
}

/// The flags a file of [kind] may carry, in the order they are written
List<ReliefQualityFlag> qualityFlagsOf(ImmersiveKind kind) => switch (kind) {
  ImmersiveKind.stereoPhoto => const [
    ReliefQualityFlag.lowRelief,
    ReliefQualityFlag.hiddenAreas,
    ReliefQualityFlag.dark,
  ],
  ImmersiveKind.volumetricScene => const [
    ReliefQualityFlag.lowRelief,
    ReliefQualityFlag.hiddenAreas,
    ReliefQualityFlag.dark,
    ReliefQualityFlag.sky,
    ReliefQualityFlag.fovGuessed,
    ReliefQualityFlag.smallZone,
    ReliefQualityFlag.wideGamut,
  ],
  ImmersiveKind.panorama360 => const [
    ReliefQualityFlag.fovGuessed,
    ReliefQualityFlag.seam,
    ReliefQualityFlag.mostlyInvented,
  ],
  ImmersiveKind.stereoPanorama360 => const [
    ReliefQualityFlag.hiddenAreas,
    ReliefQualityFlag.seam,
    ReliefQualityFlag.mostlyInvented,
  ],
};

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

/// The extension of every 3D photo Immuch360 writes, and of every file of phases 2 and 3
const sbsFileExtension = '.jpg';

/// What follows the name of the original in the name of a 3D scene: "salon_scene3D.jpg". "3D" follows a letter, so
/// the rules of the devices that read "3d" as a word (two eyes stacked) never take it, and it says neither "360" nor
/// "pano"; "scene3d" is a word of its own for the probe of the side by side photos (design-final 2026-10-27, 8.3).
const sceneNameSuffix = '_scene3D';

/// What follows the name of the original in the name of a generated 360° panorama: "salon_360.jpg"
const panoramaNameSuffix = '_360';

/// What follows the name of the original in the name of a 360° 3D panorama: "salon_360_3D.jpg"
const stereoPanoramaNameSuffix = '_360_3D';

/// What follows the name of a source that already says 360 or pano in the name of its 3D version: "PANO_0001_3D.jpg"
const stereoOf360NameSuffix = '_3D';

/// The suffixes of the names of the versions of an original: a 3D photo, a 360° 3D panorama, a 3D scene, a 360°
/// panorama and the 3D version of a 360° photo (isDerivedNameCandidate tries each, so their order does not matter)
const derivedNameSuffixes = [
  sbsFullNameSuffix,
  stereoPanoramaNameSuffix,
  sceneNameSuffix,
  panoramaNameSuffix,
  stereoOf360NameSuffix,
];

// The words of a name that says 360° as the devices read it: "360" on its own, not within a longer number, or "pano"
// (local_panorama.service.dart)
final _says360 = RegExp(r'(?<![0-9])360(?![0-9])|pano', caseSensitive: false);

/// Whether the name [name] already says 360 or pano, so that the name of its 3D version only adds "_3D"
bool nameSays360(String name) => _says360.hasMatch(fileStem(name));

/// What follows the name of [originalName] in the name of its version of [kind], extension included: the part a name
/// shortened for Windows always keeps whole (the length rule of sbsTargetName). A 3D version of a 360° photo whose name
/// already says 360 or pano takes "_3D.jpg".
String derivedNameEnd(ImmersiveKind kind, String originalName) => switch (kind) {
  ImmersiveKind.stereoPhoto => '$sbsFullNameSuffix$sbsFileExtension',
  ImmersiveKind.volumetricScene => '$sceneNameSuffix$sbsFileExtension',
  ImmersiveKind.panorama360 => '$panoramaNameSuffix$sbsFileExtension',
  ImmersiveKind.stereoPanorama360 =>
    nameSays360(originalName)
        ? '$stereoOf360NameSuffix$sbsFileExtension'
        : '$stereoPanoramaNameSuffix$sbsFileExtension',
};

/// The name of the version of [kind] of [originalName], before the safe file name of the computers: "salon.jpg" gives
/// "salon_scene3D.jpg", "salon_360.jpg", "salon_360_3D.jpg"; "PANO_0001.jpg" gives "PANO_0001_3D.jpg" for its 3D
/// version
String derivedFileNameFor(ImmersiveKind kind, String originalName) =>
    '${fileStem(originalName)}${derivedNameEnd(kind, originalName)}';

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

/// The constants of scene-v1, the 3D scene made from one photo: its geometry estimated by MoGe-2, two layers cut at the
/// breaks of depth, the bands the near layer hides filled in by LaMa, meshes in metres (design-final 2026-10-27,
/// sections 2.3, 2.4 and 3.4, with the decisions of the measure M2: the grid step of [gridStepFor], LaMa for every
/// band, MI-GAN kept for the seam of a panorama only). The algorithm is written once in
/// .github/desktop/ai/make_scene_golden.py, whose fixture (test/fixtures/ai_immersive/scene_golden_v1.json) holds the
/// Dart of the computers and the Kotlin of the Quest. The measures in the headset (MQ) may tighten the zone by 25 %, or
/// move the comfort distance to 0.6 m, without changing the format.
abstract final class SceneV1 {
  /// Immuch360:Pipeline
  static const pipeline = 'scene-v1';

  /// Immuch360:SceneFormat, see [glbLayersV1]
  static const format = glbLayersV1;

  /// The longest side of the map of the geometry, in pixels
  static const mapLongSide = 1024;

  /// One vertex every this many pixels of the map, or more for a nearly square photo: the step of a map is the smallest
  /// from this one whose main grid keeps at most [maxGridVertices] vertices ([gridStepFor])
  static const gridStep = 4;

  /// The most vertices of the main grid of a scene, the near layer before any cut (M2: a square map of 1024 at step 4
  /// makes 257 x 257 = 66 049 vertices, over the 65 535 of a mesh and the budget of the headset)
  static const maxGridVertices = 50000;

  /// The columns, or the rows, of the grid of a side of [length] values of the map at [step], as ReliefMesh makes them:
  /// round(length / step) + 1, at least 2
  static int gridLineCount(int length, int step) {
    final lines = (length + step ~/ 2) ~/ step + 1;
    return lines < 2 ? 2 : lines;
  }

  /// The grid step of a map of [width] x [height]: [gridStep], or the smallest step above it whose grid of
  /// [gridLineCount] columns and rows has at most [maxGridVertices] vertices. 4 for the 4:3, 3:2, 16:9 and 3:1 maps of
  /// 1024, 5 for a square one; the same both ways round, so a quarter turn keeps it. It goes to Immuch360:GridStep and
  /// to the key of the settings ([SceneXmp.settingsKey]).
  static int gridStepFor(int width, int height) {
    var step = gridStep;
    while (gridLineCount(width, step) * gridLineCount(height, step) > maxGridVertices) {
      step++;
    }
    return step;
  }

  /// Two neighbours stay linked when their normalised disparities differ by this much at most (the rule of relief-v1)
  static const breakThreshold = ReliefV1.linkThreshold;

  /// The percentiles the disparity is normalised between
  static const lowPercentile = ReliefV1.lowPercentile;
  static const highPercentile = ReliefV1.highPercentile;

  /// Nothing of the scene closer than this to the eye at the start: the scene grows around the eye until the
  /// percentile [comfortPercentile] of its depth is this far
  static const comfortDistance = 0.45;
  static const comfortPercentile = 2;

  /// The width of the band the near side of a break hides, round(factor * jump) clamped, in pixels of the map
  static const bandFactor = 160.0;
  static const bandMin = 8;
  static const bandMax = 48;

  /// The window the depth of a band is smoothed over
  static const bandSmoothing = 5;

  /// The pixels LaMa fills reach this many times the band into the near side, so the fill continues the background
  static const inpaintMaskFactor = 2;

  /// The regions sent to LaMa: the boxes of the bands widened by this margin, merged when they touch, cut beyond
  /// the largest side (LaMa takes windows of 512 x 512 of the map)
  static const inpaintMargin = 64;
  static const inpaintRegionMax = 512;

  /// A pixel whose mask of MoGe is under this has no depth: with the sky, it goes on a far plane at twice the
  /// percentile [skyPercentile] of the depth, clamped to [skyNearest], [skyFarthest]
  static const validMask = 0.5;
  static const skyPercentile = 99;
  static const skyNearest = 20.0;
  static const skyFarthest = 200.0;

  /// sky when more than this fraction of the photo has no depth
  static const skyRatio = 0.15;

  /// hiddenAreas when the bands cover more than this fraction of the photo
  static const hiddenAreasRatio = 0.08;

  /// fovGuessed when the focal length of the model differs from that of the EXIF by more than this fraction of the
  /// latter (focal lengths, not fields of view: make_focal_shift_golden.py, step 5)
  static const fovMismatch = 0.25;

  /// The grid of points the focal length and the shift are fitted on
  static const focalGrid = 64;

  /// The zone the eye may move in, in metres after the comfort scale: lateral from the bands (centile [zonePercentile]
  /// of what each band covers), vertical a share of it, forward a share of the centile [forwardPercentile] of the
  /// depth, backward a share of the lateral
  static const zonePercentile = 10;
  static const lateralMin = 0.10;
  static const lateralMax = 0.50;
  static const verticalShare = 0.6;
  static const forwardPercentile = 5;
  static const forwardShare = 0.35;
  static const forwardMin = 0.10;
  static const forwardMax = 1.00;
  static const backwardShare = 0.5;
  static const backwardMin = 0.05;
  static const backwardMax = 0.25;

  /// smallZone when the lateral zone is under this
  static const smallZone = 0.12;

  /// Beyond the zone (its normalised distance rho over 1), the layers flatten towards the plane of the photo from rho
  /// [flattenFrom] to [flattenTo], the background then [flatBackground] behind it, and darken from [darkenFrom] to
  /// [flattenTo], up to [darkenMax]; the meshes are made again when the factor moved by [flattenStep]
  static const flattenFrom = 1.0;
  static const flattenTo = 1.5;
  static const darkenFrom = 1.25;
  static const darkenMax = 0.95;
  static const flatBackground = 0.01;
  static const flattenStep = 0.02;

  /// The left thumbstick glides at this speed, starting and stopping over [glideEase] seconds, within the zone
  static const glideSpeed = 0.25;
  static const glideEase = 0.2;

  /// The meshes of a scene: at most [maxMeshes], each of at most [maxMeshVertices] vertices (16 bit indices)
  static const maxMeshes = 8;
  static const maxMeshVertices = 65535;

  /// The textures: the photo at [photoTextureMax] pixels on its longest side, JPEG quality [photoTextureQuality]; the
  /// background at [backgroundTextureMax], quality [backgroundTextureQuality]; the preview at [previewMax], quality
  /// [previewQuality]
  static const photoTextureMax = 4096;
  static const photoTextureQuality = 90;
  static const backgroundTextureMax = 1024;
  static const backgroundTextureQuality = 85;
  static const previewMax = 2048;
  static const previewQuality = 85;
}

/// The constants of pano-v1, the 360° panorama generated around a photo (design-final 2026-10-27, section 4.3). The
/// projection and the pasting back are written once in .github/desktop/ai/make_pano_golden.py (fixture
/// test/fixtures/ai_immersive/pano_golden_v1.json). The steps, the quantization and the threshold of the seam come
/// from the measure M3.
abstract final class PanoV1 {
  /// Immuch360:Pipeline
  static const pipeline = 'pano-v1';

  /// The control image: the photo projected at the centre of an equirectangular frame, pure green elsewhere
  static const controlWidth = 2048;
  static const controlHeight = 1024;

  /// The panorama written, after the upscale
  static const outputWidth = 8192;
  static const outputHeight = 4096;
  static const upscale = 4;

  /// The columns added on each side by wrapping before the upscale, cut after it
  static const upscalePadding = 32;

  /// The band of the seam filled in after a roll of half a turn, in pixels of the control frame
  static const seamBand = 128;

  /// The edge of the photo pasted back is blended over this fraction of its size
  static const pasteFeather = 0.02;

  /// The generation: guidance and strength of the LoRA
  static const guidance = 4.0;
  static const loraStrength = 1.0;

  /// The checks of the output: the luminance must vary more than this (a grey image is refused), at most this
  /// fraction of pure green may stay
  static const minLumaDeviation = 2.0;
  static const maxGreen = 0.005;

  /// mostlyInvented when more than this fraction of the sphere is invented
  static const mostlyInvented = 0.90;

  /// The JPEG written
  static const quality = 90;
}

/// The constants of relief-360-v1, the 3D version of a 360° panorama, generated or a photo of the user (design-final
/// 2026-10-27, section 4.4): the depth of 20 tangent views by the depth model of phase 1, then the shift of relief-v1
/// row by row, at most 1° at the equator and nothing at the poles, the left eye the panorama itself. Written once in
/// .github/desktop/ai/make_pano_golden.py.
abstract final class Relief360V1 {
  /// Immuch360:Pipeline
  static const pipeline = 'relief-360-v1';

  /// The largest shift, at the equator, for the nearest point: the budget of phase 1
  static const maxShiftDegrees = 1.0;

  /// The tangent views, the faces of an icosahedron, each the input of the depth model
  static const tangentViews = 20;

  /// The map of the whole sphere
  static const mapWidth = 2048;
  static const mapHeight = 1024;

  /// The output, top and bottom, the left eye on top: each eye 4096 x 2048
  static const eyeWidth = 4096;
  static const eyeHeight = 2048;

  /// Refused when more than this fraction of the right eye would be filled in ("Not enough relief for a comfortable
  /// 3D panorama"), or when the map is flat (the lowRelief rule of relief-v1)
  static const maxFilled = 0.08;

  /// Two neighbours stay linked when their depths differ by this much at most (the rule of relief-v1)
  static const linkThreshold = ReliefV1.linkThreshold;
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

/// The honesty sentence of a 3D scene, everywhere it shows
const sceneHonesty = 'Reconstructed from one photo, explore within its limits';

/// The honesty sentence of a panorama generated beyond the edges of a photo, everywhere it shows
const panoramaHonesty = "Generated by AI beyond the photo's edges";

/// The description of a 3D scene, with its honesty sentence
const sceneDescription =
    '3D scene made by Immuch360 from a single photo. $sceneHonesty: the depth is estimated and the areas hidden in the '
    'photo are filled in by AI.';

/// The description of a generated 360° panorama, with its honesty sentence
const panoramaDescription =
    '360° panorama made by Immuch360 from a single photo. $panoramaHonesty: everything outside the original photo is '
    'invented; the photo itself is kept.';

/// The description of the 3D version of a generated 360° panorama
const stereoPanoramaDescription =
    '360° 3D panorama made by Immuch360 from a single photo. $panoramaHonesty: everything outside the original photo '
    'is invented, and the relief is estimated by AI.';

/// The description of the 3D version of a 360° photo of the user
const stereo360Description =
    '3D version of a 360° photo made by Immuch360. The relief is estimated by AI; areas hidden in the photo are filled '
    'in.';

/// The IPTC digital source type of every scene and panorama Immuch360 makes, "Edited using Generative AI": the
/// marking a machine reads (AI Act, article 50(2)), written as Iptc4xmpExt:DigitalSourceType
const iptcCompositeWithTrainedAlgorithmicMedia =
    'http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia';

T? _byXmp<T extends Enum>(List<T> values, Object? value, String Function(T) name) {
  for (final candidate in values) {
    if (name(candidate) == value) {
      return candidate;
    }
  }
  return null;
}
