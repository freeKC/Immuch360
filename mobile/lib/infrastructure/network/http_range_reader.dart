// Reads a part of a file over plain HTTP with a Range request, for the shares that serve their files that way (WebDAV,
// the DLNA media servers). No file is ever downloaded whole: a read asks for its bytes only, and stops the transfer
// once they arrived.
//
// Some servers ignore the Range header and answer with the whole file. Reads still work then: the transfer is kept
// open for a while after a read, so that the next read further in the same file goes on from where the last one
// stopped instead of transferring the start of the file again.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/services/network_file_system.dart';

/// Sends a request and gives its answer, with the URL that answered (after the redirects the sender follows); the
/// request is aborted when [abort] completes before its answer (an http.RequestAbortedException then)
typedef HttpSend =
    Future<(http.StreamedResponse, Uri)> Function(
      String method,
      Uri uri, {
      Map<String, String> headers,
      Future<void>? abort,
    });

/// Throws the exception matching an unexpected answer about [key] (a path, an object id), after dropping its body
typedef HttpFail = Future<Never> Function(http.StreamedResponse response, String key);

/// Reads byte ranges of the resources of one server through [HttpSend], see [read]
class HttpRangeReader {
  HttpRangeReader({required this._send, required this._fail, this._isClosed});

  final HttpSend _send;
  final HttpFail _fail;
  final bool Function()? _isClosed;
  bool _closed = false;

  /// Null until a read tells, false once the server answered a range request with the whole file
  bool? _rangesHonoured;

  /// Transfers left open on a server that ignores ranges, per key, so that the next read further in the resource goes
  /// on from where the last one stopped instead of downloading its start again
  final Map<String, List<SequentialHttpRead>> _openReads = {};

  /// Longest wait for the answer of the server, then between two parts of a body
  static const answerTimeout = Duration(seconds: 30);

  /// How long a transfer left open on a server that ignores ranges waits for the next read
  static const openReadTimeout = Duration(seconds: 15);

  /// Transfers kept open per key on a server that ignores ranges: a player reading at a few places of one file at once
  static const maxOpenReadsPerKey = 3;

  /// Past this size, an error or redirect body is not read to its end (which lets its connection serve again) but
  /// dropped with its connection
  static const maxDiscardedBody = 64 * 1024;

  /// Whether the server honours range requests: null until a read tells, false when it answers them with the whole
  /// file (reads still work, but each one transfers the file from its start up to the bytes asked for)
  bool? get supportsRanges => _rangesHonoured;

  bool get _isDone => _closed || (_isClosed?.call() ?? false);

  /// [length] bytes from [offset] of the resource at [uri], fewer at its end, none past it. [key] groups the
  /// transfers kept open on a server that ignores ranges (the WebDAV path, the DLNA object id). [headers] go with the
  /// request, along with the range and "accept-encoding: identity" (offsets are those of the file, not of a
  /// compressed body).
  ///
  /// When [abort] completes first, the read stops at once, waiting for its answer or in the middle of its body: the
  /// request is aborted (see [HttpSend]), the body's connection dropped, and a [NetworkReadAborted] thrown. The media
  /// bridge stops so the read of a player that went away (a seek elsewhere in the film): left to end, it held the link
  /// and one of the connections to the server while the player waited for the bytes of the new place.
  Future<Uint8List> read(
    Uri uri,
    String key,
    int offset,
    int length, {
    Map<String, String> headers = const {},
    Future<void>? abort,
  }) async {
    RangeError.checkNotNegative(offset, 'offset');
    RangeError.checkNotNegative(length, 'length');
    if (length == 0) {
      return Uint8List(0);
    }
    if (abort == null) {
      return _read(uri, key, offset, length, headers, null);
    }
    final stop = _ReadStop(abort);
    try {
      final bytes = await _read(uri, key, offset, length, headers, stop);
      stop.check();
      return bytes;
    } catch (error) {
      if (stop.stopped) {
        throw const NetworkReadAborted();
      }
      rethrow;
    } finally {
      stop.end();
    }
  }

