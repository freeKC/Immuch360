// The seam of one whole job of the AI features on a computer: a photo in, a file written to its .part file out
// (design-final 2026-10-26, section 2.7). The queue and the screens only know this interface, so they are built and
// tested with fakes (test/desktop/ai/fakes) before the real engines exist, and the native codec, then the engines of
// the later phases, plug in behind it without touching them.
//
// One sealed spec per kind of job (design-final 2026-10-27, sections 2.5 and 4.5): the 3D photo of phase 1
// (ImmersiveJob, also named SbsJob), the 3D scene (SceneJob, a list of sources for the day a scene is made from several
// photos, one today), the 360° panorama (PanoramaJob) and the 360° 3D panorama (StereoPanoramaJob). The engine of a
// kind runs the spec of that kind; its steps, each with the phase the screens show, are those of ImmersiveStage.of.
// A job ends with a result whose details are sealed per kind too.
//
// DartImmersiveEngine (lot A4b) chains the decoding, DepthBackend (ONNX Runtime), relief-v1 and SbsCodec in a worker
// isolate. No engine opens the original for writing or touches the final name: the caller renames the .part.
//
// The splat scene (store/m2/splat-maker-2026-11-01/plan-2026-11-01.md, lot SP0) is the first kind made from many
// sources: SplatJob names the photos, or the video, as members the engine reads one after the other, never all copied
// at once; its steps are those of the photos (or of the frames of the video), of COLMAP, of Brush and of the copy for
// the headset, its failures those of placing the photos and of the training, and its result the counts the panel tells.

import 'dart:typed_data';

import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';

/// The parts of a job the screens show: "Preparing", "Computing" with its percentage, "Finishing"
enum ImmersivePhase { preparing, computing, finishing }

/// The steps of a job, each with its phase. A job of one kind goes through those of [ImmersiveStage.of], in that
/// order, which is the order of this list: what a job reports never goes back.
enum ImmersiveStage {
  /// Every kind: the original read, then decoded (orientation and quarter turns applied)
  reading(ImmersivePhase.preparing),
  decoding(ImmersivePhase.preparing),

  /// A panorama: the field of view of the photo (EXIF, else the model of the geometry), the photo projected on the
  /// control frame, the models loaded, the generation, the seam joined, the upscale, the photo pasted back
  fieldOfView(ImmersivePhase.preparing),
  projection(ImmersivePhase.preparing),
  loadingModels(ImmersivePhase.computing),
  generating(ImmersivePhase.computing),
  seam(ImmersivePhase.computing),
  upscale(ImmersivePhase.computing),
  pasteBack(ImmersivePhase.finishing),

  /// A scene: the geometry, the layers cut at the breaks, the hidden bands filled in (region after region), the
  /// meshes, then the textures
  geometry(ImmersivePhase.computing),
  layers(ImmersivePhase.computing),
  inpaint(ImmersivePhase.computing),
  mesh(ImmersivePhase.computing),
  textures(ImmersivePhase.finishing),

  /// A 3D photo: the depth of the photo; a 360° 3D panorama: the depth of its tangent views, merged
  depth(ImmersivePhase.computing),
  panoramaDepth(ImmersivePhase.computing),

  /// A 3D photo and a 360° 3D panorama: the right eye (the percentage comes from its rows)
  rightEye(ImmersivePhase.computing),

  /// A splat scene: the photos prepared (turned, reduced, the blurred ones left out) or the frames taken from the
  /// video, each counted; then COLMAP on the processor, the points of each image, the matching (blocks of an exhaustive
  /// matching, images of a sequential one) and the mapping (the cameras placed); then Brush on the graphics card, its
  /// steps; then the copy for the headset, scaled and written as SPZ version 2 (and the .ply when asked)
  photos(ImmersivePhase.preparing),
  frames(ImmersivePhase.preparing),
  features(ImmersivePhase.computing),
  matching(ImmersivePhase.computing),
  mapping(ImmersivePhase.computing),
  training(ImmersivePhase.computing),
  splatCopy(ImmersivePhase.finishing),

