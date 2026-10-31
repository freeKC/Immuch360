import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/models/watch_progress.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';

/// The watch progress of the films the immersive viewer of the Meta Quest plays (FreeKC's rule of 31 October 2026, see
/// WatchRule): one store for the whole app, Flutter's, which the viewer feeds with its progress events and which tells
/// where a film starts. The viewer keeps no memory of its own. Held by the navigators, which outlive the widget that
/// opened the viewer: never a ref.
class ImmersiveWatch {
  const ImmersiveWatch({required this.store, required this.rule, required this.noticeText});

  final WatchProgressStore store;
  final WatchRule rule;

  /// The words of the notice of a film that starts at a position, "Resumed at 42:10" in the language of the app
  final String Function(Duration position) noticeText;

  /// The threshold the viewer is given (ImmersiveApi.open's watchMinDurationMs), -1 with the setting off
  int get minDurationMs => rule.minDurationMs;

  /// Where the film of [key] starts: where it was left (see resumeAt), with [duration] when the app knows it; 0 for
  /// another media, and for none
  Duration startOf(WatchKey? key, {Duration? duration}) =>
      key == null ? Duration.zero : resumeAt(store.find(key), rule: rule, duration: duration);

  /// Where a film opened from a player of the app starts: where that player is, [inApp], when it played (the viewer
  /// carries on from there, nothing to say), else where the film was left, with its notice
  ({Duration position, String? notice}) startFrom(Duration inApp, {required WatchKey? key, Duration? duration}) {
    if (inApp > Duration.zero) {
      return (position: inApp, notice: null);
    }
    final start = startOf(key, duration: duration);
    return (position: start, notice: noticeOf(start));
  }

  /// The notice of a film that starts at [position], null from the beginning
  String? noticeOf(Duration position) => position > Duration.zero ? noticeText(position) : null;

  /// The viewer tells where the film of [key] is: [positionMs] of [durationMs]; nothing for a video that is no film
  void record(WatchKey? key, int positionMs, int durationMs) {
    if (key == null || durationMs <= 0) {
      return;
    }
    final duration = Duration(milliseconds: durationMs);
    if (!rule.isFilm(duration)) {
      return;
    }
    store.record(key, position: Duration(milliseconds: positionMs), duration: duration);
  }
}
