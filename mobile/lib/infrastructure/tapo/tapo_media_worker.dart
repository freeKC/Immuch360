// The media sessions of the cameras, off the UI isolate: each fetch of a clip and each batch of thumbnails runs in an
// isolate of its own (the AES of the parts, the demuxer and the QuickTime writer take seconds of CPU for a long clip on
// a phone), while [TapoMediaWorker] keeps the rules of the cameras in the UI isolate (P§7.11): one media session per
// camera at a time, the clip the user waits for before the thumbnails (a waiting clip ends the batch of thumbnails
// after its current picture), at most 24 thumbnails per session, a pause of a second after each clip, and the busy
// answers retried after 4, 8 and 12 s before the user is told.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/mov_writer.dart';
import 'package:immich_mobile/infrastructure/tapo/mpeg_ts_demuxer.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_media_session.dart';
import 'package:logging/logging.dart';

final _log = Logger('TapoMedia');

/// The media port of one camera, with the password of its TP-Link account
class TapoMediaTarget {
  const TapoMediaTarget({required this.host, required this.password, required this.playerId, this.port = 8800});

  final String host;
  final String password;
  final String playerId;
  final int port;

  @override
  String toString() => 'TapoMediaTarget($host:$port)';
}

/// See the header
class TapoMediaWorker {
  TapoMediaWorker({
    this.busyDelays = const [Duration(seconds: 4), Duration(seconds: 8), Duration(seconds: 12)],
    this.pauseAfterClip = const Duration(seconds: 1),
    this.pauseAfterFailedBatch = const Duration(seconds: 2),
  });

  /// The worker of the app
  static final instance = TapoMediaWorker();

  final List<Duration> busyDelays;
  final Duration pauseAfterClip;
  final Duration pauseAfterFailedBatch;

  static const maxThumbnailsPerSession = 24;

  final Map<String, _Camera> _cameras = {};

  _Camera _camera(TapoMediaTarget target) =>
      _cameras.putIfAbsent('${target.host.toLowerCase()}:${target.port}', () => _Camera());

  /// Fetches the clip from [start] to [end] (UTC seconds) into the QuickTime file [outPath], written whole or not at
  /// all. [creation] and [zoneOffset] date it. [onProgress] goes from 0 to 1; completing [cancel] stops it with a
  /// [TapoCameraException] of kind cancelled.
  Future<void> fetchClip(
    TapoMediaTarget target, {
    required int start,
    required int end,
    required String outPath,
    required DateTime creation,
    required Duration zoneOffset,
    void Function(double progress)? onProgress,
    Future<void>? cancel,
  }) {
    final task = _ClipTask(
      target: target,
      job: {
        'host': target.host,
        'port': target.port,
        'password': target.password,
        'playerId': target.playerId,
        'start': start,
        'end': end,
        'outPath': outPath,
        'creationMs': creation.toUtc().millisecondsSinceEpoch,
        'zoneOffsetMinutes': zoneOffset.inMinutes,
      },
      onProgress: onProgress,
    );
    unawaited(cancel?.then((_) => task.cancel()));
    final camera = _camera(target);
    camera.clips.add(task);
    // The thumbnails give way to the clip the user waits for
    camera.batch?.stop();
    _pump(camera);
    return task.done.future;
  }

  /// The camera's picture of the recording that starts at [start], written to [path] (a JPEG); null when the camera
  /// has none or could not send it
  Future<Uint8List?> thumbnail(TapoMediaTarget target, {required int start, required String path}) {
    final camera = _camera(target);
    final waiting = camera.thumbnails[start];
    if (waiting != null) {
      return waiting.done.future;
    }
    final task = _ThumbnailTask(target: target, start: start, path: path);
    camera.thumbnails[start] = task;
    _pump(camera);
    return task.done.future;
  }

