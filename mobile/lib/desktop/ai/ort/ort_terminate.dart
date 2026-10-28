// Stops a run of ONNX Runtime from another isolate (design-final 2026-10-27, sections 2.5 and 4.5, lot C1). A pass of
// MoGe or of LaMa lasts seconds; the isolate that runs it is blocked in Run, so the flag it reads between two steps
// (isolate_cancel.dart) cannot reach it until the pass ends. The isolate that runs the model makes the options of the
// runs of its job (OrtRunOptions, ort_session.dart) and sends their handle, plain numbers, to the root isolate; when the
// job is cancelled, the root isolate calls RunOptionsSetTerminate here, through its own binding of the same library,
// which the worker already loaded in the process. ONNX Runtime looks at the stop before each node it runs, inside a
// Loop too, and Run gives an error; the session turns it into OrtRunStopped, since the flag kept next to the options
// says a stop was asked.
//
// The options must outlive every call made here: the worker gives them back only once the root isolate has said it
// will not stop them any more (ai_worker.dart). This file opens no OrtEnv: the telemetry of ONNX Runtime starts with
// the first OrtEnv, which only the worker makes, after turning the telemetry off (ort_session.dart).

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_api_bindings.dart' as ort;
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';

/// What another isolate needs to stop the runs of one OrtRunOptions: the library, the address of the options and the
/// address of the flag that says a stop was asked. Plain values, sent in a message.
class OrtRunStopHandle {
  const OrtRunStopHandle({required this.libraryPath, required this.optionsAddress, required this.askedAddress});

  final String libraryPath;
  final int optionsAddress;
  final int askedAddress;

  @override
  String toString() => 'OrtRunStopHandle(0x${optionsAddress.toRadixString(16)} of $libraryPath)';
}

/// Stops the runs of the options of [handle], from any isolate of the process
final class OrtRunStopper {
  OrtRunStopper(this.handle);

  final OrtRunStopHandle handle;
  var _stopped = false;

  /// Whether [stop] was called
  bool get stopped => _stopped;

  /// Raises the flag next to the options, then asks ONNX Runtime to end the run in progress at its next node, and
  /// every later run with the same options at once. A second call does nothing. Throws [OrtLoadException] when the
  /// library cannot be bound here, [OrtException] when ONNX Runtime refuses.
  void stop() {
    if (_stopped) {
      return;
    }
    _stopped = true;
    Pointer<Int32>.fromAddress(handle.askedAddress).value = 1;
    final calls = _StopCalls.of(handle.libraryPath);
    calls.check(calls.setTerminate(Pointer<ort.OrtRunOptions>.fromAddress(handle.optionsAddress)));
  }
}

/// RunOptionsSetTerminate of one library, bound once per isolate
final class _StopCalls {
  _StopCalls(this._api);

  static final _bound = <String, _StopCalls>{};

  static _StopCalls of(String libraryPath) => _bound[libraryPath] ??= _bind(libraryPath);

  static _StopCalls _bind(String libraryPath) {
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
    final api = base == nullptr
        ? nullptr
        : base.ref.GetApi.asFunction<Pointer<ort.OrtApi> Function(int)>()(ortApiVersion);
    if (api == nullptr) {
      throw OrtLoadException('$libraryPath does not give API $ortApiVersion');
    }
    return _StopCalls(api);
  }

  final Pointer<ort.OrtApi> _api;

  late final setTerminate = _api.ref.RunOptionsSetTerminate
      .asFunction<Pointer<ort.OrtStatus> Function(Pointer<ort.OrtRunOptions>)>();
  late final _getErrorMessage = _api.ref.GetErrorMessage.asFunction<Pointer<Char> Function(Pointer<ort.OrtStatus>)>();
  late final _getErrorCode = _api.ref.GetErrorCode.asFunction<int Function(Pointer<ort.OrtStatus>)>();
  late final _releaseStatus = _api.ref.ReleaseStatus.asFunction<void Function(Pointer<ort.OrtStatus>)>();

  /// Throws the OrtException of [status] when it is not null, after releasing it
  void check(Pointer<ort.OrtStatus> status) {
    if (status == nullptr) {
      return;
    }
    final text = _getErrorMessage(status).cast<Utf8>();
    final message = text == nullptr
        ? ''
        : utf8.decode(text.cast<Uint8>().asTypedList(text.length), allowMalformed: true);
    final code = _getErrorCode(status);
    _releaseStatus(status);
    throw OrtException('RunOptionsSetTerminate: $message', code: code);
  }
}
