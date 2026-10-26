// ONNX Runtime by dart:ffi, on the processor (design-final 2026-10-26 section 2.1, lot A4a). The library is a file
// the user installs on demand with the AI components (lot A3a), opened by its path. The code asks it for the table of
// API 23, which ONNX Runtime 1.31.0 (Windows x64, Linux x64, Apple Silicon) and 1.23.2 (the last release built for
// Intel Macs) both give, so one set of bindings (ort_api_bindings.dart) serves every computer. A session reads the
// names and shapes of its input and output from the model, never from constants, and runs one float32 tensor in and
// one out, which is all a depth model needs.
//
// Every OrtStatus that is not null becomes an OrtException carrying ONNX Runtime's own message, and every native
// object is released in a finally, counted by kind on the way (OrtRuntime.liveObjects, for the tests). The calls are
// synchronous: the worker isolate of lot A4b runs a whole job as one event. Settings of the design: intra-op threads =
// logical processors minus two (at least one), inter-op threads = 1, and session.intra_op.allow_spinning = 0 so that
// ONNX Runtime's threads do not spin between two passes.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:immich_mobile/desktop/ai/ort/ort_api_bindings.dart' as ort;

/// The version of the table of functions asked of ONNX Runtime: 1.23 and every later release give it
const ortApiVersion = 23;

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

/// How a session uses the processor
class OrtSessionSettings {
  const OrtSessionSettings({required this.intraOpThreads, this.interOpThreads = 1, this.allowSpinning = false});

  /// The settings of the design for a computer with [logicalProcessors]: all of them but two for one pass
  factory OrtSessionSettings.forProcessors(int logicalProcessors) =>
      OrtSessionSettings(intraOpThreads: math.max(1, logicalProcessors - 2));

  /// [OrtSessionSettings.forProcessors] for this computer
  factory OrtSessionSettings.forThisComputer() => OrtSessionSettings.forProcessors(Platform.numberOfProcessors);

  final int intraOpThreads;
  final int interOpThreads;

  /// Whether ONNX Runtime's threads keep spinning between two passes (session.intra_op.allow_spinning)
  final bool allowSpinning;
}

/// An input or an output of a model: its name, its element type (ONNXTensorElementDataType) and its shape, -1 for a
/// dimension the model leaves free
class OrtTensorSpec {
  const OrtTensorSpec(this.name, this.elementType, this.shape);

  final String name;
  final int elementType;
  final List<int> shape;

  bool get isFloat => elementType == ort.ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;

  @override
  String toString() => '$name $shape';
}

/// A float32 tensor given by a session
class OrtTensor {
  const OrtTensor(this.shape, this.values);

  final List<int> shape;
  final Float32List values;
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
  /// OrtMemoryInfo...): an open session holds one OrtEnv and one OrtSession, a pass leaves nothing
  @visibleForTesting
  Map<String, int> get liveObjects => Map.unmodifiable(_calls.live);

