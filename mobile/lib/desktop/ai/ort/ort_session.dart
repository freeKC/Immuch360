// ONNX Runtime by dart:ffi, on the processor (design-final 2026-10-26 section 2.1, lot A4a). The library is a file
// the user installs on demand with the AI components (lot A3a), opened by its path. The code asks it for the table of
// API 23, which ONNX Runtime 1.31.0 (Windows x64, Linux x64, Apple Silicon) and 1.23.2 (the last release built for
// Intel Macs) both give, so one set of bindings (ort_api_bindings.dart) serves every computer. A session reads the
// names, types and shapes of its inputs and outputs from the model, never from constants.
//
// Phase 1 ran one float32 tensor in and one out ([OrtSession.run], kept for the depth model). The models of phases 2
// and 3 take and give more (design-final 2026-10-27, sections 2.3, 2.5 and 10.1 point 3, lot C1): [OrtSession.runNamed]
// gives named inputs of float32, uint8 or int64 (ort_tensor.dart), in shapes the model leaves free, and reads every
// output it is asked for. A run takes the OrtRunOptions of its job ([OrtRunOptions]): the root isolate stops a run
// in progress through them from outside (ort_terminate.dart), since the isolate that runs the model is blocked in Run;
// the run then throws [OrtRunStopped]. A session may also give its memory back after each run instead of keeping the
// arena of ONNX Runtime ([OrtSessionSettings.cpuMemArena]): 0.9 GB less at the peak of MoGe for the same time
// (measure M2).
//
// Every OrtStatus that is not null becomes an OrtException carrying ONNX Runtime's own message, and every native
// object is released in a finally, counted by kind on the way (OrtRuntime.liveObjects, for the tests). The calls are
// synchronous: the worker isolate of lot A4b runs a whole job as one event. Settings of the design: intra-op threads =
// logical processors minus two (at least one), inter-op threads = 1, and session.intra_op.allow_spinning = 0 so that
// ONNX Runtime's threads do not spin between two passes.
//
// The official builds of ONNX Runtime 1.31.0 send telemetry to Microsoft unless told not to (its docs/Privacy.md): on
// Linux and macOS, at the first OrtEnv, they write a device id and queue an event for
// mobile.events.data.microsoft.com; on Windows, the DLL reports through ETW. The app is local only, so both are
// turned off: ORT_DISABLE_TELEMETRY=1 in the environment of the process before the library is opened, then
// DisableTelemetryEvents on each OrtEnv. 1.23.2 for Intel Macs has no telemetry; the two calls are harmless there.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:immich_mobile/desktop/ai/ort/ort_api_bindings.dart' as ort;
import 'package:immich_mobile/desktop/ai/ort/ort_tensor.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_terminate.dart';

export 'package:immich_mobile/desktop/ai/ort/ort_tensor.dart';
export 'package:immich_mobile/desktop/ai/ort/ort_terminate.dart' show OrtRunStopHandle, OrtRunStopper;

/// The version of the table of functions asked of ONNX Runtime: 1.23 and every later release give it
const ortApiVersion = 23;

/// The variable that keeps the telemetry of ONNX Runtime off for the whole process, read when its first OrtEnv is made
const ortTelemetryOffVariable = 'ORT_DISABLE_TELEMETRY';

/// A call to ONNX Runtime failed; [message] is ONNX Runtime's own when it gave one
class OrtException implements Exception {
  const OrtException(this.message, {this.code});

  final String message;

  /// The OrtErrorCode of the failed call, null when the failure came before any call
  final int? code;

  @override
  String toString() => 'OrtException: $message';
}

/// The library could not be opened, is not ONNX Runtime, or does not give API [ortApiVersion]
class OrtLoadException extends OrtException {
  const OrtLoadException(super.message);
}

/// A run ended because another isolate stopped it through its [OrtRunOptions]: the job was cancelled
class OrtRunStopped extends OrtException {
  const OrtRunStopped(super.message, {super.code});
}

/// How a session uses the processor
class OrtSessionSettings {
  const OrtSessionSettings({
    required this.intraOpThreads,
    this.interOpThreads = 1,
    this.allowSpinning = false,
    this.cpuMemArena = true,
  });

