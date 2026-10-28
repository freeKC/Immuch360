// One photo in the queue of 3D conversions of a computer (design-final 2026-10-26, section 2.6): its source, the kind
// of conversion, its state in the words of the spec (5.3 and 5.4: preparing, computing, finishing, done or failed,
// and skipped or cancelled for a batch), its progress, its destination planned then real, the quality flags of its
// result and "3 of 12" for its batch. The queue (conversion_queue.dart) changes jobs, the screens only show them.
//
// Phases 2 and 3 (design-final 2026-10-27, sections 4.5 and 9.1) add the kind of each job and its lane, the job a 360°
// 3D panorama is chained after (the panorama it is made from), "step 12 of 28" and the time left, and why a job still
// waits when the other lane runs.
//
// A source says how to get the bytes the engine reads: a file of this computer is read in place, a server original or
// a file of a share is copied to a temporary folder first (by the screens, lot A5c). Either way the original is never
// opened for writing.

import 'dart:io';
import 'dart:isolate';

import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

/// The two lanes of the queue (design-final 2026-10-27, section 4.5), one job at a time on each: the processor, and
/// the graphics card for a generation
enum ConversionLane { cpu, gpu }

/// What a job makes: "2D to 3D SBS" (phase 1), "2D to 3D scene", "2D to 360° panorama", "360° to 3D 360°"
enum ConversionKind {
  sbsFromPhoto(ImmersiveKind.stereoPhoto, ConversionLane.cpu),
  sceneFromPhoto(ImmersiveKind.volumetricScene, ConversionLane.cpu),
  panoramaFromPhoto(ImmersiveKind.panorama360, ConversionLane.gpu),
  stereoPanoramaFromPanorama(ImmersiveKind.stereoPanorama360, ConversionLane.cpu);

  const ConversionKind(this.output, this.lane);

  /// The kind of file it writes
  final ImmersiveKind output;

  /// The lane it runs on
  final ConversionLane lane;

  /// The steps of its engine, in their order
  List<ImmersiveStage> get stages => ImmersiveStage.of(output);

  /// How long a job of this kind takes on this computer, as [timings] tell its steps
  Duration expectedDuration(AiTimings timings) =>
      Duration(milliseconds: stages.fold(0, (sum, stage) => sum + (timings.of(name, stage.name) ?? 0)));
}

/// The time left of a job of [kind] at [stage], which has taken [inStage] so far: the time the step itself tells
/// ([stageLeft], the steps of a generation), else what its timing leaves of it, then the timings of the steps after it;
/// null when nothing tells any of them
Duration? conversionTimeLeft(
  ConversionKind kind,
  ImmersiveStage stage, {
  required AiTimings timings,
  Duration inStage = Duration.zero,
  Duration? stageLeft,
}) {
  final stages = kind.stages;
  final at = stages.indexOf(stage);
  if (at < 0) {
    return null;
  }
  var known = stageLeft != null;
  var left = stageLeft ?? Duration.zero;
  if (stageLeft == null) {
    final expected = timings.of(kind.name, stage.name);
    if (expected != null) {
      known = true;
      final rest = Duration(milliseconds: expected) - inStage;
      left += rest.isNegative ? Duration.zero : rest;
    }
  }
  for (final later in stages.skip(at + 1)) {
    final expected = timings.of(kind.name, later.name);
    if (expected != null) {
      known = true;
      left += Duration(milliseconds: expected);
    }
  }
  return known ? left : null;
}

/// Why a job still waits while its lane is free
enum ConversionWait {
  /// The other lane runs and the memory free cannot hold both jobs (memory_probe.dart): the job starts when it can,
  /// at the latest when the other one ends
  memory,

  /// Other programs hold the memory of the graphics card (gpu_budget.dart): the job starts once enough is free, asked
  /// again a little later or when the user asks for it; the memory free goes with it (ConversionJob.waitingFree)
  graphicsMemory,
}

/// Where a job is: the steps of the engines between waiting and the four ends, in the order of ImmersiveStage, so
/// that a state reported never goes back
enum ConversionState {
  waiting,
  reading,
  decoding,
  fieldOfView,
  projection,
  loadingModels,
  generating,
  seam,
  upscale,
  pasteBack,
  geometry,
  layers,
  inpaint,
  mesh,
  textures,
  depth,
  panoramaDepth,
  rightEye,
  encoding,
  writing,
  done,
  skipped,
  cancelled,
  failed;

  /// The step of the engine it stands for, null for waiting and the ends
  ImmersiveStage? get stage => isActive ? ImmersiveStage.values.byName(name) : null;

