// The copy of one film into a file of this device, resumable: the bytes go into "<copy>.part", which a copy cut short
// (a lost link, a pause, the app closed) continues with a Range request from its length, as long as the server tells
// the same identity of the file (for Plex the key of its part, whose change stamp moves when the file changes, and its
// size). A server that sends the whole file instead of the range, or a file that changed, starts the copy over. Once
// whole, the partial file takes the name of the copy.
//
// The bytes come through NetworkFileDownloads, in Dart: for a Plex server through its pinned client, with the token in
// its header only. No native downloader gets the address or the token (the rule of every share client of the app).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/film_download.model.dart';
import 'package:immich_mobile/domain/services/film_download/film_download_rules.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:logging/logging.dart';

final _log = Logger('FilmTransfer');

/// Opens the file from byte [from]; [abort] stops the request and its body
typedef FilmDownloadOpener = Future<NetworkDownloadStream> Function(int from, Future<void> abort);

/// How a transfer ended
enum FilmTransferEnd { completed, paused, cancelled }

/// What a transfer ended with
class FilmTransferResult {
  const FilmTransferResult(this.end, {required this.received, this.total, this.identity});

  final FilmTransferEnd end;
  final int received;
  final int? total;
  final String? identity;
}

/// A failure of a transfer the user has to see, after the retries of the network failures
class FilmTransferException implements Exception {
  const FilmTransferException(this.failure, this.message);

  final FilmDownloadFailure failure;

  /// In English, without the token, an address or a path
  final String message;

  @override
  String toString() => 'FilmTransferException(${failure.name}): $message';
}

/// The failure [error] stands for, and whether trying again may help (the network, the server answering 5xx)
({FilmDownloadFailure failure, bool retry}) filmDownloadFailureOf(Object error) {
  if (error is FilmTransferException) {
    return (failure: error.failure, retry: false);
  }
  if (error is NetworkFileSystemException) {
    if (error.isDownloadForbidden) {
      return (failure: FilmDownloadFailure.forbidden, retry: false);
    }
    if (error.isFileUnreadable) {
      // The server lists the film but cannot read its file: it may come back (a volume mounted again), so the copy
      // tries again with the waits of a lost link, then tells why
      return (failure: FilmDownloadFailure.unreadable, retry: true);
    }
    if (error.isNotFound) {
      return (failure: FilmDownloadFailure.gone, retry: false);
    }
    if (error.isAuthentication) {
      return (failure: FilmDownloadFailure.failed, retry: false);
    }
    // The server did not answer, or answered a status of its own: a NAS that is busy or rebooting
    return (failure: FilmDownloadFailure.unreachable, retry: true);
  }
  if (error is FileSystemException && isDiskFull(error)) {
    return (failure: FilmDownloadFailure.noSpace, retry: false);
  }
  if (error is FileSystemException) {
    return (failure: FilmDownloadFailure.failed, retry: false);
  }
  if (error is SocketException ||
      error is TimeoutException ||
      error is HttpException ||
      error is http.ClientException ||
      error is _CutShort) {
    return (failure: FilmDownloadFailure.unreachable, retry: true);
  }
  return (failure: FilmDownloadFailure.failed, retry: false);
}

/// Whether [error] says the disk is full: ENOSPC (28) on Android, Linux and macOS, ERROR_DISK_FULL (112) and
/// ERROR_HANDLE_DISK_FULL (39) on Windows
bool isDiskFull(FileSystemException error) {
  final code = error.osError?.errorCode;
  if (Platform.isWindows) {
    return code == 112 || code == 39;
  }
  return code == 28;
}

/// The waits between the tries after a network failure: the copy goes on by itself after a lost link
const filmTransferRetryDelays = [
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 30),
  Duration(seconds: 60),
  Duration(seconds: 60),
  Duration(seconds: 120),
  Duration(seconds: 120),
];