  /// The settings of the design for a computer with [logicalProcessors]: all of them but two for one pass
  factory OrtSessionSettings.forProcessors(int logicalProcessors) =>
      OrtSessionSettings(intraOpThreads: math.max(1, logicalProcessors - 2));

  /// [OrtSessionSettings.forProcessors] for this computer
  factory OrtSessionSettings.forThisComputer() => OrtSessionSettings.forProcessors(Platform.numberOfProcessors);

  final int intraOpThreads;
  final int interOpThreads;

  /// Whether ONNX Runtime's threads keep spinning between two passes (session.intra_op.allow_spinning)
  final bool allowSpinning;

  /// Whether the session keeps the memory of a pass in the arena of ONNX Runtime for the next one (its default), or
  /// gives it back after each pass (DisableCpuMemArena: MoGe peaks at 1.35 GB instead of 2.25, measure M2)
  final bool cpuMemArena;

  /// These settings with [cpuMemArena] set
  OrtSessionSettings withCpuMemArena(bool keep) => OrtSessionSettings(
    intraOpThreads: intraOpThreads,
    interOpThreads: interOpThreads,
    allowSpinning: allowSpinning,
    cpuMemArena: keep,
  );
}

/// ONNX Runtime opened from one file, and its table of functions at API [ortApiVersion]
final class OrtRuntime {
  OrtRuntime._(this.libraryPath, this.version, this._calls);

  /// Opened in this isolate, by path: a library is never unloaded
  static final _opened = <String, OrtRuntime>{};

  /// ONNX Runtime from the file at [libraryPath]. Throws [OrtLoadException] with the reason when there is no file
  /// there, when the system refuses to load it, when it is not ONNX Runtime, or when it is older than 1.23.
  static OrtRuntime load(String libraryPath) {
    final known = _opened[libraryPath];
    if (known != null) {
      return known;
    }
    if (!File(libraryPath).existsSync()) {
      throw OrtLoadException('No ONNX Runtime library at $libraryPath');
    }
    if (!_turnTelemetryOff()) {
      throw OrtLoadException('$libraryPath is not loaded: the telemetry of ONNX Runtime could not be turned off');
    }
    final DynamicLibrary library;
    try {
      library = DynamicLibrary.open(libraryPath);
    } on ArgumentError catch (error) {
      throw OrtLoadException('ONNX Runtime could not be loaded from $libraryPath: ${error.message}');
    }
    if (!library.providesSymbol('OrtGetApiBase')) {
      throw OrtLoadException('$libraryPath is not ONNX Runtime: it has no OrtGetApiBase');
    }
    final base = ort.OrtBindings(library).OrtGetApiBase();
    if (base == nullptr) {
      throw OrtLoadException('$libraryPath gave no OrtApiBase');
    }
    final version = _string(base.ref.GetVersionString.asFunction<Pointer<Char> Function()>()());
    final api = base.ref.GetApi.asFunction<Pointer<ort.OrtApi> Function(int)>()(ortApiVersion);
    if (api == nullptr) {
      throw OrtLoadException(
        'ONNX Runtime $version at $libraryPath does not give API $ortApiVersion: version 1.23 or later is needed',
      );
    }
    return _opened[libraryPath] = OrtRuntime._(libraryPath, version, _OrtCalls(api));
  }

  final String libraryPath;

  /// The version ONNX Runtime gives, such as 1.31.0
  final String version;

  final _OrtCalls _calls;

  /// The native objects made through this library and not given back yet, by kind (OrtEnv, OrtSession, OrtValue,
  /// OrtRunOptions...): an open session holds one OrtEnv and one OrtSession, a pass leaves nothing
  @visibleForTesting
  Map<String, int> get liveObjects => Map.unmodifiable(_calls.live);

  /// How many OrtEnv had their telemetry events turned off (DisableTelemetryEvents): one per session opened
  @visibleForTesting
  int get telemetryEventsOff => _calls.telemetryOff;

  /// A session on the model at [modelPath]. Throws [OrtException] with ONNX Runtime's message when the model cannot
  /// be read.
  OrtSession openSession(String modelPath, {OrtSessionSettings? settings}) =>
      OrtSession._open(this, modelPath, settings ?? OrtSessionSettings.forThisComputer());

