// What a copy to the clipboard puts there: the files of this computer as they are, and the files that are elsewhere
// (an asset of the Immich server, a file of a share or of a media server) fetched first, as every feature of the app
// takes a remote file (no refusal by source), into a folder of their own under the cache of the app, under their real
// names: <cache>/immuch360-clipboard/<time of the copy>/. The clipboard then points to those copies, so they are kept
// while it may still be pasted:
// - the folder of a copy gets a marker once its files are on the clipboard, with the token of that write and the run
//   of the app it was made in (desktop_clipboard.dart);
// - at each copy and at each start, a folder at least [clipboardCopyMinAge] old is deleted once the clipboard no
//   longer holds its write (something else was copied since, here or in another program; on Linux, also once the app
//   that served it quit), or has no marker (a copy cancelled or failed, whose files are deleted at once anyway);
// - any folder [clipboardCopyMaxAge] old is deleted, whatever the clipboard holds.
// The minimum age leaves a chat program or a mail the time to read a file pasted just before another copy.
//
// The share window of Windows and the share menu of macOS (lib/desktop/share) take their files from the same folder:
// the files fetched for a share are moved into a folder of their own ([keepShareCopies]), never deleted while the
// window of this run may read them, then marked when it is done with them ([releaseShareCopies]); the folder goes once
// [clipboardCopyMinAge] after that end, since the program chosen (a mail, a nearby device) may still be reading.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/files/saved_files.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('ClipboardCopies');

/// [text] without any URL: the requests of a share go through the media bridge, whose URLs carry its token, the
/// source, the folder and the file name, and those of the server carry the asset; none of it goes into the log
String clipboardLogText(String text) => text.replaceAll(_urlInText, '<url>');

final _urlInText = RegExp(r'[A-Za-z][A-Za-z0-9+.-]*://[^\s,)]*');

/// What a failed fetch says, for the log: the message of an http error without its request URL, then [clipboardLogText]
String clipboardFetchErrorText(Object error) =>
    clipboardLogText(error is http.ClientException ? 'ClientException: ${error.message}' : '$error');

/// The folder of the copies under the cache of the app
const clipboardCopiesFolderName = 'immuch360-clipboard';

/// The marker of a folder whose files went on the clipboard
const clipboardCopyMarker = '.clipboard.json';

/// The marker of a folder whose files went to the share window of the system, with the time it was done with them
const shareCopyMarker = '.share.json';

/// The folders whose files a share window of this run may still read: never deleted meanwhile
final Set<String> _sharesOpen = {};

/// How long the files of a copy are kept at least, see the top of this file
const clipboardCopyMinAge = Duration(hours: 1);

/// How long the files of a copy are kept at most
const clipboardCopyMaxAge = Duration(days: 7);

/// `<cache of the app>/immuch360-clipboard`
Future<Directory> clipboardCopiesRoot() async =>
    Directory(p.join((await getApplicationCacheDirectory()).path, clipboardCopiesFolderName));

/// This run of the app, for the markers: on Linux the clipboard is served by the app, so a write of an earlier run is
/// no longer held
final clipboardRun = '${pid}_${DateTime.now().microsecondsSinceEpoch}';

/// Asks for the bytes of a remote file; the request is aborted once [abort] completes
typedef ClipboardFetch = Future<http.StreamedResponse> Function(Future<void> abort);

/// A photo or a video to copy
sealed class ClipboardSource {
  const ClipboardSource();

  /// Its file name, as the copy is named
  String get name;

  bool get isVideo;
}

/// A file of this computer, copied as it is
class LocalClipboardSource extends ClipboardSource {
  const LocalClipboardSource(this.path, {required this.isVideo});

  final String path;

  @override
  final bool isVideo;

  @override
  String get name => p.basename(path);
}

/// A file elsewhere, fetched before it goes on the clipboard
class RemoteClipboardSource extends ClipboardSource {
  const RemoteClipboardSource({required this.name, required this.isVideo, required this.fetch, this.size});

