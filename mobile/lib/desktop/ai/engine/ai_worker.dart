// The worker isolate of the AI features on a computer (design-final 2026-10-26, sections 2.1 and 2.6): one isolate
// that keeps the models' sessions from one photo to the next and gives each back after two minutes without use (some
// 300 MB of memory for the depth model), and runs each job as one synchronous event (immersive_chain.dart), so that
// the window never waits for a photo. The bytes of the original, and the pixels the engine of Flutter decoded on the
// root isolate for the photos that are not JPEG, come as TransferableTypedData: moved, not copied again. The cancel
// flag lives in native memory (NativeCancelFlag), read by the worker in the middle of a job without a message. The
// progress comes back as messages, which the root isolate hears while the worker computes.
//
// Everything the worker is made with is a plain object sent to it (AiWorkerSetup): the description of the model
// (DepthBackendSpec), the codec choice, the memory probe and the system of thread priorities, real or fake. The model
// itself, ONNX Runtime and its session, only ever exist in the worker.
//
// Phases 2 and 3 (design-final 2026-10-27, sections 2.5 and 4.5, lot C1) add three things:
//  - jobs of other kinds as tasks (AiWorkerTask), plain objects sent to the worker and run there with what it keeps
//    (AiWorkerContext): the scene engine of lot S1 is one;
//  - at most two sessions open at once, each given back two minutes after the last job that used it (AiSessionKeeper):
//    a scene needs MoGe and LaMa, a 3D photo the depth model; a third one opened gives back the least used;
//  - the stop of a pass of ONNX Runtime in progress. The flag above is read between two steps, but a pass of MoGe or
//    LaMa takes seconds and the worker is blocked in Run meanwhile. So a task makes the OrtRunOptions of its job in the
//    worker and sends their handle to the root isolate at once; the root isolate watches the cancel flag of the job and,
//    when it is raised, stops the run through its own binding of the same library (ort_terminate.dart): Run ends
//    within milliseconds with OrtRunStopped, which the task turns into a cancelled job (a task that lets it out fails
//    its call as cancelled, AiWorkerTaskFailed.cancelled). When the job ends, the root isolate forgets the handle,
//    then tells the worker, which only then gives the options back: no stop can reach options given back.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/thread_priority.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_depth_backend.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:logging/logging.dart';

final _log = Logger('AiWorker');

/// How long the worker keeps a session after the last job that used it (design 2.1)
const aiSessionKeep = Duration(minutes: 2);

/// How many sessions of ONNX Runtime the worker keeps open at most (design-final 2026-10-27, section 2.5)
const aiSessionsMax = 2;

/// How often the root isolate looks at the cancel flag of a job whose runs it can stop
const aiStopWatch = Duration(milliseconds: 50);

/// The name under which the worker keeps the session of the 3D photo's depth model
const aiDepthSession = 'depth';

/// The sessions the worker keeps between jobs: at most [maxOpen], each given back [keep] after the end of the last job
/// that used it; opening one more gives back the one used least recently. A session is anything with a way to give
/// it back; the worker's jobs run as single synchronous events, so no timer fires while a job uses a session.
class AiSessionKeeper {
  AiSessionKeeper({this.maxOpen = aiSessionsMax, this.keep = aiSessionKeep}) : assert(maxOpen > 0, 'At least one');

  final int maxOpen;
  final Duration keep;

  /// By name, the least recently used first
  final _open = <String, _KeptSession>{};
  final _usedInJob = <String>{};
  var _closes = 0;

  /// The names of the sessions open, the least recently used first
  List<String> get openNames => List.unmodifiable(_open.keys);

  /// How many sessions were given back to stay under [maxOpen] or after [keep] without use
  int get closes => _closes;

  /// The session [name], opened by [open] unless it is open already; [close] gives it back. Throws [StateError] when
  /// the session open under [name] is not a [T].
  T open<T extends Object>(String name, T Function() open, void Function(T session) close) {
    final kept = _open[name];
    if (kept != null) {
      final session = kept.session;
      if (session is! T) {
        throw StateError('The session $name is a ${session.runtimeType}, not a $T');
      }
      _used(name);
      return session;
    }
    makeRoom(name);
    final session = open();
    _open[name] = _KeptSession(session, () => close(session));
    _used(name);
    return session;
  }

