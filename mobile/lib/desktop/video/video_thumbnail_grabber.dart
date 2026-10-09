// A frame of a video for its thumbnail on the computers (design 2.7): the share tiles (VideoThumbnailApi, the
// network browser) and the videos of the folder library (LocalImageApi), where the phones ask the system
// (MediaMetadataRetriever, AVAssetImageGenerator, MediaStore and PhotoKit thumbnails).
//
// A muted player of the pool, without texture or audio, opens the file or the bridge URL, goes to the frame asked
// for (past a black first frame or a fade in), and mpv's screenshot of that frame is scaled and encoded as a JPEG in
// another isolate (DesktopPlayer.grabFrame). One grab at a time: each is a decoder, and an 8K HEVC one is heavy. The
// callers keep the results as the phones keep theirs: the share tiles in the video thumbnail disk cache, the library
// in its thumbnail cache.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:logging/logging.dart';

final _log = Logger('VideoThumbnailGrabber');

class VideoThumbnailGrabber {
  VideoThumbnailGrabber({
    this._pool,
    this.openTimeout = const Duration(seconds: 30),
    this.frameTimeout = const Duration(seconds: 15),
  });

  /// The grabber of the app, on the app's pool
  static final shared = VideoThumbnailGrabber();

  final PlayerPool? _pool;

  /// Longest wait for the file to open and show its first frame (a share that is slow to answer)
  final Duration openTimeout;

  /// Longest wait for the frame asked for once the file is open
  final Duration frameTimeout;

  PlayerPool get _players => _pool ?? desktopPlayerPool;

  Future<void> _turn = Future.value();

  /// A JPEG of the frame at [time] of [resource] (a path of this computer or a media bridge URL), scaled into [box];
  /// at the middle of a video shorter than twice [time]. Null when the video gives no frame: the caller shows its
  /// film tile.
  Future<Uint8List?> grab(String resource, {required Duration time, required FrameBox box}) {
    final result = _turn.then((_) => _grab(resource, time, box));
    _turn = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<Uint8List?> _grab(String resource, Duration time, FrameBox box) async {
    final lease = _players.lease(PlayerKind.thumbnail, label: 'thumbnails');
    // Wakes the waits below at each event of the player
    final changed = StreamController<void>.broadcast();
    StreamSubscription<PlayerEvent>? subscription;
    var restarts = 0;
    String? failure;

    Future<bool> until(bool Function() condition, Duration timeout) async {
      final deadline = DateTime.now().add(timeout);
      while (!condition()) {
        final left = deadline.difference(DateTime.now());
        if (failure != null || left <= Duration.zero) {
          return false;
        }
        // The duration comes as a property, not an event: a short poll catches it
        const poll = Duration(milliseconds: 100);
        await changed.stream.first.timeout(left < poll ? left : poll, onTimeout: () {});
      }
      return true;
    }

    try {
      final engine = await lease.acquire();
      subscription = engine.events.listen((event) {
        switch (event.kind) {
          case PlayerEventKind.restarted:
            restarts++;
          case PlayerEventKind.failed:
            failure = event.message;
          case PlayerEventKind.loaded:
            break;
        }
        changed.add(null);
      });

      await engine.open(resource, streamed: resource.startsWith('http'));
      if (!await until(() => restarts > 0 && engine.duration.value > Duration.zero, openTimeout)) {
        _log.fine('No first frame for a thumbnail: ${failure ?? 'timed out'}');
        return null;
      }
      final duration = engine.duration.value;
      final at = Duration(microseconds: math.min(time.inMicroseconds, duration.inMicroseconds ~/ 2));
      if (at > Duration.zero) {
        final before = restarts;
        await engine.seek(at);
        if (!await until(() => restarts > before, frameTimeout)) {
          _log.fine('The frame of a thumbnail did not come: ${failure ?? 'timed out'}');
          return null;
        }
      }
      // mpv restarted, so the frame is on its (null) output; a screenshot may still miss it for a moment
      for (var attempt = 0; attempt < 10; attempt++) {
        final frame = await engine.grabFrame(box);
        if (frame != null && frame.isNotEmpty) {
          return frame;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return null;
    } catch (error) {
      _log.fine('No thumbnail: ${redactPlayerText('$error')}');
      return null;
    } finally {
      await subscription?.cancel();
      await changed.close();
      // Stopped by the pool: the file of this computer is let go, the share's connection closed
      await lease.release();
    }
  }
}