  /// Every kind but the scene: the JPEG encoded; then every kind: the file written
  encoding(ImmersivePhase.finishing),
  writing(ImmersivePhase.finishing);

  const ImmersiveStage(this.phase);

  /// What the screens show for it
  final ImmersivePhase phase;

  /// The steps of the 3D photo of phase 1
  static const sbs = [reading, decoding, depth, rightEye, encoding, writing];

  /// The steps of a 3D scene
  static const scene = [reading, decoding, geometry, layers, inpaint, mesh, textures, writing];

  /// The steps of a 360° panorama
  static const panorama = [
    reading,
    decoding,
    fieldOfView,
    projection,
    loadingModels,
    generating,
    seam,
    upscale,
    pasteBack,
    encoding,
    writing,
  ];

  /// The steps of a 360° 3D panorama
  static const stereoPanorama = [reading, decoding, panoramaDepth, rightEye, encoding, writing];

  /// The steps of a splat scene: the sources read (a photo of the server copied, the sums of the photos), then the
  /// photos, or the frames of a video (SplatJob.stages keeps the one of its job, [splatOf]), COLMAP, Brush, the copy
  /// for the headset and the file written
  static const splat = [reading, photos, frames, features, matching, mapping, training, splatCopy, writing];

  /// The steps of a splat scene made from a video ([video]) or from photos: those of [splat] without the frames of a
  /// video for photos, without the photos for a video
  static List<ImmersiveStage> splatOf({required bool video}) => [
    for (final stage in splat)
      if (stage != (video ? photos : frames)) stage,
  ];

  /// The steps of a job that makes a file of [kind], in their order
  static List<ImmersiveStage> of(ImmersiveKind kind) => switch (kind) {
    ImmersiveKind.stereoPhoto => sbs,
    ImmersiveKind.volumetricScene => scene,
    ImmersiveKind.panorama360 => panorama,
    ImmersiveKind.stereoPanorama360 => stereoPanorama,
    ImmersiveKind.gaussianSplat => splat,
  };
}

/// Why a job did not end with a file
enum ImmersiveErrorCode {
  /// Asked to stop; nothing is left under the final name, the caller deletes the .part
  cancelled,

  /// The file could not be decoded (damaged, truncated)
  decodeFailed,

  /// A format this computer cannot read (HEIC on Linux, for example)
  unsupportedFormat,
  outOfMemory,

  /// The .part could not be written for a reason other than the two below
  writeFailed,

  /// No space left (ENOSPC 28, ERROR_DISK_FULL 112, ERROR_HANDLE_DISK_FULL 39): the queue pauses
  diskFull,

  /// The destination refuses new files
  readOnly,

  /// The original went away while it was read (a drive unplugged, a share gone)
  sourceLost,

  /// The depth model failed to load or to run; the message of ONNX Runtime goes with it
  modelFailed,

  /// A component is missing or damaged
  componentsMissing,

  /// No graphics card this job can run on (none found, too small, integrated and not allowed)
  gpuUnavailable,

  /// Other programs hold the memory of the graphics card: the job waits, then fails with this if it is cancelled, or
  /// when the generator found too little of it free and cut its work into segments, which spoils the image
  gpuBusy,

  /// The graphics card ran out of memory during the generation (told by the error output of the generator)
  gpuOutOfMemory,

  /// The generator ended with an error; the end of its error output goes with it
  generatorFailed,

  /// The generator wrote nothing for 180 s and was stopped
  generatorStalled,

  /// The generated image was refused: grey, green left, wrong size
  outputRejected,

  /// The photo or the result is larger than the kind allows
  tooLarge,

  /// The 360° panorama has too little relief, or too much would be filled in: no 3D version is written
  notEnoughRelief,

