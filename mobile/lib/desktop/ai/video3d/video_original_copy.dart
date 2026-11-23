// The original of a 3D video that is not a file of this computer, downloaded whole as the first step of its job (lot
// ai3d-remote-51, 22 November 2026: a video of the Immich server or of a share was skipped with "save it to a folder of
// this computer first"; the job is now queued at once and downloads it itself). The bytes are those the player reads:
// the original of the server with the session of the app, the file of a share through the media bridge
// (DownloadableOriginal.openBytes).
//
// The copy goes to `<destination>/.immuch360-work-<id>-original/<name>`: on the drive of the 3D video, whose free space
// the dialog and the engine read, under a hidden name no scan imports, beside the work folder and never in it (the engine
// empties its work folder when it starts a job again). The free space of that drive is read once the answer tells the
// size, before a byte is written: too little, and the job fails as a disk full with both figures. The bytes go to
// `<name>.part`, renamed once whole; a Pause, a lost connection, a Retry or a quit leave the part, and the next run asks
// for the rest with a Range request (from the first byte again when the other end ignores it). Pause and Stop end the
// download within a tenth of a second, even while the other end sends nothing. The copy is deleted with the work of the
// job once its 3D video is made, stopped, refused or discarded (deleteVideoOriginalCopy).

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/original_bytes.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/files/saved_files.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('VideoOriginalCopy');

/// Room kept free on the drive beyond the copy: the work of the job and the MP4 come after it
const videoDownloadMargin = 256 * 1024 * 1024;

/// How often a download under way looks whether it was stopped, bytes or no bytes
const _stopCheck = Duration(milliseconds: 100);

/// The folder of the copy of the original of the job whose work folder is [workFolder]
String videoOriginalCopyFolderOf(String workFolder) => '$workFolder-original';

/// The copy of the original named [name] of the job whose work folder is [workFolder]
String videoOriginalCopyPathOf(String workFolder, String name) =>
    p.join(videoOriginalCopyFolderOf(workFolder), safeFileName(name));

/// The bytes of the original written so far, and how many there are in all when told
typedef VideoDownloadProgress = ({int copied, int? total});

/// The message of a download that finds too little room, read back by [videoDownloadRoomOf] for the panel
String videoDownloadRoomMessage(int free, int need) => 'download-room $free $need';

/// The free space and the space needed a download that found too little room told, null for another message
({int free, int need})? videoDownloadRoomOf(String? message) {
  final match = RegExp(r'^download-room (\d+) (\d+)$').firstMatch(message ?? '');
  return match == null ? null : (free: int.parse(match.group(1)!), need: int.parse(match.group(2)!));
}

/// Downloads the original of [source] for the job whose work folder is [workFolder], or goes on with the part an
/// earlier run left; gives the path of the copy once whole (at once when it is there already). [isStopping]: a Pause
/// or a Stop of the job, the download then ends with a ConversionException cancelled, its part kept. [onProgress] is
/// told the bytes written, at most once per thousandth and per megabyte. [freeSpace] reads the room of the drive.
/// Throws a [ConversionException]: diskFull (with [videoDownloadRoomMessage] when the room was read short before),
/// writeFailed, sourceLost when the other end does not give the file whole, cancelled.
Future<String> downloadVideoOriginal(
  DownloadableOriginal source,
  String workFolder, {
  required bool Function() isStopping,
  void Function(VideoDownloadProgress progress)? onProgress,
  AiFreeSpaceReader? freeSpace,
}) async {
  final whole = File(videoOriginalCopyPathOf(workFolder, source.name));
  if (whole.existsSync()) {
    final length = whole.lengthSync();
    onProgress?.call((copied: length, total: length));
    return whole.path;
  }
  final folder = whole.parent;
  final part = File('${whole.path}.part');
  try {
    await folder.create(recursive: true);
  } on FileSystemException catch (error) {
    throw _writeError(error);
  }

  final abort = Completer<void>();
  final watch = Timer.periodic(_stopCheck, (_) {
    if (!abort.isCompleted && isStopping()) {
      abort.complete();
    }
  });
  try {
    return await _download(source, whole, part, abort, isStopping, onProgress, freeSpace);
  } finally {
    watch.cancel();
  }
}

