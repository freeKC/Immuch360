// A photo of a share opened in the app (SMB, WebDAV, DLNA, Plex), copied for its conversion (spec 3.2: "a temporary
// local copy" when a remote source cannot be read in place). The file is read through the media bridge, as the pages
// of the shares read it, into <temp>/immuch360-ai/<a folder of its own>/: once, when the conversion dialog opens, with
// the bytes copied and their total told as it goes and a cancel; the dialog reads the facts of the photo from that
// copy, with the same probes as a file of this computer, and its job reads the same copy, no second download. The
// copy is deleted with its folder when the job ends, whatever the end, and copied again by a Retry; one a crash left
// is deleted at the next start once an hour old (cleanUpAiCopiesAtStart). Nothing is ever written to the original.
//
// A copy that finds no room fails as a disk full, which pauses the queue as for the version itself. A cancel stops the
// copy within a tenth of a second even when the share sends nothing more (a NAS that stopped answering): the request
// to the bridge is aborted and its partial copy deleted, without waiting for the share to time out.

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/creator/server_original_source.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/files/saved_files.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/domain/models/ai_immersive/derived_file_rule.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('ShareFileSource');

/// Asks the media bridge for the bytes of a file of a share at [url]; the request is aborted once [abort] completes
typedef ShareFileFetcher = Future<http.StreamedResponse> Function(Uri url, {Future<void>? abort});

/// How often a copy under way looks whether it was cancelled, chunk or no chunk
const _cancelCheck = Duration(milliseconds: 100);

/// The bytes of a copy written so far, and how many there are in all when the share or the bridge tells it
typedef ShareCopyProgress = void Function(int copied, int? total);

/// Looks for a version of the original among the files of its folder on the share (see RemoteVersionLookup)
typedef ShareVersionLookup =
    Future<ExistingVersion?> Function(
      DerivedRuleOriginal original,
      String settingsKey, {
      required ImmersiveKind kind,
      bool Function(ExistingVersion version)? where,
    });

var _copies = 0;

/// A file of a share, copied once into the cache of this computer before its conversion. Its versions are looked for
/// in the folder of the original on the share too ([versions]), where a batch that skips a photo with a version made
/// with the same settings finds the one a computer put there.
class ShareFileSource implements ConversionSource, RemoteVersionLookup {
  ShareFileSource({
    required this.entry,
    required this._url,
    required this._fetch,
    this.exif = const ImmersiveExif(),
    this._versions,
    Future<Directory> Function()? copiesFolder,
    Future<String> Function(String path, NativeCancelFlag cancel)? hash,
  }) : _copiesFolder = copiesFolder ?? aiCopiesFolder,
       _hash = hash ?? sha1InIsolate;

  /// The file on its share: its source, its path, the size its share listed
  final NetworkEntry entry;

  /// The fields the version keeps from it: the date of a photo that is not a JPEG, read from the copy by the dialog
  /// once it is made (the engine reads the EXIF of a JPEG itself)
  @override
  ImmersiveExif exif;

  final Future<Uri> Function() _url;
  final ShareFileFetcher _fetch;
  final Future<Directory> Function() _copiesFolder;
  final Future<String> Function(String path, NativeCancelFlag cancel) _hash;
  final ShareVersionLookup? _versions;

  Directory? _folder;
  String? _copy;
  Future<String>? _copying;

  @override
  String get name => entry.name;

  /// The share it is on
  String get sourceId => entry.sourceId;

  /// The original is not on this computer
  @override
  String? get folder => null;

  /// The copy once made, null before and once released
  String? get copyPath => _copy;

  /// Copies the file into a folder of its own among the copies of the AI, once: a copy made already is given again
  /// while its file is there. [onProgress] is told the bytes written and their total; [isCancelled] stops the copy.
  /// Throws a [ConversionException]: sourceLost when the bridge does not give the file whole, diskFull or writeFailed
  /// when the copy cannot be written, cancelled; no copy is left then.
  Future<String> copy({bool Function()? isCancelled, ShareCopyProgress? onProgress}) {
    final made = _copy;
    if (made != null && File(made).existsSync()) {
      return Future.value(made);
    }
    final pending = _copying;
    if (pending != null) {
      return pending;
    }
    final copying = _copyOnce(isCancelled ?? () => false, onProgress);
    _copying = copying;
    return copying.whenComplete(() => _copying = null);
  }

  Future<String> _copyOnce(bool Function() isCancelled, ShareCopyProgress? onProgress) async {
    await release();
    try {
      return _copy = await _download(isCancelled, onProgress);
    } catch (_) {
      await release();
      rethrow;
    }
  }

  Future<String> _download(bool Function() isCancelled, ShareCopyProgress? onProgress) async {
    final File file;
    try {
      final root = await _copiesFolder();
      final folder = _folder = await Directory(
        p.join(root.path, 'share-$pid-${++_copies}-${DateTime.now().microsecondsSinceEpoch}'),
      ).create(recursive: true);
      file = File(p.join(folder.path, safeFileName(name)));
    } on FileSystemException catch (error) {
      throw _writeError(error);
    }

    // Cancelled: the request aborted and the bytes no longer awaited, whether the share sends some or not
    final abort = Completer<void>();
    final watch = Timer.periodic(_cancelCheck, (_) {
      if (!abort.isCompleted && isCancelled()) {
        abort.complete();
      }
    });
    try {
      return await _receive(file, abort, isCancelled, onProgress);
    } finally {
      watch.cancel();
    }
  }