  /// A splat scene: fewer usable photos or frames than SplatV1.minImages once the unreadable and the blurred ones are
  /// left out; the message is splatCountsMessage(usable, all)
  tooFewImages,

  /// COLMAP ended with an error (not a crash for want of memory, which is [outOfMemory]); the end of its error output
  /// goes with it
  posesFailed,

  /// COLMAP wrote nothing for SplatV1.colmapSilence and was stopped
  posesStalled,

  /// Too few images placed in 3D: fewer than SplatV1.minPlacedShare of them or than SplatV1.minPlaced, none when no
  /// two photos could be matched; the message is splatCountsMessage(placed, all)
  notEnoughOverlap,

  /// Brush ended with an error; the end of its error output goes with it
  trainingFailed,

  /// Brush wrote nothing for SplatV1.brushSilence and was stopped
  trainingStalled,
}

/// The counts a failure of a splat scene carries as its message: "12/150", the images it could use or place of those
/// it was given
String splatCountsMessage(int count, int all) => '$count/$all';

/// The counts of [message] (see [splatCountsMessage]), null when it holds none
(int count, int all)? splatCountsOf(String? message) {
  final match = RegExp(r'^(\d+)/(\d+)$').firstMatch(message ?? '');
  return match == null ? null : (int.parse(match.group(1)!), int.parse(match.group(2)!));
}

/// The original of a job: a file read in place, or bytes already copied (a server original, a file of a share)
class ImmersiveSource {
  const ImmersiveSource({required this.name, required this.size, required this.sha1, this.path, this.bytes})
    : assert(path != null || bytes != null, 'A source is a path or bytes');

  /// The name of the original, "salon.jpg"
  final String name;

  /// Its size in bytes
  final int size;

  /// The SHA-1 of its bytes in base64, written as SourceSha1
  final String sha1;

  /// The file to read, never opened for writing
  final String? path;

  /// Or its bytes
  final Uint8List? bytes;
}

/// The EXIF fields the 3D photo keeps: no make, no model, no thumbnail (a 2:1 picture with the make of a 360° camera
/// or of a DJI drone would be taken for a sphere), the orientation always 1
class ImmersiveExif {
  const ImmersiveExif({
    this.dateTimeOriginal,
    this.offsetTimeOriginal,
    this.latitude,
    this.longitude,
    this.altitude,
    this.software,
  });

  /// "2026:10:27 10:12:00", as the original wrote it
  final String? dateTimeOriginal;

  /// "+01:00"
  final String? offsetTimeOriginal;
  final double? latitude;
  final double? longitude;
  final double? altitude;

  /// "Immuch360 Desktop 3.3.0"
  final String? software;
}

/// What a job makes, one spec per kind: the queue builds the spec of the kind of a job, the engine of that kind runs
/// it. What every kind shares is here.
sealed class ImmersiveJobSpec {
  const ImmersiveJobSpec({
    required this.id,
    required this.partPath,
    required this.derivativeId,
    required this.creatorTool,
    required this.created,
    this.quarterTurns = 0,
    this.exif = const ImmersiveExif(),
  });

  /// The id of the job in the queue
  final String id;

  /// The quarter turns clockwise the user sees the photo with, applied after its EXIF orientation
  final int quarterTurns;

  /// Where the file goes: `.<final name>.<pid>-<n>.immuch360.part`, renamed by the caller
  final String partPath;
  final ImmersiveExif exif;

  /// The XMP fields the caller decides: DerivativeId, CreatorTool and Created
  final String derivativeId;
  final String creatorTool;
  final String created;

  /// The kind of file the job makes
  ImmersiveKind get kind;

  /// The files the job reads
  List<ImmersiveSource> get sources;

  /// The original the file made is a version of: its SourceName, SourceSize and SourceSha1
  ImmersiveSource get original => sources.first;

  /// The steps of the job, in their order
  List<ImmersiveStage> get stages => ImmersiveStage.of(kind);
}