  @override
  final String name;

  @override
  final bool isVideo;

  final ClipboardFetch fetch;

  /// Its size when its listing tells it, for the progress before the answer gives it
  final int? size;
}

/// Why a copy did not reach the clipboard
enum ClipboardCopyFailure {
  /// The user cancelled the fetch
  cancelled,

  /// A remote file could not be fetched whole
  fetchFailed,

  /// The copy could not be written into the cache
  writeFailed,

  /// The system refused the clipboard
  clipboardRefused,

  /// A later copy was asked before this one reached the clipboard: the later one wins, this one writes nothing
  superseded,
}

class ClipboardCopyException implements Exception {
  const ClipboardCopyException(this.failure, [this.detail]);

  final ClipboardCopyFailure failure;
  final String? detail;

  @override
  String toString() => 'ClipboardCopyException(${failure.name}${detail == null ? '' : ': $detail'})';
}

/// The bytes fetched so far and those of all the remote files, when known
typedef ClipboardFetchProgress = void Function(int fetched, int? total);

/// Fetches [sources] into a new folder of [root], under their names (the first free "name (n)" when two have the same);
/// the folder and the paths, in the order of [sources]. [cancelled] completing stops the fetch at once, even while a
/// share sends nothing. Throws a [ClipboardCopyException] (cancelled, fetchFailed, writeFailed); the folder is then
/// deleted.
Future<({Directory folder, List<String> paths})> fetchClipboardCopies(
  List<RemoteClipboardSource> sources,
  Directory root, {
  Future<void>? cancelled,
  ClipboardFetchProgress? onProgress,
  DateTime Function() now = DateTime.now,
}) async {
  final Directory folder;
  try {
    folder = await _newFolder(root, now());
  } on FileSystemException catch (error) {
    throw ClipboardCopyException(ClipboardCopyFailure.writeFailed, error.message);
  }
  final abort = Completer<void>();
  var finished = false;
  unawaited(
    cancelled?.then((_) {
      // A cancel once every file is in leaves the requests, which are over, alone
      if (!finished && !abort.isCompleted) {
        abort.complete();
      }
    }),
  );
  final listed = sources.every((source) => source.size != null)
      ? sources.fold<int>(0, (sum, source) => sum + source.size!)
      : null;
  var done = 0;
  try {
    final paths = <String>[];
    for (final source in sources) {
      if (abort.isCompleted) {
        throw const ClipboardCopyException(ClipboardCopyFailure.cancelled);
      }
      final before = done;
      paths.add(
        await _fetchOne(source, folder, abort, (fetched) {
          done = before + fetched;
          onProgress?.call(done, listed);
        }),
      );
    }
    finished = true;
    return (folder: folder, paths: paths);
  } catch (_) {
    finished = true;
    // A request still under way stops
    if (!abort.isCompleted) {
      abort.complete();
    }
    await _deleteQuietly(folder);
    rethrow;
  }
}

/// A new folder of [root] for a copy made [at], named after the time so that the oldest sort first
Future<Directory> _newFolder(Directory root, DateTime at) async {
  final stamp = at.toUtc().microsecondsSinceEpoch;
  for (var attempt = 0; ; attempt++) {
    final folder = Directory(p.join(root.path, attempt == 0 ? '$stamp' : '${stamp}_$attempt'));
    if (!folder.existsSync()) {
      return folder.create(recursive: true);
    }
  }
}

