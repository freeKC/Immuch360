import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// A stop flag the isolates of a scan or of a hash run read between files. It lives in native memory, which every
/// isolate of the process sees, so the isolate that asks for the stop does not have to wait for a message to reach a
/// worker busy reading a file: the worker sees the flag at its next chunk.
class NativeCancelFlag {
  NativeCancelFlag() : _flag = calloc<Int32>();

  final Pointer<Int32> _flag;
  var _freed = false;

  /// What the workers are given: the address of the flag
  int get address => _flag.address;

  bool get isCancelled => !_freed && _flag.value != 0;

  void cancel() {
    if (!_freed) {
      _flag.value = 1;
    }
  }

  /// Once no worker reads it any more
  void free() {
    if (!_freed) {
      _freed = true;
      calloc.free(_flag);
    }
  }

  /// The reader a worker builds from [address]
  static bool Function() readerOf(int address) {
    final flag = Pointer<Int32>.fromAddress(address);
    return () => flag.value != 0;
  }
}