/// One photo to make into a full side by side 3D photo (the name of phase 1; [SbsJob] in the specs of phases 2 and 3)
final class ImmersiveJob extends ImmersiveJobSpec {
  const ImmersiveJob({
    required super.id,
    required this.source,
    required super.partPath,
    required super.derivativeId,
    required super.creatorTool,
    required super.created,
    super.quarterTurns = 0,
    this.maxEyeWidth = ReliefV1.maxEyeWidth,
    this.parallax = ReliefV1.parallax,
    this.convergence = ReliefV1.convergence,
    super.exif = const ImmersiveExif(),
  });

  final ImmersiveSource source;

  /// A wider photo is reduced so that one eye is this wide at most, and the job says so
  final int maxEyeWidth;

  /// The settings of relief-v1
  final double parallax;
  final double convergence;

  @override
  ImmersiveKind get kind => ImmersiveKind.stereoPhoto;

  @override
  List<ImmersiveSource> get sources => [source];
}

/// The spec of a 3D photo, by the name of the specs of phases 2 and 3
typedef SbsJob = ImmersiveJob;

/// One photo, or the video, a splat scene is made from. The engine reads the members one after the other while it
/// prepares them ([load], then [release] once its own copy is made), so that 200 photos of a server are never copied at
/// once. The queue makes them from the sources of the dialog (lot SP6): a file of this computer read in place, an
/// original of the server downloaded to the work folder.
abstract interface class SplatMember {
  /// The name of the original, "DSCF4667.JPG"
  String get name;

  /// When it was taken, which orders the photos in time (the sequential matching of a video, 200 of 512 photos spread
  /// evenly); null when nothing tells it, the name then orders it
  DateTime? get taken;

  /// The camera that took it, "Canon EOS REBEL T3 18 mm 4272x2848": the photos of one camera share their intrinsics
  /// (one folder per camera for COLMAP); null when nothing tells it
  String? get camera;

  /// Reads, or copies, the original; throws a ConversionException as a source of the queue does
  Future<ImmersiveSource> load(NativeCancelFlag cancel);

  /// Deletes what [load] copied; nothing for a file read in place
  Future<void> release();
}

/// The settings of one splat scene, those of SplatV1 unless the measure M1 or the user says otherwise
class SplatSettings {
  const SplatSettings({
    this.subject = SplatSubject.place,
    this.steps = SplatV1.steps,
    this.maxGaussians = SplatV1.maxGaussians,
    this.shDegree = SplatV1.shDegree,
    this.trainingResolution = SplatV1.trainingResolution,
    this.siftMaxImageSize = SplatV1.siftMaxImageSize,
    this.keepPly = false,
  });

  /// "What did you film?": a place or an object, which sets the scale
  final SplatSubject subject;
  final int steps;
  final int maxGaussians;
  final int shDegree;
  final int trainingResolution;
  final int siftMaxImageSize;

  /// "Also save a .ply for other 3D apps": the same gaussians, at full precision, in the order of 3D Gaussian Splatting
  final bool keepPly;

  /// What makes two scenes of the same photos the same, with the sums of the photos: the key of a work folder kept for
  /// Retry (SplatV1.workKept)
  String get key =>
      '${SplatV1.pipeline};${subject.name};$steps;$maxGaussians;$shDegree;$trainingResolution;'
      '$siftMaxImageSize';

  @override
  bool operator ==(Object other) =>
      other is SplatSettings &&
      other.subject == subject &&
      other.steps == steps &&
      other.maxGaussians == maxGaussians &&
      other.shDegree == shDegree &&
      other.trainingResolution == trainingResolution &&
      other.siftMaxImageSize == siftMaxImageSize &&
      other.keepPly == keepPly;

  @override
  int get hashCode =>
      Object.hash(subject, steps, maxGaussians, shDegree, trainingResolution, siftMaxImageSize, keepPly);
}