  void _pump(_Camera camera) {
    if (camera.running) {
      return;
    }
    while (camera.clips.isNotEmpty && camera.clips.first.isCancelled) {
      camera.clips.removeFirst().fail(const TapoCameraException(TapoErrorKind.cancelled));
    }
    if (camera.clips.isNotEmpty) {
      camera.running = true;
      final task = camera.clips.removeFirst();
      unawaited(
        _runClip(task).whenComplete(() async {
          await Future<void>.delayed(pauseAfterClip);
          camera.running = false;
          _pump(camera);
        }),
      );
      return;
    }
    if (camera.thumbnails.isNotEmpty) {
      camera.running = true;
      final batch = camera.thumbnails.values.take(maxThumbnailsPerSession).toList();
      for (final task in batch) {
        camera.thumbnails.remove(task.start);
      }
      unawaited(
        _runThumbnails(camera, batch).then((failed) async {
          if (failed) {
            await Future<void>.delayed(pauseAfterFailedBatch);
          }
          camera.running = false;
          _pump(camera);
        }),
      );
    }
  }

  Future<void> _runClip(_ClipTask task) async {
    for (var attempt = 0; ; attempt++) {
      if (task.isCancelled) {
        task.fail(const TapoCameraException(TapoErrorKind.cancelled));
        return;
      }
      try {
        await _spawnClip(task);
        task.succeed();
        return;
      } on TapoCameraException catch (error) {
        if (error.kind != TapoErrorKind.busy || attempt >= busyDelays.length) {
          task.fail(error);
          return;
        }
        _log.info('The camera is busy with another viewer: trying again in ${busyDelays[attempt].inSeconds} s');
        await Future.any([Future<void>.delayed(busyDelays[attempt]), task.cancelled.future]);
      }
    }
  }

  Future<void> _spawnClip(_ClipTask task) async {
    final replies = ReceivePort();
    final exits = ReceivePort();
    final result = Completer<void>();
    SendPort? control;
    task.onCancel = () => control?.send('cancel');
    replies.listen((message) {
      if (message is SendPort) {
        control = message;
        if (task.isCancelled) {
          message.send('cancel');
        }
      } else if (message is Map) {
        switch (message['type']) {
          case 'progress':
            task.onProgress?.call((message['value'] as num).toDouble());
          case 'done':
            if (!result.isCompleted) {
              result.complete();
            }
          case 'error':
            if (!result.isCompleted) {
              result.completeError(_exceptionOf(message));
            }
        }
      }
    });
    exits.listen((_) {
      if (!result.isCompleted) {
        result.completeError(const TapoCameraException(TapoErrorKind.unsupported, detail: 'fetch ended'));
      }
    });
    try {
      await Isolate.spawn(_clipEntry, (replies.sendPort, task.job), onExit: exits.sendPort, errorsAreFatal: true);
      await result.future;
    } finally {
      task.onCancel = null;
      replies.close();
      exits.close();
    }
  }

  /// Runs [batch] on one connection; true when it failed before its end
  Future<bool> _runThumbnails(_Camera camera, List<_ThumbnailTask> batch) async {
    final target = batch.first.target;
    final pending = {for (final task in batch) task.start: task};
    final replies = ReceivePort();
    final exits = ReceivePort();
    final ended = Completer<bool>();
    final handle = _Batch();
    camera.batch = handle;
    replies.listen((message) {
      if (message is SendPort) {
        handle.control = message;
        if (handle.stopped) {
          message.send('stop');
        }
      } else if (message is Map) {
        switch (message['type']) {
          case 'thumbnail':
            final task = pending.remove(message['start']);
            if (task != null) {
              unawaited(task.finish(message['ok'] == true));
            }
          case 'end':
            if (!ended.isCompleted) {
              ended.complete(false);
            }
          case 'error':
            _log.fine('No thumbnails from the camera: ${_exceptionOf(message)}');
            if (!ended.isCompleted) {
              ended.complete(true);
            }
        }
      }
    });
    exits.listen((_) {
      if (!ended.isCompleted) {
        ended.complete(true);
      }
    });
    try {
      await Isolate.spawn(
        _thumbnailsEntry,
        (
          replies.sendPort,
          <String, Object?>{
            'host': target.host,
            'port': target.port,
            'password': target.password,
            'playerId': target.playerId,
            'starts': [for (final task in batch) task.start],
            'paths': [for (final task in batch) task.path],
          },
        ),
        onExit: exits.sendPort,
        errorsAreFatal: true,
      );
      return await ended.future;
    } catch (error) {
      _log.warning('Could not start the thumbnails of a camera: $error');
      return true;
    } finally {
      if (identical(camera.batch, handle)) {
        camera.batch = null;
      }
      replies.close();
      exits.close();
      // What the batch did not reach: asked again when given way to a clip, without a picture after a failure
      for (final task in pending.values) {
        if (handle.stopped) {
          camera.thumbnails.putIfAbsent(task.start, () => task);
        } else {
          task.done.complete(null);
        }
      }
    }
  }

