// What a 3D video job needs of the app around the engine (store/m2/release-49/lots/video3d-plan.md, sections 2 and
// 4.5): the programs of the FFmpeg archive started by the runner of the AI features (a job object on Windows,
// immuch360-run on Linux, below normal priority, the journal), the heavy work in an isolate of its own (the window
// loop, one session of Video Depth Anything Small for the job, the Rust frame work) whose run Cancel and Pause stop
// within a second through OrtRunOptions, and the computer kept awake while a job runs (not the screen).

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dbus/dbus.dart';
import 'package:ffi/ffi.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/thread_priority.dart';
import 'package:immich_mobile/desktop/ai/ort/depth_provider.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/ai/video3d/sphere_video_worker.dart';
import 'package:immich_mobile/desktop/ai/video3d/vda_window_loop.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_engine.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_frame_ops.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';
import 'package:logging/logging.dart';

final _log = Logger('Video3d');

/// The programs of the FFmpeg archive through the runner of the AI features, at low priority
class ManagedVideoProgramRunner implements VideoProgramRunner {
  const ManagedVideoProgramRunner(this.runner);

  final ManagedProcessRunner runner;

  @override
  Future<VideoProgram> start(String executable, List<String> arguments) async =>
      _Managed(await runner.startBinary(ProcessLaunch(executable: executable, arguments: arguments)));
}

class _Managed implements VideoProgram {
  _Managed(this._process);

  final ManagedBinaryProcess _process;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  IOSink get stdin => _process.stdin;

  @override
  Future<String> get errors => _process.errors;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void kill() => _process.kill();
}

/// What the worker isolate of a job is opened with: plain values, sent in a message
class VideoWorkerSetup {
  const VideoWorkerSetup({
    required this.ortLibrary,
    required this.modelPath,
    required this.eyeWidth,
    required this.eyeHeight,
    required this.modelWidth,
    required this.modelHeight,
    required this.parallax,
    required this.convergence,
    required this.half,
    required this.edgeFade,
    required this.alignment,
    this.intraOpThreads,
    this.cpuMemArena = true,
    this.lowPriority = true,
    this.sphereShiftDegrees,
    this.cardLibrary,
    this.depthDevice = depthDeviceAuto,
    this.allowSoftwareCard = false,
    this.depthCardMemory,
  });

  final String ortLibrary;
  final String modelPath;
  final int eyeWidth;
  final int eyeHeight;
  final int modelWidth;
  final int modelHeight;
  final double parallax;
  final double convergence;
  final bool half;
  final bool edgeFade;
  final VideoDepthAlignment alignment;

  /// ONNX Runtime's threads for a pass: logical processors minus 2 when null
  final int? intraOpThreads;
  final bool cpuMemArena;

  /// The threads of the session lowered as those of the photos (thread_priority.dart)
  final bool lowPriority;

  /// A 360° video: the shift of the nearest point at the equator (the worker of the sphere, sphere_video_worker.dart,
  /// its faces of modelWidth x modelWidth); null for a flat video
  final double? sphereShiftDegrees;

  /// The DirectML build of ONNX Runtime (Windows), null when this computer has none: the processor then
  final String? cardLibrary;

  /// Where the depth model runs, as "This computer" says (depth_provider.dart): auto, processor or card: then the name
  final String depthDevice;

  /// The renderer of Windows on the processor (WARP) counted as a card: the CI only
  final bool allowSoftwareCard;

  /// video_depth_cards.json, the cards whose check gave another depth (DepthCardMemory); null: none kept
  final String? depthCardMemory;
}

/// The worker of a job in an isolate of its own: the frames go there as TransferableTypedData, the side by side frames
/// come back the same way. [stop] stops the model's run in progress (and every later one) from the caller's isolate.
class IsolateVideoFrameWorker implements VideoFrameWorker {
  IsolateVideoFrameWorker._(this._isolate, this._commands, this._replies, this._stopHandle, this._exit);

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _replies;
  final OrtRunStopHandle _stopHandle;
  final ReceivePort _exit;
  final _pending = <int, Completer<Object?>>{};
  var _next = 0;
  var _closed = false;