Future<String> _fetchOne(
  RemoteClipboardSource source,
  Directory folder,
  Completer<void> abort,
  void Function(int fetched) onFetched,
) async {
  const cancelledError = ClipboardCopyException(ClipboardCopyFailure.cancelled);
  final File file;
  try {
    file = await reserveFileIn(folder, safeFileName(source.name));
  } on FileSystemException catch (error) {
    throw ClipboardCopyException(ClipboardCopyFailure.writeFailed, error.message);
  }
  final http.StreamedResponse response;
  try {
    final fetching = source.fetch(abort.future);
    response = await Future.any([fetching, abort.future.then<http.StreamedResponse>((_) => throw cancelledError)]);
    if (abort.isCompleted) {
      // An answer that came all the same: its bytes are not read
      unawaited(fetching.then((late) => late.stream.listen(null).cancel(), onError: (Object _) {}));
      throw cancelledError;
    }
  } on ClipboardCopyException {
    rethrow;
  } on http.RequestAbortedException {
    throw cancelledError;
  } on Exception catch (error) {
    throw ClipboardCopyException(ClipboardCopyFailure.fetchFailed, clipboardFetchErrorText(error));
  }
  if (response.statusCode != HttpStatus.ok) {
    unawaited(response.stream.drain<void>().catchError((_) {}));
    throw ClipboardCopyException(ClipboardCopyFailure.fetchFailed, 'Answered ${response.statusCode}');
  }
  final expected = response.contentLength;
  final sink = file.openWrite();
  var fetched = 0;
  var sinkFailed = false;
  try {
    final received = Completer<void>();
    final subscription = response.stream.listen(
      (chunk) {
        sink.add(chunk);
        fetched += chunk.length;
        onFetched(fetched);
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
          received.completeError(cancelledError);
          unawaited(subscription.cancel());
        }
      }),
    );
    try {
      await received.future;
    } on ClipboardCopyException {
      rethrow;
    } on http.RequestAbortedException {
      throw cancelledError;
    } on Exception catch (error) {
      throw ClipboardCopyException(ClipboardCopyFailure.fetchFailed, clipboardFetchErrorText(error));
    }
  } finally {
    try {
      await sink.close();
    } on FileSystemException catch (error) {
      sinkFailed = true;
      _log.warning('A copy for the clipboard could not be written: ${error.message}');
    }
  }
  if (sinkFailed) {
    throw const ClipboardCopyException(ClipboardCopyFailure.writeFailed);
  }
  if (expected != null && fetched != expected) {
    throw ClipboardCopyException(ClipboardCopyFailure.fetchFailed, 'Got $fetched bytes of $expected');
  }
  return file.path;
}

/// Writes the marker of [folder]: its files went on the clipboard with [token], in [run]
Future<void> markClipboardCopy(Directory folder, int token, {String? run}) => File(
  p.join(folder.path, clipboardCopyMarker),
).writeAsString(jsonEncode({'token': token, 'run': run ?? clipboardRun}));

/// Deletes the folders of [root] the rule at the top of this file lets go, never [keep]; how many went. [holds] asks
/// the clipboard about a token written in this run, [systemTokens] whether a token of an earlier run can be asked too
/// (Windows and macOS, whose counters belong to the system rather than to the app).
Future<int> cleanClipboardCopies(
  Directory root, {
  required Future<bool> Function(int token) holds,
  required bool systemTokens,
  Directory? keep,
  String? run,
  DateTime Function() now = DateTime.now,
  Duration minAge = clipboardCopyMinAge,
  Duration maxAge = clipboardCopyMaxAge,
}) async {
  final thisRun = run ?? clipboardRun;
  final List<Directory> folders;
  try {
    folders = [
      await for (final entity in root.list(followLinks: false))
        if (entity is Directory) entity,
    ];
  } on FileSystemException {
    return 0;
  }
  var deleted = 0;
  final at = now();
  for (final folder in folders) {
    if (keep != null && p.equals(folder.path, keep.path)) {
      continue;
    }
    if (_sharesOpen.contains(p.normalize(folder.path))) {
      continue;
    }
    final made = await _shareEndedAt(folder) ?? _madeAt(folder);
    if (made == null) {
      continue;
    }
    final age = at.difference(made);
    if (age < minAge) {
      continue;
    }
    if (age < maxAge && await _stillHeld(folder, holds, systemTokens: systemTokens, run: thisRun)) {
      continue;
    }
    if (await _deleteQuietly(folder)) {
      deleted++;
    }
  }
  return deleted;
}