  /// The options of the runs of one job, to be given back by [OrtRunOptions.release]
  OrtRunOptions createRunOptions() => using((arena) {
    final out = arena<Pointer<ort.OrtRunOptions>>();
    _calls.check(_calls.createRunOptions(out), 'CreateRunOptions');
    _calls.made('OrtRunOptions');
    return OrtRunOptions._(this, out.value, calloc<Int32>());
  });
}

/// The options of the runs of one job (OrtRunOptions), made in the isolate that runs the model. Another isolate stops
/// the run in progress, and every later run with the same options, through [handle] (OrtRunStopper, ort_terminate.dart);
/// the run then throws [OrtRunStopped]. Next to the options lives a flag in native memory that the stopper raises
/// before it asks ONNX Runtime to stop, so that the session tells a stopped run from a failed one without reading
/// ONNX Runtime's message. [release] gives both back, once no isolate can stop the runs any more.
final class OrtRunOptions {
  OrtRunOptions._(this.runtime, this._options, this._asked);

  final OrtRuntime runtime;
  final Pointer<ort.OrtRunOptions> _options;
  final Pointer<Int32> _asked;
  var _released = false;

  bool get isReleased => _released;

  /// What another isolate needs to stop the runs: plain values, sent in a message. Throws [StateError] once released.
  OrtRunStopHandle get handle {
    if (_released) {
      throw StateError('These OrtRunOptions were given back');
    }
    return OrtRunStopHandle(
      libraryPath: runtime.libraryPath,
      optionsAddress: _options.address,
      askedAddress: _asked.address,
    );
  }

  /// Whether a stop was asked, from any isolate
  bool get stopAsked => !_released && _asked.value != 0;

  /// Stops the run in progress and every later run with these options, as another isolate does through [handle]
  void stop() => OrtRunStopper(handle).stop();

  /// Gives the options back. Only once no isolate can call [OrtRunStopper.stop] on them any more (ai_worker.dart waits
  /// for the root isolate to say so).
  void release() {
    if (_released) {
      return;
    }
    _released = true;
    runtime._calls.releaseRunOptions(_options);
    calloc.free(_asked);
  }
}

/// A model loaded by ONNX Runtime, ready to run; [close] gives its memory back
final class OrtSession {
  OrtSession._(this.runtime, this.modelPath, this._env, this._session, this.inputs, this.outputs);

  static OrtSession _open(OrtRuntime runtime, String modelPath, OrtSessionSettings settings) {
    final calls = runtime._calls;
    return using((arena) {
      final envOut = arena<Pointer<ort.OrtEnv>>();
      calls.check(
        calls.createEnv(
          ort.OrtLoggingLevel.ORT_LOGGING_LEVEL_WARNING,
          'immuch360'.toNativeUtf8(allocator: arena).cast(),
          envOut,
        ),
        'CreateEnv',
      );
      calls.made('OrtEnv');
      final env = envOut.value;
      Pointer<ort.OrtSession> session = nullptr;
      try {
        // What turns off the ETW events of the Windows DLL; elsewhere ORT_DISABLE_TELEMETRY already did it
        calls.check(calls.disableTelemetryEvents(env), 'DisableTelemetryEvents');
        calls.telemetryOff++;
        final optionsOut = arena<Pointer<ort.OrtSessionOptions>>();
        calls.check(calls.createSessionOptions(optionsOut), 'CreateSessionOptions');
        calls.made('OrtSessionOptions');
        final options = optionsOut.value;
        try {
          calls.check(calls.setIntraOpNumThreads(options, settings.intraOpThreads), 'SetIntraOpNumThreads');
          calls.check(calls.setInterOpNumThreads(options, settings.interOpThreads), 'SetInterOpNumThreads');
          if (!settings.cpuMemArena) {
            calls.check(calls.disableCpuMemArena(options), 'DisableCpuMemArena');
          }
          calls.check(
            calls.setSessionGraphOptimizationLevel(options, ort.GraphOptimizationLevel.ORT_ENABLE_ALL),
            'SetSessionGraphOptimizationLevel',
          );
          calls.check(
            calls.addSessionConfigEntry(
              options,
              'session.intra_op.allow_spinning'.toNativeUtf8(allocator: arena).cast(),
              (settings.allowSpinning ? '1' : '0').toNativeUtf8(allocator: arena).cast(),
            ),
            'AddSessionConfigEntry',
          );
          final sessionOut = arena<Pointer<ort.OrtSession>>();
          calls.check(calls.createSession(env, _nativePath(modelPath, arena), options, sessionOut), 'CreateSession');
          calls.made('OrtSession');
          session = sessionOut.value;
        } finally {
          calls.releaseSessionOptions(options);
        }
        final inputs = calls.specs(session, input: true);
        final outputs = calls.specs(session, input: false);
        return OrtSession._(runtime, modelPath, env, session, inputs, outputs);
      } catch (_) {
        if (session != nullptr) {
          calls.releaseSession(session);
        }
        calls.releaseEnv(env);
        rethrow;
      }
    });
  }