  static TapoCameraException _exceptionOf(Map<Object?, Object?> message) {
    final kind = TapoErrorKind.values.where((kind) => kind.name == message['kind']).firstOrNull;
    return TapoCameraException(
      kind ?? TapoErrorKind.unsupported,
      code: message['code'] as int?,
      detail: message['detail'] as String?,
    );
  }
}

class _Camera {
  final Queue<_ClipTask> clips = Queue();
  final LinkedHashMap<int, _ThumbnailTask> thumbnails = LinkedHashMap();
  bool running = false;
  _Batch? batch;
}

class _Batch {
  SendPort? control;
  bool stopped = false;

  void stop() {
    stopped = true;
    control?.send('stop');
  }
}

class _ClipTask {
  _ClipTask({required this.target, required this.job, this.onProgress});

  final TapoMediaTarget target;
  final Map<String, Object?> job;
  final void Function(double progress)? onProgress;
  final done = Completer<void>();
  final cancelled = Completer<void>();
  void Function()? onCancel;

  bool get isCancelled => cancelled.isCompleted;

  void cancel() {
    if (!cancelled.isCompleted) {
      cancelled.complete();
      onCancel?.call();
    }
  }

  void succeed() {
    if (!done.isCompleted) {
      done.complete();
    }
  }

  void fail(TapoCameraException error) {
    if (!done.isCompleted) {
      done.completeError(error);
    }
  }
}

class _ThumbnailTask {
  _ThumbnailTask({required this.target, required this.start, required this.path});

  final TapoMediaTarget target;
  final int start;
  final String path;
  final done = Completer<Uint8List?>();

  Future<void> finish(bool ok) async {
    Uint8List? bytes;
    if (ok) {
      try {
        bytes = await File(path).readAsBytes();
      } catch (error) {
        _log.fine('A thumbnail of a camera could not be read back: $error');
      }
    }
    if (!done.isCompleted) {
      done.complete(bytes);
    }
  }
}

Map<String, Object?> _errorMessage(Object error) => switch (error) {
  TapoCameraException() => {'type': 'error', 'kind': error.kind.name, 'code': error.code, 'detail': error.detail},
  MovWriterException() => {'type': 'error', 'kind': TapoErrorKind.unsupported.name, 'detail': 'no video'},
  _ => {'type': 'error', 'kind': TapoErrorKind.unsupported.name, 'detail': error.runtimeType.toString()},
};

