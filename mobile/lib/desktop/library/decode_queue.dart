// The thumbnails of the folder library being made, outside the phones' native decoders: a few at a time, so that a
// timeline of large photos does not decode dozens at once, and the latest requested first, so that after a fast
// scroll the tiles on screen come before those scrolled past.

import 'dart:async';
import 'dart:typed_data';

/// One job for every request of the same thumbnail, at most [slots] running, the one requested last first; a job
/// dropped once every request for it was cancelled before it started
class DecodeQueue {
  DecodeQueue(this.slots);

  final int slots;
  int _active = 0;
  final _jobs = <String, _DecodeJob>{};
  final _byRequest = <int, _DecodeJob>{};
  final _waiting = <_DecodeJob>{};

  /// The result of [work] for [key], or null when the job was dropped
  Future<Uint8List?> run(String key, int requestId, Future<Uint8List> Function() work) {
    final job = _jobs.putIfAbsent(key, () => _DecodeJob(key, work));
    job.requests.add(requestId);
    _byRequest[requestId] = job;
    if (!job.started) {
      // Asked for again: moved to the front
      _waiting.remove(job);
      _waiting.add(job);
    }
    _pump();
    return job.completer.future.whenComplete(() => _byRequest.remove(requestId));
  }

  void cancel(int requestId) {
    final job = _byRequest.remove(requestId);
    if (job == null || !job.requests.remove(requestId) || job.requests.isNotEmpty || job.started) {
      return;
    }
    _waiting.remove(job);
    _jobs.remove(job.key);
    job.completer.complete(null);
  }

  void _pump() {
    while (_active < slots && _waiting.isNotEmpty) {
      final job = _waiting.last;
      _waiting.remove(job);
      job.started = true;
      _active++;
      unawaited(_start(job));
    }
  }

  Future<void> _start(_DecodeJob job) async {
    try {
      job.completer.complete(await job.work());
    } catch (error, stack) {
      job.completer.completeError(error, stack);
    } finally {
      _active--;
      _jobs.remove(job.key);
      _pump();
    }
  }
}

class _DecodeJob {
  _DecodeJob(this.key, this.work);

  final String key;
  final Future<Uint8List> Function() work;
  final requests = <int>{};
  final completer = Completer<Uint8List?>();
  bool started = false;
}