  Future<String> _receive(
    File file,
    Completer<void> abort,
    bool Function() isCancelled,
    ShareCopyProgress? onProgress,
  ) async {
    const cancelled = ConversionException(ImmersiveErrorCode.cancelled);
    final http.StreamedResponse response;
    try {
      // The bridge opens the share first: a share that does not answer is not waited for either
      final url = await Future.any([_url(), abort.future.then<Uri>((_) => throw cancelled)]);
      final fetching = _fetch(url, abort: abort.future);
      response = await Future.any([fetching, abort.future.then<http.StreamedResponse>((_) => throw cancelled)]);
      if (abort.isCompleted) {
        // A bridge that answered all the same: its bytes are not read
        unawaited(fetching.then((late) => late.stream.listen(null).cancel(), onError: (Object _) {}));
      }
    } on ConversionException {
      rethrow;
    } on http.RequestAbortedException {
      throw cancelled;
    } on Exception catch (error) {
      throw ConversionException(ImmersiveErrorCode.sourceLost, '$error');
    }
    if (response.statusCode != HttpStatus.ok) {
      unawaited(response.stream.drain<void>().catchError((_) {}));
      throw ConversionException(ImmersiveErrorCode.sourceLost, 'The share answered ${response.statusCode}');
    }
    // The size the bridge reads from the share now, else the one the share listed: a photo edited on the NAS since its
    // folder was shown is copied as it is now
    final expected = response.contentLength ?? entry.size;
    var copied = 0;
    onProgress?.call(0, expected);

    final sink = file.openWrite();
    try {
      final received = Completer<void>();
      final subscription = response.stream.listen(
        (chunk) {
          if (isCancelled()) {
            if (!abort.isCompleted) {
              abort.complete();
            }
            return;
          }
          sink.add(chunk);
          copied += chunk.length;
          onProgress?.call(copied, expected);
        },
        onError: (Object error, StackTrace stack) {
          if (!received.isCompleted) {
            received.completeError(error, stack);
          }
        },
        onDone: () {
          if (!received.isCompleted) {
            received.complete();
          }
        },
        cancelOnError: true,
      );
      unawaited(
        abort.future.then((_) {
          if (!received.isCompleted) {
            received.completeError(cancelled);
            unawaited(subscription.cancel());
          }
        }),
      );
      await received.future;
      await sink.flush();
    } on FileSystemException catch (error) {
      throw _writeError(error);
    } on ConversionException {
      rethrow;
    } on http.RequestAbortedException {
      throw cancelled;
    } on Exception catch (error) {
      throw ConversionException(ImmersiveErrorCode.sourceLost, '$error');
    } finally {
      try {
        await sink.close();
      } on FileSystemException catch (error) {
        _log.fine('The copy of $name was not closed cleanly: ${error.message}');
      }
    }
    if (isCancelled()) {
      throw cancelled;
    }
    if (expected != null && copied != expected) {
      throw ConversionException(ImmersiveErrorCode.sourceLost, 'The share gave $copied bytes of $expected');
    }
    return file.path;
  }

  @override
  Future<ImmersiveSource> prepare(NativeCancelFlag cancel) async {
    final path = await copy(isCancelled: () => cancel.isCancelled);
    try {
      final size = await File(path).length();
      return ImmersiveSource(name: name, size: size, sha1: await _hash(path, cancel), path: path);
    } on Sha1Cancelled {
      throw const ConversionException(ImmersiveErrorCode.cancelled);
    } on FileSystemException catch (error) {
      throw ConversionException(ImmersiveErrorCode.sourceLost, error.osError?.message ?? error.message);
    }
  }

  /// A write of the copy that failed: a disk full pauses the queue, anything else fails the photo
  static ConversionException _writeError(FileSystemException error) {
    final failure = CreatorWriteException.of(error);
    return ConversionException(
      failure.failure == WriteFailure.diskFull ? ImmersiveErrorCode.diskFull : ImmersiveErrorCode.writeFailed,
      failure.message,
    );
  }

  @override
  Future<ExistingVersion?> versionWithSettings(
    DerivedRuleOriginal original,
    String settingsKey, {
    required ImmersiveKind kind,
    bool Function(ExistingVersion version)? where,
  }) async {
    final versions = _versions;
    if (versions == null) {
      return null;
    }
    try {
      return await versions(original, settingsKey, kind: kind, where: where);
    } catch (error) {
      // The share cannot be read now: the photo is converted, as for a folder that cannot be read
      _log.warning('The versions of $name on its share could not be looked up: $error');
      return null;
    }
  }

  @override
  Future<void> release() async {
    final folder = _folder;
    _folder = null;
    _copy = null;
    if (folder == null) {
      return;
    }
    try {
      await folder.delete(recursive: true);
    } on FileSystemException catch (error) {
      _log.warning('The copy of $name stays until the next start: ${error.message}');
    }
  }
}
