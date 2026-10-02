// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Main-isolate proxy for a single worker isolate. [Worker.spawn] kicks
/// off the worker, [Worker.send] forwards a command, [Worker.close]
/// asks it to disconnect cleanly (with a 5-second escape hatch) before
/// killing the isolate.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:meta/meta.dart';

import '../smb2_error_type.dart';
import '../smb2_exceptions.dart';
import 'messages.dart';
import 'worker_main.dart';

/// One worker isolate's handle. Visible to [Smb2Pool] and to
/// [Smb2PoolHandle]'s finalizer; not part of the public API.
class Worker {
  final SendPort _sendPort;
  final Isolate _isolate;
  final ReceivePort _exitPort;

  /// Currently-awaited [send] completers. Tracked so that if the worker
  /// dies (Isolate-level exit OR explicit [close]) we can finish every
  /// pending Future with a typed connection error instead of leaving
  /// them hung forever waiting on a reply that's never coming.
  final Set<Completer<dynamic>> _pending = {};

  bool _dead = false;

  Worker._(this._sendPort, this._isolate, this._exitPort) {
    _isolate.addOnExitListener(_exitPort.sendPort);
    _exitPort.listen((_) => _markDead());
  }

  /// Internal accessor used by [Smb2PoolHandle]'s GC finalizer to
  /// best-effort close a leaked handle. Wrapping it as a getter keeps
  /// [_sendPort] genuinely private to this file otherwise.
  SendPort get sendPort => _sendPort;

  /// `true` once the worker isolate has exited (either via [close], an
  /// uncaught error, or an explicit kill). [send] starts rejecting
  /// immediately after this flips so callers don't queue up new requests
  /// against a dead worker.
  bool get isDead => _dead;

  /// Spawn a worker isolate with the given [ConnectParams] and wait for
  /// it to confirm a successful libsmb2 connection.
  static Future<Worker> spawn(ConnectParams p) async {
    final initPort = ReceivePort();
    final exitPort = ReceivePort();
    final isolate = await Isolate.spawn(
      workerMain,
      InitMsg(
        sendPort: initPort.sendPort,
        host: p.host,
        share: p.share,
        user: p.user,
        password: p.password,
        domain: p.domain,
        timeoutSeconds: p.timeoutSeconds,
        seal: p.seal,
        signing: p.signing,
        version: p.version,
        testLibOverride: p.testLibOverride,
      ),
    );

    final result = await initPort.first;
    initPort.close();

    if (result is SendPort) {
      return Worker._(result, isolate, exitPort);
    }
    // Initialisation failed; exitPort never gets listened to.
    exitPort.close();
    throw Smb2Exception('Worker failed to start: $result');
  }

  /// Send [cmd] with [args] and await its reply.
  ///
  /// Two races resolve the returned Future:
  ///
  ///   1. The worker replies → the awaiting Completer completes with
  ///      that value (or throws an [Smb2Exception] reconstructed from
  ///      the wire-format [ErrorMsg]).
  ///   2. The worker dies → [_markDead] iterates every pending
  ///      Completer and finishes it with a typed connection
  ///      [Smb2Exception], so the awaiter sees an error instead of a
  ///      Future that never settles.
  ///
  /// Both paths share the same Completer; whichever fires first wins,
  /// and the other side is a no-op (the second check guards against
  /// `Completer.complete` being called twice).
  Future<T> send<T>(String cmd, Map<String, dynamic> args) async {
    if (_dead) {
      throw const Smb2Exception(
        'Worker isolate is dead',
        null,
        Smb2ErrorType.connection,
      );
    }
    final replyPort = ReceivePort();
    final completer = Completer<dynamic>();
    _pending.add(completer);
    StreamSubscription<dynamic>? sub;
    try {
      sub = replyPort.listen((msg) {
        if (!completer.isCompleted) completer.complete(msg);
      });
      _sendPort.send({...args, 'cmd': cmd, 'replyTo': replyPort.sendPort});
      final result = await completer.future;
      if (result is ErrorMsg) {
        throw Smb2Exception(
          result.message,
          result.errorCode,
          result.errorTypeIndex != null
              ? Smb2ErrorType.values[result.errorTypeIndex!]
              : Smb2ErrorType.unknown,
        );
      }
      if (result is TransferableTypedData) {
        return result.materialize().asUint8List() as T;
      }
      return result as T;
    } finally {
      _pending.remove(completer);
      await sub?.cancel();
      replyPort.close();
    }
  }

  /// Mark the worker dead and fail every pending [send]. Called from
  /// the [Isolate.addOnExitListener] callback and from [close].
  ///
  /// Idempotent: calling it twice is harmless.
  void _markDead() {
    if (_dead) return;
    _dead = true;
    const error = Smb2Exception(
      'Worker isolate died with in-flight requests',
      null,
      Smb2ErrorType.connection,
    );
    // Snapshot to a list — completing a Completer triggers `finally`
    // blocks in `send` that mutate `_pending`.
    for (final c in _pending.toList()) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pending.clear();
    _exitPort.close();
  }

  /// Ask the worker to disconnect cleanly, then kill the isolate.
  ///
  /// Gives the worker 5 seconds to flush its current operation; if it
  /// doesn't reply (already dead, stuck, …) we fall through to the
  /// unconditional kill below. Either path ends with [_markDead] so any
  /// pending sends don't hang forever.
  Future<void> close() async {
    if (_dead) return;
    final replyPort = ReceivePort();
    _sendPort.send({'cmd': 'close', 'replyTo': replyPort.sendPort});
    try {
      await replyPort.first.timeout(const Duration(seconds: 5));
    } catch (_) {
      // Worker may be unresponsive or already dead — kill immediately.
    } finally {
      replyPort.close();
    }
    _isolate.kill(priority: Isolate.immediate);
    _markDead();
  }

  /// Test-only: kill the worker isolate immediately, without sending
  /// the cooperative `close` message first. Lets tests verify that
  /// pending sends complete with a connection error instead of hanging
  /// forever waiting on a reply that's never coming.
  @visibleForTesting
  void killForTest() {
    if (_dead) return;
    _isolate.kill(priority: Isolate.immediate);
    _markDead();
  }
}
