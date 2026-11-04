// The scene of a splat photo taken out of its file (plan of 3 November 2026, section 5): the last SplatLength bytes,
// from the copy on the device, or from the original on the server in one GET with a suffix range:
//
//   206: Content-Range "bytes a-b/T" with b-a+1 = SplatLength and b = T-1: the body is the scene
//   200 with Content-Length T (a server that ignores the range, as FreeKC's does): T below SplatLength + 4 is a copy that
//        lost its scene; else the first T - SplatLength bytes are skipped as they arrive, the rest is the scene
//   200 without Content-Length (a proxy that chunks): the body goes to <out>.whole.part, then its tail is copied
//   416, or a 206 of another range: asked again without a range, then as a 200
//
// The bytes are written to <out>.part as they come, never held whole, their SHA-256 computed on the way; the part is
// renamed only when the length and the sum match, deleted otherwise; a tail that does not start as an SPZ is refused at
// its first bytes, and the rest of its transfer stopped. A cancel aborts the request once its answer came (the rule of
// httpRangeReader: ok_http crashes on an abort before) and leaves no .part.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_tail.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_writer.dart';
import 'package:immich_mobile/domain/services/splat_viewer_files.dart';

/// Where the scene of a splat photo is read from
sealed class SplatTailSource {
  const SplatTailSource();
}

/// The copy of the photo on this device
final class SplatTailFromFile extends SplatTailSource {
  const SplatTailFromFile(this.file);

  final File file;

  @override
  String toString() => 'the copy on the device';
}

/// The original of the photo on the server: [url] without the edited parameter, read with [client] and [headers]
final class SplatTailFromServer extends SplatTailSource {
  const SplatTailFromServer({required this.client, required this.url, this.headers = const {}});

  final http.Client client;
  final Uri url;
  final Map<String, String> headers;

  @override
  String toString() => 'the server';
}

/// Why a scene was not taken out of its photo
enum SplatTailFetchProblem {
  /// The file is shorter than its scene: another program saved the photo again
  lost,

  /// The tail is not an SPZ, or not of the bytes the packet sums: the file was changed
  damaged,

  /// The server or the network failed
  network,

  cancelled,
}

class SplatTailFetchException implements Exception {
  const SplatTailFetchException(this.problem, [this.detail = '']);

  final SplatTailFetchProblem problem;
  final String detail;

  @override
  String toString() => 'SplatTailFetchException(${problem.name}${detail.isEmpty ? '' : ': $detail'})';
}

/// How the scene came
enum SplatTailRoute {
  /// From the copy on the device
  file,

  /// A 206 of the server: the scene alone
  range,

  /// A 200 of the server with its length: the whole photo, its head skipped
  whole,

  /// A 200 of the server without a length: the whole photo written, then its tail copied
  chunked,
}

/// A scene taken out of its photo: [file], of the length the packet says, the bytes [received] from the network for it
class SplatTailFetched {
  const SplatTailFetched({required this.file, required this.route, required this.received, required this.head});

  final File file;
  final SplatTailRoute route;
  final int received;

  /// What the head of the scene says: the SPZ wins over the packet
  final SplatHead head;
}

/// Takes the scene [xmp] names out of [source] into [out] (see the top of this file). [onProgress] is told the bytes
/// done and the bytes expected (0 when unknown); [cancel] stops it.
Future<SplatTailFetched> fetchSplatTail({
  required SplatTailSource source,
  required SplatPhotoXmp xmp,
  required File out,
  void Function(int done, int total)? onProgress,
  SplatPrepareCancel? cancel,
}) async {
  final length = xmp.splatLength;
  final sha256 = xmp.splatSha256;
  if (!xmp.isComplete || xmp.isNewer || length == null || sha256 == null) {
    throw const SplatTailFetchException(SplatTailFetchProblem.damaged, 'the packet names no scene this build reads');
  }
  final part = File('${out.path}.part');
  final sink = _TailSink(part, length: length, sha256: sha256, version: xmp.splatVersion!);
  try {
    await sink.open();
    final (route, received) = switch (source) {
      SplatTailFromFile(:final file) => (
        SplatTailRoute.file,
        await _fromFile(file, length, sink, onProgress: onProgress, cancel: cancel),
      ),
      SplatTailFromServer() => await _fromServer(source, out, length, sink, onProgress: onProgress, cancel: cancel),
    };
    // A cancel as the last bytes came: nothing kept, as the user asked
    if (cancel?.isCancelled ?? false) {
      throw const SplatTailFetchException(SplatTailFetchProblem.cancelled);
    }
    final head = await sink.finish(xmp);
    final file = await part.rename(out.path);
    return SplatTailFetched(file: file, route: route, received: received, head: head);
  } catch (_) {
    await sink.discard();
    rethrow;
  }
}

