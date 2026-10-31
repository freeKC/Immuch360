// Where a video was left, kept on this device only (FreeKC's request of 31 October 2026). A long video, a film, resumes
// where it was left and shows how much of it was watched on its tile; a shorter one, a holiday clip, always starts from
// the beginning and keeps nothing. Nothing goes to the server: Immich has no watched state.

import 'dart:math' as math;

import 'package:immich_mobile/domain/models/config/viewer_config.dart';

/// Which videos are films (see [isFilm]): the "Remember where I stopped" setting ([enabled], on by default) and its
/// threshold in minutes ([minMinutes], 10 by default): a film is longer than it, as the setting says ("In videos longer
/// than N min"); 0 makes every video whose duration is known a film
class WatchRule {
  const WatchRule({this.enabled = true, this.minMinutes = 10});

  /// The settings of the viewer, see ViewerConfig.resumeVideos and resumeMinMinutes
  factory WatchRule.of(ViewerConfig viewer) =>
      WatchRule(enabled: viewer.resumeVideos, minMinutes: viewer.resumeMinMinutes);

  final bool enabled;
  final int minMinutes;

  /// The threshold: a film is longer than this, a video of exactly this long is not
  Duration get minDuration => Duration(minutes: math.max(0, minMinutes));

  /// Whether a video of [duration] is a film, longer than [minDuration]: its position is remembered and resumed, its
  /// tile shows how much of it was watched, and it plays once whatever Looping says. Never with the setting off, nor
  /// without a duration.
  bool isFilm(Duration? duration) => enabled && duration != null && duration > Duration.zero && duration > minDuration;

  /// [minDuration] in milliseconds, -1 with the setting off: what the immersive viewer of the Meta Quest is given
  int get minDurationMs => enabled ? minDuration.inMilliseconds : -1;

  @override
  bool operator ==(Object other) => other is WatchRule && other.enabled == enabled && other.minMinutes == minMinutes;

  @override
  int get hashCode => Object.hash(enabled, minMinutes);

  @override
  String toString() => 'WatchRule(enabled: $enabled, minMinutes: $minMinutes)';
}

/// The end of a film of [duration] where a stop counts as watched: its last two minutes, a fifth of a short clip (a
/// threshold of 0 makes a 40 s clip a film, which would be watched as soon as it starts otherwise)
Duration watchEndTail(Duration duration) => _shorter(const Duration(minutes: 2), duration * 0.2);

/// The start of a film of [duration] where a stop keeps nothing: its first thirty seconds, a twentieth of a short clip.
/// Seeking back to 0 restarts it, and a film swiped past during its autoplay leaves no row.
Duration watchStartMargin(Duration duration) => _shorter(const Duration(seconds: 30), duration * 0.05);

Duration _shorter(Duration a, Duration b) => a < b ? a : b;

/// How far a duration known now may differ from [duration], the one of a row, before it counts as another file (see
/// [resumeAt]): 1 % of it, 2 s at least. Two durations of one film differ by more than a few seconds: the transcode and
/// the original, a media server's own probe, an audio or subtitle stream longer than the video.
Duration watchDurationTolerance(Duration duration) {
  final relative = duration * 0.01;
  return relative > const Duration(seconds: 2) ? relative : const Duration(seconds: 2);
}

/// Where the video of [key] was left: [position] in its [duration], 0 for a film to start from the beginning;
/// [watched] once it was stopped in its end tail (see [watchEndTail]), which the next viewings keep. [fingerprint] finds
/// a file of a share again once it was renamed or moved (see WatchKey).
class WatchProgress {
  const WatchProgress({
    required this.key,
    required this.position,
    required this.duration,
    required this.watched,
    required this.updatedAt,
    this.fingerprint,
  });

  final String key;
  final Duration position;
  final Duration duration;
  final bool watched;
  final DateTime updatedAt;
  final String? fingerprint;

  /// How much of the video was watched, from 0 to 1
  double get fraction {
    if (duration <= Duration.zero) {
      return 0;
    }
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  WatchProgress copyWith({
    String? key,
    Duration? position,
    Duration? duration,
    bool? watched,
    DateTime? updatedAt,
    String? fingerprint,
  }) => WatchProgress(
    key: key ?? this.key,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    watched: watched ?? this.watched,
    updatedAt: updatedAt ?? this.updatedAt,
    fingerprint: fingerprint ?? this.fingerprint,
  );

  @override
  bool operator ==(Object other) =>
      other is WatchProgress &&
      other.key == key &&
      other.position == position &&
      other.duration == duration &&
      other.watched == watched &&
      other.updatedAt == updatedAt &&
      other.fingerprint == fingerprint;

  @override
  int get hashCode => Object.hash(key, position, duration, watched, updatedAt, fingerprint);

  @override
  String toString() =>
      'WatchProgress($key, ${position.inMilliseconds} of ${duration.inMilliseconds} ms'
      '${watched ? ', watched' : ''}${fingerprint != null ? ', $fingerprint' : ''})';
}

/// The row of [key] once a player stopped at [position] in [duration], over [previous]: in the end tail the film is
/// watched and goes back to 0; under the start margin it goes back to 0; elsewhere it keeps [position]. A watched film
/// stays watched. Null when nothing is left to keep (at 0 and never watched): the row goes. Without a duration nothing
/// is known, and [previous] stays as it was.
WatchProgress? recordWatch({
  required String key,
  WatchProgress? previous,
  required Duration position,
  required Duration duration,
  required DateTime now,
  String? fingerprint,
}) {
  if (duration <= Duration.zero) {
    return previous;
  }
  final at = position < Duration.zero ? Duration.zero : position;
  final ended = at >= duration - watchEndTail(duration);
  final watched = ended || (previous?.watched ?? false);
  final kept = ended || at < watchStartMargin(duration) ? Duration.zero : at;
  if (kept == Duration.zero && !watched) {
    return null;
  }
  return WatchProgress(
    key: key,
    position: kept,
    duration: duration,
    watched: watched,
    updatedAt: now,
    fingerprint: fingerprint ?? previous?.fingerprint,
  );
}

/// Where a video whose row is [row] starts: where it was left for a film (see [WatchRule.isFilm], with [duration], the
/// duration known now, else the one of the row), from the beginning otherwise. A duration known now that differs from
/// the one of the row by more than [watchDurationTolerance] is another file at the same place: from the beginning.
Duration resumeAt(WatchProgress? row, {required WatchRule rule, Duration? duration}) {
  if (row == null || row.position <= Duration.zero) {
    return Duration.zero;
  }
  final known = duration != null && duration > Duration.zero ? duration : null;
  if (!rule.isFilm(known ?? row.duration)) {
    return Duration.zero;
  }
  if (known != null && (known - row.duration).abs() > watchDurationTolerance(row.duration)) {
    return Duration.zero;
  }
  return row.position;
}