/// One copy into [target], through [open]. [identity] is the one the bytes of the partial file came under, null when
/// there are none yet. [onProgress] gets the bytes on the disk and the total as they grow, [onIdentity] the identity
/// once the server told it (kept with the copy, for its next start), [onRetry] the wait before the next try after a
/// cut link or a server that does not answer ("Waiting for the server").
class FilmTransfer {
  FilmTransfer({
    required this.target,
    required this.open,
    this.identity,
    this.onProgress,
    this.onIdentity,
    this.onRetry,
    this.idleTimeout = const Duration(seconds: 60),
    this.retryDelays = filmTransferRetryDelays,
    this.writeChunk = 1024 * 1024,
  });

  /// The path of the whole copy; the bytes go to [partialPath] until it is whole
  final String target;
  final FilmDownloadOpener open;
  String? identity;
  final void Function(int received, int? total)? onProgress;
  final void Function(String identity)? onIdentity;
  final void Function(Duration delay)? onRetry;

  /// Longest wait for the next bytes before the request is dropped and tried again
  final Duration idleTimeout;
  final List<Duration> retryDelays;

  /// Bytes gathered before they are written
  final int writeChunk;

  String get partialPath => '$target$filmDownloadPartialSuffix';

  FilmTransferEnd? _stop;
  Completer<void> _abort = Completer<void>();
  StreamIterator<List<int>>? _body;
  Timer? _retryTimer;
  Completer<void>? _retryWait;
  int _received = 0;
  int? _total;

  /// Whether the request under way wrote bytes
  bool _progressed = false;

  /// Stops the copy and keeps its bytes for later
  void pause() => _halt(FilmTransferEnd.paused);

  /// Stops the copy and deletes its bytes
  void cancel() => _halt(FilmTransferEnd.cancelled);

  void _halt(FilmTransferEnd end) {
    _stop ??= end;
    if (!_abort.isCompleted) {
      _abort.complete();
    }
    unawaited(_body?.cancel());
    _retryTimer?.cancel();
    final wait = _retryWait;
    if (wait != null && !wait.isCompleted) {
      wait.complete();
    }
  }

  /// Copies until the file is whole, the copy is paused or cancelled, or a failure that tries do not help: that one is
  /// thrown as a [FilmTransferException]
  Future<FilmTransferResult> run() async {
    final partial = File(partialPath);
    await partial.parent.create(recursive: true);
    var tries = 0;
    while (true) {
      final stopped = _stop;
      if (stopped != null) {
        return _ended(stopped, partial);
      }
      _progressed = false;
      try {
        final completed = await _once(partial);
        if (completed) {
          await _finish(partial);
          return FilmTransferResult(FilmTransferEnd.completed, received: _received, total: _total, identity: identity);
        }
      } catch (error) {
        final stopped = _stop;
        if (stopped != null) {
          return _ended(stopped, partial);
        }
        if (_progressed) {
          // Bytes came, then the link dropped: a long copy over a weak link goes on as long as it moves
          tries = 0;
        }
        final kind = filmDownloadFailureOf(error);
        if (!kind.retry || tries >= retryDelays.length) {
          _log.info('The copy stopped: ${kind.failure.name} (${error.runtimeType})');
          throw error is FilmTransferException ? error : FilmTransferException(kind.failure, _messageOf(error));
        }
        final delay = retryDelays[tries++];
        _log.fine('The copy is cut (${error.runtimeType}): trying again in ${delay.inSeconds} s');
        onRetry?.call(delay);
        await _sleep(delay);
      }
    }
  }