/// The isolate of one clip: the media session, the demuxer and the QuickTime writer, into `<outPath>.part` renamed
/// to outPath once whole
Future<void> _clipEntry((SendPort, Map<String, Object?>) message) async {
  final (reply, job) = message;
  final control = ReceivePort();
  reply.send(control.sendPort);
  var cancelled = false;
  TapoMediaSession? session;
  control.listen((command) {
    if (command == 'cancel') {
      cancelled = true;
      // As at the end of a clip: "do stop" frees the camera's session slot, which the close alone may keep until the
      // camera's own time limit, the next fetch being told busy meanwhile
      session?.stop();
      unawaited(session?.close());
    }
  });
  final outPath = job['outPath']! as String;
  final partial = File('$outPath.part');
  RandomAccessFile? output;
  try {
    final start = job['start']! as int;
    final end = job['end']! as int;
    session = await TapoMediaSession.open(
      job['host']! as String,
      job['password']! as String,
      port: job['port']! as int,
    );
    if (cancelled) {
      throw const TapoCameraException(TapoErrorKind.cancelled);
    }
    await partial.parent.create(recursive: true);
    final file = output = partial.openSync(mode: FileMode.write);
    final writer = MovWriter(
      file,
      creation: DateTime.fromMillisecondsSinceEpoch(job['creationMs']! as int, isUtc: true),
      zoneOffset: Duration(minutes: job['zoneOffsetMinutes']! as int),
    );
    late final MpegTsDemuxer demuxer;
    demuxer = MpegTsDemuxer(
      onVideo: (frame) {
        if (demuxer.videoCodec == TsVideoCodec.h265) {
          throw const TapoCameraException(TapoErrorKind.h265);
        }
        writer.addVideo(frame);
      },
      onAudio: (chunk) {
        writer.audioOffsetSeconds = demuxer.audioOffsetSeconds;
        writer.addAudio(chunk);
      },
    );
    final span = end - start;
    var reported = -1.0;
    final finished = await tapoDownloadClip(
      session,
      start: start,
      end: end,
      playerId: job['playerId']! as String,
      onData: (part) {
        demuxer.feed(part.body, wallMs: part.wallMs);
        final wall = part.wallMs;
        final seconds = wall == null ? writer.videoSeconds : wall / 1000 - start;
        final progress = span <= 0 ? 0.0 : (seconds / span).clamp(0.0, 1.0);
        if (progress - reported >= 0.01) {
          reported = progress;
          reply.send({'type': 'progress', 'value': progress});
        }
      },
      // Never roll into the next recordings
      shouldStop: () => cancelled || writer.videoSeconds > span + 5,
    );
    if (cancelled) {
      throw const TapoCameraException(TapoErrorKind.cancelled);
    }
    demuxer.flush();
    session.stop();
    await session.close();
    session = null;
    if (!finished) {
      _log.fine('A clip ended past its end time; what came until then is kept');
    }
    writer.finish();
    file.closeSync();
    output = null;
    await partial.rename(outPath);
    reply.send({'type': 'progress', 'value': 1.0});
    reply.send({'type': 'done'});
  } catch (error) {
    // The partial file goes before the answer: the page may fetch the clip again at once, and a delete after the
    // answer could take the file of that new fetch
    output?.closeSync();
    output = null;
    if (partial.existsSync()) {
      partial.deleteSync();
    }
    reply.send(cancelled ? _errorMessage(const TapoCameraException(TapoErrorKind.cancelled)) : _errorMessage(error));
  } finally {
    // After the answer on a failure: the close may wait a moment for the camera (see TapoMediaSession.close)
    session?.stop();
    await session?.close();
    control.close();
  }
}

/// The isolate of a batch of thumbnails: one connection, one picture after the other, until the batch or a 'stop'
Future<void> _thumbnailsEntry((SendPort, Map<String, Object?>) message) async {
  final (reply, job) = message;
  final control = ReceivePort();
  reply.send(control.sendPort);
  var stopped = false;
  control.listen((command) {
    if (command == 'stop') {
      stopped = true;
    }
  });
  TapoMediaSession? session;
  try {
    session = await TapoMediaSession.open(
      job['host']! as String,
      job['password']! as String,
      port: job['port']! as int,
    );
    final starts = (job['starts']! as List).cast<int>();
    final paths = (job['paths']! as List).cast<String>();
    for (var i = 0; i < starts.length && !stopped; i++) {
      Uint8List? image;
      try {
        image = await tapoSnapshot(session, start: starts[i], playerId: job['playerId']! as String);
      } on TimeoutException {
        // A recording without a picture keeps the camera silent: the connection is not used again
        reply.send({'type': 'thumbnail', 'start': starts[i], 'ok': false});
        break;
      }
      if (image != null) {
        final file = File(paths[i]);
        await file.parent.create(recursive: true);
        final partial = File('${paths[i]}.part');
        await partial.writeAsBytes(image, flush: true);
        await partial.rename(file.path);
      }
      reply.send({'type': 'thumbnail', 'start': starts[i], 'ok': image != null});
    }
    reply.send({'type': 'end'});
  } catch (error) {
    reply.send(_errorMessage(error));
  } finally {
    session?.stop();
    await session?.close();
    control.close();
  }
}
