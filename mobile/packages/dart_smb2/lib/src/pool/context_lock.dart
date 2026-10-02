/// One libsmb2 context created or destroyed at a time, for the whole isolate.
///
/// `smb2_init_context` and `smb2_destroy_context` change a global
/// `active_contexts` list (libsmb2's `init.c`) without a lock, so two
/// isolates creating or destroying a context at the same moment can
/// corrupt it. Every worker of every [Smb2Pool] is spawned (which creates
/// its context and connects) and closed (which logs off and destroys it)
/// through [Smb2ContextLock.run], including the respawns of the
/// auto-reconnect, and so is [Smb2Pool.listSharesOn].
library;

import 'dart:async';

import 'pool.dart';

/// The process-wide order of the libsmb2 context creations and
/// destructions of this isolate. An application that creates contexts of
/// its own (an `Smb2Client` in an isolate of its own) or wants several
/// pool operations to run together runs them through [run] too.
abstract final class Smb2ContextLock {
  static Future<void> _tail = Future<void>.value();

  /// Zone key marking the actions that hold the lock.
  static final Object _holding = Object();

  /// Runs [action] once the actions passed before it are done, or have
  /// run for longer than their [limit]: the limit keeps an action that
  /// never ends (a worker that died before reporting) from holding the
  /// others back forever. It counts from the start of [action], not from
  /// the call.
  ///
  /// [action] may call [run] again (a pool that connects inside the
  /// action of its caller): the nested call runs at once, within the
  /// lock it already holds.
  static Future<T> run<T>(
    Future<T> Function() action, {
    required Duration limit,
  }) {
    if (Zone.current[_holding] == true) {
      return action();
    }
    final previous = _tail;
    final released = Completer<void>();
    _tail = released.future;
    return previous.then((_) {
      void release() {
        if (!released.isCompleted) released.complete();
      }

      final timer = Timer(limit, release);
      final Future<T> result;
      try {
        result = runZoned(action, zoneValues: {_holding: true});
      } catch (error, stackTrace) {
        timer.cancel();
        release();
        return Future<T>.error(error, stackTrace);
      }
      result.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        timer.cancel();
        release();
      });
      return result;
    });
  }
}
