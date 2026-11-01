// When a streamed video plays, and what its link says, from what the link brings: FreeKC's request of 31 October 2026,
// a film starts as soon as it reasonably can, a link that cannot keep up waits for enough to play a while rather than
// pausing every few seconds, a server that is merely slow is never taken for a dead one while bytes keep arriving, and
// the user reads what is going on. The rule of the Android players is LinkStartRule.kt; this one is the same, checked
// against the same cases (android/app/src/test/resources/video_link_rule_cases.json), for the players of the computers
// (media_kit, see MediaKitVideoPlayerController) and for the texts of every player. Pure Dart.

import 'dart:math' as math;

/// The start rule, see [linkTargetMs]
abstract final class VideoLinkRule {
  /// A link this much faster than the video starts at once
  static const fastRatio = 1.25;

  static const startMs = 1000;
  static const rebufferMs = 2000;
  static const nearStartMs = 2000;
  static const nearRebufferMs = 4000;

  /// The play a short link buffers for before it plays, at the start and after a stall
  static const startHorizonMs = 30000;
  static const rebufferHorizonMs = 60000;

  static const startMaxMs = 15000;
  static const rebufferMaxMs = 30000;

  /// The longest wait once [startMs] (or [rebufferMs]) is buffered: short at the start, where the user waits for the
  /// first frame, longer after a stall, where a longer wait gives a longer play
  static const startLongestWaitMs = 4000;

  /// Under this ratio the start waits for [startMs] only, as Media3 does: a second of wait gives ratio / (1 - ratio)
  /// seconds of play, less than a second here. After a stall the wait stays: fewer and longer pauses are better.
  static const startWaitRatio = 0.5;
  static const rebufferLongestWaitMs = 30000;

  /// Bytes that count as progress: a trickle of a few bytes is none
  static const progressBytes = 16 * 1024;

  /// A wait without progress for this long is a server or a link that stopped sending
  static const deadAfter = Duration(seconds: 30);

  /// A link below this ratio for [slowAfter] is said to be too slow for the video
  static const slowRatio = 0.9;
  static const slowAfter = Duration(seconds: 5);

  /// A link that brought nothing for this long, the window of the rate, is silent rather than slow
  static const silentAfter = Duration(seconds: 4);
}

/// The least media there is before a video plays: [VideoLinkRule.startMs], [VideoLinkRule.rebufferMs] after a stall
int linkMinimumMs({required bool rebuffering}) => rebuffering ? VideoLinkRule.rebufferMs : VideoLinkRule.startMs;

int _longestWaitMs({required bool rebuffering}) =>
    rebuffering ? VideoLinkRule.rebufferLongestWaitMs : VideoLinkRule.startLongestWaitMs;

/// The media to have ahead of the position before playing, [ratio] being what the link brings per second against what
/// the video consumes per second (null while unknown):
///
/// | Link                | Before playing, at the start or after a seek | After a stall                 |
/// |---------------------|----------------------------------------------|-------------------------------|
/// | unknown, or >= 1.25 | 1 s                                          | 2 s                           |
/// | 1 to 1.25           | 2 s                                          | 4 s                           |
/// | 0.5 to 1            | 30 s x (1 - ratio), 1 to 15 s                | 60 s x (1 - ratio), 2 to 30 s |
/// | below 0.5           | 1 s                                          | 30 s                          |
int linkTargetMs(double? ratio, {required bool rebuffering}) {
  if (ratio == null || ratio.isNaN || ratio >= VideoLinkRule.fastRatio) {
    return linkMinimumMs(rebuffering: rebuffering);
  }
  if (ratio >= 1) {
    return rebuffering ? VideoLinkRule.nearRebufferMs : VideoLinkRule.nearStartMs;
  }
  if (!rebuffering && ratio < VideoLinkRule.startWaitRatio) {
    return VideoLinkRule.startMs;
  }
  final short = 1 - math.max(ratio, 0.0);
  return rebuffering
      ? (VideoLinkRule.rebufferHorizonMs * short).round().clamp(VideoLinkRule.rebufferMs, VideoLinkRule.rebufferMaxMs)
      : (VideoLinkRule.startHorizonMs * short).round().clamp(VideoLinkRule.startMs, VideoLinkRule.startMaxMs);
}