  /// Gives back the sessions used least recently, so that one more under [name] keeps at most [maxOpen] open: for a
  /// session its owner opens itself (the depth model of the 3D photo, opened by its chain)
  void makeRoom(String name) {
    if (_open.containsKey(name)) {
      return;
    }
    while (_open.length >= maxOpen) {
      _giveBack(_open.keys.first);
    }
  }

  /// The session [name], opened by its owner, is open and was used by this job; [close] gives it back
  void adopt(String name, void Function() close) {
    _open[name] ??= _KeptSession(name, close);
    _used(name);
  }

  /// The owner of the session [name] closed it, or never opened it
  void forget(String name) {
    _open.remove(name)?.timer?.cancel();
    _usedInJob.remove(name);
  }

  /// The job ended: the sessions it used are given back [keep] from now unless another job uses them
  void endJob() {
    for (final name in _usedInJob) {
      final kept = _open[name];
      if (kept == null) {
        continue;
      }
      kept.timer?.cancel();
      kept.timer = Timer(keep, () {
        if (identical(_open[name], kept)) {
          _giveBack(name);
        }
      });
    }
    _usedInJob.clear();
  }

  /// Gives every session back
  void closeAll() {
    for (final name in List.of(_open.keys)) {
      _giveBack(name);
    }
    _usedInJob.clear();
  }

  void _used(String name) {
    final kept = _open.remove(name)!;
    kept.timer?.cancel();
    kept.timer = null;
    _open[name] = kept;
    _usedInJob.add(name);
  }

  void _giveBack(String name) {
    final kept = _open.remove(name);
    if (kept == null) {
      return;
    }
    kept.timer?.cancel();
    _usedInJob.remove(name);
    _closes++;
    try {
      kept.close();
    } catch (error, stack) {
      _log.warning('The session $name could not be given back', error, stack);
    }
  }
}

class _KeptSession {
  _KeptSession(this.session, this.close);

  final Object session;
  final void Function() close;
  Timer? timer;
}

/// What a task runs with in the worker
abstract interface class AiWorkerContext {
  /// Whether the job was cancelled (its NativeCancelFlag, read without a message)
  bool get isCancelled;

  /// The sessions the worker keeps between jobs
  AiSessionKeeper get sessions;

  /// The options of the runs of ONNX Runtime of this job, from the library at [libraryPath]: made at the first call,
  /// their handle sent at once to the root isolate, which stops the run in progress when the job is cancelled (the
  /// run then throws OrtRunStopped). Kept by the worker until the root isolate lets them go: never released by the
  /// task. Throws [StateError] when the job asks for the options of a second library, OrtLoadException when the
  /// library cannot be loaded.
  OrtRunOptions runOptions(String libraryPath);

  /// Tells the root isolate where the job is
  void progress(ImmersiveProgress progress);
}

/// A job run in the worker as one synchronous event: a plain object sent to the worker isolate, where [run] runs. What
/// it gives back is sent to the root isolate; what it throws fails the call with [AiWorkerTaskFailed].
///
/// A cancelled job is not a failed one (design-final 2026-10-27, section 2.5). A task reads
/// [AiWorkerContext.isCancelled] between its steps, and turns the OrtRunStopped of a run stopped by the cancel into
/// its own cancelled result. When it lets OrtRunStopped out, or throws anything once its job was cancelled, the call
/// fails with an [AiWorkerTaskFailed] whose [AiWorkerTaskFailed.cancelled] is true: the caller then shows the job as
/// cancelled, not failed.
abstract interface class AiWorkerTask<T> {
  T run(AiWorkerContext context);
}

/// A task threw in the worker: its [message], and whether its job was [cancelled]
class AiWorkerTaskFailed implements Exception {
  const AiWorkerTaskFailed(this.message, {this.cancelled = false});

  final String message;

  /// The task threw because its job was cancelled: OrtRunStopped out of a run the cancel stopped, or anything thrown
  /// once the cancel flag of the job was raised. The job is to be shown as cancelled.
  final bool cancelled;