  /// What the screens show for it
  ConversionPhase get phase => switch (this) {
    waiting => ConversionPhase.waiting,
    done => ConversionPhase.done,
    skipped => ConversionPhase.skipped,
    cancelled => ConversionPhase.cancelled,
    failed => ConversionPhase.failed,
    _ => switch (stage!.phase) {
      ImmersivePhase.preparing => ConversionPhase.preparing,
      ImmersivePhase.computing => ConversionPhase.computing,
      ImmersivePhase.finishing => ConversionPhase.finishing,
    },
  };

  /// Done, skipped, cancelled or failed: nothing more happens to the job unless it is retried
  bool get isEnded => index >= done.index;

  /// Between waiting and its end
  bool get isActive => this != waiting && !isEnded;

  static ConversionState of(ImmersiveStage stage) => switch (stage) {
    ImmersiveStage.reading => reading,
    ImmersiveStage.decoding => decoding,
    ImmersiveStage.fieldOfView => fieldOfView,
    ImmersiveStage.projection => projection,
    ImmersiveStage.loadingModels => loadingModels,
    ImmersiveStage.generating => generating,
    ImmersiveStage.seam => seam,
    ImmersiveStage.upscale => upscale,
    ImmersiveStage.pasteBack => pasteBack,
    ImmersiveStage.geometry => geometry,
    ImmersiveStage.layers => layers,
    ImmersiveStage.inpaint => inpaint,
    ImmersiveStage.mesh => mesh,
    ImmersiveStage.textures => textures,
    ImmersiveStage.depth => depth,
    ImmersiveStage.panoramaDepth => panoramaDepth,
    ImmersiveStage.rightEye => rightEye,
    ImmersiveStage.encoding => encoding,
    ImmersiveStage.writing => writing,
  };
}

/// The states as the spec words them (5.3 and 5.4): the texts are the ai_immersive_state_ keys
enum ConversionPhase { waiting, preparing, computing, finishing, done, skipped, cancelled, failed }

/// Why a job was skipped
enum ConversionSkipReason {
  video,
  sphere360,
  vr180,
  spatial,

  /// Already a side by side photo, ours or of another tool
  alreadyStereo,

  /// Already a version the app made from a photo (a 3D scene, a 360° panorama for a kind made from a flat photo)
  alreadyVersion,

  /// Not a 360° photo of a full sphere, for the 3D version of a 360° photo
  notSphere,

  /// A format this computer cannot read (HEIC on Linux)
  unreadableFormat,

  /// A version with the same settings exists and the batch skips such photos (the default)
  sameSettingsExists,

  /// The name of the 3D photo is taken and the user chose Skip for such files
  nameTaken,

  /// The original cannot be reached from this computer: a file gone since the last scan, a photo of a server the app
  /// is not signed in to
  unreachable,

  /// A 360° 3D panorama chained after a panorama that was not made: failed, cancelled, or skipped without a file
  parentNotMade,
}

/// What a batch does with a photo that already has a version with the same settings. A name taken by another file is
/// the other choice of the batch, AiWhenExists, which this one goes before.
enum ExistingVersionChoice {
  /// The default, see DesktopAiSettings.skipExisting
  skip,

  /// Another version beside it, with its own DerivativeId: nothing is replaced then, whatever the choice for a name
  /// taken says
  newVersion,

  /// The new 3D photo takes the place of that version when it is in the destination folder and still ours with its
  /// DerivativeId
  replace,
}

/// Failures a source or the writer of the 3D photos report, with the code of the engine that tells them apart
class ConversionException implements Exception {
  const ConversionException(this.code, [this.message]);

  final ImmersiveErrorCode code;
  final String? message;

  @override
  String toString() => 'ConversionException(${code.name}${message == null ? '' : ': $message'})';
}

/// The original of a job
abstract interface class ConversionSource {
  /// The name of the original, "salon.jpg"
  String get name;

  /// Its folder on this computer, null for a server original or a file of a share
  String? get folder;

  /// The fields the 3D photo keeps from it (dates, place)
  ImmersiveExif get exif;

  /// Reads, or copies, the original and gives what the engine reads, with its size and its SHA-1 in base64. Throws a
  /// [ConversionException]: sourceLost when it cannot be reached, diskFull when its temporary copy has no room,
  /// cancelled when [cancel] stopped a long read.
  Future<ImmersiveSource> prepare(NativeCancelFlag cancel);

  /// Deletes what [prepare] copied; nothing for a file read in place
  Future<void> release();
}