  /// A session on the model at [modelPath]. Throws [OrtException] with ONNX Runtime's message when the model cannot
  /// be read.
  OrtSession openSession(String modelPath, {OrtSessionSettings? settings}) =>
      OrtSession._open(this, modelPath, settings ?? OrtSessionSettings.forThisComputer());
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
        final optionsOut = arena<Pointer<ort.OrtSessionOptions>>();
        calls.check(calls.createSessionOptions(optionsOut), 'CreateSessionOptions');
        calls.made('OrtSessionOptions');
        final options = optionsOut.value;
        try {
          calls.check(calls.setIntraOpNumThreads(options, settings.intraOpThreads), 'SetIntraOpNumThreads');
          calls.check(calls.setInterOpNumThreads(options, settings.interOpThreads), 'SetInterOpNumThreads');
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
    final count = shape.fold(1, (total, dimension) => total * dimension);
    if (count != values.length) {
      throw ArgumentError('A tensor of shape $shape holds $count values, not ${values.length}');
    }
    final calls = runtime._calls;
    return using((arena) {
      final data = arena<Float>(values.isEmpty ? 1 : values.length);
      data.asTypedList(values.length).setAll(0, values);
      final dimensions = arena<Int64>(shape.isEmpty ? 1 : shape.length);
      for (var i = 0; i < shape.length; i++) {
        dimensions[i] = shape[i];
      }
      final memoryInfoOut = arena<Pointer<ort.OrtMemoryInfo>>();
      calls.check(
        calls.createCpuMemoryInfo(
          ort.OrtAllocatorType.OrtArenaAllocator,
          ort.OrtMemType.OrtMemTypeDefault,
          memoryInfoOut,
        ),
        'CreateCpuMemoryInfo',
      );
      calls.made('OrtMemoryInfo');
      final memoryInfo = memoryInfoOut.value;
      // Zeroed by the arena (calloc), so that the finally below sees null for a value never made
      final inputOut = arena<Pointer<ort.OrtValue>>();
      final outputOut = arena<Pointer<ort.OrtValue>>();
      try {
        calls.check(
          calls.createTensorWithDataAsOrtValue(
            memoryInfo,
            data.cast(),
            values.length * sizeOf<Float>(),
            dimensions,
            shape.length,
            ort.ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
            inputOut,
          ),
          'CreateTensorWithDataAsOrtValue',
        );
        calls.made('OrtValue');
        final inputName = arena<Pointer<Char>>()..value = inputs.first.name.toNativeUtf8(allocator: arena).cast();
        final outputName = arena<Pointer<Char>>()..value = outputs.first.name.toNativeUtf8(allocator: arena).cast();
        calls.check(calls.run(_session, nullptr, inputName, inputOut, 1, outputName, 1, outputOut), 'Run');
        calls.made('OrtValue');
        final output = outputOut.value;
        final infoOut = arena<Pointer<ort.OrtTensorTypeAndShapeInfo>>();
        calls.check(calls.getTensorTypeAndShape(output, infoOut), 'GetTensorTypeAndShape');
        calls.made('OrtTensorTypeAndShapeInfo');
        final OrtTensorSpec described;
        try {
          described = calls.describe(outputs.first.name, infoOut.value);
        } finally {
          calls.releaseTensorTypeAndShapeInfo(infoOut.value);
        }
        if (!described.isFloat) {
          throw OrtException(
            'The output ${described.name} of $modelPath is not float32 (type ${described.elementType})',
          );
        }
        final outputCount = described.shape.fold(1, (total, dimension) => total * dimension);
        final dataOut = arena<Pointer<Void>>();
        calls.check(calls.getTensorMutableData(output, dataOut), 'GetTensorMutableData');
        final result = Float32List.fromList(dataOut.value.cast<Float>().asTypedList(outputCount));
        return OrtTensor(described.shape, result);
      } finally {
        if (outputOut.value != nullptr) {
          calls.releaseValue(outputOut.value);
        }
        if (inputOut.value != nullptr) {
          calls.releaseValue(inputOut.value);
        }
        calls.releaseMemoryInfo(memoryInfo);
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

  late final createSessionOptions = _api.ref.CreateSessionOptions
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<Pointer<ort.OrtSessionOptions>>)>();
  late final setIntraOpNumThreads = _api.ref.SetIntraOpNumThreads
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtSessionOptions>, int)>();
  late final setInterOpNumThreads = _api.ref.SetInterOpNumThreads
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtSessionOptions>, int)>();
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

  late final createCpuMemoryInfo = _api.ref.CreateCpuMemoryInfo
      .asFunction<Pointer<ort.OrtStatus> Function(int, int, Pointer<Pointer<ort.OrtMemoryInfo>>)>();
  late final releaseMemoryInfo = _counted(
    'OrtMemoryInfo',
    _api.ref.ReleaseMemoryInfo.asFunction<void Function(Pointer<ort.OrtMemoryInfo>)>(),
  );
  late final createTensorWithDataAsOrtValue = _api.ref.CreateTensorWithDataAsOrtValue
      .asFunction<
        Pointer<ort.OrtStatus> Function(
          Pointer<ort.OrtMemoryInfo>,
          Pointer<Void>,
          int,
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
  late final getTensorMutableData = _api.ref.GetTensorMutableData
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtValue>, Pointer<Pointer<Void>>)>();
  late final releaseValue = _counted(
    'OrtValue',
    _api.ref.ReleaseValue.asFunction<void Function(Pointer<ort.OrtValue>)>(),
  );

  /// The native objects made and not given back yet, by kind ([OrtRuntime.liveObjects])
  final live = <String, int>{};

  /// Counts one native object of [kind], made by the call that just succeeded
  void made(String kind) => live[kind] = (live[kind] ?? 0) + 1;

  /// Counts one native object of [kind] given back
  void given(String kind) => live[kind] = (live[kind] ?? 0) - 1;

  /// [release], counting the object it gives back
  void Function(Pointer<T>) _counted<T extends NativeType>(String kind, void Function(Pointer<T>) release) => (object) {
    given(kind);
    release(object);
  };

  /// Throws the OrtException of [status] when it is not null, after releasing it
  void check(Pointer<ort.OrtStatus> status, String call) {
    if (status == nullptr) {
      return;
    }
    try {
      throw OrtException('$call: ${_string(getErrorMessage(status))}', code: getErrorCode(status));
    } finally {
      releaseStatus(status);
    }
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