  Future<Uint8List> _read(
    Uri uri,
    String key,
    int offset,
    int length,
    Map<String, String> headers,
    _ReadStop? stop,
  ) async {
    final open = _takeOpenRead(key, offset);
    if (open != null) {
      stop?.follow(open);
      try {
        final bytes = await open.read(offset, length);
        stop?.check();
        _keepOpenRead(key, open);
        return bytes;
      } catch (_) {
        // The server dropped the transfer while it waited: a new request below. Or the read was stopped.
        await open.cancel();
        stop?.check();
      }
    }

    final sent = _send(
      'GET',
      uri,
      headers: {...headers, 'range': 'bytes=$offset-${offset + length - 1}', 'accept-encoding': 'identity'},
      abort: stop?.stopping,
    );
    final (response, _) = stop == null ? await sent : await stop.race(sent);
    final SequentialHttpRead transfer;
    switch (response.statusCode) {
      case 206:
        _rangesHonoured = true;
        final start = _contentRangeStart(response.headers['content-range']) ?? offset;
        if (start > offset) {
          await discardHttpBody(response);
          throw NetworkFileSystemException('The server sent another part of $key than the one asked for');
        }
        transfer = SequentialHttpRead(response.stream, start);
      case 200:
        // The whole file, the range ignored; a file that fits in the bytes asked for proves nothing
        final contentLength = response.contentLength;
        if (offset > 0 || contentLength == null || contentLength > length) {
          _rangesHonoured = false;
        }
        transfer = SequentialHttpRead(response.stream, 0);
      case 416:
        // Past the end of the file
        await discardHttpBody(response);
        return Uint8List(0);
      default:
        return _fail(response, key);
    }

    stop?.follow(transfer);
    final Uint8List bytes;
    try {
      bytes = await transfer.read(offset, length);
      stop?.check();
    } catch (_) {
      await transfer.cancel();
      rethrow;
    }
    if (_rangesHonoured == false) {
      _keepOpenRead(key, transfer);
    } else {
      await transfer.finish();
    }
    return bytes;
  }

  /// Stops the transfers kept open; [read] is not called again
  Future<void> close() async {
    _closed = true;
    final openReads = _openReads.values.expand((reads) => reads).toList();
    _openReads.clear();
    await Future.wait(openReads.map((read) => read.cancel()));
  }

  SequentialHttpRead? _takeOpenRead(String key, int offset) {
    final reads = _openReads[key];
    if (reads == null) {
      return null;
    }
    // The one that went the furthest without going past the offset
    SequentialHttpRead? best;
    for (final read in reads) {
      if (read.position <= offset && (best == null || read.position > best.position)) {
        best = read;
      }
    }
    if (best != null) {
      best.stopWaiting();
      reads.remove(best);
      if (reads.isEmpty) {
        _openReads.remove(key);
      }
    }
    return best;
  }

  void _keepOpenRead(String key, SequentialHttpRead read) {
    if (_isDone || read.isDone) {
      unawaited(read.cancel());
      return;
    }
    final reads = _openReads.putIfAbsent(key, () => []);
    reads.add(read);
    while (reads.length > maxOpenReadsPerKey) {
      unawaited(reads.removeAt(0).cancel());
    }
    read.waitFor(openReadTimeout, () {
      final current = _openReads[key];
      if (current != null && current.remove(read)) {
        if (current.isEmpty) {
          _openReads.remove(key);
        }
        unawaited(read.cancel());
      }
    });
  }

  static int? _contentRangeStart(String? header) {
    if (header == null) {
      return null;
    }
    final match = RegExp(r'bytes\s+(\d+)-\d+').firstMatch(header);
    return match == null ? null : int.parse(match.group(1)!);
  }
}

/// The stop of one read of [HttpRangeReader.read]: once its abort completed, the transfer it follows is cancelled, the
/// answer it waits for is dropped when it comes, and [check] throws
class _ReadStop {
  _ReadStop(Future<void> abort) {
    unawaited(abort.then<void>((_) => _stop(), onError: (Object _) => _stop()));
  }

  final _stopping = Completer<void>();
  SequentialHttpRead? _transfer;
  bool _ended = false;

  /// Whether the read was stopped before it ended
  bool get stopped => _stopping.isCompleted;

  /// Completes when the read is stopped: the abort of its request
  Future<void> get stopping => _stopping.future;

  void _stop() {
    if (_ended || stopped) {
      return;
    }
    _stopping.complete();
    final transfer = _transfer;
    if (transfer != null) {
      unawaited(transfer.cancel());
    }
  }

  /// [transfer] is the body the read takes its bytes from now: cancelled at once if the read is stopped
  void follow(SequentialHttpRead transfer) {
    _transfer = transfer;
    if (stopped) {
      unawaited(transfer.cancel());
    }
  }

  /// Throws [NetworkReadAborted] once the read was stopped
  void check() {
    if (stopped) {
      throw const NetworkReadAborted();
    }
  }

