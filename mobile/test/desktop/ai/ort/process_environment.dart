// The environment of this process as the system holds it, where ONNX Runtime reads its variables (getenv, or
// GetEnvironmentVariableW on Windows). Platform.environment is a copy made when the process started: it does not see
// what ort_session.dart sets through FFI.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The value of [name] in the environment of the process, null when it is not set
String? processVariable(String name) => using((arena) {
  if (Platform.isWindows) {
    final getVariable = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          Uint32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, Pointer<Utf16>, int)
        >('GetEnvironmentVariableW');
    const capacity = 32767;
    final buffer = arena<Uint16>(capacity).cast<Utf16>();
    final length = getVariable(name.toNativeUtf16(allocator: arena), buffer, capacity);
    return length == 0 ? null : buffer.toDartString(length: length);
  }
  final getenv = DynamicLibrary.process()
      .lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>('getenv');
  final value = getenv(name.toNativeUtf8(allocator: arena));
  return value == nullptr ? null : value.toDartString();
});

/// Sets [name] to [value] in the environment of the process, or removes it when [value] is null
void setProcessVariable(String name, String? value) => using((arena) {
  final bool done;
  if (Platform.isWindows) {
    final setVariable = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<Int32 Function(Pointer<Utf16>, Pointer<Utf16>), int Function(Pointer<Utf16>, Pointer<Utf16>)>(
          'SetEnvironmentVariableW',
        );
    final text = value == null ? nullptr : value.toNativeUtf16(allocator: arena);
    done = setVariable(name.toNativeUtf16(allocator: arena), text) != 0;
  } else if (value == null) {
    final unsetenv = DynamicLibrary.process().lookupFunction<Int Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>(
      'unsetenv',
    );
    done = unsetenv(name.toNativeUtf8(allocator: arena)) == 0;
  } else {
    final setenv = DynamicLibrary.process()
        .lookupFunction<
          Int Function(Pointer<Utf8>, Pointer<Utf8>, Int),
          int Function(Pointer<Utf8>, Pointer<Utf8>, int)
        >('setenv');
    done = setenv(name.toNativeUtf8(allocator: arena), value.toNativeUtf8(allocator: arena), 1) == 0;
  }
  if (!done) {
    throw StateError('$name could not be ${value == null ? 'removed from' : 'set in'} the environment of the process');
  }
});
