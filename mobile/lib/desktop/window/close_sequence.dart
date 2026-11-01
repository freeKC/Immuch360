// What the app ends before its window goes, once a close is decided (close_guard.dart, DesktopShell). On 1 November
// 2026 the window of desktop build 19 froze when FreeKC closed it, and Windows offered to end it: the engine tears the
// app down after the window goes, on the thread of the window, and waits there for whatever still runs in native code,
// a share that stopped answering, a libmpv that does not return, a library being loaded. Nothing of the app ended its
// own work first, and what it kept in memory was lost: the logs of the session, where the film was.
//
// So the app ends its own work first, one step after the other, each with a bound of its own: none of them can hold
// the close, which lasts their sum at most (about 1.7 s) and a few milliseconds when nothing waits.
// - The films open in a page save where they are (VideoWatchRecorder.closeAll), and stop following their players,
//   whose teardown says nothing of where the film was.
// - The players are disposed, all at once: libmpv stops reading and calling Dart. One that does not answer is told to
//   stop calling Dart and left as it is (PlayerPool.close).
// - The media bridge stops: its connections are cut, so that a read of libmpv on one of them returns at once.
// - The connections to the shares close.
// - The logs of the session are written, the lines of this close included: a window close sends Flutter neither
//   paused nor detached, and the log service wrote its buffer only then or 5 s after a line.
// The databases stay open: SQLite's journal keeps every write made, and the end of the process closes them.
//
// On Windows the window hides as soon as the close is decided, and the runner ends the process within a few seconds
// whatever still runs (DesktopWindow.prepareClose, windows/runner/close_watchdog.cpp).

import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/domain/services/video_watch_recorder.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('DesktopClose');

/// One step of a close: [run] is given [timeout] at most, after which the close goes on without it
class DesktopCloseStep {
  const DesktopCloseStep(this.name, this.timeout, this.run);

  /// For the log: what the step ends, never a path or an address
  final String name;
  final Duration timeout;
  final FutureOr<void> Function() run;
}

/// How a step of a close ended
enum DesktopCloseStepEnd { done, failed, timedOut }

/// The bounds of the steps of a close, see the top of this file
abstract final class DesktopCloseBounds {
  static const watchProgress = Duration(milliseconds: 400);

  /// Each player, all at once
  static const player = Duration(milliseconds: 400);
  static const players = Duration(milliseconds: 500);
  static const mediaBridge = Duration(milliseconds: 200);
  static const shares = Duration(milliseconds: 200);
  static const logs = Duration(milliseconds: 400);

  /// The longest a close waits for the app, all steps together
  static const total = Duration(milliseconds: 1700);
}

/// Runs [steps] one after the other, each within its timeout, and tells how each ended. A step that throws or does
/// not end in time is logged, and the next one runs.
Future<Map<String, DesktopCloseStepEnd>> runDesktopClose(List<DesktopCloseStep> steps) async {
  final ends = <String, DesktopCloseStepEnd>{};
  for (final step in steps) {
    final watch = Stopwatch()..start();
    try {
      await Future.sync(step.run).timeout(step.timeout);
      ends[step.name] = DesktopCloseStepEnd.done;
    } on TimeoutException {
      ends[step.name] = DesktopCloseStepEnd.timedOut;
      _log.warning('Closing: ${step.name} did not end within ${step.timeout.inMilliseconds} ms, the app goes on');
    } catch (error, stackTrace) {
      ends[step.name] = DesktopCloseStepEnd.failed;
      _log.warning('Closing: ${step.name} failed after ${watch.elapsedMilliseconds} ms', error, stackTrace);
    }
  }
  return ends;
}

/// Writes the logs the log service holds in memory; nothing when it was never started
Future<void> flushDesktopLogs() {
  final LogService logs;
  try {
    logs = LogService.I;
  } on LoggerUnInitializedException {
    return Future.value();
  }
  return logs.flush();
}

/// How the logs are written at a close, replaced by the tests
final desktopCloseLogsProvider = Provider<Future<void> Function()>((ref) => flushDesktopLogs);

/// The steps of a close of the window, made when the close is decided from what runs then: what was never made is not
/// made for a close (ref.exists), as for the close guard
final desktopCloseStepsProvider = Provider<List<DesktopCloseStep> Function()>((ref) {
  return () => [
    const DesktopCloseStep('the watch progress', DesktopCloseBounds.watchProgress, VideoWatchRecorder.closeAll),
    DesktopCloseStep(
      'the players',
      DesktopCloseBounds.players,
      () => closeDesktopPlayerPool(timeout: DesktopCloseBounds.player),
    ),
    if (ref.exists(mediaBridgeProvider))
      DesktopCloseStep('the media bridge', DesktopCloseBounds.mediaBridge, () => ref.read(mediaBridgeProvider).stop()),
    if (ref.exists(networkConnectionsProvider))
      DesktopCloseStep('the shares', DesktopCloseBounds.shares, () => ref.read(networkConnectionsProvider).closeAll()),
    DesktopCloseStep('the logs', DesktopCloseBounds.logs, ref.read(desktopCloseLogsProvider)),
  ];
});