Future<String> _download(
  DownloadableOriginal source,
  File whole,
  File part,
  Completer<void> abort,
  bool Function() isStopping,
  void Function(VideoDownloadProgress progress)? onProgress,
  AiFreeSpaceReader? freeSpace,
) async {
  const stopped = ConversionException(ImmersiveErrorCode.cancelled);
  if (isStopping()) {
    throw stopped;
  }
  var have = part.existsSync() ? part.lengthSync() : 0;
  OriginalBytes bytes;
  try {
    bytes = await _open(source, have, abort);
  } on OriginalRangeRefused {
    // A part longer than the original is now: from the first byte again
    _log.info('${source.name}: the range from $have was refused, downloaded again');
    have = 0;
    bytes = await _open(source, 0, abort);
  }
  if (bytes.offset != have) {
    // The other end ignored the range: the part is written again from the first byte
    _log.info('${source.name}: the range from $have was not honoured, downloaded again');
    have = 0;
  }
  final total = bytes.total;
  if (freeSpace != null && total != null) {
    final need = math.max(0, total - have) + videoDownloadMargin;
    AiFreeSpace? room;
    try {
      room = await freeSpace(part.parent);
    } catch (error) {
      _log.fine('The free space for ${source.name} is not known: $error');
    }
    if (room != null && room.free < need) {
      unawaited(bytes.stream.listen(null).cancel().catchError((_) {}));
      throw ConversionException(ImmersiveErrorCode.diskFull, videoDownloadRoomMessage(room.free, need));
    }
  }

  final RandomAccessFile file;
  try {
    file = await part.open(mode: have > 0 ? FileMode.append : FileMode.write);
  } on FileSystemException catch (error) {
    unawaited(bytes.stream.listen(null).cancel().catchError((_) {}));
    throw _writeError(error);
  }
  var copied = have;
  var told = -1;
  void tell({bool always = false}) {
    // At most once per thousandth and per megabyte: a video of gigabytes is not a state per chunk
    final step = math.max(1024 * 1024, (total ?? 0) ~/ 1000);
    if (always || told < 0 || copied - told >= step) {
      told = copied;
      onProgress?.call((copied: copied, total: total));
    }
  }

  tell(always: true);
  // The write under way, awaited before the file closes
  Future<void> writing = Future.value();
  try {
    final received = Completer<void>();
    late final StreamSubscription<List<int>> subscription;
    void fail(Object error, [StackTrace? stack]) {
      if (!received.isCompleted) {
        received.completeError(error, stack);
      }
      unawaited(subscription.cancel().catchError((_) {}));
    }

    subscription = bytes.stream.listen(
      (chunk) {
        // One write at a time: the other end waits while the disk writes, no gigabyte held in memory
        subscription.pause();
        writing = file.writeFrom(chunk).then((_) {
          copied += chunk.length;
          tell();
          subscription.resume();
        }, onError: fail);
      },
      onError: fail,
      onDone: () {
        if (!received.isCompleted) {
          received.complete();
        }
      },
      cancelOnError: true,
    );
    unawaited(abort.future.then((_) => fail(stopped)));
    await received.future;
    await file.flush();
  } on FileSystemException catch (error) {
    throw _writeError(error);
  } on ConversionException {
    rethrow;
  } on http.RequestAbortedException {
    throw stopped;
  } on Exception catch (error) {
    throw ConversionException(ImmersiveErrorCode.sourceLost, '$error');
  } finally {
    try {
      await writing.catchError((Object _) {});
      await file.close();
    } on FileSystemException catch (error) {
      _log.fine('The copy of ${source.name} was not closed cleanly: ${error.message}');
    }
    // What is on the disk now, also after a stop or a failure: the part a Resume goes on from
    tell(always: true);
  }
  if (isStopping()) {
    throw stopped;
  }
  if (total != null && copied != total) {
    // The part stays: the next run asks for the rest
    throw ConversionException(ImmersiveErrorCode.sourceLost, 'Downloaded $copied bytes of $total');
  }
  try {
    await part.rename(whole.path);
  } on FileSystemException catch (error) {
    throw _writeError(error);
  }
  _log.info('${source.name} downloaded: $copied bytes');
  return whole.path;
}

/// The bytes of [source] from [offset]; the wait ends at once when [abort] completes
Future<OriginalBytes> _open(DownloadableOriginal source, int offset, Completer<void> abort) async {
  const stopped = ConversionException(ImmersiveErrorCode.cancelled);
  final opening = source.openBytes(offset: offset, abort: abort.future);
  try {
    final bytes = await Future.any([opening, abort.future.then<OriginalBytes>((_) => throw stopped)]);
    if (abort.isCompleted) {
      throw stopped;
    }
    return bytes;
  } on ConversionException catch (error) {
    if (error.code == ImmersiveErrorCode.cancelled) {
      // An answer that came all the same: its bytes are not read
      unawaited(opening.then((late) => late.stream.listen(null).cancel(), onError: (Object _) {}));
    }
    rethrow;
  }
}

/// A write of the copy that failed: a disk full pauses the queue, anything else fails the job
ConversionException _writeError(FileSystemException error) {
  final failure = CreatorWriteException.of(error);
  return ConversionException(
    failure.failure == WriteFailure.diskFull ? ImmersiveErrorCode.diskFull : ImmersiveErrorCode.writeFailed,
    failure.message,
  );
}

/// Deletes the copy of the original of the job whose work folder is [workFolder], when there is one; never fails
Future<void> deleteVideoOriginalCopy(String workFolder) async {
  final folder = Directory(videoOriginalCopyFolderOf(workFolder));
  try {
    if (folder.existsSync()) {
      await folder.delete(recursive: true);
    }
  } on FileSystemException catch (error) {
    _log.warning('The copy of the original of a 3D video stays: ${error.message}');
  }
}
