// A frame of a video for its thumbnail on the computers (design 2.7): the share tiles (VideoThumbnailApi, the
// network browser) and the videos of the folder library (LocalImageApi), where the phones ask the system
// (MediaMetadataRetriever, AVAssetImageGenerator, MediaStore and PhotoKit thumbnails).
//
// A muted player of the pool, without texture or audio, opens the file or the bridge URL, goes to the frame asked
// for (past a black first frame or a fade in), and mpv's screenshot of that frame is scaled and encoded as a JPEG in
// another isolate (DesktopPlayer.grabFrame). An AV2 video (.ivf, .obu) is opened through the URL of its companion,
// started for the grab and stopped after it (av2_playback.dart); without the AV2 decoder installed it gives no frame,
// and the caller shows its tile without one (no download without a gesture: plan of the AV2 videos, section 1.2). One grab at a time: each is a decoder, and an 8K HEVC one is heavy. The
// callers keep the results as the phones keep theirs: the share tiles in the video thumbnail disk cache, the library
// in its thumbnail cache.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/video/av2_playback.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:logging/logging.dart';

final _log = Logger('VideoThumbnailGrabber');

class VideoThumbnailGrabber {
  VideoThumbnailGrabber({
    this._pool,
    this.openTimeout = const Duration(seconds: 30),
    this.frameTimeout = const Duration(seconds: 15),
    Av2Playbacks? Function()? av2,
  }) : _av2 = av2 ?? (() => Av2Playbacks.app);

  /// The grabber of the app, on the app's pool
  static final shared = VideoThumbnailGrabber();

  final PlayerPool? _pool;

  /// Longest wait for the file to open and show its first frame (a share that is slow to answer)
  final Duration openTimeout;

  /// Longest wait for the frame asked for once the file is open
  final Duration frameTimeout;

  PlayerPool get _players => _pool ?? desktopPlayerPool;

  /// The AV2 videos' companions: the app's once its window started
  final Av2Playbacks? Function() _av2;

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
    final av2 = _av2();
    String? served;
    if (av2 != null) {
      try {
        served = await av2.openResource(resource, forThumbnail: true);
      } on Av2NotAv2 {
        // Another codec in an .ivf: as any video
      } on Av2PlaybackException catch (error) {
        _log.fine('No thumbnail of an AV2 video: $error');
        return null;
      }
    }
    try {
      return await _grabFrame(served ?? resource, time, box);
    } finally {
      if (served != null) {
        await av2!.release(served);
      }
    }
  }

  Future<Uint8List?> _grabFrame(String resource, Duration time, FrameBox box) async {
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