  final OrtRuntime runtime;
  final String modelPath;
  final Pointer<ort.OrtEnv> _env;
  final Pointer<ort.OrtSession> _session;

  /// The inputs and outputs, as the model names them
  final List<OrtTensorSpec> inputs;
  final List<OrtTensorSpec> outputs;

  bool _closed = false;

  bool get isClosed => _closed;

  /// Runs the model on [values] shaped [shape] (its first input), and gives its first output, which must be float32.
  /// Throws [OrtException] with ONNX Runtime's message when the model refuses the input.
  OrtTensor run(Float32List values, List<int> shape) {
    if (_closed) {
      throw StateError('The ONNX Runtime session of $modelPath is closed');
    }
    final output = runNamed({inputs.first.name: OrtTensor(shape, values)}, outputs: [outputs.first.name]).values.single;
    if (output.type != OrtElementType.float32) {
      throw OrtException('The output ${outputs.first.name} of $modelPath is not float32 (type ${output.type.onnx})');
    }
    return output;
  }

  /// Runs the model on [given], its inputs by name, and gives the outputs named in [wanted] (every output of the
  /// model when null), by name, each with the shape and the type ONNX Runtime gave it. [options] are the options of
  /// the runs of the job: when another isolate stops them, the run ends at its next node and this throws
  /// [OrtRunStopped]. Throws [ArgumentError] for an output the model does not have, and [OrtException] with ONNX
  /// Runtime's message when the model refuses the inputs (a name, a type or a shape it does not take, one missing).
  Map<String, OrtTensor> runNamed(Map<String, OrtTensor> given, {List<String>? outputs, OrtRunOptions? options}) {
    if (_closed) {
      throw StateError('The ONNX Runtime session of $modelPath is closed');
    }
    final wanted = outputs ?? [for (final output in this.outputs) output.name];
    for (final name in wanted) {
      if (!this.outputs.any((output) => output.name == name)) {
        throw ArgumentError('$modelPath has no output $name: it gives ${this.outputs.join(', ')}');
      }
    }
    if (options != null && (options.isReleased || !identical(options.runtime, runtime))) {
      throw ArgumentError('The run options were given back, or belong to another ONNX Runtime');
    }
    final calls = runtime._calls;
    final names = given.keys.toList(growable: false);
    return using((arena) {
      // Zeroed by the arena (calloc), so that the finally below sees null for a value never made
      final inputNames = arena<Pointer<Char>>(math.max(1, names.length));
      final inputValues = arena<Pointer<ort.OrtValue>>(math.max(1, names.length));
      final outputNames = arena<Pointer<Char>>(math.max(1, wanted.length));
      final outputValues = arena<Pointer<ort.OrtValue>>(math.max(1, wanted.length));
      try {
        final allocatorOut = arena<Pointer<ort.OrtAllocator>>();
        calls.check(calls.getAllocatorWithDefaultOptions(allocatorOut), 'GetAllocatorWithDefaultOptions');
        for (var i = 0; i < names.length; i++) {
          inputNames[i] = names[i].toNativeUtf8(allocator: arena).cast();
          final tensor = given[names[i]]!;
          final shape = tensor.shape;
          final dimensions = arena<Int64>(math.max(1, shape.length));
          for (var d = 0; d < shape.length; d++) {
            dimensions[d] = shape[d];
          }
          final valueOut = arena<Pointer<ort.OrtValue>>();
          calls.check(
            calls.createTensorAsOrtValue(allocatorOut.value, dimensions, shape.length, tensor.type.onnx, valueOut),
            'CreateTensorAsOrtValue',
          );
          calls.made('OrtValue');
          // Given back by the finally from here on
          inputValues[i] = valueOut.value;
          final length = tensor.data.lengthInBytes;
          if (length > 0) {
            final dataOut = arena<Pointer<Void>>();
            calls.check(calls.getTensorMutableData(valueOut.value, dataOut), 'GetTensorMutableData');
            dataOut.value.cast<Uint8>().asTypedList(length).setAll(0, tensor.rawBytes);
          }
        }
        for (var i = 0; i < wanted.length; i++) {
          outputNames[i] = wanted[i].toNativeUtf8(allocator: arena).cast();
        }
        final status = calls.run(
          _session,
          options?._options ?? nullptr,
          inputNames,
          inputValues,
          names.length,
          outputNames,
          wanted.length,
          outputValues,
        );
        for (var i = 0; i < wanted.length; i++) {
          if (outputValues[i] != nullptr) {
            calls.made('OrtValue');
          }
        }
        calls.check(status, 'Run', stopped: options != null && options.stopAsked);
        return {for (var i = 0; i < wanted.length; i++) wanted[i]: calls.read(outputValues[i], wanted[i], modelPath)};
      } finally {
        for (var i = 0; i < wanted.length; i++) {
          if (outputValues[i] != nullptr) {
            calls.releaseValue(outputValues[i]);
          }
        }
        for (var i = 0; i < names.length; i++) {
          if (inputValues[i] != nullptr) {
            calls.releaseValue(inputValues[i]);
          }
        }
      }
    });
  }

