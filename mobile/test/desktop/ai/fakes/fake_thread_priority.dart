// A system layer of thread priorities without any system: a list of threads the test changes, and every call
// recorded, so that the tests see what the engine asks on each system.

import 'package:immich_mobile/desktop/ai/engine/thread_priority.dart';

class FakeThreadPriority implements ThreadPriorityPlatform {
  FakeThreadPriority({
    Map<int, String?>? threads,
    this.listsThreads = true,
    this.lowersCurrentThread = true,
    this.namesThreads = false,
  }) : current = {...?threads};

  /// The threads of the fake process now, by id and name
  final Map<int, String?> current;

  /// macOS does not list them
  final bool listsThreads;

  /// Windows lowers the calling thread, Linux and macOS leave it
  final bool lowersCurrentThread;

  /// Linux: a thread takes the name of its creator, and the calling thread can be named
  final bool namesThreads;

  /// The name of the calling thread now
  String callingName = 'main';

  /// Threads that refuse to be lowered (gone, or a system that says no)
  final refused = <int>{};

  /// Every call, in order: "threads", "name immuch360-ai", "lower 12", "lowerCurrent", "restore"
  final calls = <String>[];

  @override
  Map<int, String?>? threads() {
    calls.add('threads');
    return listsThreads ? Map.of(current) : null;
  }

  @override
  void Function()? nameCurrentThread(String name) {
    if (!namesThreads) {
      return null;
    }
    calls.add('name $name');
    final previous = callingName;
    callingName = name;
    return () {
      calls.add('name $previous');
      callingName = previous;
    };
  }

  @override
  bool lowerThread(int id) {
    calls.add('lower $id');
    return !refused.contains(id);
  }

  @override
  void Function()? lowerCurrentThread() {
    calls.add('lowerCurrent');
    return lowersCurrentThread ? () => calls.add('restore') : null;
  }

  @override
  int? priorityOf(int id) => null;

  @override
  int? currentThreadId() => null;
}
