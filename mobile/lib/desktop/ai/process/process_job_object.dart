// A Windows job object for each program the AI features start (sd-cli of stable-diffusion.cpp, lot P2; design-final
// 2026-10-27, section 4.5, point 3). The job is made with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, the program is put in it
// right after it starts, and the app holds the one handle of the job: when the app ends, a crash or a kill from the Task
// Manager included, Windows closes the handle and ends every process of the job, so no sd-cli is left holding the
// memory of the graphics card. "Causes all processes associated with the job to terminate when the last handle to the
// job is closed" (https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_basic_limit_information).
// The job also gives its processes the "below normal" priority class when asked, so that the app stays smooth while
// the graphics card and the processor work for minutes.
//
// Also here, for the journal of managed_process.dart: whether a process id is still running, and the path of its
// program. kernel32 by FFI, as thread_priority.dart.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// A job whose processes end when it is closed
abstract interface class ProcessJobObject {
  /// Puts the process [pid] in the job; false when Windows refused (the process is gone, or a job it is in forbids
  /// another)
  bool assign(int pid);

  /// Closes the handle of the job: every process still in it ends
  void close();
}

/// Makes the job of one program, "below normal" when [lowPriority]; null when Windows refused
typedef ProcessJobObjects = ProcessJobObject? Function({required bool lowPriority});

const _jobObjectExtendedLimitInformation = 9; // JOBOBJECTINFOCLASS
const _limitPriorityClass = 0x00000020; // JOB_OBJECT_LIMIT_PRIORITY_CLASS
const _limitKillOnJobClose = 0x00002000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
const _belowNormalPriorityClass = 0x00004000; // BELOW_NORMAL_PRIORITY_CLASS
const _processTerminate = 0x0001; // PROCESS_TERMINATE
const _processSetQuota = 0x0100; // PROCESS_SET_QUOTA
const _processQueryLimited = 0x1000; // PROCESS_QUERY_LIMITED_INFORMATION
const _stillActive = 259; // STILL_ACTIVE

// JOBOBJECT_EXTENDED_LIMIT_INFORMATION on x64: JOBOBJECT_BASIC_LIMIT_INFORMATION (64 bytes: two LARGE_INTEGER, LimitFlags
// at 16, the working set sizes, ActiveProcessLimit, Affinity, PriorityClass at 56, SchedulingClass), IO_COUNTERS (48)
// and four SIZE_T
const _extendedLimitLength = 144;
const _limitFlagsOffset = 16;
const _priorityClassOffset = 56;

typedef _CreateJobNative = IntPtr Function(Pointer<Void>, Pointer<Utf16>);
typedef _CreateJob = int Function(Pointer<Void>, Pointer<Utf16>);
typedef _SetJobInformationNative = Int32 Function(IntPtr, Int32, Pointer<Uint8>, Uint32);
typedef _SetJobInformation = int Function(int, int, Pointer<Uint8>, int);
typedef _OpenProcessNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcess = int Function(int, int, int);
typedef _AssignNative = Int32 Function(IntPtr, IntPtr);
typedef _Assign = int Function(int, int);
typedef _HandleNative = Int32 Function(IntPtr);
typedef _Handle = int Function(int);
typedef _ExitCodeNative = Int32 Function(IntPtr, Pointer<Uint32>);
typedef _ExitCode = int Function(int, Pointer<Uint32>);
typedef _ImageNameNative = Int32 Function(IntPtr, Uint32, Pointer<Utf16>, Pointer<Uint32>);
typedef _ImageName = int Function(int, int, Pointer<Utf16>, Pointer<Uint32>);

/// The functions of kernel32, looked up once
final class _Kernel32 {
  _Kernel32() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    createJob = kernel32.lookupFunction<_CreateJobNative, _CreateJob>('CreateJobObjectW');
    setJobInformation = kernel32.lookupFunction<_SetJobInformationNative, _SetJobInformation>(
      'SetInformationJobObject',
    );
    openProcess = kernel32.lookupFunction<_OpenProcessNative, _OpenProcess>('OpenProcess');
    assign = kernel32.lookupFunction<_AssignNative, _Assign>('AssignProcessToJobObject');
    closeHandle = kernel32.lookupFunction<_HandleNative, _Handle>('CloseHandle');
    exitCode = kernel32.lookupFunction<_ExitCodeNative, _ExitCode>('GetExitCodeProcess');
    imageName = kernel32.lookupFunction<_ImageNameNative, _ImageName>('QueryFullProcessImageNameW');
  }

  static final instance = _Kernel32();

  late final _CreateJob createJob;
  late final _SetJobInformation setJobInformation;
  late final _OpenProcess openProcess;
  late final _Assign assign;
  late final _Handle closeHandle;
  late final _ExitCode exitCode;
  late final _ImageName imageName;
}

/// The job object of one program on Windows
final class WindowsJobObject implements ProcessJobObject {
  WindowsJobObject._(this._handle);

  int _handle;

  /// A new job that kills its processes when closed, and lowers them to "below normal" when [lowPriority]; null when
  /// Windows refused
  static WindowsJobObject? create({required bool lowPriority}) {
    final kernel32 = _Kernel32.instance;
    final handle = kernel32.createJob(nullptr, nullptr);
    if (handle == 0) {
      return null;
    }
    final info = calloc<Uint8>(_extendedLimitLength);
    try {
      final view = ByteData.sublistView(info.asTypedList(_extendedLimitLength));
      view.setUint32(_limitFlagsOffset, _limitKillOnJobClose | (lowPriority ? _limitPriorityClass : 0), Endian.little);
      if (lowPriority) {
        view.setUint32(_priorityClassOffset, _belowNormalPriorityClass, Endian.little);
      }
      if (kernel32.setJobInformation(handle, _jobObjectExtendedLimitInformation, info, _extendedLimitLength) == 0) {
        kernel32.closeHandle(handle);
        return null;
      }
    } finally {
      calloc.free(info);
    }
    return WindowsJobObject._(handle);
  }

  @override
  bool assign(int pid) {
    if (_handle == 0) {
      return false;
    }
    final kernel32 = _Kernel32.instance;
    final process = kernel32.openProcess(_processSetQuota | _processTerminate, 0, pid);
    if (process == 0) {
      return false;
    }
    try {
      return kernel32.assign(_handle, process) != 0;
    } finally {
      kernel32.closeHandle(process);
    }
  }

  @override
  void close() {
    if (_handle != 0) {
      _Kernel32.instance.closeHandle(_handle);
      _handle = 0;
    }
  }
}

/// The job of a program on Windows ([ProcessJobObjects])
ProcessJobObject? windowsJobObject({required bool lowPriority}) => WindowsJobObject.create(lowPriority: lowPriority);

/// The full path of the program the process [pid] runs, null when no such process runs any more (Windows)
String? windowsProcessImage(int pid) {
  final kernel32 = _Kernel32.instance;
  final process = kernel32.openProcess(_processQueryLimited, 0, pid);
  if (process == 0) {
    return null;
  }
  final code = calloc<Uint32>();
  final size = calloc<Uint32>();
  final name = calloc<Uint16>(32768).cast<Utf16>();
  try {
    if (kernel32.exitCode(process, code) == 0 || code.value != _stillActive) {
      return null;
    }
    size.value = 32768;
    if (kernel32.imageName(process, 0, name, size) == 0) {
      return null;
    }
    return name.toDartString(length: size.value);
  } finally {
    kernel32.closeHandle(process);
    calloc.free(code);
    calloc.free(size);
    calloc.free(name);
  }
}