/// The last [length] bytes of [file] into [sink]
Future<int> _fromFile(
  File file,
  int length,
  _TailSink sink, {
  void Function(int done, int total)? onProgress,
  SplatPrepareCancel? cancel,
}) async {
  final handle = await file.open();
  try {
    final total = await handle.length();
    if (total < length + 4) {
      throw SplatTailFetchException(SplatTailFetchProblem.lost, 'a file of $total bytes for a scene of $length');
    }
    await handle.setPosition(total - length);
    var done = 0;
    while (done < length) {
      if (cancel?.isCancelled ?? false) {
        throw const SplatTailFetchException(SplatTailFetchProblem.cancelled);
      }
      final bytes = await handle.read(math.min(splatPhotoChunk, length - done));
      if (bytes.isEmpty) {
        throw const SplatTailFetchException(SplatTailFetchProblem.lost, 'the file got shorter');
      }
      await sink.add(bytes);
      done += bytes.length;
      onProgress?.call(done, length);
    }
    return 0;
  } finally {
    await handle.close();
  }
}

final _contentRange = RegExp(r'^\s*bytes\s+(\d+)-(\d+)/(\d+)\s*$', caseSensitive: false);

/// The scene from the original on the server (see the top of this file): the route it came by and the bytes received
Future<(SplatTailRoute, int)> _fromServer(
  SplatTailFromServer source,
  File out,
  int length,
  _TailSink sink, {
  void Function(int done, int total)? onProgress,
  SplatPrepareCancel? cancel,
}) async {
  var response = await _send(source, range: 'bytes=-$length', cancel: cancel);
  var received = 0;
  if (response.response.statusCode == 206) {
    final range = _contentRange.firstMatch(response.response.headers['content-range'] ?? '');
    final first = int.tryParse(range?.group(1) ?? '');
    final last = int.tryParse(range?.group(2) ?? '');
    final total = int.tryParse(range?.group(3) ?? '');
    if (first != null && last != null && total != null && last - first + 1 == length && last == total - 1) {
      received = await _stream(
        response,
        sink,
        skip: 0,
        take: length,
        total: length,
        onProgress: onProgress,
        cancel: cancel,
      );
      return (SplatTailRoute.range, received);
    }
    // Another range than the scene: asked again whole
    response.close();
    response = await _send(source, cancel: cancel);
  } else if (response.response.statusCode == 416) {
    response.close();
    response = await _send(source, cancel: cancel);
  }
  final status = response.response.statusCode;
  if (status != 200) {
    response.close();
    throw SplatTailFetchException(SplatTailFetchProblem.network, 'HTTP $status');
  }
  final total = response.response.contentLength;
  if (total != null && total >= 0) {
    if (total < length + 4) {
      response.close();
      throw SplatTailFetchException(SplatTailFetchProblem.lost, 'an original of $total bytes for a scene of $length');
    }
    received = await _stream(
      response,
      sink,
      skip: total - length,
      take: length,
      total: total,
      onProgress: onProgress,
      cancel: cancel,
    );
    return (SplatTailRoute.whole, received);
  }
  // No length: the whole body first, then its tail
  final whole = File('${out.path}.whole.part');
  final wholeSink = await whole.open(mode: FileMode.write);
  try {
    var done = 0;
    await for (final bytes in response.response.stream) {
      if (cancel?.isCancelled ?? false) {
        throw const SplatTailFetchException(SplatTailFetchProblem.cancelled);
      }
      await wholeSink.writeFrom(bytes);
      done += bytes.length;
      onProgress?.call(done, 0);
    }
    await wholeSink.close();
    await _fromFile(whole, length, sink, cancel: cancel);
    return (SplatTailRoute.chunked, done);
  } on http.RequestAbortedException {
    throw const SplatTailFetchException(SplatTailFetchProblem.cancelled);
  } finally {
    response.close();
    try {
      await wholeSink.close();
    } catch (_) {
      // Closed already
    }
    try {
      await whole.delete();
    } on FileSystemException {
      // Never written
    }
  }
}

/// A request sent, and how to stop what is left of its body
class _Sent {
  _Sent(this.response, this._abort);

  final http.StreamedResponse response;
  final Completer<void> _abort;

  void close() {
    if (!_abort.isCompleted) {
      _abort.complete();
    }
  }
}