/// Whether the video plays now, with [bufferedMs] of media ahead and [minimumHeldMs] since [linkMinimumMs] was there
/// (null while it is not): the target is there, or the longest wait is over
bool linkShouldStart(int bufferedMs, double? ratio, {required bool rebuffering, int? minimumHeldMs}) {
  if (bufferedMs >= linkTargetMs(ratio, rebuffering: rebuffering)) {
    return true;
  }
  return bufferedMs >= linkMinimumMs(rebuffering: rebuffering) &&
      minimumHeldMs != null &&
      minimumHeldMs >= _longestWaitMs(rebuffering: rebuffering);
}

/// About how long the wait still lasts, in ms; null when it cannot be told (no measure, or nothing arrives)
int? linkRemainingWaitMs(int bufferedMs, double? ratio, {required bool rebuffering, int? minimumHeldMs}) {
  if (ratio == null || ratio.isNaN || ratio <= 0) {
    return null;
  }
  final missing = math.max(linkTargetMs(ratio, rebuffering: rebuffering) - bufferedMs, 0);
  var wait = (missing / ratio).round();
  final untilMinimum = (math.max(linkMinimumMs(rebuffering: rebuffering) - bufferedMs, 0) / ratio).round();
  // The longest wait counts from the minimum: the wait never goes past it
  final cap = untilMinimum + _longestWaitMs(rebuffering: rebuffering) - (minimumHeldMs ?? 0);
  if (wait > cap) {
    wait = cap;
  }
  return math.max(wait, 0);
}

/// Whether a video that waits ([waiting]) with [sinceProgressMs] since the last progress is dead
bool linkIsDead({required bool waiting, int? sinceProgressMs}) =>
    waiting && sinceProgressMs != null && sinceProgressMs >= VideoLinkRule.deadAfter.inMilliseconds;

/// Whether [ratio], measured below [VideoLinkRule.slowRatio] for [slowFor], says the link is too slow for the video
bool linkIsSlow(double? ratio, Duration slowFor) =>
    ratio != null && !ratio.isNaN && ratio < VideoLinkRule.slowRatio && slowFor >= VideoLinkRule.slowAfter;

