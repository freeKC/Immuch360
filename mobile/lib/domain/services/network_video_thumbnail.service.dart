// The thumbnails of the videos of the network share browser: a frame of the video taken by the platform
// (MediaMetadataRetriever, AVAssetImageGenerator) from its media bridge URL, kept on disk.

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/infrastructure/network/video_thumbnail_disk_cache.dart';
import 'package:immich_mobile/platform/video_thumbnail_api.g.dart';
import 'package:logging/logging.dart';

final _log = Logger('NetworkVideoThumbnailService');

class NetworkVideoThumbnailService {
  NetworkVideoThumbnailService({
    required this._api,
    this._diskCache,
    this._waitForPhotos,
    this.maxConcurrent = 2,
    this.timeout = const Duration(seconds: 60),
    this.retryDelay = const Duration(seconds: 3),
    this.retryFailedAfter = const Duration(minutes: 10),
  });

  /// Where in the video the frame is taken, past a black first frame or a fade in
  static const frameTimeMs = 1000;

  /// Width the frames are taken at, that of the photo thumbnails
  static const maxWidth = 400;

  final VideoThumbnailApi _api;
  final VideoThumbnailDiskCache? _diskCache;
  final Future<void> Function()? _waitForPhotos;

  /// Most frames taken at once
  final int maxConcurrent;

  /// Longest wait for a frame, should the platform not answer. It gives up on its own before (45 s): the turn is held
  /// until the platform answers, so that no more than [maxConcurrent] videos are read at once.
  final Duration timeout;

  /// Wait before the one more try a frame gets: a read cut short (the media bridge bound again as the app comes back
  /// to the foreground, a share that did not answer for a moment) is not the video failing
  final Duration retryDelay;

  /// How long a video whose frame could not be taken is not asked again
  final Duration retryFailedAfter;

  /// Tries of a frame before the video is given up for [retryFailedAfter]
  static const maxAttempts = 2;

  /// Longest wait for the photo thumbnails before a frame is taken
  static const maxWaitForPhotos = Duration(seconds: 10);

  /// The videos whose frame could not be taken, with when they failed
  final _failed = <NetworkMediaKey, DateTime>{};
  final _pending = <NetworkMediaKey, _PendingThumbnail>{};
  int _running = 0;
  final _waiting = Queue<Completer<void>>();

  /// The JPEG thumbnail of the video [key] served by the media bridge at [url], null when there is none.
  ///
  /// From the disk cache when it is there. Otherwise the frame is taken from the video, after the photo thumbnails
  /// asked for meanwhile, [maxConcurrent] at a time; a video no longer wanted when its turn comes ([isWanted] false,
  /// its tile scrolled away) is skipped, and asked again next time. A frame that cannot be taken is tried once more
  /// after [retryDelay]; when that fails too the video keeps no thumbnail for [retryFailedAfter], or until
  /// [forgetFailures].
  Future<Uint8List?> thumbnail(NetworkMediaKey key, Uri url, {bool Function()? isWanted}) {
    final failedAt = _failed[key];
    if (failedAt != null) {
      if (DateTime.now().difference(failedAt) < retryFailedAfter) {
        return Future.value(null);
      }
      _failed.remove(key);
    }
    final pending = _pending[key];
    if (pending != null) {
      pending.want(isWanted);
      return pending.result;
    }
    final request = _PendingThumbnail()..want(isWanted);
    _pending[key] = request;
    request.result = _load(key, url, request).whenComplete(() => _pending.remove(key));
    return request.result;
  }

  /// Tries the videos that failed again the next time they are asked for (a refresh of the folder)
  void forgetFailures() => _failed.clear();

  Future<Uint8List?> _load(NetworkMediaKey key, Uri url, _PendingThumbnail request) async {
    final cached = await _diskCache?.read(key);
    if (cached != null) {
      return cached;
    }
    // Not for ever: a photo that never comes does not keep the videos without a frame
    await _waitForPhotos?.call().timeout(maxWaitForPhotos, onTimeout: () {});
    for (var attempt = 1; ; attempt++) {
      try {
        return await _take(key, url, request);
      } catch (error) {
        _log.fine('No thumbnail for ${key.path} (try $attempt): $error');
        if (attempt >= maxAttempts) {
          _failed[key] = DateTime.now();
          return null;
        }
      }
      await Future<void>.delayed(retryDelay);
    }
  }

  /// The frame of the video, in its turn; null when no longer wanted
  Future<Uint8List?> _take(NetworkMediaKey key, Uri url, _PendingThumbnail request) async {
    await _takeTurn();
    try {
      if (!request.isWanted) {
        return null;
      }
      final bytes = await _api.thumbnailForUrl(url.toString(), const {}, frameTimeMs, maxWidth).timeout(timeout);
      if (bytes.isEmpty) {
        throw StateError('No frame');
      }
      await _diskCache?.write(key, bytes);
      return bytes;
    } finally {
      _endTurn();
    }
  }

  Future<void> _takeTurn() async {
    if (_running < maxConcurrent && _waiting.isEmpty) {
      _running++;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    // Handed over by _endTurn, the count of frames under way staying the same
    await turn.future;
  }

  void _endTurn() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _running--;
    }
  }
}

/// A thumbnail under way, shared by the tiles that asked for the same video meanwhile
class _PendingThumbnail {
  final _wanted = <bool Function()?>[];
  late final Future<Uint8List?> result;

  void want(bool Function()? isWanted) => _wanted.add(isWanted);

  /// Whether any of the tiles still wants it
  bool get isWanted => _wanted.any((isWanted) => isWanted == null || isWanted());
}
