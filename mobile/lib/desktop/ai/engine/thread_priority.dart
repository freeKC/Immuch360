// The threads of a 3D conversion at a low priority, so that the app stays usable while a photo is computed (spec 5.3;
// design-final 2026-10-26, section 2.6, point 6). Two cores are left free by the settings of the session already
// (intra-op threads = logical processors minus two); this file lowers the threads themselves:
//
// | System  | Threads of ONNX Runtime                                   | Thread of the worker isolate during a job      |
// |---------|-----------------------------------------------------------|------------------------------------------------|
// | Windows | THREAD_PRIORITY_BELOW_NORMAL by SetThreadPriority on the  | the same during the synchronous body of the    |
// |         | threads that appear while the session opens (Toolhelp     | job, put back at its end                       |
// |         | snapshots before and after, kernel32 by FFI)              |                                                |
// | Linux   | nice 10 by setpriority on the threads that appear in      | unchanged: Linux does not let a thread come    |
// |         | /proc/self/task while the session opens                   | back to 0 without a privilege, and the thread  |
// |         |                                                           | serves other isolates afterwards               |
// | macOS   | unchanged in phase 1 (the quality of service of another   | unchanged                                      |
// |         | thread is not set without native code)                    |                                                |
//
// The body of a job runs as one synchronous event of its isolate, so its thread does not change on the way.
//
// Which threads are the session's: on Linux a thread takes the name of the thread that creates it, so the opening
// thread carries the name [sessionThreadName] for the time of the call, and only the threads born with that name are
// lowered. A thread the Dart VM starts meanwhile for another isolate (DartWorker, named by the VM) is left as it is:
// it serves the rest of the app afterwards. Measured on ai1: ONNX Runtime 1.23.2 starts intra-op minus one threads
// with the session, 1.31.0 one more at the first session of the process; all of them carry the name. Windows gives
// its threads no inherited name: every thread born during the call is lowered there, which the call being short
// (some 0.8 s) makes a thread of another isolate unlikely.
//
// Every call on the system goes through ThreadPriorityPlatform, so that a test sees each one with a fake.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The name the opening thread lends to the threads of the session on Linux (15 characters at most)
const sessionThreadName = 'immuch360-ai';

/// What a program can do with the priority of its own threads, on one system
abstract interface class ThreadPriorityPlatform {
  /// The platform of this computer; plain objects, sent to the worker isolate of the jobs
  factory ThreadPriorityPlatform.system() {
    if (Platform.isWindows) {
      return const WindowsThreadPriority();
    }
    if (Platform.isLinux) {
      return const LinuxThreadPriority();
    }
    return const UnchangedThreadPriority();
  }

  /// The threads of this process now, by id, with their names where the system gives them; null where they are not
  /// listed (macOS)
  Map<int, String?>? threads();

  /// Names the calling thread [name], so that the threads it creates meanwhile carry it, and gives what puts its own
  /// name back; null where threads do not take the name of their creator (Windows, macOS)
  void Function()? nameCurrentThread(String name);

  /// Gives the thread [id] the priority of a background computation; false when the system refused or the thread is
  /// gone
  bool lowerThread(int id);

  /// Lowers the calling thread and gives what puts it back, to be called on the same thread; null where the calling
  /// thread is left as it is
  void Function()? lowerCurrentThread();

  /// The priority of the thread [id] as the system writes it (Windows: -1 is below normal; Linux: its nice value),
  /// for the tests and the logs; null where not read
  int? priorityOf(int id);

  /// The id of the calling thread, null where not read
  int? currentThreadId();
}

/// The priorities of the jobs, on [platform]
class ComputePriority {
  const ComputePriority(this.platform);

  final ThreadPriorityPlatform platform;

  /// Runs [open], the call that makes the threads of a session, then lowers the threads it made: those born
  /// meanwhile, with the name [sessionThreadName] where threads take the name of their creator. Gives what [open]
  /// gave and how many threads were lowered. A failure of [open] lowers nothing: its threads are gone with it.
  ({T value, int lowered}) lowerThreadsBornDuring<T>(T Function() open) {
    final before = platform.threads();
    if (before == null) {
      return (value: open(), lowered: 0);
    }
    final restoreName = platform.nameCurrentThread(sessionThreadName);
    final T value;
    try {
      value = open();
    } finally {
      restoreName?.call();
    }
    var lowered = 0;
    for (final MapEntry(key: id, value: name) in (platform.threads() ?? const <int, String?>{}).entries) {
      if (before.containsKey(id) || (restoreName != null && name != sessionThreadName)) {
        continue;
      }
      if (platform.lowerThread(id)) {
        lowered++;
      }
    }
    return (value: value, lowered: lowered);
  }