  /// One request: true once the file is whole
  Future<bool> _once(File partial) async {
    var have = partial.existsSync() ? await partial.length() : 0;
    if (have > 0 && identity == null) {
      // Bytes of an unknown version: they cannot be continued
      have = 0;
    }
    _abort = Completer<void>();
    final answer = await open(have, _abort.future);
    if (_stop != null) {
      await _drop(answer);
      return false;
    }
    final known = identity;
    if (known != null && known != answer.identity && have > 0) {
      _log.info('The file changed on the server: the copy starts over');
      await _drop(answer);
      identity = answer.identity;
      onIdentity?.call(answer.identity);
      await _truncate(partial, 0);
      return _once(partial);
    }
    if (known != answer.identity) {
      identity = answer.identity;
      onIdentity?.call(answer.identity);
    }
    _total = answer.total;
    if (answer.start != have) {
      if (answer.start != 0) {
        await _drop(answer);
        throw const FilmTransferException(
          FilmDownloadFailure.failed,
          'The server sent another part than the one asked',
        );
      }
      // The whole file instead of the rest: from the start again
      have = 0;
    }
    final total = answer.total;
    if (total != null && have > total) {
      // Longer than the file: bytes of another version
      await _drop(answer);
      await _truncate(partial, 0);
      return _once(partial);
    }
    _received = have;
    onProgress?.call(have, total);
    if (total != null && have == total) {
      await _drop(answer);
      return true;
    }
    final RandomAccessFile file;
    try {
      file = await partial.open(mode: FileMode.append);
    } catch (_) {
      // The body is never read: its transfer stops, rather than its connection staying open until the server ends it
      await _drop(answer);
      rethrow;
    }
    try {
      try {
        await file.truncate(have);
        await file.setPosition(have);
      } catch (_) {
        await _drop(answer);
        rethrow;
      }
      final body = StreamIterator(answer.bytes);
      _body = body;
      final pending = BytesBuilder(copy: false);
      try {
        while (await body.moveNext().timeout(idleTimeout)) {
          pending.add(body.current);
          if (pending.length >= writeChunk) {
            _progressed = true;
            _received += pending.length;
            await file.writeFrom(pending.takeBytes());
            onProgress?.call(_received, total);
          }
          if (_stop != null) {
            break;
          }
        }
      } finally {
        if (pending.isNotEmpty) {
          _progressed = true;
          _received += pending.length;
          await file.writeFrom(pending.takeBytes());
          onProgress?.call(_received, total);
        }
        _body = null;
        unawaited(body.cancel());
      }
      await file.flush();
    } finally {
      await file.close();
    }
    if (_stop != null) {
      return false;
    }
    if (total == null) {
      // The server told no size: the end of its answer is the end of the file
      _total = _received;
      return true;
    }
    if (_received < total) {
      throw const _CutShort();
    }
    if (_received > total) {
      await _truncate(partial, 0);
      throw const FilmTransferException(FilmDownloadFailure.failed, 'The server sent more than the size it told');
    }
    return true;
  }

  Future<void> _finish(File partial) async {
    final whole = File(target);
    if (!partial.existsSync()) {
      // A file of no bytes: nothing was written
      await partial.create(recursive: true);
    }
    if (whole.existsSync()) {
      await whole.delete();
    }
    await partial.rename(target);
  }

  Future<FilmTransferResult> _ended(FilmTransferEnd end, File partial) async {
    if (end == FilmTransferEnd.cancelled) {
      try {
        if (partial.existsSync()) {
          await partial.delete();
        }
      } on FileSystemException catch (error) {
        _log.warning('The bytes of a cancelled copy were not deleted: ${error.osError?.errorCode}');
      }
      return FilmTransferResult(end, received: 0, total: _total, identity: identity);
    }
    final have = partial.existsSync() ? await partial.length() : 0;
    return FilmTransferResult(end, received: have, total: _total, identity: identity);
  }

  Future<void> _sleep(Duration delay) {
    final wait = Completer<void>();
    _retryWait = wait;
    _retryTimer = Timer(delay, () {
      if (!wait.isCompleted) {
        wait.complete();
      }
    });
    return wait.future;
  }

  static Future<void> _drop(NetworkDownloadStream answer) async {
    try {
      await answer.bytes.listen(null).cancel();
    } catch (_) {
      // Nothing to do with a failure to stop a body nobody reads
    }
  }

  static Future<void> _truncate(File partial, int length) async {
    if (!partial.existsSync()) {
      return;
    }
    final file = await partial.open(mode: FileMode.append);
    try {
      await file.truncate(length);
    } finally {
      await file.close();
    }
  }

  static String _messageOf(Object error) => switch (error) {
    NetworkFileSystemException(:final message) => message,
    FileSystemException() => 'The copy could not be written on this device',
    _ => 'The copy failed (${error.runtimeType})',
  };
}

/// The answer ended before the size the server told
class _CutShort implements Exception {
  const _CutShort();
}
