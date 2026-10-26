// One photo in the queue of 3D conversions of a computer (design-final 2026-10-26, section 2.6): its source, the kind
// of conversion, its state in the words of the spec (5.3 and 5.4: preparing, computing, finishing, done or failed,
// and skipped or cancelled for a batch), its progress, its destination planned then real, the quality flags of its
// result and "3 of 12" for its batch. The queue (conversion_queue.dart) changes jobs, the screens only show them.
//
// A source says how to get the bytes the engine reads: a file of this computer is read in place, a server original or
// a file of a share is copied to a temporary folder first (by the screens, lot A5c). Either way the original is never
// opened for writing.

import 'dart:io';
import 'dart:isolate';

import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

/// What a job makes; phase 1 has one kind, "2D to 3D SBS"
enum ConversionKind { sbsFromPhoto }

/// Where a job is: the steps of the engine between waiting and the four ends
enum ConversionState {
  waiting,
  reading,
  decoding,
  depth,
  rightEye,
  encoding,
  writing,
  done,
  skipped,
  cancelled,
  failed;

  /// What the screens show for it
  ConversionPhase get phase => switch (this) {
    waiting => ConversionPhase.waiting,
    reading || decoding => ConversionPhase.preparing,
    depth || rightEye => ConversionPhase.computing,
    encoding || writing => ConversionPhase.finishing,
    done => ConversionPhase.done,
    skipped => ConversionPhase.skipped,
    cancelled => ConversionPhase.cancelled,
    failed => ConversionPhase.failed,
  };

  /// Done, skipped, cancelled or failed: nothing more happens to the job unless it is retried
  bool get isEnded => index >= done.index;

  /// Between waiting and its end
  bool get isActive => this != waiting && !isEnded;

  static ConversionState of(ImmersiveStage stage) => switch (stage) {
    ImmersiveStage.reading => reading,
    ImmersiveStage.decoding => decoding,
    ImmersiveStage.depth => depth,
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

  /// A format this computer cannot read (HEIC on Linux)
  unreadableFormat,

  /// A version with the same settings exists and the batch skips such photos (the default)
  sameSettingsExists,

  /// The name of the 3D photo is taken and the user chose Skip for such files
  nameTaken,
}

/// What a batch does with a photo that already has a version with the same settings
enum ExistingVersionChoice {
  /// The default, see DesktopAiSettings.skipExisting
  skip,

  /// Another version beside it, with its own DerivativeId
  newVersion,

  /// The new 3D photo takes the place of that version, when it is still ours with its DerivativeId
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

/// A file of this computer, read in place: the folders of the library and the files opened with the program
class LocalFileSource implements ConversionSource {
  /// [sha1] and [size] as the library index knows them; the sum is computed again when the file changed size since
  LocalFileSource(
    this.path, {
    this.sha1,
    this.size,
    this.exif = const ImmersiveExif(),
    Future<String> Function(String path, NativeCancelFlag cancel)? hash,
  }) : _hash = hash ?? sha1InIsolate;

  final String path;
  final String? sha1;
  final int? size;
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
      final known = sha1;
      final sum = known != null && known.isNotEmpty && length == size ? known : await _hash(path, cancel);
      return ImmersiveSource(name: name, size: length, sha1: sum, path: path);
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

/// Where the 3D photo of a job is planned: its folder and the name it would get there
class ConversionTarget {
  const ConversionTarget({required this.folder, required this.fileName});

  /// Next to the original: [folder] of the original and the name of [sbsFileNameFor]
  factory ConversionTarget.nextTo(String originalPath) =>
      ConversionTarget(folder: p.dirname(originalPath), fileName: sbsFileNameFor(p.basename(originalPath)));

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
    this.quarterTurns = 0,
    this.existing = ExistingVersionChoice.skip,
    this.state = ConversionState.waiting,
    this.perMille = 0,
    this.writtenPath,
    this.replaced = false,
    this.existingVersionPath,
    this.eyeWidth,
    this.eyeHeight,
    this.reduced = false,
    this.qualityFlags = const [],
    this.error,
    this.message,
    this.skipReason,
  });

  final String id;
  final ConversionSource source;
  final ConversionKind kind;

  /// Its place in the batch it came with, from 1: "3 of 12"
  final int batchIndex;
  final int batchSize;

  /// The destination planned; null for a photo skipped from the start
  final ConversionTarget? target;
  final int quarterTurns;
  final ExistingVersionChoice existing;
  final ConversionState state;

  /// How far the job is, in thousandths of the whole job
  final int perMille;

  /// The destination for real, once done: the name may differ from the one planned ("name (1)")
  final String? writtenPath;

  /// The 3D photo took the place of an existing version, at [writtenPath]
  final bool replaced;

  /// The version with the same settings found before the run: the reason of a skip, or the file replaced
  final String? existingVersionPath;

  /// The size of one eye of the 3D photo, and whether the original was wider than the cap and reduced
  final int? eyeWidth;
  final int? eyeHeight;
  final bool reduced;
  final List<ReliefQualityFlag> qualityFlags;

  /// Why it failed, and the words of the system or of the model
  final ImmersiveErrorCode? error;
  final String? message;
  final ConversionSkipReason? skipReason;

  ConversionPhase get phase => state.phase;

  /// From 0 to 1
  double get progress => perMille / 1000;

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
    ImmersiveErrorCode? error,
    String? message,
    ConversionSkipReason? skipReason,
  }) => ConversionJob(
    id: id,
    source: source,
    batchIndex: batchIndex,
    batchSize: batchSize,
    target: target,
    kind: kind,
    quarterTurns: quarterTurns,
    existing: existing,
    state: state ?? this.state,
    perMille: perMille ?? this.perMille,
    writtenPath: writtenPath ?? this.writtenPath,
    replaced: replaced ?? this.replaced,
    existingVersionPath: existingVersionPath ?? this.existingVersionPath,
    eyeWidth: eyeWidth ?? this.eyeWidth,
    eyeHeight: eyeHeight ?? this.eyeHeight,
    reduced: reduced ?? this.reduced,
    qualityFlags: qualityFlags ?? this.qualityFlags,
    error: error ?? this.error,
    message: message ?? this.message,
    skipReason: skipReason ?? this.skipReason,
  );

  /// The job as it was added, to run again
  ConversionJob restarted() => ConversionJob(
    id: id,
    source: source,
    batchIndex: batchIndex,
    batchSize: batchSize,
    target: target,
    kind: kind,
    quarterTurns: quarterTurns,
    existing: existing,
  );

  @override
  String toString() => 'ConversionJob($id, ${source.name}, ${state.name})';
}