  /// Runs [body] with the calling thread lowered where the system allows it back, and put back after, even when
  /// [body] throws
  T whileLowered<T>(T Function() body) {
    final restore = platform.lowerCurrentThread();
    try {
      return body();
    } finally {
      restore?.call();
    }
  }
}

/// macOS, and any other system: nothing is changed
class UnchangedThreadPriority implements ThreadPriorityPlatform {
  const UnchangedThreadPriority();

  @override
  Map<int, String?>? threads() => null;

  @override
  void Function()? nameCurrentThread(String name) => null;

  @override
  bool lowerThread(int id) => false;

  @override
  void Function()? lowerCurrentThread() => null;

  @override
  int? priorityOf(int id) => null;

  @override
  int? currentThreadId() => null;
}

// --- Linux ------------------------------------------------------------------------------------------------------------

/// The nice value of a background computation
const linuxComputeNice = 10;

// PRIO_PROCESS: with the id of a thread, setpriority changes that thread only (setpriority(2), NOTES)
const _prioProcess = 0;

typedef _SetPriorityNative = Int32 Function(Int32, Uint32, Int32);
typedef _SetPriority = int Function(int, int, int);

/// The functions of libc, looked up once per isolate
final _setPriority = DynamicLibrary.process().lookupFunction<_SetPriorityNative, _SetPriority>('setpriority');

class LinuxThreadPriority implements ThreadPriorityPlatform {
  const LinuxThreadPriority();

  @override
  Map<int, String?>? threads() {
    final found = <int, String?>{};
    for (final entry in Directory('/proc/self/task').listSync()) {
      final id = int.tryParse(entry.path.split('/').last);
      if (id == null) {
        continue;
      }
      String? name;
      try {
        name = File('/proc/self/task/$id/comm').readAsStringSync().trim();
      } on FileSystemException {
        // Gone meanwhile
        continue;
      }
      found[id] = name;
    }
    return found;
  }

  @override
  void Function()? nameCurrentThread(String name) {
    // The calling thread's own entry: /proc/thread-self (Linux 3.17), its name 15 characters at most
    final comm = File('/proc/thread-self/comm');
    try {
      final previous = comm.readAsStringSync().trim();
      comm.writeAsStringSync(name);
      return () {
        try {
          comm.writeAsStringSync(previous);
        } on FileSystemException {
          // The name only serves the diagnostics
        }
      };
    } on FileSystemException {
      return null;
    }
  }

  @override
  bool lowerThread(int id) {
    final nice = priorityOf(id);
    if (nice == null) {
      return false;
    }
    // Already as low or lower: setting 10 would raise it, which needs a privilege
    if (nice >= linuxComputeNice) {
      return true;
    }
    return _setPriority(_prioProcess, id, linuxComputeNice) == 0;
  }

  @override
  void Function()? lowerCurrentThread() => null;

  @override
  int? priorityOf(int id) {
    try {
      return parseTaskStatNice(File('/proc/self/task/$id/stat').readAsStringSync());
    } on FileSystemException {
      return null;
    }
  }

  @override
  int? currentThreadId() {
    try {
      // /proc/thread-self leads to /proc/<pid>/task/<tid>
      return int.tryParse(Link('/proc/thread-self').resolveSymbolicLinksSync().split('/').last);
    } on FileSystemException {
      return null;
    }
  }
}

/// The nice value in [stat], the content of `/proc/<pid>/task/<tid>/stat` (proc(5)): field 19, counted after the
/// name in parentheses, which may hold spaces and parentheses itself
int? parseTaskStatNice(String stat) {
  final close = stat.lastIndexOf(')');
  if (close < 0) {
    return null;
  }
  // Fields 3 on: state, ppid, pgrp, session, tty_nr, tpgid, flags, minflt, cminflt, majflt, cmajflt, utime, stime,
  // cutime, cstime, priority, nice
  final fields = stat.substring(close + 1).trim().split(RegExp(r'\s+'));
  return fields.length > 16 ? int.tryParse(fields[16]) : null;
}

// --- Windows ----------------------------------------------------------------------------------------------------------

/// THREAD_PRIORITY_BELOW_NORMAL
const windowsBelowNormal = -1;

const _snapThread = 0x00000004; // TH32CS_SNAPTHREAD
const _invalidHandle = -1; // INVALID_HANDLE_VALUE
const _threadSetLimited = 0x0400; // THREAD_SET_LIMITED_INFORMATION
const _threadQueryLimited = 0x0800; // THREAD_QUERY_LIMITED_INFORMATION
const _priorityError = 0x7FFFFFFF; // THREAD_PRIORITY_ERROR_RETURN

// THREADENTRY32: dwSize, cntUsage, th32ThreadID, th32OwnerProcessID, tpBasePri, tpDeltaPri, dwFlags
const _threadEntryLength = 28;
const _threadEntryId = 8;
const _threadEntryOwner = 12;