  /// Gives the session's memory back (about 300 MB for Depth Anything V2 Small); [run] cannot be called afterwards
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    runtime._calls.releaseSession(_session);
    runtime._calls.releaseEnv(_env);
  }
}

/// Sets ORT_DISABLE_TELEMETRY=1 in the environment of the process, where ONNX Runtime reads it (getenv, or
/// GetEnvironmentVariableW on Windows); Platform.environment is a copy made at start, so the system is called. False
/// when the system refused.
bool _turnTelemetryOff() => using((arena) {
  if (Platform.isWindows) {
    final setVariable = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<Int32 Function(Pointer<Utf16>, Pointer<Utf16>), int Function(Pointer<Utf16>, Pointer<Utf16>)>(
          'SetEnvironmentVariableW',
        );
    return setVariable(ortTelemetryOffVariable.toNativeUtf16(allocator: arena), '1'.toNativeUtf16(allocator: arena)) !=
        0;
  }
  final setenv = DynamicLibrary.process()
      .lookupFunction<Int Function(Pointer<Utf8>, Pointer<Utf8>, Int), int Function(Pointer<Utf8>, Pointer<Utf8>, int)>(
        'setenv',
      );
  return setenv(ortTelemetryOffVariable.toNativeUtf8(allocator: arena), '1'.toNativeUtf8(allocator: arena), 1) == 0;
});

/// A path as ONNX Runtime reads it (ORTCHAR_T): UTF-16 on Windows, UTF-8 elsewhere
Pointer<Char> _nativePath(String path, Allocator allocator) => Platform.isWindows
    ? path.toNativeUtf16(allocator: allocator).cast()
    : path.toNativeUtf8(allocator: allocator).cast();

/// A string ONNX Runtime gives, read even when it is not valid UTF-8 (a message about a path, say)
String _string(Pointer<Char> text) {
  if (text == nullptr) {
    return '';
  }
  final utf8Text = text.cast<Utf8>();
  return utf8.decode(utf8Text.cast<Uint8>().asTypedList(utf8Text.length), allowMalformed: true);
}