  @override
  String toString() => 'AiWorkerTaskFailed${cancelled ? ' (cancelled)' : ''}: $message';
}

/// How the worker makes its model: a plain object sent to the worker isolate, where [create] runs
abstract interface class DepthBackendSpec {
  DepthBackend create();
}

/// Depth Anything V2 Small on ONNX Runtime, the files of the AI components (lot A3a)
class OrtBackendSpec implements DepthBackendSpec {
  const OrtBackendSpec({required this.libraryPath, required this.modelPath, this.modelSha256 = depthModelOnnxSha256});

  final String libraryPath;
  final String modelPath;
  final String modelSha256;

  @override
  DepthBackend create() => OrtDepthBackend(libraryPath: libraryPath, modelPath: modelPath, modelSha256: modelSha256);
}

/// What the worker is made with
class AiWorkerSetup {
  const AiWorkerSetup({
    required this.backend,
    this.codec = SbsCodecChoice.auto,
    this.keepSession = aiSessionKeep,
    this.memory = const SystemMemoryProbe(),
    this.priority,
  });

  final DepthBackendSpec backend;
  final SbsCodecChoice codec;

  /// The session is given back after this long without a job
  final Duration keepSession;
  final MemoryProbe memory;

  /// The system of thread priorities, this computer's when null
  final ThreadPriorityPlatform? priority;
}

/// One job as it travels to the worker: the job without the bytes of its source, the bytes and pixels moved apart
class AiWorkerJob {
  AiWorkerJob({
    required this.job,
    required Uint8List bytes,
    SbsDecoded? decoded,
    required this.cancelAddress,
    this.earlierTimes = const {},
  }) : _bytes = TransferableTypedData.fromList([bytes]),
       _pixels = decoded == null ? null : TransferableTypedData.fromList([decoded.rgba]),
       _width = decoded?.width,
       _height = decoded?.height,
       _iccProfile = decoded?.iccProfile;

  final ImmersiveJob job;

  /// The address of the NativeCancelFlag of the job
  final int cancelAddress;

  /// The steps the root isolate did already
  final Map<ImmersiveStage, Duration> earlierTimes;
  final TransferableTypedData _bytes;
  final TransferableTypedData? _pixels;
  final int? _width;
  final int? _height;
  final Uint8List? _iccProfile;

  /// In the worker, once: what the chain reads
  ChainOriginal materialize() {
    final pixels = _pixels;
    return ChainOriginal(
      bytes: _bytes.materialize().asUint8List(),
      decoded: pixels == null
          ? null
          : SbsDecoded(
              width: _width!,
              height: _height!,
              rgba: pixels.materialize().asUint8List(),
              iccProfile: _iccProfile,
            ),
    );
  }
}

/// What the worker says of itself, for the tests and the logs
class AiWorkerStatus {
  const AiWorkerStatus({
    required this.jobs,
    required this.sessionOpen,
    required this.sessionCloses,
    this.openSessions = const [],
    this.runOptionsHeld = 0,
    this.runOptionsAlive = 0,
  });

  /// The jobs it ran, tasks included
  final int jobs;

  /// Whether the depth model's session is open
  final bool sessionOpen;

  /// How many times it gave a session back, after [AiWorkerSetup.keepSession] without a job or to open another
  final int sessionCloses;

  /// The names of the sessions open, the least recently used first
  final List<String> openSessions;

  /// The run options it keeps until the root isolate lets them go
  final int runOptionsHeld;

  /// The OrtRunOptions made in the worker and not given back to ONNX Runtime yet, counted by the libraries themselves:
  /// [runOptionsHeld] once the worker gave back every one the root isolate let go
  final int runOptionsAlive;
}

/// The worker went away during a call: a crash of its isolate, or [AiWorker.close]
class AiWorkerStopped implements Exception {
  const AiWorkerStopped(this.message);

  final String message;

  @override
  String toString() => 'AiWorkerStopped: $message';
}

/// The worker isolate, seen from the root isolate
class AiWorker {
  AiWorker._(this._isolate, this._replies, this._exits, this._errors);