  /// Opens the session of [setup] in a new isolate. Throws [VideoJobException] when the model or ONNX Runtime fails.
  static Future<IsolateVideoFrameWorker> spawn(VideoWorkerSetup setup) async {
    final replies = ReceivePort('video3d worker');
    final exit = ReceivePort('video3d worker exit');
    final isolate = await Isolate.spawn(
      _workerMain,
      (replies.sendPort, setup),
      debugName: 'video3d',
      onExit: exit.sendPort,
      errorsAreFatal: true,
    );
    final first = Completer<Object?>();
    late final IsolateVideoFrameWorker worker;
    replies.listen((message) {
      if (!first.isCompleted) {
        first.complete(message);
        return;
      }
      worker._reply(message);
    });
    final hello = await first.future;
    if (hello is! (SendPort, OrtRunStopHandle)) {
      replies.close();
      exit.close();
      isolate.kill();
      throw VideoJobException('The worker of the 3D video could not start: $hello');
    }
    worker = IsolateVideoFrameWorker._(isolate, hello.$1, replies, hello.$2, exit);
    exit.listen((_) => worker._failAll('The worker of the 3D video ended'));
    return worker;
  }

  void _reply(Object? message) {
    if (message case (final int id, final Object? value)) {
      final completer = _pending.remove(id);
      if (value case _WorkerError(:final message, :final stopped)) {
        completer?.completeError(stopped ? const VideoJobStopped(false) : VideoJobException(message));
      } else {
        completer?.complete(value);
      }
    }
  }

  void _failAll(String message) {
    for (final completer in _pending.values) {
      completer.completeError(VideoJobException(message));
    }
    _pending.clear();
  }

  Future<T> _call<T>(String op, [Object? payload]) {
    if (_closed) {
      throw StateError('The worker of the 3D video is closed');
    }
    final id = _next++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commands.send((id, op, payload));
    return completer.future.then((value) => value as T);
  }

  /// Stops the model's run in progress, and every later run: the call waiting for it fails with VideoJobStopped
  void stop() => OrtRunStopper(_stopHandle).stop();

  static List<VideoSbsFrame> _frames(Object? value) => [
    for (final (index, bytes, holes) in (value! as List).cast<(int, TransferableTypedData, int)>())
      VideoSbsFrame(index: index, bytes: bytes.materialize().asUint8List(), holes: holes),
  ];

  @override
  Future<List<VideoSbsFrame>> add(Uint8List rgb) async =>
      _frames(await _call<Object?>('add', TransferableTypedData.fromList([rgb])));

  @override
  Future<List<VideoSbsFrame>> finish() async => _frames(await _call<Object?>('finish'));

  @override
  Future<VdaLoopState?> stateAfterWindow() => _call<VdaLoopState?>('state');

  @override
  Future<void> restore(VdaLoopState state, List<Uint8List> heldFrames) => _call<void>('restore', (state, heldFrames));

  @override
  Future<({int windows, List<int> cuts})> counts() async {
    final (windows, cuts) = await _call<(int, List<int>)>('counts');
    return (windows: windows, cuts: cuts);
  }