/// A file of this computer, read in place: the folders of the library and the files opened with the program.
///
/// Its sum is computed on its bytes at each run, never taken from the library index (design 2.3.1): an edit that keeps
/// the size, a turn written in the EXIF before the next scan, would give the 3D photo the sum of a photo that is gone
/// for good, and would find the version of that old photo with the same settings. It costs some 60 ms for 10 MB.
class LocalFileSource implements ConversionSource {
  LocalFileSource(
    this.path, {
    this.exif = const ImmersiveExif(),
    Future<String> Function(String path, NativeCancelFlag cancel)? hash,
  }) : _hash = hash ?? sha1InIsolate;

  final String path;
  @override
  final ImmersiveExif exif;
  final Future<String> Function(String path, NativeCancelFlag cancel) _hash;

  @override
  String get name => p.basename(path);

  @override
  String get folder => p.dirname(path);

  @override
  Future<ImmersiveSource> prepare(NativeCancelFlag cancel) async {
    try {
      final length = await File(path).length();
      return ImmersiveSource(name: name, size: length, sha1: await _hash(path, cancel), path: path);
    } on FileSystemException catch (error) {
      throw ConversionException(ImmersiveErrorCode.sourceLost, error.osError?.message ?? error.message);
    } on Sha1Cancelled {
      throw const ConversionException(ImmersiveErrorCode.cancelled);
    }
  }

  @override
  Future<void> release() async {}
}

/// The SHA-1 of the file at [path] in base64, computed by the system's library in an isolate of its own (as the
/// library hashes its files), stopped by [cancel] between two chunks with [Sha1Cancelled]
Future<String> sha1InIsolate(String path, NativeCancelFlag cancel) {
  final address = cancel.address;
  return Isolate.run(() {
    final engine = Sha1Engine.open();
    try {
      return sha1OfFile(path, engine: engine, isCancelled: NativeCancelFlag.readerOf(address));
    } finally {
      engine.close();
    }
  }, debugName: 'ai-source-sha1');
}

/// Where the file of a job is planned: its folder and the name it would get there
class ConversionTarget {
  const ConversionTarget({required this.folder, required this.fileName});

  /// The version of [kind] of the original named [originalName] in [folder], the 3D photo by default: its name made
  /// safe for Windows (design 4.1), its end kept whole, as versionTargetName gives it. A name from a server or a share
  /// may hold a character Windows refuses.
  factory ConversionTarget.inFolder(
    String folder,
    String originalName, {
    ConversionKind kind = ConversionKind.sbsFromPhoto,
  }) => ConversionTarget(folder: folder, fileName: versionTargetName(kind.output, originalName));

  /// Next to the original, in its folder
  factory ConversionTarget.nextTo(String originalPath, {ConversionKind kind = ConversionKind.sbsFromPhoto}) =>
      ConversionTarget.inFolder(p.dirname(originalPath), p.basename(originalPath), kind: kind);

  final String folder;
  final String fileName;

  String get path => p.join(folder, fileName);
}

/// One photo to convert, as the dialog hands it to the queue
class ConversionRequest {
  const ConversionRequest({required this.source, this.target, this.quarterTurns = 0, this.skip})
    : assert(target != null || skip != null, 'A job that runs has a destination');

  final ConversionSource source;

  /// Null for a photo skipped from the start
  final ConversionTarget? target;

  /// The quarter turns clockwise the user sees the photo with
  final int quarterTurns;

  /// Known before anything runs: a video, a 360° photo, a 3D photo already, a format this system cannot read
  final ConversionSkipReason? skip;
}

/// A job of the queue, unchanged once made: the queue replaces it with a copy at each change
class ConversionJob {
  const ConversionJob({
    required this.id,
    required this.source,
    required this.batchIndex,
    required this.batchSize,
    this.target,
    this.kind = ConversionKind.sbsFromPhoto,
    this.parentId,
    this.inputPath,
    this.quarterTurns = 0,
    this.existing = ExistingVersionChoice.skip,
    this.whenExists = AiWhenExists.keepBoth,
    this.state = ConversionState.waiting,
    this.perMille = 0,
    this.writtenPath,
    this.replaced = false,
    this.existingVersionPath,
    this.eyeWidth,
    this.eyeHeight,
    this.reduced = false,
    this.qualityFlags = const [],
    this.details,
    this.error,
    this.message,
    this.skipReason,
    this.step,
    this.steps,
    this.remaining,
    this.waitingFor,
    this.waitingFree,
  });

  final String id;

  /// The original: the photo, also for a 360° 3D panorama chained after the panorama made from it
  final ConversionSource source;
  final ConversionKind kind;

  /// The job whose file this one is made from: the panorama of a 360° 3D panorama chained after it
  final String? parentId;