/// What a link brings, as LinkMeter.kt measures it: the bytes received per second the player asked for bytes over the
/// last [window], and the time it asked for bytes since the last progress (each [VideoLinkRule.progressBytes] that
/// arrive). The player asks for bytes while it wants more ([setWanted]) and a read of it is under way ([start] to
/// [end]), or a read failed and the player tries again ([end] with failed). Both measures count that time only, to
/// the millisecond (review of 1 November 2026): a film read a while ago and opened again was said to be on a link
/// that stopped sending until its first bytes came, and a buffer topped up a chunk at a time measured what the film
/// consumes rather than what the link brings. A new ask after a time without one starts the clock of progress again;
/// the tries after a failed read keep it. The computers feed it with the reads of the share the media bridge makes
/// for their player. [clock] is a parameter so that the tests drive it.
class VideoLinkMeter {
  VideoLinkMeter({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  static const window = Duration(seconds: 4);
  static const _slotMs = 250;
  static final _slots = window.inMilliseconds ~/ _slotMs + 1;

  /// A first rate is told once this much arrived, or after [firstValueTime] of asking
  static const firstValueBytes = 256 * 1024;
  static const firstValueTime = Duration(seconds: 1);

  final DateTime Function() _clock;
  late final _slotBytes = List<int>.filled(_slots, 0);
  late final _slotNumber = List<int>.filled(_slots, -1);

  /// The ms of each slot the player asked for bytes
  late final _slotAskedMs = List<int>.filled(_slots, 0);
  int _lastSlot = -1;
  bool _wanted = true;

  /// The reads under way
  int _reads = 0;

  /// A read failed since the last progress: the player tries again, the bytes are still asked
  bool _failing = false;

  /// Where the asked time accounted so far ends, -1 while nothing is asked
  int _askedFrom = -1;

  /// The time bytes were asked since the last progress, or since they were asked again after a time without
  int _askedSinceProgress = 0;
  bool _started = false;
  int _total = 0;
  int _bytesAtProgress = 0;
  int? _lastRate;

  int get _now => _clock().millisecondsSinceEpoch;

  bool get _asked => _wanted && (_reads > 0 || _failing);

  /// Bytes received since the meter started
  int get receivedBytes => _total;

  /// Whether a read started
  bool get started => _started;

  /// A read of the video starts
  void start() => _change(() {
    _started = true;
    _reads++;
  });

  /// A read of the video ends, [failed] when it threw: the player tries again
  void end({bool failed = false}) => _change(() {
    _reads = math.max(_reads - 1, 0);
    if (failed) {
      _failing = true;
    }
  });

  /// The player wants more media ([wanted]), or holds what it wants
  void setWanted(bool wanted) => _change(() => _wanted = wanted);

  /// The player opened the video again: the clock of progress starts from now, a read that failed before included (a
  /// meter kept for a file outlives the opens of its player)
  void restart() {
    final now = _now;
    _account(now);
    _failing = false;
    _askedSinceProgress = 0;
    if (!_asked) {
      _askedFrom = -1;
    }
  }

  /// [count] bytes arrived
  void add(int count) {
    if (count <= 0) {
      return;
    }
    final now = _now;
    _change(() {
      _started = true;
      // Bytes come from a read under way, whatever was said of it
      if (_reads == 0) {
        _reads = 1;
      }
    }, now: now);
    _slotBytes[(now ~/ _slotMs) % _slots] += count;
    _total += count;
    if (_total - _bytesAtProgress >= VideoLinkRule.progressBytes) {
      _askedSinceProgress = 0;
      _bytesAtProgress = _total;
      _failing = false;
    }
  }

  /// Bytes received per second bytes were asked, over the last [window]; the last value while none were asked in that
  /// window; null before [firstValueBytes] arrived or [firstValueTime] of asking passed
  int? rate() {
    if (!_started) {
      return null;
    }
    final now = _now;
    _account(now);
    return _computeRate(now);
  }

  /// The time bytes were asked since the last progress, or since they were asked again after a time without (a new
  /// open, a seek), a link that never sent included; null before any read
  Duration? sinceProgress() {
    if (!_started) {
      return null;
    }
    _account(_now);
    return Duration(milliseconds: _askedSinceProgress);
  }

  /// Applies [change] at [now], the asked time accounted to it first: an ask that begins after a time without one
  /// starts the clock of progress again (unless a read failed: its tries keep it)
  void _change(void Function() change, {int? now}) {
    final at = now ?? _now;
    _account(at);
    final before = _asked;
    change();
    final after = _asked;
    if (!before && after) {
      _askedFrom = at;
      if (!_failing) {
        _askedSinceProgress = 0;
      }
    } else if (before && !after) {
      _askedFrom = -1;
      _computeRate(at);
    }
  }

  /// The time asked from [_askedFrom] to [now] goes to the clock of progress and to the slots of the window
  void _account(int now) {
    _fill(now);
    final from = _askedFrom;
    if (from < 0 || now <= from) {
      return;
    }
    _askedSinceProgress += now - from;
    var t = math.max(from, (now ~/ _slotMs - _slots + 1) * _slotMs);
    while (t < now) {
      final slot = t ~/ _slotMs;
      final end = math.min(now, (slot + 1) * _slotMs);
      _slotAskedMs[slot % _slots] += end - t;
      t = end;
    }
    _askedFrom = now;
  }

  int? _computeRate(int now) {
    final current = now ~/ _slotMs;
    var bytes = 0;
    var time = 0;
    for (var k = 0; k < _slots; k++) {
      final slot = current - k;
      final i = slot % _slots;
      if (_slotNumber[i] != slot) {
        continue;
      }
      bytes += _slotBytes[i];
      time += _slotAskedMs[i];
    }
    if (time <= 0) {
      return _lastRate;
    }
    if (_lastRate == null && time < firstValueTime.inMilliseconds && bytes < firstValueBytes) {
      return null;
    }
    return _lastRate = bytes * 1000 ~/ time;
  }

  void _fill(int now) {
    final current = now ~/ _slotMs;
    if (_lastSlot >= 0 && current <= _lastSlot) {
      return;
    }
    final int from;
    if (_lastSlot < 0) {
      from = current;
    } else if (current - _lastSlot > _slots) {
      from = current - _slots + 1;
    } else {
      from = _lastSlot + 1;
    }
    for (var slot = from; slot <= current; slot++) {
      final i = slot % _slots;
      _slotNumber[i] = slot;
      _slotBytes[i] = 0;
      _slotAskedMs[i] = 0;
    }
    _lastSlot = current;
  }
}