typedef _SnapshotNative = IntPtr Function(Uint32, Uint32);
typedef _Snapshot = int Function(int, int);
typedef _ThreadWalkNative = Int32 Function(IntPtr, Pointer<Uint8>);
typedef _ThreadWalk = int Function(int, Pointer<Uint8>);
typedef _HandleNative = Int32 Function(IntPtr);
typedef _Handle = int Function(int);
typedef _NoArgumentNative = Uint32 Function();
typedef _NoArgument = int Function();
typedef _OpenThreadNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenThread = int Function(int, int, int);
typedef _SetThreadPriorityNative = Int32 Function(IntPtr, Int32);
typedef _SetThreadPriority = int Function(int, int);
typedef _CurrentThreadNative = IntPtr Function();
typedef _CurrentThread = int Function();

/// The functions of kernel32, looked up once per isolate
final class _Kernel32 {
  _Kernel32() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    snapshot = kernel32.lookupFunction<_SnapshotNative, _Snapshot>('CreateToolhelp32Snapshot');
    threadFirst = kernel32.lookupFunction<_ThreadWalkNative, _ThreadWalk>('Thread32First');
    threadNext = kernel32.lookupFunction<_ThreadWalkNative, _ThreadWalk>('Thread32Next');
    closeHandle = kernel32.lookupFunction<_HandleNative, _Handle>('CloseHandle');
    processId = kernel32.lookupFunction<_NoArgumentNative, _NoArgument>('GetCurrentProcessId');
    threadId = kernel32.lookupFunction<_NoArgumentNative, _NoArgument>('GetCurrentThreadId');
    openThread = kernel32.lookupFunction<_OpenThreadNative, _OpenThread>('OpenThread');
    setPriority = kernel32.lookupFunction<_SetThreadPriorityNative, _SetThreadPriority>('SetThreadPriority');
    getPriority = kernel32.lookupFunction<_HandleNative, _Handle>('GetThreadPriority');
    currentThread = kernel32.lookupFunction<_CurrentThreadNative, _CurrentThread>('GetCurrentThread');
  }

  late final _Snapshot snapshot;
  late final _ThreadWalk threadFirst;
  late final _ThreadWalk threadNext;
  late final _Handle closeHandle;
  late final _NoArgument processId;
  late final _NoArgument threadId;
  late final _OpenThread openThread;
  late final _SetThreadPriority setPriority;
  late final _Handle getPriority;
  late final _CurrentThread currentThread;
}

final _kernel32 = _Kernel32();

class WindowsThreadPriority implements ThreadPriorityPlatform {
  const WindowsThreadPriority();

  @override
  Map<int, String?>? threads() {
    final k = _kernel32;
    // Every thread of the system: those of this process are kept
    final snapshot = k.snapshot(_snapThread, 0);
    if (snapshot == _invalidHandle) {
      return null;
    }
    try {
      return using((arena) {
        final entry = arena<Uint8>(_threadEntryLength);
        final process = k.processId();
        final found = <int, String?>{};
        entry.cast<Uint32>().value = _threadEntryLength;
        var more = k.threadFirst(snapshot, entry) != 0;
        while (more) {
          if ((entry + _threadEntryOwner).cast<Uint32>().value == process) {
            found[(entry + _threadEntryId).cast<Uint32>().value] = null;
          }
          entry.cast<Uint32>().value = _threadEntryLength;
          more = k.threadNext(snapshot, entry) != 0;
        }
        return found;
      });
    } finally {
      k.closeHandle(snapshot);
    }
  }

  @override
  void Function()? nameCurrentThread(String name) => null;

  @override
  bool lowerThread(int id) {
    final k = _kernel32;
    final thread = k.openThread(_threadSetLimited | _threadQueryLimited, 0, id);
    if (thread == 0) {
      return false;
    }
    try {
      return k.setPriority(thread, windowsBelowNormal) != 0;
    } finally {
      k.closeHandle(thread);
    }
  }

  @override
  void Function()? lowerCurrentThread() {
    final k = _kernel32;
    // A pseudo handle, valid on the calling thread only, never closed
    final previous = k.getPriority(k.currentThread());
    if (previous == _priorityError || previous <= windowsBelowNormal) {
      return null;
    }
    if (k.setPriority(k.currentThread(), windowsBelowNormal) == 0) {
      return null;
    }
    return () => k.setPriority(k.currentThread(), previous);
  }

  @override
  int? priorityOf(int id) {
    final k = _kernel32;
    final thread = k.openThread(_threadQueryLimited, 0, id);
    if (thread == 0) {
      return null;
    }
    try {
      final priority = k.getPriority(thread);
      return priority == _priorityError ? null : priority;
    } finally {
      k.closeHandle(thread);
    }
  }

  @override
  int? currentThreadId() => _kernel32.threadId();
}
