// What the app ends before its window goes, once a close is decided (close_guard.dart, DesktopShell). On 1 November
// 2026 the window of desktop build 19 froze when FreeKC closed it, and Windows offered to end it: the engine tears the
// app down after the window goes, on the thread of the window, and waits there for whatever still runs in native code,
// a share that stopped answering, a libmpv that does not return, a library being loaded. Nothing of the app ended its
// own work first, and what it kept in memory was lost: the logs of the session, where the film was.
//
// So the app ends its own work first, one step after the other, each with a bound of its own: none of them can hold
// the close, which lasts their sum at most (1.5 s) and a few milliseconds when nothing waits. Before the steps, the
// line of the close is written at once, without waiting (beginDesktopClose): a step that blocks the app in native
// code cannot be cut by any bound, and the logs written last would then be lost with the session's last lines.
// - The films open in a page save where they are (VideoWatchRecorder.closeAll), and stop following their players,
//   whose teardown says nothing of where the film was.
// - The players are disposed, all at once: libmpv stops reading and calling Dart. One that does not answer is told to
//   stop calling Dart and left as it is (PlayerPool.close).
// - The media bridge stops: its connections are cut, so that a read of libmpv on one of them returns at once.
// - The logs of the session are written, the lines of this close included: a window close sends Flutter neither
//   paused nor detached, and the log service wrote its buffer only then or 5 s after a line.
// The databases stay open: SQLite's journal keeps every write made, and the end of the process closes them. So do the
// connections to the shares: the system closes their sockets at the end of the process, while a polite logoff from an
// SMB share that stopped answering is itself a libsmb2 call that waits up to 30 s in a worker isolate, which the end of
// the Dart VM then waits for, as it waited for the reopen of a file in the dumps of 1 November 2026.
//
// The window hides as soon as the close is decided, on the three systems (DesktopWindow.prepareClose); on Windows the
// runner also ends the process within a few seconds whatever still runs (windows/runner/close_watchdog.cpp).

import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/domain/services/video_watch_recorder.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
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
  static const logs = Duration(milliseconds: 400);

  /// The longest a close waits for the app, all steps together
  static const total = Duration(milliseconds: 1500);
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

/// The close is decided: its line goes to the log, and the logs held in memory are written at once without waiting for
/// them. A step that blocks the root isolate (an FFI call into a libmpv that waits for its core, a plugin that blocks
/// the platform thread) is cut by no bound, and on Windows the runner then ends the process: the session's lines up to
/// the close are written. [writeLogs] is that of [desktopCloseLogWritesProvider], so that the logs step waits for this
/// write too.
void beginDesktopClose(Future<void> Function() writeLogs) {
  _log.info('The window closes');
  unawaited(
    Future.sync(writeLogs).catchError(
      (Object error, StackTrace stackTrace) =>
          _log.warning('Closing: the logs could not be written', error, stackTrace),
    ),
  );
}

/// [write] made to end once the writes asked before it ended too; one that failed fails only its own caller
Future<void> Function() chainDesktopLogWrites(Future<void> Function() write) {
  var before = Future<void>.value();
  return () {
    final mine = Future.wait([before, Future.sync(write)]).then<void>((_) {});
    before = mine.then<void>((_) {}, onError: (Object _) {});
    return mine;
  };
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

/// The writes of the logs at a close, the line of the close first (beginDesktopClose), then the logs step: each ends
/// once those asked before it are written too. The log service's write takes the lines it holds and waits for those
/// only, so the logs step, which finds none left but its own, would end at once and the window would go before the
/// line of the close is written, as the replay of 1 November 2026 showed on an idle close.
final desktopCloseLogWritesProvider = Provider<Future<void> Function()>(
  (ref) => chainDesktopLogWrites(ref.read(desktopCloseLogsProvider)),
);

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
    DesktopCloseStep('the logs', DesktopCloseBounds.logs, ref.read(desktopCloseLogWritesProvider)),
  ];
});