  @override
  Future<VideoWorkerReport> report() async {
    final (lines, stages) = await _call<(List<String>, Map<String, int>)>('report');
    return VideoWorkerReport(lines: lines, stages: stages);
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    try {
      await _call<void>('close').timeout(const Duration(seconds: 10));
    } on Object catch (error) {
      _log.warning('The worker of the 3D video did not close: $error');
    }
    _closed = true;
    _replies.close();
    _exit.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

class _WorkerError {
  const _WorkerError(this.message, {this.stopped = false});

  final String message;
  final bool stopped;
}

void _workerMain((SendPort, VideoWorkerSetup) start) {
  final (replies, setup) = start;
  final commands = ReceivePort('video3d commands');
  DepthSession? depth;
  OrtRunOptions? options;
  VideoFrameOps? ops;
  VideoFrameWorker? worker;
  final lines = <String>[];
  try {
    final settings = OrtSessionSettings(
      intraOpThreads: setup.intraOpThreads ?? math.max(1, Platform.numberOfProcessors - 2),
      cpuMemArena: setup.cpuMemArena,
    );
    final priority = setup.lowPriority ? ComputePriority(ThreadPriorityPlatform.system()) : null;
    OrtSession wrap(OrtSession Function() open) =>
        priority == null ? open() : priority.lowerThreadsBornDuring(open).value;
    final opened = depth = openDepthSession(
      processorLibrary: setup.ortLibrary,
      cardLibrary: setup.cardLibrary,
      modelPath: setup.modelPath,
      width: setup.modelWidth,
      height: setup.sphereShiftDegrees != null ? setup.modelWidth : setup.modelHeight,
      settings: settings,
      choice: setup.depthDevice,
      allowSoftware: setup.allowSoftwareCard,
      wrap: wrap,
      cardMemory: switch (setup.depthCardMemory) {
        final String path => DepthCardMemory(path),
        null => null,
      },
    );
    lines.addAll(opened.lines);
    final runOptions = options = opened.runtime.createRunOptions();
    ops = nativeVideoFrameOps(threads: 2) ?? const DartVideoFrameOps();
    Float32List runOn(OrtSession model, Float32List input, int width, int height) => model
        .runNamed(
          {
            model.inputs.first.name: OrtTensor([1, vdaWindowLength, 3, height, width], input),
          },
          outputs: [model.outputs.first.name],
          options: runOptions,
        )
        .values
        .single
        .values;
    // A card that fails during the job (a driver reset, its memory full, values that are not numbers): the window run
    // again on the processor of the same library, so that the options Cancel and Pause stop stay those of the job
    Float32List run(Float32List input, int width, int height) => runDepthWindow(
      onCard: opened.session.provider.isGraphicsCard,
      run: () => runOn(opened.session, input, width, height),
      toProcessor: (reason) {
        final card = opened.plan.title;
        opened.session.close();
        opened.session = wrap(() => opened.runtime.openSession(setup.modelPath, settings: settings));
        opened.plan = const DepthProviderPlan(OrtProvider.cpu, why: 'the graphics card failed during the job');
        lines.add(
          'the graphics card failed during the job ($card: $reason): the depth model goes on on the processor, '
          'ONNX Runtime ${opened.runtime.version}, ${settings.intraOpThreads} threads',
        );
      },
    );

    final shift = setup.sphereShiftDegrees;
    worker = shift != null
        ? LocalSphereVideoFrameWorker(
            ops: ops,
            model: run,
            eyeWidth: setup.eyeWidth,
            eyeHeight: setup.eyeHeight,
            side: setup.modelWidth,
            shiftDegrees: shift,
            alignment: setup.alignment,
          )
        : LocalVideoFrameWorker(
            ops: ops,
            model: run,
            eyeWidth: setup.eyeWidth,
            eyeHeight: setup.eyeHeight,
            modelWidth: setup.modelWidth,
            modelHeight: setup.modelHeight,
            relief: VideoReliefSettings(
              parallax: setup.parallax,
              convergence: setup.convergence,
              packing: setup.half ? VideoSbsPacking.half : VideoSbsPacking.full,
              edgeFade: setup.edgeFade,
            ),
            alignment: setup.alignment,
          );
    replies.send((commands.sendPort, runOptions.handle));
  } on Object catch (error) {
    depth?.session.close();
    replies.send('$error');
    commands.close();
    return;
  }
  final job = worker;
  List<(int, TransferableTypedData, int)> pack(List<VideoSbsFrame> frames) => [
    for (final frame in frames) (frame.index, TransferableTypedData.fromList([frame.bytes]), frame.holes),
  ];
  commands.listen((message) async {
    final (id, op, payload) = message as (int, String, Object?);
    try {
      final Object? result = switch (op) {
        'add' => pack(await job.add((payload! as TransferableTypedData).materialize().asUint8List())),
        'finish' => pack(await job.finish()),
        'state' => await job.stateAfterWindow(),
        'restore' => await () async {
          final (state, held) = payload! as (VdaLoopState, List<Uint8List>);
          await job.restore(state, held);
          return null;
        }(),
        'counts' => await () async {
          final counts = await job.counts();
          return (counts.windows, counts.cuts);
        }(),
        'report' => await () async {
          final told = await job.report();
          final drained = [...lines, ...told.lines];
          lines.clear();
          return (drained, told.stages);
        }(),
        'close' => null,
        _ => throw ArgumentError('unknown command $op'),
      };
      if (op == 'close') {
        await job.close();
        depth?.session.close();
        options?.release();
        replies.send((id, null));
        commands.close();
        return;
      }
      replies.send((id, result));
    } on OrtRunStopped catch (error) {
      replies.send((id, _WorkerError('$error', stopped: true)));
    } on Object catch (error) {
      replies.send((id, _WorkerError('$error')));
    }
  });
}

// --- keeping the computer awake ---------------------------------------------------------------------------------------

/// Keeps the computer from sleeping while a 3D video job runs (the screen may still turn off): Windows
/// SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) from the root isolate's thread, macOS an IOKit assertion
/// PreventUserIdleSystemSleep, Linux a logind inhibitor "sleep:idle" held as a file descriptor. [hold] and [release]
/// never throw: a computer that refuses only logs it.
class SystemSleepGuard {
  SystemSleepGuard({DBusClient Function()? systemBus}) : _systemBus = systemBus ?? DBusClient.system;

  final DBusClient Function() _systemBus;
  var _held = false;
  int? _macAssertion;
  DBusClient? _bus;
  ResourceHandle? _inhibitor;

  bool get isHeld => _held;

  /// Windows' flags: ES_CONTINUOUS | ES_SYSTEM_REQUIRED, and ES_CONTINUOUS alone to let go
  static const windowsHold = 0x80000000 | 0x00000001;
  static const windowsRelease = 0x80000000;

  /// What logind is asked: what, who, why, mode
  static const linuxInhibit = ('sleep:idle', 'Immuch360', 'A 3D video is being made', 'block');

  Future<void> hold() async {
    if (_held) {
      return;
    }
    _held = true;
    try {
      if (Platform.isWindows) {
        final kernel = DynamicLibrary.open('kernel32.dll');
        final set = kernel.lookupFunction<Uint32 Function(Uint32), int Function(int)>('SetThreadExecutionState');
        if (set(windowsHold) == 0) {
          _log.warning('SetThreadExecutionState refused');
        }
      } else if (Platform.isMacOS) {
        _macAssertion = _macCreateAssertion();
      } else if (Platform.isLinux) {
        final bus = _bus = _systemBus();
        final reply = await bus.callMethod(
          destination: 'org.freedesktop.login1',
          path: DBusObjectPath('/org/freedesktop/login1'),
          interface: 'org.freedesktop.login1.Manager',
          name: 'Inhibit',
          values: [
            DBusString(linuxInhibit.$1),
            DBusString(linuxInhibit.$2),
            DBusString(linuxInhibit.$3),
            DBusString(linuxInhibit.$4),
          ],
          replySignature: DBusSignature('h'),
        );
        _inhibitor = (reply.values.single as DBusUnixFd).handle;
      }
    } on Object catch (error) {
      _log.warning('The computer could not be kept awake: $error');
    }
  }

  Future<void> release() async {
    if (!_held) {
      return;
    }
    _held = false;
    try {
      if (Platform.isWindows) {
        final kernel = DynamicLibrary.open('kernel32.dll');
        kernel.lookupFunction<Uint32 Function(Uint32), int Function(int)>('SetThreadExecutionState')(windowsRelease);
      } else if (Platform.isMacOS) {
        final assertion = _macAssertion;
        _macAssertion = null;
        if (assertion != null) {
          DynamicLibrary.open(
            '/System/Library/Frameworks/IOKit.framework/IOKit',
          ).lookupFunction<Int32 Function(Uint32), int Function(int)>('IOPMAssertionRelease')(assertion);
        }
      } else if (Platform.isLinux) {
        final inhibitor = _inhibitor;
        _inhibitor = null;
        if (inhibitor != null) {
          // Closing the descriptor ends the inhibitor
          inhibitor.toFile().closeSync();
        }
        await _bus?.close();
        _bus = null;
      }
    } on Object catch (error) {
      _log.warning('The computer could not be let go to sleep: $error');
    }
  }

  static int? _macCreateAssertion() {
    final core = DynamicLibrary.open('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');
    final iokit = DynamicLibrary.open('/System/Library/Frameworks/IOKit.framework/IOKit');
    final createString = core
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Uint32),
          Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int)
        >('CFStringCreateWithCString');
    final release = core.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CFRelease');
    final create = iokit
        .lookupFunction<
          Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Pointer<Uint32>),
          int Function(Pointer<Void>, int, Pointer<Void>, Pointer<Uint32>)
        >('IOPMAssertionCreateWithName');
    const utf8Encoding = 0x08000100;
    return using((arena) {
      final type = createString(nullptr, 'PreventUserIdleSystemSleep'.toNativeUtf8(allocator: arena), utf8Encoding);
      final name = createString(
        nullptr,
        'Immuch360: a 3D video is being made'.toNativeUtf8(allocator: arena),
        utf8Encoding,
      );
      final id = arena<Uint32>();
      try {
        // kIOPMAssertionLevelOn
        return create(type, 255, name, id) == 0 ? id.value : null;
      } finally {
        release(type);
        release(name);
      }
    });
  }
}