  /// The file the job reads instead of its source, once its parent made it (or found it with the same settings)
  final String? inputPath;

  /// Its place in the batch it came with, from 1: "3 of 12"
  final int batchIndex;
  final int batchSize;

  /// The destination planned; null for a photo skipped from the start
  final ConversionTarget? target;
  final int quarterTurns;
  final ExistingVersionChoice existing;

  /// What the writer does when the name of the 3D photo is taken (desktop_ai.json, spec 6.4)
  final AiWhenExists whenExists;
  final ConversionState state;

  /// How far the job is, in thousandths of the whole job
  final int perMille;

  /// The destination for real, once done: the name may differ from the one planned ("name (1)")
  final String? writtenPath;

  /// The 3D photo took the place of an existing version, at [writtenPath], as the writer did it
  final bool replaced;

  /// The version with the same settings found before the run, the reason of a skip; or the file replaced
  final String? existingVersionPath;

  /// The size of one eye of the 3D photo, and whether the original was wider than the cap and reduced
  final int? eyeWidth;
  final int? eyeHeight;
  final bool reduced;
  final List<ReliefQualityFlag> qualityFlags;

  /// What the file written tells of itself, per kind (the size of an eye, the meshes of a scene, the seed of a
  /// panorama)
  final ImmersiveResultDetails? details;

  /// Why it failed, and the words of the system or of the model
  final ImmersiveErrorCode? error;
  final String? message;
  final ConversionSkipReason? skipReason;

  /// The step of a long step of the engine under way, "step 12 of 28"; null when it tells none
  final int? step;
  final int? steps;

  /// The time left of the whole job, while it runs; null when nothing tells it
  final Duration? remaining;

  /// Why it still waits; null for a job that waits for its turn
  final ConversionWait? waitingFor;

  /// The memory of the graphics card free when it was asked, for [ConversionWait.graphicsMemory], in bytes
  final int? waitingFree;

  ConversionPhase get phase => state.phase;

  /// From 0 to 1
  double get progress => perMille / 1000;

  /// A copy with the values given; [inputPath], [step], [steps], [remaining], [waitingFor] and [waitingFree] are given
  /// as functions, so that they may go back to null
  ConversionJob copyWith({
    ConversionState? state,
    int? perMille,
    String? writtenPath,
    bool? replaced,
    String? existingVersionPath,
    int? eyeWidth,
    int? eyeHeight,
    bool? reduced,
    List<ReliefQualityFlag>? qualityFlags,
    ImmersiveResultDetails? details,
    ImmersiveErrorCode? error,
    String? message,
    ConversionSkipReason? skipReason,
    String? Function()? inputPath,
    int? Function()? step,
    int? Function()? steps,
    Duration? Function()? remaining,
    ConversionWait? Function()? waitingFor,
    int? Function()? waitingFree,
  }) => ConversionJob(
    id: id,
    source: source,
    batchIndex: batchIndex,
    batchSize: batchSize,
    target: target,
    kind: kind,
    parentId: parentId,
    inputPath: inputPath == null ? this.inputPath : inputPath(),
    quarterTurns: quarterTurns,
    existing: existing,
    whenExists: whenExists,
    state: state ?? this.state,
    perMille: perMille ?? this.perMille,
    writtenPath: writtenPath ?? this.writtenPath,
    replaced: replaced ?? this.replaced,
    existingVersionPath: existingVersionPath ?? this.existingVersionPath,
    eyeWidth: eyeWidth ?? this.eyeWidth,
    eyeHeight: eyeHeight ?? this.eyeHeight,
    reduced: reduced ?? this.reduced,
    qualityFlags: qualityFlags ?? this.qualityFlags,
    details: details ?? this.details,
    error: error ?? this.error,
    message: message ?? this.message,
    skipReason: skipReason ?? this.skipReason,
    step: step == null ? this.step : step(),
    steps: steps == null ? this.steps : steps(),
    remaining: remaining == null ? this.remaining : remaining(),
    waitingFor: waitingFor == null ? this.waitingFor : waitingFor(),
    waitingFree: waitingFree == null ? this.waitingFree : waitingFree(),
  );

  /// The job as it was added, to run again; a chained job reads again what its parent makes then
  ConversionJob restarted() => ConversionJob(
    id: id,
    source: source,
    batchIndex: batchIndex,
    batchSize: batchSize,
    target: target,
    kind: kind,
    parentId: parentId,
    inputPath: parentId == null ? inputPath : null,
    quarterTurns: quarterTurns,
    existing: existing,
    whenExists: whenExists,
  );

  @override
  String toString() => 'ConversionJob($id, ${kind.name}, ${source.name}, ${state.name})';
}
