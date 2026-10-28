// The priority of a program the AI features start, lowered so that the app stays smooth while it computes for minutes
// (design-final 2026-10-27, section 4.5, point 2): "below normal" on Windows (SetPriorityClass, kernel32 by FFI as
// thread_priority.dart does for the threads of ONNX Runtime), nice 10 on Linux and macOS (setpriority of libc).
//
// managed_process.dart calls it only where nothing else did it before the program ran: on Windows the job object of
// the program sets its priority class (process_job_object.dart), on Linux the launcher immuch360-run sets the nice
// value before it becomes the program, which every thread then inherits. On Linux, setpriority on a process id lowers
// its main thread only, and the threads it starts afterwards: hence the launcher first.

import 'dart:ffi';
import 'dart:io';

/// Lowers the priority of a running process
abstract interface class ProcessPriority {
  /// Lowers the process [pid]; false when the system refused
  bool lower(int pid);
}

/// The nice value of a lowered program on Linux and macOS
const lowProcessNice = 10;

const _belowNormalPriorityClass = 0x00004000; // BELOW_NORMAL_PRIORITY_CLASS
const _processSetInformation = 0x0200; // PROCESS_SET_INFORMATION
const _prioProcess = 0; // PRIO_PROCESS, on Linux and macOS

typedef _OpenProcessNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcess = int Function(int, int, int);
typedef _SetPriorityClassNative = Int32 Function(IntPtr, Uint32);
typedef _SetPriorityClass = int Function(int, int);
typedef _HandleNative = Int32 Function(IntPtr);
typedef _Handle = int Function(int);
typedef _SetPriorityNative = Int32 Function(Int32, Uint32, Int32);
typedef _SetPriority = int Function(int, int, int);

/// The priority of the system this runs on
final class SystemProcessPriority implements ProcessPriority {
  const SystemProcessPriority();

  @override
  bool lower(int pid) => Platform.isWindows ? _lowerWindows(pid) : _lowerPosix(pid);

  static bool _lowerWindows(int pid) {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final open = kernel32.lookupFunction<_OpenProcessNative, _OpenProcess>('OpenProcess');
    final setClass = kernel32.lookupFunction<_SetPriorityClassNative, _SetPriorityClass>('SetPriorityClass');
    final close = kernel32.lookupFunction<_HandleNative, _Handle>('CloseHandle');
    final process = open(_processSetInformation, 0, pid);
    if (process == 0) {
      return false;
    }
    try {
      return setClass(process, _belowNormalPriorityClass) != 0;
    } finally {
      close(process);
    }
  }

  static bool _lowerPosix(int pid) {
    final setPriority = DynamicLibrary.process().lookupFunction<_SetPriorityNative, _SetPriority>('setpriority');
    return setPriority(_prioProcess, pid, lowProcessNice) == 0;
  }
}
