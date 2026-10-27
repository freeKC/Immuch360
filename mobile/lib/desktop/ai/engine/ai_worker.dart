// The worker isolate of the AI features on a computer (design-final 2026-10-26, sections 2.1 and 2.6): one isolate
// that keeps the model's session from one photo to the next and gives it back after two minutes without work (some 300
// MB of memory), and runs each job as one synchronous event (immersive_chain.dart), so that the window never waits for
// a photo. The bytes of the original, and the pixels the engine of Flutter decoded on the root isolate for the photos
// that are not JPEG, come as TransferableTypedData: moved, not copied again. The cancel flag lives in native memory
// (NativeCancelFlag), read by the worker in the middle of a job without a message. The progress comes back as
// messages, which the root isolate hears while the worker computes.
//
// Everything the worker is made with is a plain object sent to it (AiWorkerSetup): the description of the model
// (DepthBackendSpec), the codec choice, the memory probe and the system of thread priorities, real or fake. The model
// itself, ONNX Runtime and its session, only ever exist in the worker.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/thread_priority.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_depth_backend.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// How long the worker keeps the model's session without a job (design 2.1)
const aiSessionKeep = Duration(minutes: 2);

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
  const AiWorkerStatus({required this.jobs, required this.sessionOpen, required this.sessionCloses});

  /// The jobs it ran
  final int jobs;

  /// Whether the model's session is open
  final bool sessionOpen;

  /// How many times it gave the session back after [AiWorkerSetup.keepSession] without a job
  final int sessionCloses;
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
  final _pending = <int, Completer<Object?>>{};
  final _progress = <int, void Function(ImmersiveProgress progress)>{};
  var _next = 0;
  var _alive = true;
  String? _lastError;

  /// Whether the isolate still runs
  bool get isAlive => _alive;

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
        _ready.complete(port);
      case _Progress(:final id, :final progress):
        _progress[id]?.call(progress);
      case _Reply(:final id, :final value):
        _progress.remove(id);
        _pending.remove(id)?.complete(value);
    }
  }

  void _stopped() {
    _alive = false;
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

  Future<Object?> _ask(_Command Function(int id) command, {void Function(ImmersiveProgress progress)? onProgress}) {
    if (!_alive) {
      return Future.error(const AiWorkerStopped('The worker of the AI features is closed'));
    }
    final id = _next++;
    final reply = _pending[id] = Completer<Object?>();
    if (onProgress != null) {
      _progress[id] = onProgress;
    }
    unawaited(_ready.future.then((port) => port.send(command(id))));
    return reply.future;
  }

  /// Runs [job] in the worker. Throws [AiWorkerStopped] when the worker goes away meanwhile.
  Future<ChainOutcome> run(AiWorkerJob job, {void Function(ImmersiveProgress progress)? onProgress}) async =>
      (await _ask((id) => _RunCommand(id, job), onProgress: onProgress))! as ChainOutcome;

  /// What the worker says of itself
  Future<AiWorkerStatus> status() async => (await _ask(_StatusCommand.new))! as AiWorkerStatus;

  /// Gives the session back and ends the isolate
  Future<void> close() async {
    if (!_alive) {
      return;
    }
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

class _StatusCommand extends _Command {
  const _StatusCommand(super.id);
}

class _CloseCommand extends _Command {
  const _CloseCommand(super.id);
}

class _Progress {
  const _Progress(this.id, this.progress);

  final int id;
  final ImmersiveProgress progress;
}

class _Reply {
  const _Reply(this.id, this.value);

  final int id;
  final Object? value;
}

/// The worker isolate: its chain is made at the first job, its session closed after [AiWorkerSetup.keepSession]
/// without a job
void _workerMain((AiWorkerSetup, SendPort) start) {
  final (setup, replies) = start;
  final commands = ReceivePort('ai-worker commands');
  replies.send(commands.sendPort);
  ImmersiveChain? chain;
  Timer? idle;
  var jobs = 0;
  var closes = 0;

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
        idle?.cancel();
        final outcome = runJob(command);
        jobs++;
        replies.send(_Reply(command.id, outcome));
        final tools = chain;
        if (tools != null && tools.sessionOpen) {
          idle = Timer(setup.keepSession, () {
            tools.closeSession();
            closes++;
          });
        }
      case final _StatusCommand command:
        replies.send(
          _Reply(
            command.id,
            AiWorkerStatus(jobs: jobs, sessionOpen: chain?.sessionOpen ?? false, sessionCloses: closes),
          ),
        );
      case final _CloseCommand command:
        idle?.cancel();
        try {
          chain?.closeSession();
        } catch (_) {
          // The isolate ends anyway
        }
        commands.close();
        Isolate.exit(replies, _Reply(command.id, null));
    }
  });
}
