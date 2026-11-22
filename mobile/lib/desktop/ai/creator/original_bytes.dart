// The bytes of an original that is not a file of this computer, read from an offset: a video of the Immich server or a
// file of a share opened in the app, which a 3D video downloads whole before its conversion (video_original_copy.dart).
// The server and the media bridge answer a Range request with 206 and its Content-Range; one that ignores it sends the
// whole file with 200, and the download starts again from its first byte.

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';

/// The bytes of an original from [offset], and the size of the whole original when the answer tells it
class OriginalBytes {
  const OriginalBytes({required this.stream, required this.offset, this.total});

  final Stream<List<int>> stream;

  /// Where [stream] starts: the offset asked when the range was honoured, else 0
  final int offset;
  final int? total;
}

/// A source whose original is not on this computer, which a 3D video downloads whole first
abstract interface class DownloadableOriginal implements ConversionSource {
  /// What video_jobs.json keeps of it, so that the next start makes it again (ConversionTools.remoteVideoSource)
  Map<String, Object?> get descriptor;

  /// The bytes of the original from [offset], the request aborted once [abort] completes. Throws a
  /// [ConversionException]: sourceLost when the server or the share does not give them, cancelled once aborted;
  /// [OriginalRangeRefused] when the range asked is past the end of the file.
  Future<OriginalBytes> openBytes({int offset = 0, Future<void>? abort});
}

/// The server answered 416: the range asked starts past the end of the file (a part longer than the original now)
class OriginalRangeRefused implements Exception {
  const OriginalRangeRefused();
}

/// The request of the bytes of [url] from [offset], aborted once [abort] completes
typedef OriginalRangeFetcher = Future<http.StreamedResponse> Function(Uri url, {int offset, Future<void>? abort});

/// The headers of a request from [offset]: none from the first byte
Map<String, String> rangeHeadersFrom(int offset) => offset > 0 ? {'Range': 'bytes=$offset-'} : const {};

/// Start and total of a Content-Range header, "bytes 100-999/1000"; null when it is not one ("bytes */1000" included)
({int start, int? total})? parseContentRange(String? header) {
  final match = RegExp(r'^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$').firstMatch(header ?? '');
  if (match == null) {
    return null;
  }
  return (start: int.parse(match.group(1)!), total: int.tryParse(match.group(3)!));
}

/// [response] to a request from [offset] as the bytes it gives: 200 the whole file, 206 the range asked; [who] names
/// the other end in the message of a failure ("server", "share")
OriginalBytes originalBytesOf(http.StreamedResponse response, int offset, String who) {
  final status = response.statusCode;
  if (status == HttpStatus.ok) {
    return OriginalBytes(stream: response.stream, offset: 0, total: response.contentLength);
  }
  if (status == HttpStatus.partialContent) {
    final range = parseContentRange(response.headers['content-range']);
    if (range != null && range.start == offset) {
      return OriginalBytes(stream: response.stream, offset: offset, total: range.total);
    }
  }
  unawaited(response.stream.drain<void>().catchError((_) {}));
  if (status == HttpStatus.requestedRangeNotSatisfiable) {
    throw const OriginalRangeRefused();
  }
  if (status == HttpStatus.partialContent) {
    throw ConversionException(ImmersiveErrorCode.sourceLost, 'The $who sent another range than the one asked');
  }
  throw ConversionException(ImmersiveErrorCode.sourceLost, 'The $who answered $status');
}
