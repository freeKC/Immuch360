// The original of a photo of the Immich server, copied for its conversion (design-final 2026-10-26, section 2.3.1; spec
// 3.2: "a temporary local copy" when a remote source cannot be read in place). The original as the server keeps it,
// never an edit, is downloaded into <temp>/immuch360-ai/<a folder of its own>/, read there by the engine, and deleted
// with its folder when the job ends, whatever the end. A copy a crash left is deleted at the next start once it is an
// hour old. Nothing is ever sent to the server: the 3D photo goes to a folder of this computer (destination.dart).
//
// A copy that finds no room fails as a disk full, which pauses the queue as for the 3D photo itself.

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/files/saved_files.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('ServerOriginalSource');

/// The folder of the temporary copies in the temporary folder of the system
const aiCopiesFolderName = 'immuch360-ai';

/// `<temp>/immuch360-ai`
Future<Directory> aiCopiesFolder() async => Directory(p.join((await getTemporaryDirectory()).path, aiCopiesFolderName));

/// Asks the server for the bytes at [url], with the authentication of the app
typedef OriginalFetcher = Future<http.StreamedResponse> Function(Uri url);

var _copies = 0;

/// A photo of the Immich server, copied before its conversion
class ServerOriginalSource implements ConversionSource {
  ServerOriginalSource({
    required this.name,
    required this.remoteId,
    required this.endpoint,
    required this._fetch,
    this.exif = const ImmersiveExif(),
    Future<Directory> Function()? copiesFolder,
    Future<String> Function(String path, NativeCancelFlag cancel)? hash,
  }) : _copiesFolder = copiesFolder ?? aiCopiesFolder,
       _hash = hash ?? sha1InIsolate;

  @override
  final String name;
  final String remoteId;

  /// The address of the server API, ".../api"
  final String endpoint;
  @override
  final ImmersiveExif exif;
  final OriginalFetcher _fetch;
  final Future<Directory> Function() _copiesFolder;
  final Future<String> Function(String path, NativeCancelFlag cancel) _hash;

  Directory? _folder;

  /// The original is not on this computer: its 3D photo goes to a chosen folder
  @override
  String? get folder => null;

  /// The address of the original, never an edit
  Uri get url => Uri.parse('$endpoint/assets/$remoteId/original');

  @override
  Future<ImmersiveSource> prepare(NativeCancelFlag cancel) async {
    await release();
    final File copy;
    try {
      final root = await _copiesFolder();
      final folder = _folder = await Directory(
        p.join(root.path, '$pid-${++_copies}-${DateTime.now().microsecondsSinceEpoch}'),
      ).create(recursive: true);
      copy = File(p.join(folder.path, safeFileName(name)));
    } on FileSystemException catch (error) {
      throw _writeError(error);
    }

    final http.StreamedResponse response;
    try {
      response = await _fetch(url);
    } on Exception catch (error) {
      throw ConversionException(ImmersiveErrorCode.sourceLost, '$error');
    }
    if (response.statusCode != HttpStatus.ok) {
      unawaited(response.stream.drain<void>().catchError((_) {}));
      throw ConversionException(ImmersiveErrorCode.sourceLost, 'The server answered ${response.statusCode}');
    }

    final sink = copy.openWrite();
    try {
      await for (final chunk in response.stream) {
        if (cancel.isCancelled) {
          throw const ConversionException(ImmersiveErrorCode.cancelled);
        }
        sink.add(chunk);
      }
      await sink.flush();
    } on FileSystemException catch (error) {
      throw _writeError(error);
    } on ConversionException {
      rethrow;
    } on Exception catch (error) {
      throw ConversionException(ImmersiveErrorCode.sourceLost, '$error');
    } finally {
      try {
        await sink.close();
      } on FileSystemException catch (error) {
        _log.fine('The copy of $name was not closed cleanly: ${error.message}');
      }
    }

    try {
      final size = await copy.length();
      return ImmersiveSource(name: name, size: size, sha1: await _hash(copy.path, cancel), path: copy.path);
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
  Future<void> release() async {
    final folder = _folder;
    _folder = null;
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

/// At the start of the app: deletes the copies an earlier session left (a crash, a power cut), those older than [age]
/// only, so that a second window of the app never loses the copy it reads; never fails. The temporary folder is on a
/// local disk: read without waiting for the threads of dart:io.
Future<void> cleanUpAiCopiesAtStart({
  Duration age = const Duration(hours: 1),
  Future<Directory> Function()? copiesFolder,
  DateTime Function()? now,
}) async {
  try {
    final root = await (copiesFolder ?? aiCopiesFolder)();
    if (!root.existsSync()) {
      return;
    }
    final limit = (now ?? DateTime.now)().subtract(age);
    for (final entry in root.listSync(followLinks: false)) {
      try {
        if (_lastWriteIn(entry).isBefore(limit)) {
          entry.deleteSync(recursive: true);
        }
      } on FileSystemException catch (error) {
        _log.fine('A copy of an earlier session stays: ${error.message}');
      }
    }
  } catch (error, stack) {
    _log.warning('The copies of an earlier session were not cleaned up', error, stack);
  }
}

/// When the copy in [entry] was last written: its newest file, or the folder itself while it holds none
DateTime _lastWriteIn(FileSystemEntity entry) {
  if (entry is! Directory) {
    return entry.statSync().modified;
  }
  DateTime? newest;
  for (final file in entry.listSync(recursive: true, followLinks: false)) {
    if (file is File) {
      final modified = file.statSync().modified;
      if (newest == null || modified.isAfter(newest)) {
        newest = modified;
      }
    }
  }
  return newest ?? entry.statSync().modified;
}