  /// The answer of [sent], or [NetworkReadAborted] as soon as the read is stopped; an answer that comes after the
  /// stop has its body dropped with its connection
  Future<(http.StreamedResponse, Uri)> race(Future<(http.StreamedResponse, Uri)> sent) {
    final result = Completer<(http.StreamedResponse, Uri)>();
    unawaited(
      sent.then<void>(
        (answer) {
          if (result.isCompleted) {
            unawaited(answer.$1.stream.listen(null).cancel());
          } else {
            result.complete(answer);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!result.isCompleted) {
            result.completeError(error, stackTrace);
          }
        },
      ),
    );
    unawaited(
      _stopping.future.then<void>((_) {
        if (!result.isCompleted) {
          result.completeError(const NetworkReadAborted());
        }
      }),
    );
    return result.future;
  }

  /// The read ended (with its bytes or a failure): a later abort leaves alone what it kept open
  void end() => _ended = true;
}

/// Reads and drops a small body so that its connection serves the next request; stops a large or slow one
Future<void> discardHttpBody(http.StreamedResponse response) async {
  var length = 0;
  try {
    // Leaving the loop stops the transfer
    await for (final chunk in response.stream.timeout(SequentialHttpRead.endTimeout)) {
      length += chunk.length;
      if (length > HttpRangeReader.maxDiscardedBody) {
        break;
      }
    }
  } catch (_) {
    // Nothing to do with a failure to drop a body nobody reads
  }
}

/// A response body read in order: [read] skips up to the offset asked for, then takes the bytes asked for and keeps
/// what came beyond them for the next read
class SequentialHttpRead {
  SequentialHttpRead(this._stream, this.position);

  /// Longest wait for the end of a body once its last byte arrived
  static const endTimeout = Duration(seconds: 5);

  final Stream<List<int>> _stream;
  StreamIterator<List<int>>? _iterator;

  /// Offset in the file of the next byte to take
  int position;

  /// Bytes received and not taken yet, from [position]
  Uint8List? _pending;
  bool _done = false;
  Timer? _waiting;

  /// The body ended
  bool get isDone => _done && _pending == null;

  /// [length] bytes from [offset] (not before [position]), fewer when the body ends first
  Future<Uint8List> read(int offset, int length) async {
    assert(offset >= position);
    final iterator = _iterator ??= StreamIterator(_stream);
    final bytes = BytesBuilder(copy: false);
    while (bytes.length < length) {
      var chunk = _pending;
      _pending = null;
      if (chunk == null) {
        if (_done) {
          break;
        }
        if (!await iterator.moveNext().timeout(HttpRangeReader.answerTimeout)) {
          _done = true;
          break;
        }
        final data = iterator.current;
        chunk = data is Uint8List ? data : Uint8List.fromList(data);
      }
      if (position < offset) {
        final skip = min(offset - position, chunk.length);
        position += skip;
        if (skip == chunk.length) {
          continue;
        }
        chunk = Uint8List.sublistView(chunk, skip);
      }
      final take = min(length - bytes.length, chunk.length);
      bytes.add(take == chunk.length ? chunk : Uint8List.sublistView(chunk, 0, take));
      position += take;
      if (take < chunk.length) {
        _pending = Uint8List.sublistView(chunk, take);
      }
    }
    return bytes.takeBytes();
  }

  /// Calls [onTimeout] unless the next read comes within [timeout]
  void waitFor(Duration timeout, void Function() onTimeout) {
    _waiting?.cancel();
    _waiting = Timer(timeout, onTimeout);
  }

  void stopWaiting() {
    _waiting?.cancel();
    _waiting = null;
  }

  /// Waits for the end of a body read up to its last byte, so that its connection serves the next request (stopping
  /// a transfer drops its connection); stops the transfer when more than the bytes asked for comes
  Future<void> finish() async {
    if (!_done && _pending == null) {
      try {
        final iterator = _iterator ??= StreamIterator(_stream);
        if (!await iterator.moveNext().timeout(endTimeout)) {
          _done = true;
          return;
        }
      } catch (_) {
        // Stopped below
      }
    }
    await cancel();
  }

  /// Stops the transfer
  Future<void> cancel() async {
    stopWaiting();
    _done = true;
    _pending = null;
    try {
      final iterator = _iterator;
      if (iterator == null) {
        await _stream.listen(null).cancel();
      } else {
        await iterator.cancel();
      }
    } catch (_) {
      // Nothing to do with a failure to stop a transfer nobody reads any more
    }
  }
}