/// When the copy of [folder] was made, from its name; null for a folder the app did not make
DateTime? _madeAt(Directory folder) {
  final name = p.basename(folder.path);
  final stamp = int.tryParse(name.split('_').first);
  return stamp == null ? null : DateTime.fromMicrosecondsSinceEpoch(stamp, isUtc: true);
}

/// When the share window was done with the files of [folder], null for a folder of the clipboard or a share whose
/// end was never told (the app quit meanwhile: its age then counts from the fetch)
Future<DateTime?> _shareEndedAt(Directory folder) async {
  final marker = File(p.join(folder.path, shareCopyMarker));
  if (!marker.existsSync()) {
    return null;
  }
  try {
    final decoded = jsonDecode(await marker.readAsString());
    final ended = decoded is Map ? decoded['ended'] : null;
    return ended is int ? DateTime.fromMicrosecondsSinceEpoch(ended, isUtc: true) : null;
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// Moves [files], fetched for a share into folders that go afterwards, into a new folder of [root] under their own
/// names (the first free "name (n)" when two have the same); the folder, kept while the share is open, and the new
/// paths in order. A file that cannot be moved is copied. Throws a [FileSystemException]; the folder then goes.
Future<({Directory folder, List<String> paths})> keepShareCopies(
  List<File> files,
  Directory root, {
  DateTime Function() now = DateTime.now,
}) async {
  final folder = await _newFolder(root, now());
  _sharesOpen.add(p.normalize(folder.path));
  try {
    final paths = <String>[];
    for (final file in files) {
      final kept = await moveIntoFolder(file, folder, safeFileName(p.basename(file.path)));
      paths.add(kept.path);
    }
    return (folder: folder, paths: paths);
  } catch (_) {
    _sharesOpen.remove(p.normalize(folder.path));
    await _deleteQuietly(folder);
    rethrow;
  }
}

/// The share of the files of [folder] is over: the folder goes [clipboardCopyMinAge] after [now], at a later copy,
/// share or start
Future<void> releaseShareCopies(Directory folder, {DateTime Function() now = DateTime.now}) async {
  try {
    await File(
      p.join(folder.path, shareCopyMarker),
    ).writeAsString(jsonEncode({'ended': now().toUtc().microsecondsSinceEpoch, 'run': clipboardRun}));
  } on FileSystemException catch (error) {
    // Without its marker the folder goes once an hour after the fetch
    _log.info('A share folder has no end marker: ${error.message}');
  } finally {
    _sharesOpen.remove(p.normalize(folder.path));
  }
}

/// Whether a share window of this run may still read the files of [folder]
bool shareCopiesOpen(Directory folder) => _sharesOpen.contains(p.normalize(folder.path));

Future<bool> _stillHeld(
  Directory folder,
  Future<bool> Function(int token) holds, {
  required bool systemTokens,
  required String run,
}) async {
  try {
    final marker = jsonDecode(await File(p.join(folder.path, clipboardCopyMarker)).readAsString());
    if (marker is! Map) {
      return false;
    }
    final token = marker['token'];
    if (token is! int || (!systemTokens && marker['run'] != run)) {
      return false;
    }
    return await holds(token);
  } on FileSystemException {
    return false;
  } on FormatException {
    return false;
  }
}

Future<bool> _deleteQuietly(Directory folder) async {
  try {
    await folder.delete(recursive: true);
    return true;
  } on FileSystemException catch (error) {
    // A file still open by the program it was pasted into, on Windows: the next copy or start tries again
    _log.info('A copy for the clipboard stays for now: ${error.message}');
    return false;
  }
}

/// The share of [fetched] in [total] for a progress bar, null while the total is not known
double? clipboardFetchFraction(int fetched, int? total) =>
    total == null || total <= 0 ? null : math.min(1, fetched / total);
