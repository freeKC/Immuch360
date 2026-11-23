// A video of the server or of a share for the tests of its download (video_original_copy.dart): its bytes sent in
// chunks from the offset asked, or from the first byte when it ignores ranges; it can wait before each chunk, fail once
// after some bytes, send nothing more after some bytes until the request is aborted, refuse a range once, send fewer
// bytes than it tells, or tell no size.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/original_bytes.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';

class FakeDownloadableOriginal implements DownloadableOriginal {
  FakeDownloadableOriginal(this.name, this.bytes, {this.chunk = 1000, this.honoursRange = true, this.tellsSize = true});

  @override
  final String name;
  final List<int> bytes;

  /// The bytes of each chunk
  int chunk;

  /// Whether a request from an offset gets the bytes from there (206), else the whole file again (200)
  bool honoursRange;

  /// Whether the answer tells the size of the file
  bool tellsSize;

  /// Awaited before each chunk: a slow server
  Future<void> Function()? beforeChunk;

  /// The next answer fails after this many of its bytes, once
  int? failAfter;

  /// The next answer sends nothing more after this many of its bytes, until the request is aborted, once
  int? stallAfter;

  /// The next request from an offset is refused (416), once
  bool refuseRangeOnce = false;

  /// Each answer sends this many bytes fewer than the file has
  int shortBy = 0;

  /// The offsets asked, in their order
  final offsets = <int>[];

  /// The requests aborted
  var aborted = 0;

  @override
  String? get folder => null;

  @override
  ImmersiveExif get exif => const ImmersiveExif();

  @override
  Map<String, Object?> get descriptor => {'kind': 'fake', 'name': name};

  @override
  Future<ImmersiveSource> prepare(NativeCancelFlag cancel) =>
      throw const ConversionException(ImmersiveErrorCode.sourceLost, 'A video is downloaded by its job');

  @override
  Future<void> release() async {}

  @override
  Future<OriginalBytes> openBytes({int offset = 0, Future<void>? abort}) async {
    offsets.add(offset);
    if (refuseRangeOnce && offset > 0) {
      refuseRangeOnce = false;
      throw const OriginalRangeRefused();
    }
    final start = honoursRange ? offset : 0;
    final end = bytes.length - shortBy;
    var stopped = false;
    final controller = StreamController<List<int>>(onCancel: () => stopped = true);
    unawaited(
      abort?.then((_) {
        if (!stopped) {
          aborted++;
        }
        stopped = true;
      }),
    );
    final failing = failAfter;
    failAfter = null;
    final stalling = stallAfter;
    stallAfter = null;
    unawaited(() async {
      var at = start;
      var sent = 0;
      while (at < end && !stopped) {
        if (failing != null && sent >= failing) {
          controller.addError(const SocketException('Connection reset by peer'));
          break;
        }
        if (stalling != null && sent >= stalling) {
          // Nothing more, whatever comes: only the abort ends it
          await (abort ?? Completer<void>().future);
          break;
        }
        await beforeChunk?.call();
        if (stopped) {
          break;
        }
        final size = math.min(chunk, end - at);
        controller.add(bytes.sublist(at, at + size));
        at += size;
        sent += size;
        // A microtask, not a timer: the widget tests run in a fake clock
        await Future<void>.microtask(() {});
      }
      await controller.close();
    }());
    return OriginalBytes(stream: controller.stream, offset: start, total: tellsSize ? bytes.length : null);
  }
}