/// One photo to make into a 3D scene, `<name>_scene3D.jpg` (scene-v1). [sources] holds one photo in version 1, never
/// none; a scene made from several, one day, comes through SceneBackend with the same spec. With [glbPartPath], the
/// engine also writes the scene as a .glb there. The app leaves it null: "Also save a .glb copy" copies the scene the
/// file carries once it is written, checked by its length and its SHA-256, outside the queue (SceneGlbCopies in
/// scene_glb_export.dart); only the tests of the engine give it.
final class SceneJob extends ImmersiveJobSpec {
  const SceneJob({
    required super.id,
    required this.sources,
    required super.partPath,
    required super.derivativeId,
    required super.creatorTool,
    required super.created,
    super.quarterTurns = 0,
    super.exif = const ImmersiveExif(),
    this.glbPartPath,
  });

  @override
  final List<ImmersiveSource> sources;
  final String? glbPartPath;

  @override
  ImmersiveKind get kind => ImmersiveKind.volumetricScene;
}

/// Photos or a video to make into a splat scene, `<name>_splat.spz` (splat-v1): [members] in the order of the time they
/// were taken, at most SplatV1.maxPhotos photos, or the video alone ([isVideo]). [lead] is the source the scene names
/// as its original, the first photo in time or the video, which the queue prepares as the source of every job; the
/// engine reads the others through [members]. With [plyPartPath], the engine also writes the same gaussians as a .ply
/// there ("Also save a .ply for other 3D apps"), renamed by the caller with the .spz. [timings] are the times of the
/// steps of a job of 150 images on this computer (AiTimings, lot SP6), from which the engine tells the time left of the
/// whole job; the defaults of the plan when the queue gives none.
final class SplatJob extends ImmersiveJobSpec {
  const SplatJob({
    required super.id,
    required this.lead,
    required this.members,
    required super.partPath,
    required super.derivativeId,
    required super.creatorTool,
    required super.created,
    this.isVideo = false,
    this.settings = const SplatSettings(),
    this.plyPartPath,
    this.timings = const {},
    super.exif = const ImmersiveExif(),
  });

  final ImmersiveSource lead;

  /// Never empty; the video alone for a video
  final List<SplatMember> members;
  final bool isVideo;
  final SplatSettings settings;
  final String? plyPartPath;

  /// The times of the steps of a job of 150 images, as this computer measured them
  final Map<ImmersiveStage, Duration> timings;

  @override
  ImmersiveKind get kind => ImmersiveKind.gaussianSplat;

  @override
  List<ImmersiveSource> get sources => [lead];

  /// The steps of the splat scene without those of the other source: the frames of a video, or the photos
  @override
  List<ImmersiveStage> get stages => ImmersiveStage.splatOf(video: isVideo);
}

/// One photo to make into a 360° panorama generated beyond its edges, `<name>_360.jpg` (pano-v1): the transformer
/// [generator] (its catalogue id, the variant the gate chose), [steps] and the [seed] drawn for this job
final class PanoramaJob extends ImmersiveJobSpec {
  const PanoramaJob({
    required super.id,
    required this.source,
    required super.partPath,
    required super.derivativeId,
    required super.creatorTool,
    required super.created,
    required this.generator,
    required this.steps,
    required this.seed,
    super.quarterTurns = 0,
    super.exif = const ImmersiveExif(),
  });

  final ImmersiveSource source;
  final String generator;
  final int steps;
  final int seed;

  @override
  ImmersiveKind get kind => ImmersiveKind.panorama360;

  @override
  List<ImmersiveSource> get sources => [source];
}

/// A 360° panorama to make into its 3D version (relief-360-v1): [source] the equirectangular file read, a 360° photo
/// of the user or a panorama the app generated. For the latter, [photo] is the photo it was generated from, whose
/// version the 3D panorama is too, and [parent] the packet of the panorama (its region, its DerivativeId).
final class StereoPanoramaJob extends ImmersiveJobSpec {
  const StereoPanoramaJob({
    required super.id,
    required this.source,
    required super.partPath,
    required super.derivativeId,
    required super.creatorTool,
    required super.created,
    this.photo,
    this.parent,
    super.quarterTurns = 0,
    super.exif = const ImmersiveExif(),
  });

