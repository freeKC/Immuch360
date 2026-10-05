// The Range header of a request for one file, read the same way by the servers of the app: the local media bridge
// that serves the shares to the players, and the phone share that serves the gallery to a headset.

import 'dart:math';

/// What a Range header asks of a file of [size] bytes: [start] included, [end] excluded. Null to ignore it and send
/// the whole file: another unit, several ranges, or a header that does not parse. An empty range (start >= end) when
/// no byte of it is in the file, to answer 416.
({int start, int end})? parseSingleByteRange(String header, int size) {
  final match = RegExp(r'^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*$', caseSensitive: false).firstMatch(header);
  if (match == null) {
    return null;
  }
  final first = match.group(1)!;
  final last = match.group(2)!;
  const unsatisfiable = (start: 0, end: 0);

  if (first.isEmpty) {
    // The last bytes of the file: bytes=-n
    if (last.isEmpty) {
      return null;
    }
    // Too many digits for an int: more bytes than any file has
    final suffix = int.tryParse(last) ?? size;
    if (suffix == 0 || size == 0) {
      return unsatisfiable;
    }
    return (start: max(0, size - suffix), end: size);
  }

  final start = int.tryParse(first);
  if (start == null || start >= size) {
    return unsatisfiable;
  }
  if (last.isEmpty) {
    return (start: start, end: size);
  }
  final lastByte = int.tryParse(last);
  if (lastByte != null && lastByte < start) {
    return null;
  }
  return (start: start, end: lastByte == null ? size : min(lastByte + 1, size));
}
