// Reads a whole file of a network share as a stream of chunks, for an upload: the HTTP request takes the chunks as it
// sends them, so that a large video never sits in memory whole.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/network_file_system.dart';

/// Size of the chunks [readWholeFile] reads by default: large enough for the SMB stream pool to read its pieces at
/// once, small enough that two of them in memory do not matter
const networkUploadChunkSize = 8 * 1024 * 1024;

/// Thrown by [readWholeFile] once the upload it reads for is cancelled
class NetworkReadCancelledException implements Exception {
  const NetworkReadCancelledException();

  @override
  String toString() => 'NetworkReadCancelledException';
}

/// The [size] bytes of the file at [path] of [fileSystem], in chunks of [chunkSize] bytes read one after the other
/// from the start. The next chunk is read while the caller handles the current one, so that the share and the
/// network to the server work at the same time; never more than one ahead, so that memory stays at two chunks.
///
/// Reading in sequence is what an SMB share expects of a video or a large file: from the second chunk on, its reads go
/// to the stream pool of the connection (see SmbFileSystem.readRange).
///
/// Throws a [NetworkFileSystemException] when the share gives fewer bytes than [size] (the file got shorter since it
/// was listed): the request would otherwise send fewer bytes than it announced. Throws a
/// [NetworkReadCancelledException] once [isCancelled] is true. [onProgress] gets the bytes read so far.
///
/// Each listen reads the file again from its first byte, so a request sent again gets the whole file again.
Stream<Uint8List> readWholeFile(
  NetworkFileSystem fileSystem,
  String path,
  int size, {
  int chunkSize = networkUploadChunkSize,
  bool Function()? isCancelled,
  void Function(int bytesRead)? onProgress,
}) async* {
  RangeError.checkNotNegative(size, 'size');
  if (chunkSize <= 0) {
    throw ArgumentError.value(chunkSize, 'chunkSize', 'Must be positive');
  }
  if (size == 0) {
    return;
  }

  Future<Uint8List> readAt(int offset) async {
    final length = min(chunkSize, size - offset);
    final bytes = await fileSystem.readRange(path, offset, length);
    if (bytes.length != length) {
      throw NetworkFileSystemException(
        'Read ${bytes.length} bytes of $path at $offset instead of $length: the file changed on the share',
      );
    }
    return bytes;
  }

  // Not awaited at once: a failure of the read ahead must reach the caller when its turn comes, not the zone
  Future<Uint8List> ahead(int offset) {
    final read = readAt(offset);
    unawaited(read.then<void>((_) {}, onError: (_) {}));
    return read;
  }

  var offset = 0;
  Future<Uint8List>? next = ahead(0);
  try {
    while (next != null) {
      if (isCancelled?.call() ?? false) {
        throw const NetworkReadCancelledException();
      }
      final bytes = await next;
      offset += bytes.length;
      next = offset < size ? ahead(offset) : null;
      onProgress?.call(offset);
      yield bytes;
    }
  } finally {
    // A listener that stopped (the request was aborted) leaves the read ahead to end on its own
    next?.ignore();
  }
}