  final ImmersiveSource source;
  final ImmersiveSource? photo;
  final PanoramaXmp? parent;

  @override
  ImmersiveKind get kind => ImmersiveKind.stereoPanorama360;

  @override
  List<ImmersiveSource> get sources => [source];

  @override
  ImmersiveSource get original => photo ?? source;
}

/// Where a job is: its step and how far, in thousandths of the whole job. A long step may also count what it goes
/// through, [step] of [steps] (the steps of a generation, the regions filled in), with the [remaining] time when the
/// engine can tell it: "step 12 of 28, about 3 min left".
class ImmersiveProgress {
  const ImmersiveProgress(this.stage, this.perMille, {this.step, this.steps, this.remaining});

  final ImmersiveStage stage;

  /// 0 to 1000
  final int perMille;
  final int? step;
  final int? steps;
  final Duration? remaining;

  @override
  bool operator ==(Object other) =>
      other is ImmersiveProgress &&
      other.stage == stage &&
      other.perMille == perMille &&
      other.step == step &&
      other.steps == steps &&
      other.remaining == remaining;

  @override
  int get hashCode => Object.hash(stage, perMille, step, steps, remaining);

  @override
  String toString() => 'ImmersiveProgress($stage, $perMille${steps == null ? '' : ', $step of $steps'})';
}

/// What a finished job tells of the file it wrote, one kind per kind of job
sealed class ImmersiveResultDetails {
  const ImmersiveResultDetails();
}

/// A 3D photo: the size of one eye, and whether the photo was reduced to the cap of an eye
final class SbsResultDetails extends ImmersiveResultDetails {
  const SbsResultDetails({required this.eyeWidth, required this.eyeHeight, this.reduced = false});

  final int eyeWidth;
  final int eyeHeight;
  final bool reduced;
}

/// A 3D scene: its meshes, vertices and triangles, its zone, its comfort scale, the part of the photo filled in and
/// its field of view
final class SceneResultDetails extends ImmersiveResultDetails {
  const SceneResultDetails({
    required this.meshes,
    required this.vertices,
    required this.triangles,
    required this.safe,
    required this.scale,
    required this.hiddenFraction,
    required this.fieldOfView,
  });

  final int meshes;
  final int vertices;
  final int triangles;
  final SceneSafeZone safe;
  final double scale;
  final double hiddenFraction;
  final double fieldOfView;
}

/// A 360° panorama: its size, the seed and the steps of its generation, the part of the sphere the photo covers
final class PanoramaResultDetails extends ImmersiveResultDetails {
  const PanoramaResultDetails({
    required this.width,
    required this.height,
    required this.seed,
    required this.steps,
    required this.sourceCoverage,
  });

  final int width;
  final int height;
  final int seed;
  final int steps;
  final double sourceCoverage;
}

/// A 360° 3D panorama: the size of its frame (both eyes) and the part of the right eye filled in
final class StereoPanoramaResultDetails extends ImmersiveResultDetails {
  const StereoPanoramaResultDetails({required this.width, required this.height, required this.filledFraction});

  final int width;
  final int height;
  final double filledFraction;
}

/// A splat scene: its [gaussians] (the bytes of the .spz are those of ImmersiveResult.bytesWritten), the [images] it was
/// trained from and how many of them COLMAP [placed] ("Done: 150,000 gaussians, 3.6 MB, from 150 of 150 photos"; "24 of
/// 150 photos could not be placed"), photos or frames of a video ([fromVideo]), the frames left out as [blurred], the
/// scale written ([scale], metres a unit of COLMAP) for what was filmed ([subject]), and the size of the .ply when one
/// was written
final class SplatResultDetails extends ImmersiveResultDetails {
  const SplatResultDetails({
    required this.gaussians,
    required this.images,
    required this.placed,
    required this.subject,
    required this.scale,
    this.fromVideo = false,
    this.blurred = 0,
    this.shDegree = SplatV1.shDegree,
    this.plyBytes,
  });