  final Isolate _isolate;
  final ReceivePort _replies;
  final ReceivePort _exits;
  final ReceivePort _errors;
  final _ready = Completer<SendPort>();
  SendPort? _port;
  final _pending = <int, Completer<Object?>>{};
  final _progress = <int, void Function(ImmersiveProgress progress)>{};

  /// The cancel flag of each job running, by its id
  final _cancels = <int, bool Function()>{};

  /// The runs the root isolate can stop, by the id of their job, while the job runs
  final _stoppers = <int, (OrtRunStopper, bool Function())>{};
  Timer? _stopWatch;
  final _heldAcks = <int>[];
  var _next = 0;
  var _alive = true;
  String? _lastError;

  /// Whether the isolate still runs
  bool get isAlive => _alive;

  /// For the tests: keeps the word that lets the worker give run options back, until [releaseRunOptions]
  @visibleForTesting
  bool holdRunOptions = false;

  /// For the tests: says the word kept by [holdRunOptions]
  @visibleForTesting
  void releaseRunOptions() {
    for (final id in _heldAcks) {
      _send(_RunOptionsDone(id));
    }
    _heldAcks.clear();
  }

  /// Starts a worker made with [setup]
  static Future<AiWorker> spawn(AiWorkerSetup setup) async {
    final replies = ReceivePort('ai-worker replies');
    final exits = ReceivePort('ai-worker exit');
    final errors = ReceivePort('ai-worker errors');
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _workerMain,
        (setup, replies.sendPort),
        debugName: 'ai-worker',
        onExit: exits.sendPort,
        onError: errors.sendPort,
      );
    } catch (_) {
      replies.close();
      exits.close();
      errors.close();
      rethrow;
    }
    final worker = AiWorker._(isolate, replies, exits, errors);
    replies.listen(worker._onReply);
    errors.listen((error) => worker._lastError = error is List && error.isNotEmpty ? '${error.first}' : '$error');
    exits.listen((_) => worker._stopped());
    await worker._ready.future;
    return worker;
  }

  void _onReply(Object? message) {
    switch (message) {
      case final SendPort port:
        _port = port;
        _ready.complete(port);
      case _Progress(:final id, :final progress):
        _progress[id]?.call(progress);
      case _RunOptionsMade(:final id, :final handle):
        _watchRuns(id, handle);
      case _Reply(:final id, :final value):
        _ended(id);
        _pending.remove(id)?.complete(value);
      case _TaskFailed(:final id, :final message, :final cancelled):
        _ended(id);
        _pending.remove(id)?.completeError(AiWorkerTaskFailed(message, cancelled: cancelled));
    }
  }

  /// The job [id] made the options of its runs: from now on its cancel stops them
  void _watchRuns(int id, OrtRunStopHandle handle) {
    final isCancelled = _cancels[id];
    if (isCancelled == null) {
      // Its job is not known here (it ended, or the worker is closing): nothing will stop them
      _send(_RunOptionsDone(id));
      return;
    }
    _stoppers[id] = (OrtRunStopper(handle), isCancelled);
    _checkStops();
    _stopWatch ??= Timer.periodic(aiStopWatch, (_) => _checkStops());
  }

  /// Stops the runs of every job cancelled since the last look
  void _checkStops() {
    for (final MapEntry(key: id, value: (stopper, isCancelled)) in _stoppers.entries) {
      if (!stopper.stopped && isCancelled()) {
        try {
          stopper.stop();
        } catch (error, stack) {
          // The job ends anyway at its next step, as before
          _log.warning('The run of the job $id could not be stopped', error, stack);
        }
      }
    }
  }

  /// The job [id] ended: its runs are forgotten here, then the worker may give their options back
  void _ended(int id) {
    _progress.remove(id);
    _cancels.remove(id);
    final watched = _stoppers.remove(id) != null;
    if (_stoppers.isEmpty) {
      _stopWatch?.cancel();
      _stopWatch = null;
    }
    if (watched) {
      if (holdRunOptions) {
        _heldAcks.add(id);
      } else {
        _send(_RunOptionsDone(id));
      }
    }
  }

  void _send(Object message) {
    if (_alive) {
      _port?.send(message);
    }
  }

  void _forgetRuns() {
    _stoppers.clear();
    _cancels.clear();
    _heldAcks.clear();
    _stopWatch?.cancel();
    _stopWatch = null;
  }

  void _stopped() {
    _alive = false;
    _forgetRuns();
    final reason = _lastError == null ? 'The worker of the AI features stopped' : 'The worker stopped: $_lastError';
    for (final pending in _pending.values) {
      pending.completeError(AiWorkerStopped(reason));
    }
    _pending.clear();
    _progress.clear();
    if (!_ready.isCompleted) {
      _ready.completeError(AiWorkerStopped(reason));
    }
    _replies.close();
    _exits.close();
    _errors.close();
  }

  Future<Object?> _ask(
    _Command Function(int id) command, {
    void Function(ImmersiveProgress progress)? onProgress,
    int? cancelAddress,
  }) {
    if (!_alive) {
      return Future.error(const AiWorkerStopped('The worker of the AI features is closed'));
    }
    final id = _next++;
    final reply = _pending[id] = Completer<Object?>();
    if (onProgress != null) {
      _progress[id] = onProgress;
    }
    if (cancelAddress != null) {
      _cancels[id] = NativeCancelFlag.readerOf(cancelAddress);
    }
    unawaited(_ready.future.then((port) => port.send(command(id))));
    return reply.future;
  }

  /// Runs [job] in the worker. Throws [AiWorkerStopped] when the worker goes away meanwhile.
  Future<ChainOutcome> run(AiWorkerJob job, {void Function(ImmersiveProgress progress)? onProgress}) async =>
      (await _ask((id) => _RunCommand(id, job), onProgress: onProgress))! as ChainOutcome;

  /// Runs [task] in the worker; the flag at [cancelAddress] (a NativeCancelFlag) cancels it, and stops the runs of
  /// ONNX Runtime it made options for. Throws [AiWorkerTaskFailed] when the task throws (its cancelled set when the
  /// task threw because of the cancel), [AiWorkerStopped] when the worker goes away meanwhile.
  Future<T> runTask<T>(
    AiWorkerTask<T> task, {
    required int cancelAddress,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async =>
      (await _ask((id) => _TaskCommand(id, task, cancelAddress), onProgress: onProgress, cancelAddress: cancelAddress))
          as T;

  /// What the worker says of itself
  Future<AiWorkerStatus> status() async => (await _ask(_StatusCommand.new))! as AiWorkerStatus;

  /// Gives the sessions and the run options back and ends the isolate
  Future<void> close() async {
    if (!_alive) {
      return;
    }
    // Nothing is stopped from here on: the worker may give every run options back
    _forgetRuns();
    try {
      await _ask(_CloseCommand.new);
    } on AiWorkerStopped {
      // Gone before it answered
    }
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

sealed class _Command {
  const _Command(this.id);

  final int id;
}

class _RunCommand extends _Command {
  const _RunCommand(super.id, this.job);

  final AiWorkerJob job;
}

class _TaskCommand extends _Command {
  const _TaskCommand(super.id, this.task, this.cancelAddress);

  final AiWorkerTask<Object?> task;
  final int cancelAddress;
}

class _StatusCommand extends _Command {
  const _StatusCommand(super.id);
}

class _CloseCommand extends _Command {
  const _CloseCommand(super.id);
}

/// From the root isolate: the job [id] ended and nothing will stop its runs any more
class _RunOptionsDone {
  const _RunOptionsDone(this.id);

  final int id;
}

class _Progress {
  const _Progress(this.id, this.progress);

  final int id;
  final ImmersiveProgress progress;
}

/// From the worker: the job [id] made the options of its runs
class _RunOptionsMade {
  const _RunOptionsMade(this.id, this.handle);

  final int id;
  final OrtRunStopHandle handle;
}

class _Reply {
  const _Reply(this.id, this.value);

  final int id;
  final Object? value;
}

class _TaskFailed {
  const _TaskFailed(this.id, this.message, {required this.cancelled});

  final int id;
  final String message;
  final bool cancelled;
}

/// What a task runs with: the cancel flag of its job, the sessions of the worker, the options of its runs
class _TaskContext implements AiWorkerContext {
  _TaskContext(this._id, int cancelAddress, this._replies, this.sessions, this._held)
    : _isCancelled = NativeCancelFlag.readerOf(cancelAddress);

  final int _id;
  final bool Function() _isCancelled;
  final SendPort _replies;
  final Map<int, OrtRunOptions> _held;
  OrtRunOptions? _options;

  @override
  final AiSessionKeeper sessions;

  @override
  bool get isCancelled => _isCancelled();

  @override
  OrtRunOptions runOptions(String libraryPath) {
    final made = _options;
    if (made != null) {
      if (made.runtime.libraryPath != libraryPath) {
        throw StateError('This job runs on ${made.runtime.libraryPath}, not on $libraryPath');
      }
      return made;
    }
    final options = OrtRuntime.load(libraryPath).createRunOptions();
    _held[_id] = options;
    _replies.send(_RunOptionsMade(_id, options.handle));
    return _options = options;
  }

  @override
  void progress(ImmersiveProgress progress) => _replies.send(_Progress(_id, progress));
}

/// The worker isolate: its chain is made at the first job; its sessions are kept by an [AiSessionKeeper]; the run
/// options of each task are kept until the root isolate lets them go
void _workerMain((AiWorkerSetup, SendPort) start) {
  final (setup, replies) = start;
  final commands = ReceivePort('ai-worker commands');
  replies.send(commands.sendPort);
  final sessions = AiSessionKeeper(keep: setup.keepSession);
  final held = <int, OrtRunOptions>{};
  ImmersiveChain? chain;
  var jobs = 0;

  ChainOutcome runJob(_RunCommand command) {
    final job = command.job;
    try {
      final tools = chain ??= ImmersiveChain(
        backend: setup.backend.create(),
        codecs: setup.codec.codecs(),
        memory: setup.memory,
        priority: ComputePriority(setup.priority ?? ThreadPriorityPlatform.system()),
      );
      return tools.run(
        job.job,
        job.materialize(),
        isCancelled: NativeCancelFlag.readerOf(job.cancelAddress),
        onProgress: (progress) => replies.send(_Progress(command.id, progress)),
        earlierTimes: job.earlierTimes,
      );
    } catch (error) {
      // The chain never throws; what could is making it (the model, the codecs)
      return ChainOutcome(ImmersiveResult.failed(ImmersiveErrorCode.modelFailed, message: '$error'));
    }
  }

  commands.listen((Object? message) {
    switch (message) {
      case final _RunCommand command:
        if (!(chain?.sessionOpen ?? false)) {
          sessions.makeRoom(aiDepthSession);
        }
        final outcome = runJob(command);
        jobs++;
        final tools = chain;
        if (tools != null && tools.sessionOpen) {
          sessions.adopt(aiDepthSession, tools.closeSession);
        } else {
          sessions.forget(aiDepthSession);
        }
        sessions.endJob();
        replies.send(_Reply(command.id, outcome));
      case final _TaskCommand command:
        final context = _TaskContext(command.id, command.cancelAddress, replies, sessions, held);
        Object reply;
        try {
          reply = _Reply(command.id, command.task.run(context));
        } catch (error) {
          reply = _TaskFailed(command.id, '$error', cancelled: error is OrtRunStopped || context.isCancelled);
        }
        jobs++;
        sessions.endJob();
        replies.send(reply);
      case _RunOptionsDone(:final id):
        held.remove(id)?.release();
      case final _StatusCommand command:
        replies.send(
          _Reply(
            command.id,
            AiWorkerStatus(
              jobs: jobs,
              sessionOpen: chain?.sessionOpen ?? false,
              sessionCloses: sessions.closes,
              openSessions: sessions.openNames,
              runOptionsHeld: held.length,
              runOptionsAlive: OrtRuntime.liveInThisIsolate('OrtRunOptions'),
            ),
          ),
        );
      case final _CloseCommand command:
        try {
          sessions.closeAll();
        } catch (_) {
          // The isolate ends anyway
        }
        // The root isolate forgot every handle before it asked to close
        for (final options in held.values) {
          options.release();
        }
        held.clear();
        commands.close();
        Isolate.exit(replies, _Reply(command.id, null));
    }
  });
}