/// The entries of the table the app calls, bound once per library. .github/desktop/ai/ort_bindings/ort_functions.json
/// lists them with their place in the table; ort_bindings_test.dart keeps that list and this code together.
final class _OrtCalls {
  _OrtCalls(this._api);

  final Pointer<ort.OrtApi> _api;

  late final getErrorCode = _api.ref.GetErrorCode.asFunction<int Function(Pointer<ort.OrtStatus>)>();
  late final getErrorMessage = _api.ref.GetErrorMessage.asFunction<Pointer<Char> Function(Pointer<ort.OrtStatus>)>();
  late final releaseStatus = _api.ref.ReleaseStatus.asFunction<void Function(Pointer<ort.OrtStatus>)>();

  late final createEnv = _api.ref.CreateEnv
      .asFunction<Pointer<ort.OrtStatus> Function(int, Pointer<Char>, Pointer<Pointer<ort.OrtEnv>>)>();
  late final releaseEnv = _counted('OrtEnv', _api.ref.ReleaseEnv.asFunction<void Function(Pointer<ort.OrtEnv>)>());
  late final disableTelemetryEvents = _api.ref.DisableTelemetryEvents
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtEnv>)>();

  late final createSessionOptions = _api.ref.CreateSessionOptions
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<Pointer<ort.OrtSessionOptions>>)>();
  late final setIntraOpNumThreads = _api.ref.SetIntraOpNumThreads
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtSessionOptions>, int)>();
  late final setInterOpNumThreads = _api.ref.SetInterOpNumThreads
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtSessionOptions>, int)>();
  late final disableCpuMemArena = _api.ref.DisableCpuMemArena
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtSessionOptions>)>();
  late final setSessionGraphOptimizationLevel = _api.ref.SetSessionGraphOptimizationLevel
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtSessionOptions>, int)>();
  late final addSessionConfigEntry = _api.ref.AddSessionConfigEntry
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtSessionOptions>, Pointer<Char>, Pointer<Char>)>();
  late final releaseSessionOptions = _counted(
    'OrtSessionOptions',
    _api.ref.ReleaseSessionOptions.asFunction<void Function(Pointer<ort.OrtSessionOptions>)>(),
  );

  late final createSession = _api.ref.CreateSession
      .asFunction<
        Pointer<ort.OrtStatus> Function(
          Pointer<ort.OrtEnv>,
          Pointer<Char>,
          Pointer<ort.OrtSessionOptions>,
          Pointer<Pointer<ort.OrtSession>>,
        )
      >();
  late final releaseSession = _counted(
    'OrtSession',
    _api.ref.ReleaseSession.asFunction<void Function(Pointer<ort.OrtSession>)>(),
  );

  late final sessionGetInputCount = _api.ref.SessionGetInputCount
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtSession>, Pointer<Size>)>();
  late final sessionGetOutputCount = _api.ref.SessionGetOutputCount
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtSession>, Pointer<Size>)>();
  late final sessionGetInputName = _api.ref.SessionGetInputName
      .asFunction<
        Pointer<ort.OrtStatus> Function(Pointer<ort.OrtSession>, int, Pointer<ort.OrtAllocator>, Pointer<Pointer<Char>>)
      >();
  late final sessionGetOutputName = _api.ref.SessionGetOutputName
      .asFunction<
        Pointer<ort.OrtStatus> Function(Pointer<ort.OrtSession>, int, Pointer<ort.OrtAllocator>, Pointer<Pointer<Char>>)
      >();
  late final sessionGetInputTypeInfo = _api.ref.SessionGetInputTypeInfo
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtSession>, int, Pointer<Pointer<ort.OrtTypeInfo>>)>();
  late final sessionGetOutputTypeInfo = _api.ref.SessionGetOutputTypeInfo
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtSession>, int, Pointer<Pointer<ort.OrtTypeInfo>>)>();
  late final castTypeInfoToTensorInfo = _api.ref.CastTypeInfoToTensorInfo
      .asFunction<
        Pointer<ort.OrtStatus> Function(Pointer<ort.OrtTypeInfo>, Pointer<Pointer<ort.OrtTensorTypeAndShapeInfo>>)
      >();
  late final releaseTypeInfo = _counted(
    'OrtTypeInfo',
    _api.ref.ReleaseTypeInfo.asFunction<void Function(Pointer<ort.OrtTypeInfo>)>(),
  );

  late final getTensorElementType = _api.ref.GetTensorElementType
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtTensorTypeAndShapeInfo>, Pointer<UnsignedInt>)>();
  late final getDimensionsCount = _api.ref.GetDimensionsCount
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtTensorTypeAndShapeInfo>, Pointer<Size>)>();
  late final getDimensions = _api.ref.GetDimensions
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtTensorTypeAndShapeInfo>, Pointer<Int64>, int)>();
  late final getTensorTypeAndShape = _api.ref.GetTensorTypeAndShape
      .asFunction<
        Pointer<ort.OrtStatus> Function(Pointer<ort.OrtValue>, Pointer<Pointer<ort.OrtTensorTypeAndShapeInfo>>)
      >();
  late final releaseTensorTypeAndShapeInfo = _counted(
    'OrtTensorTypeAndShapeInfo',
    _api.ref.ReleaseTensorTypeAndShapeInfo.asFunction<void Function(Pointer<ort.OrtTensorTypeAndShapeInfo>)>(),
  );

  late final getAllocatorWithDefaultOptions = _api.ref.GetAllocatorWithDefaultOptions
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<Pointer<ort.OrtAllocator>>)>();
  late final allocatorFree = _api.ref.AllocatorFree
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtAllocator>, Pointer<Void>)>();

  late final createTensorAsOrtValue = _api.ref.CreateTensorAsOrtValue
      .asFunction<
        Pointer<ort.OrtStatus> Function(
          Pointer<ort.OrtAllocator>,
          Pointer<Int64>,
          int,
          int,
          Pointer<Pointer<ort.OrtValue>>,
        )
      >();
  late final run = _api.ref.Run
      .asFunction<
        Pointer<ort.OrtStatus> Function(
          Pointer<ort.OrtSession>,
          Pointer<ort.OrtRunOptions>,
          Pointer<Pointer<Char>>,
          Pointer<Pointer<ort.OrtValue>>,
          int,
          Pointer<Pointer<Char>>,
          int,
          Pointer<Pointer<ort.OrtValue>>,
        )
      >();
  late final createRunOptions = _api.ref.CreateRunOptions
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<Pointer<ort.OrtRunOptions>>)>();
  late final releaseRunOptions = _counted(
    'OrtRunOptions',
    _api.ref.ReleaseRunOptions.asFunction<void Function(Pointer<ort.OrtRunOptions>)>(),
  );
  late final getTensorMutableData = _api.ref.GetTensorMutableData
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtValue>, Pointer<Pointer<Void>>)>();
  late final releaseValue = _counted(
    'OrtValue',
    _api.ref.ReleaseValue.asFunction<void Function(Pointer<ort.OrtValue>)>(),
  );

  /// The native objects made and not given back yet, by kind ([OrtRuntime.liveObjects])
  final live = <String, int>{};

  /// The calls to DisableTelemetryEvents that succeeded ([OrtRuntime.telemetryEventsOff])
  var telemetryOff = 0;

  /// Counts one native object of [kind], made by the call that just succeeded
  void made(String kind) => live[kind] = (live[kind] ?? 0) + 1;

  /// Counts one native object of [kind] given back
  void given(String kind) => live[kind] = (live[kind] ?? 0) - 1;

  /// [release], counting the object it gives back
  void Function(Pointer<T>) _counted<T extends NativeType>(String kind, void Function(Pointer<T>) release) => (object) {
    given(kind);
    release(object);
  };

  /// Throws the OrtException of [status] when it is not null, after releasing it: an [OrtRunStopped] when the call
  /// failed after a stop was asked ([stopped])
  void check(Pointer<ort.OrtStatus> status, String call, {bool stopped = false}) {
    if (status == nullptr) {
      return;
    }
    final message = '$call: ${_string(getErrorMessage(status))}';
    final code = getErrorCode(status);
    releaseStatus(status);
    throw stopped ? OrtRunStopped(message, code: code) : OrtException(message, code: code);
  }

  /// A copy of the tensor [value] gave as the output [name] of [modelPath]. Throws [OrtException] for a type the app
  /// does not read.
  OrtTensor read(Pointer<ort.OrtValue> value, String name, String modelPath) {
    return using((arena) {
      final infoOut = arena<Pointer<ort.OrtTensorTypeAndShapeInfo>>();
      check(getTensorTypeAndShape(value, infoOut), 'GetTensorTypeAndShape');
      made('OrtTensorTypeAndShapeInfo');
      final OrtTensorSpec described;
      try {
        described = describe(name, infoOut.value);
      } finally {
        releaseTensorTypeAndShapeInfo(infoOut.value);
      }
      final type = described.type;
      if (type == null) {
        throw OrtException(
          'The output $name of $modelPath is of type ${described.elementType}, which the app does not read',
        );
      }
      final length = elementCountOf(described.shape) * type.bytes;
      if (length == 0) {
        return OrtTensor.copyOf(type, described.shape, Uint8List(0));
      }
      final dataOut = arena<Pointer<Void>>();
      check(getTensorMutableData(value, dataOut), 'GetTensorMutableData');
      return OrtTensor.copyOf(type, described.shape, dataOut.value.cast<Uint8>().asTypedList(length));
    });
  }

  /// The name, type and shape of the inputs or outputs of [session]
  List<OrtTensorSpec> specs(Pointer<ort.OrtSession> session, {required bool input}) {
    return using((arena) {
      final countOut = arena<Size>();
      check(
        input ? sessionGetInputCount(session, countOut) : sessionGetOutputCount(session, countOut),
        input ? 'SessionGetInputCount' : 'SessionGetOutputCount',
      );
      final allocatorOut = arena<Pointer<ort.OrtAllocator>>();
      check(getAllocatorWithDefaultOptions(allocatorOut), 'GetAllocatorWithDefaultOptions');
      final allocator = allocatorOut.value;
      final found = <OrtTensorSpec>[];
      for (var index = 0; index < countOut.value; index++) {
        final nameOut = arena<Pointer<Char>>();
        check(
          input
              ? sessionGetInputName(session, index, allocator, nameOut)
              : sessionGetOutputName(session, index, allocator, nameOut),
          input ? 'SessionGetInputName' : 'SessionGetOutputName',
        );
        made('name');
        final String name;
        try {
          name = _string(nameOut.value);
        } finally {
          check(allocatorFree(allocator, nameOut.value.cast()), 'AllocatorFree');
          given('name');
        }
        final typeOut = arena<Pointer<ort.OrtTypeInfo>>();
        check(
          input ? sessionGetInputTypeInfo(session, index, typeOut) : sessionGetOutputTypeInfo(session, index, typeOut),
          input ? 'SessionGetInputTypeInfo' : 'SessionGetOutputTypeInfo',
        );
        made('OrtTypeInfo');
        try {
          final tensorOut = arena<Pointer<ort.OrtTensorTypeAndShapeInfo>>();
          check(castTypeInfoToTensorInfo(typeOut.value, tensorOut), 'CastTypeInfoToTensorInfo');
          if (tensorOut.value == nullptr) {
            throw OrtException('The ${input ? 'input' : 'output'} $name is not a tensor');
          }
          // Owned by the type info, released with it
          found.add(describe(name, tensorOut.value));
        } finally {
          releaseTypeInfo(typeOut.value);
        }
      }
      return found;
    });
  }

  /// The element type and shape [info] holds, under [name]
  OrtTensorSpec describe(String name, Pointer<ort.OrtTensorTypeAndShapeInfo> info) {
    return using((arena) {
      final typeOut = arena<UnsignedInt>();
      check(getTensorElementType(info, typeOut), 'GetTensorElementType');
      final countOut = arena<Size>();
      check(getDimensionsCount(info, countOut), 'GetDimensionsCount');
      final count = countOut.value;
      final dimensions = arena<Int64>(count == 0 ? 1 : count);
      check(getDimensions(info, dimensions, count), 'GetDimensions');
      return OrtTensorSpec(name, typeOut.value, List<int>.generate(count, (i) => dimensions[i], growable: false));
    });
  }
}
