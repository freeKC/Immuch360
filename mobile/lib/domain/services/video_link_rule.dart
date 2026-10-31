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

/// What a link brings, as LinkMeter.kt measures it: the bytes per second over the last [window] while the player
/// wanted more ([wanted]), and the time since the last progress (each [VideoLinkRule.progressBytes] that arrive). The
/// computers feed it with the bytes the media bridge sends their player. [clock] is a parameter so that the tests
/// drive it.
class VideoLinkMeter {
  VideoLinkMeter({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  static const window = Duration(seconds: 4);
  static const _slotMs = 250;
  static final _slots = window.inMilliseconds ~/ _slotMs + 1;

  /// A first rate is told once this much arrived, or after [firstValueTime] of loading
  static const firstValueBytes = 256 * 1024;
  static const firstValueTime = Duration(seconds: 1);

  final DateTime Function() _clock;
  late final _slotBytes = List<int>.filled(_slots, 0);
  late final _slotNumber = List<int>.filled(_slots, -1);
  late final _slotWanted = List<bool>.filled(_slots, false);
  int _lastSlot = -1;
  bool _wanted = true;
  int _startedAt = -1;
  int _total = 0;
  int _progressAt = -1;
  int _bytesAtProgress = 0;
  int? _lastRate;

  int get _now => _clock().millisecondsSinceEpoch;

  /// Bytes received since the meter started
  int get receivedBytes => _total;

  /// Whether a read started
  bool get started => _startedAt >= 0;

  /// The first read of the video started: the time since progress counts from it
  void start() {
    if (_startedAt < 0) {
      final now = _now;
      _fill(now);
      _startedAt = now;
    }
  }

  /// The player wants more media ([wanted]), or holds what it wants
  void setWanted(bool wanted) {
    final now = _now;
    _fill(now);
    if (_wanted && !wanted) {
      _computeRate(now);
    }
    _wanted = wanted;
    if (wanted) {
      _slotWanted[(now ~/ _slotMs) % _slots] = true;
    }
  }

  /// [count] bytes arrived
  void add(int count) {
    if (count <= 0) {
      return;
    }
    final now = _now;
    _fill(now);
    if (_startedAt < 0) {
      _startedAt = now;
    }
    _slotBytes[(now ~/ _slotMs) % _slots] += count;
    _total += count;
    if (_total - _bytesAtProgress >= VideoLinkRule.progressBytes) {
      _progressAt = now;
      _bytesAtProgress = _total;
    }
  }

  /// Bytes per second over the last [window] while the player wanted more; the last value while it wanted none in that
  /// window; null before [firstValueBytes] arrived or [firstValueTime] of wanting passed
  int? rate() {
    if (_startedAt < 0) {
      return null;
    }
    final now = _now;
    _fill(now);
    return _computeRate(now);
  }

  /// Time since the last progress, or since the first read for a link that never sent; null before any read
  Duration? sinceProgress() {
    final from = _progressAt >= 0 ? _progressAt : _startedAt;
    return from < 0 ? null : Duration(milliseconds: math.max(_now - from, 0));
  }

  int? _computeRate(int now) {
    final current = now ~/ _slotMs;
    var bytes = 0;
    var time = 0;
    for (var k = 0; k < _slots; k++) {
      final slot = current - k;
      final i = slot % _slots;
      if (_slotNumber[i] != slot || !_slotWanted[i]) {
        continue;
      }
      bytes += _slotBytes[i];
      time += slot == current ? now - slot * _slotMs : _slotMs;
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
      _slotWanted[i] = _wanted;
    }
    _lastSlot = current;
  }
}
