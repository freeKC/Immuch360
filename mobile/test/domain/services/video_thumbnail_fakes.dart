import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/platform/video_thumbnail_api.g.dart';

/// A pigeon host standing in for MediaMetadataRetriever and AVAssetImageGenerator: records what it is asked for, and
/// answers [frameOf] the URL, or waits for the test to [answer] when [gated]
class FakeVideoThumbnailHost extends VideoThumbnailApi {
  FakeVideoThumbnailHost({this.gated = false});

  bool gated;

  /// The frame of a video, by its URL; throws when null
  Uint8List? Function(String url) frameOf = (url) => Uint8List.fromList([0xff, 0xd8, ...url.codeUnits, 0xff, 0xd9]);

  final calls = <({String url, Map<String, String> headers, int timeMs, int maxWidth})>[];

  /// The calls waiting for [answer], by URL
  final waiting = <String, Completer<Uint8List>>{};
  int inFlight = 0;
  int maxInFlight = 0;

  /// The URLs asked for, in order
  List<String> get urls => [for (final call in calls) call.url];

  @override
  Future<Uint8List> thumbnailForUrl(String url, Map<String, String> headers, int timeMs, int maxWidth) async {
    calls.add((url: url, headers: headers, timeMs: timeMs, maxWidth: maxWidth));
    inFlight++;
    maxInFlight = max(maxInFlight, inFlight);
    try {
      if (gated) {
        final gate = Completer<Uint8List>();
        waiting[url] = gate;
        return await gate.future;
      }
      final frame = frameOf(url);
      if (frame == null) {
        throw StateError('Cannot decode $url');
      }
      return frame;
    } finally {
      inFlight--;
    }
  }

  /// Ends the call for [url] waiting in [waiting] with its frame, or with an error when [frameOf] gives none
  void answer(String url) {
    final gate = waiting.remove(url)!;
    final frame = frameOf(url);
    if (frame == null) {
      gate.completeError(StateError('Cannot decode $url'));
    } else {
      gate.complete(frame);
    }
  }
}

NetworkMediaKey videoKey(String path, {int size = 1000, DateTime? modified}) =>
    (sourceId: 'nas', path: path, size: size, modified: modified ?? DateTime.utc(2026, 10, 2));

Uri bridgeUrl(String path) => Uri.parse('http://127.0.0.1:1234/token/nas$path');