Future<_Sent> _send(SplatTailFromServer source, {String? range, SplatPrepareCancel? cancel}) async {
  if (cancel?.isCancelled ?? false) {
    throw const SplatTailFetchException(SplatTailFetchProblem.cancelled);
  }
  final abort = Completer<void>();
  var answered = false;
  unawaited(
    cancel?.whenCancelled.then((_) {
      // Never before the answer came: the client of Android completes its response twice then, and the app crashes
      if (answered && !abort.isCompleted) {
        abort.complete();
      }
    }),
  );
  final request = http.AbortableRequest('GET', source.url, abortTrigger: abort.future)..headers.addAll(source.headers);
  if (range != null) {
    request.headers['range'] = range;
  }
  try {
    final response = await source.client.send(request);
    answered = true;
    final sent = _Sent(response, abort);
    if (cancel?.isCancelled ?? false) {
      sent.close();
      throw const SplatTailFetchException(SplatTailFetchProblem.cancelled);
    }
    return sent;
  } on http.RequestAbortedException {
    throw const SplatTailFetchException(SplatTailFetchProblem.cancelled);
  } on SplatTailFetchException {
    rethrow;
  } catch (error) {
    throw SplatTailFetchException(SplatTailFetchProblem.network, '$error');
  }
}

/// The body of [sent] into [sink]: its first [skip] bytes dropped, then [take] bytes; the bytes received
Future<int> _stream(
  _Sent sent,
  _TailSink sink, {
  required int skip,
  required int take,
  required int total,
  void Function(int done, int total)? onProgress,
  SplatPrepareCancel? cancel,
}) async {
  var received = 0;
  var taken = 0;
  try {
    await for (final bytes in sent.response.stream) {
      if (cancel?.isCancelled ?? false) {
        throw const SplatTailFetchException(SplatTailFetchProblem.cancelled);
      }
      final start = received;
      received += bytes.length;
      if (received > skip) {
        final from = math.max(0, skip - start);
        final to = math.min(bytes.length, skip + take - start);
        if (from < to) {
          await sink.add(bytes is Uint8List ? Uint8List.sublistView(bytes, from, to) : bytes.sublist(from, to));
          taken += to - from;
        }
      }
      onProgress?.call(received, total);
      if (received > skip + take) {
        throw SplatTailFetchException(SplatTailFetchProblem.network, 'more than the $total bytes announced');
      }
    }
  } on http.RequestAbortedException {
    throw const SplatTailFetchException(SplatTailFetchProblem.cancelled);
  } on SplatTailFetchException {
    rethrow;
  } on http.ClientException catch (error) {
    throw SplatTailFetchException(SplatTailFetchProblem.network, error.message);
  } finally {
    sent.close();
  }
  if (taken != take) {
    throw SplatTailFetchException(SplatTailFetchProblem.network, 'the body ended after $received bytes');
  }
  return received;
}

/// The .part a scene is written to, its sum and its first bytes kept on the way. A tail that does not start as an SPZ
/// of [version] is refused at its first bytes: a photo cut short, or one a gallery appended its own bytes to, keeps a
/// size that passes, and its whole scene would come for nothing (review of 4 November 2026).
class _TailSink {
  _TailSink(this.part, {required this.length, required this.sha256, required this.version});

  final File part;
  final int length;
  final String sha256;
  final int version;
  final _sum = SplatSha256();
  final _first = BytesBuilder(copy: true);
  RandomAccessFile? _handle;
  var _written = 0;
  var _started = false;

  Future<void> open() async {
    await part.parent.create(recursive: true);
    _handle = await part.open(mode: FileMode.write);
  }

  Future<void> add(List<int> bytes) async {
    _sum.add(bytes);
    if (_first.length < splatHeadBytes) {
      _first.add(
        bytes.length <= splatHeadBytes - _first.length ? bytes : bytes.sublist(0, splatHeadBytes - _first.length),
      );
    }
    if (!_started && _first.length >= math.min(4, length)) {
      if (!startsAsSpz(_first.toBytes(), version)) {
        throw const SplatTailFetchException(SplatTailFetchProblem.damaged, 'no SPZ where the scene starts');
      }
      _started = true;
    }
    _written += bytes.length;
    await _handle!.writeFrom(bytes);
  }

  /// Closes the part once the scene is whole and right: its head as the SPZ itself says it
  Future<SplatHead> finish(SplatPhotoXmp xmp) async {
    await _handle!.flush();
    await _handle!.close();
    _handle = null;
    if (_written != length) {
      throw SplatTailFetchException(SplatTailFetchProblem.damaged, '$_written bytes of $length');
    }
    final first = _first.toBytes();
    if (!startsAsSpz(first, xmp.splatVersion!)) {
      throw const SplatTailFetchException(SplatTailFetchProblem.damaged, 'no SPZ where the scene starts');
    }
    if (_sum.hex() != sha256) {
      throw const SplatTailFetchException(SplatTailFetchProblem.damaged, 'another SHA-256');
    }
    final head = splatTailHeadOf(first, xmp);
    if (head == null) {
      throw const SplatTailFetchException(SplatTailFetchProblem.damaged, 'an SPZ head that does not read');
    }
    return head;
  }

  Future<void> discard() async {
    try {
      await _handle?.close();
    } catch (_) {
      // Closed already
    }
    _handle = null;
    try {
      await part.delete();
    } on FileSystemException {
      // Never written
    }
  }
}
