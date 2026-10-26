// The seam of one whole job of the AI features on a computer: a photo in, a 3D photo written to its .part file out
// (design-final 2026-10-26, section 2.7). The queue and the screens only know this interface, so they are built and
// tested with FakeImmersiveEngine (test/desktop/ai/fakes) before the real one exists, and the native codec, then the
// engines of the later phases, plug in behind it without touching them.
//
// DartImmersiveEngine (lot A4b) chains the decoding, DepthBackend (ONNX Runtime), relief-v1 and SbsCodec in a worker
// isolate. It never opens the original for writing and never touches the final name: the caller renames the .part.

import 'dart:typed_data';

import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The steps of a job, in their order. The screens group them: reading and decoding are "Preparing", depth and
/// rightEye "Computing" (the percentage comes from the rows of the right eye), encoding and writing "Finishing".
enum ImmersiveStage { reading, decoding, depth, rightEye, encoding, writing }

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

/// One photo to make into a full side by side 3D photo
class ImmersiveJob {
  const ImmersiveJob({
    required this.id,
    required this.source,
    required this.partPath,
    required this.derivativeId,
    required this.creatorTool,
    required this.created,
    this.quarterTurns = 0,
    this.maxEyeWidth = ReliefV1.maxEyeWidth,
    this.parallax = ReliefV1.parallax,
    this.convergence = ReliefV1.convergence,
    this.exif = const ImmersiveExif(),
  });

  /// The id of the job in the queue
  final String id;
  final ImmersiveSource source;

  /// The quarter turns clockwise the user sees the photo with, applied after its EXIF orientation
  final int quarterTurns;

  /// Where the JPEG goes: `.<final name>.<pid>-<n>.immuch360.part`, renamed by the caller
  final String partPath;

  /// A wider photo is reduced so that one eye is this wide at most, and the job says so
  final int maxEyeWidth;

  /// The settings of relief-v1
  final double parallax;
  final double convergence;
  final ImmersiveExif exif;

  /// The XMP fields the caller decides: DerivativeId, CreatorTool and Created (see StereoPhotoXmp.estimated)
  final String derivativeId;
  final String creatorTool;
  final String created;
}

/// Where a job is: its step and how far, in thousandths of the whole job
class ImmersiveProgress {
  const ImmersiveProgress(this.stage, this.perMille);

  final ImmersiveStage stage;

  /// 0 to 1000
  final int perMille;

  @override
  bool operator ==(Object other) => other is ImmersiveProgress && other.stage == stage && other.perMille == perMille;

  @override
  int get hashCode => Object.hash(stage, perMille);

  @override
  String toString() => 'ImmersiveProgress($stage, $perMille)';
}

/// How a job ended
class ImmersiveResult {
  const ImmersiveResult.done({
    required int this.eyeWidth,
    required int this.eyeHeight,
    required int this.bytesWritten,
    this.reduced = false,
    this.qualityFlags = const [],
    this.stageTimes = const {},
  }) : error = null,
       message = null;

  const ImmersiveResult.failed(ImmersiveErrorCode this.error, {this.message, this.stageTimes = const {}})
    : eyeWidth = null,
      eyeHeight = null,
      bytesWritten = null,
      reduced = false,
      qualityFlags = const [];

  /// Null when the .part holds the 3D photo
  final ImmersiveErrorCode? error;

  /// What went wrong, in the words of the system or of ONNX Runtime, for the logs and the details of the job
  final String? message;

  /// The size of one eye of the file written
  final int? eyeWidth;
  final int? eyeHeight;
  final int? bytesWritten;

  /// The photo was wider than the cap of one eye and was reduced
  final bool reduced;
  final List<ReliefQualityFlag> qualityFlags;

  /// How long each step took
  final Map<ImmersiveStage, Duration> stageTimes;

  bool get isDone => error == null;
}

/// Runs whole jobs, one at a time
abstract interface class ImmersiveEngine {
  /// Makes the 3D photo of [job] into [ImmersiveJob.partPath]. [cancel] is read between two steps and every 64 rows of
  /// the right eye; a run of the model goes to its end and its result is dropped. [onProgress] hears each step and
  /// the progress inside the long ones. Never throws: a failure is a [ImmersiveResult.failed].
  Future<ImmersiveResult> run(
    ImmersiveJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  });

  /// Frees the model and the worker; the engine is not used after
  Future<void> dispose();
}