  final int gaussians;
  final int images;
  final int placed;
  final SplatSubject subject;
  final double scale;
  final bool fromVideo;
  final int blurred;
  final int shDegree;
  final int? plyBytes;

  /// The images COLMAP could not place, left out of the scene
  int get leftOut => images - placed;

  /// Whether enough of them were left out to say so (fewer than SplatV1.partialShare placed)
  bool get isPartial => images > 0 && placed < images * SplatV1.partialShare;
}

/// How a job ended
class ImmersiveResult {
  /// A 3D photo written
  const ImmersiveResult.done({
    required int this.eyeWidth,
    required int this.eyeHeight,
    required int this.bytesWritten,
    this.reduced = false,
    this.qualityFlags = const [],
    this.stageTimes = const {},
  }) : error = null,
       message = null,
       _made = null,
       afterSaved = null;

  /// A file of another kind written, with what it tells of itself
  const ImmersiveResult.made({
    required ImmersiveResultDetails details,
    required int this.bytesWritten,
    this.qualityFlags = const [],
    this.stageTimes = const {},
    this.afterSaved,
  }) : _made = details,
       error = null,
       message = null,
       eyeWidth = null,
       eyeHeight = null,
       reduced = false;

  const ImmersiveResult.failed(ImmersiveErrorCode this.error, {this.message, this.stageTimes = const {}})
    : eyeWidth = null,
      eyeHeight = null,
      bytesWritten = null,
      reduced = false,
      qualityFlags = const [],
      _made = null,
      afterSaved = null;

  final ImmersiveResultDetails? _made;

  /// What the file written tells of itself; null for a failure
  ImmersiveResultDetails? get details {
    final width = eyeWidth;
    final height = eyeHeight;
    if (width != null && height != null) {
      return SbsResultDetails(eyeWidth: width, eyeHeight: height, reduced: reduced);
    }
    return _made;
  }

  /// Null when the .part holds the 3D photo
  final ImmersiveErrorCode? error;

  /// What went wrong, in the words of the system, of ONNX Runtime or of the generator (the end of its error output),
  /// for the logs and the details of the job
  final String? message;

  /// The size of one eye of the 3D photo written; null for another kind
  final int? eyeWidth;
  final int? eyeHeight;
  final int? bytesWritten;

  /// The photo was wider than the cap of one eye and was reduced
  final bool reduced;
  final List<ReliefQualityFlag> qualityFlags;

  /// How long each step took
  final Map<ImmersiveStage, Duration> stageTimes;

  /// What the engine keeps for this job until its file is saved, let go once the queue saved it (renamed, or dropped
  /// for a name taken): the work folder of a splat scene, which a Retry starts again from when the file could not be
  /// written. Null when the engine keeps nothing; never throws.
  final Future<void> Function()? afterSaved;

  bool get isDone => error == null;
}

/// Runs whole jobs of one kind, one at a time
abstract interface class ImmersiveEngine {
  /// Makes the file of [job] into [ImmersiveJobSpec.partPath]. Each engine runs the spec of its kind (the parameter is
  /// covariant: the queue gives each engine the jobs of its kind only). [cancel] is read between two steps and inside
  /// the long ones (every 64 rows of the right eye, between two regions filled in, between two steps of a
  /// generation); a run of ONNX Runtime is stopped by its RunOptions (lot C1). [onProgress] hears each step and the
  /// progress inside the long ones. Never throws: a failure is a [ImmersiveResult.failed].
  Future<ImmersiveResult> run(
    covariant ImmersiveJobSpec job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  });

  /// Frees the model and the worker; the engine is not used after
  Future<void> dispose();
}
