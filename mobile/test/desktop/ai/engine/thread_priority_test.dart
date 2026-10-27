import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/thread_priority.dart';

import '../fakes/fake_thread_priority.dart';

void main() {
  group('the threads born while a session opens', () {
    test('lowered, those that were there before left as they were (Windows: no names to tell them by)', () {
      final system = FakeThreadPriority(threads: {1: 'immuch360', 2: '1.ui', 3: 'DartWorker'});
      final opened = ComputePriority(system).lowerThreadsBornDuring(() {
        system.current.addAll({10: 'immuch360', 11: 'immuch360', 12: null});
        return 'session';
      });
      expect(opened.value, 'session');
      expect(opened.lowered, 3);
      expect(system.calls, ['threads', 'threads', 'lower 10', 'lower 11', 'lower 12']);
    });

    test('Linux: only the threads born from the opening thread, which lends them its name for the call', () {
      final system = FakeThreadPriority(threads: {1: 'main', 2: 'DartWorker'}, namesThreads: true);
      final opened = ComputePriority(system).lowerThreadsBornDuring(() {
        // Two threads of the session take the name of the thread that creates them; the VM starts one for another
        // isolate meanwhile and names it itself
        system.current.addAll({20: system.callingName, 21: 'DartWorker', 22: system.callingName});
      });
      expect(opened.lowered, 2);
      expect(system.calls, ['threads', 'name immuch360-ai', 'name main', 'threads', 'lower 20', 'lower 22']);
      expect(system.callingName, 'main');
    });

    test('Linux: the name of the opening thread put back when the opening fails', () {
      final system = FakeThreadPriority(threads: {1: 'main'}, namesThreads: true);
      expect(
        () => ComputePriority(system).lowerThreadsBornDuring<void>(() => throw StateError('no model')),
        throwsStateError,
      );
      expect(system.calls, ['threads', 'name immuch360-ai', 'name main']);
      expect(system.callingName, 'main');
    });

    test('a thread that refuses or is gone is not counted', () {
      final system = FakeThreadPriority(threads: {1: 'a'})..refused.add(31);
      final opened = ComputePriority(system).lowerThreadsBornDuring(() => system.current.addAll({30: 'b', 31: 'c'}));
      expect(opened.lowered, 1);
      expect(system.calls, ['threads', 'threads', 'lower 30', 'lower 31']);
    });

    test('a system that does not list its threads (macOS): the session opens, nothing is lowered', () {
      final system = FakeThreadPriority(threads: {1: 'a'}, listsThreads: false);
      final opened = ComputePriority(system).lowerThreadsBornDuring(() => system.current[40] = 'b');
      expect(opened.lowered, 0);
      expect(system.calls, ['threads']);
    });

    test('an opening that fails lowers nothing and says why', () {
      final system = FakeThreadPriority(threads: {1: 'a'});
      expect(
        () => ComputePriority(system).lowerThreadsBornDuring<void>(() {
          system.current[50] = 'b';
          throw StateError('no model');
        }),
        throwsStateError,
      );
      expect(system.calls, ['threads']);
    });
  });

  group('the thread of the job', () {
    test('lowered for the body and put back after it, on the system that allows it back', () {
      final system = FakeThreadPriority();
      final value = ComputePriority(system).whileLowered(() {
        system.calls.add('body');
        return 7;
      });
      expect(value, 7);
      expect(system.calls, ['lowerCurrent', 'body', 'restore']);
    });

    test('put back when the body throws', () {
      final system = FakeThreadPriority();
      expect(
        () => ComputePriority(system).whileLowered<void>(() => throw const FormatException('broken')),
        throwsFormatException,
      );
      expect(system.calls, ['lowerCurrent', 'restore']);
    });

    test('left as it is where the system would not give it back (Linux, macOS)', () {
      final system = FakeThreadPriority(lowersCurrentThread: false);
      ComputePriority(system).whileLowered(() => system.calls.add('body'));
      expect(system.calls, ['lowerCurrent', 'body']);
    });
  });

  test('the nice value of a line of /proc/<pid>/task/<tid>/stat, whatever its name holds', () {
    const stat =
        '4242 (a (weird) name) S 1 4242 4242 0 -1 4194560 120 0 0 0 3 1 0 0 30 10 7 0 123456 1000000 300 '
        '18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 0 17 3 0 0 0 0 0';
    expect(parseTaskStatNice(stat), 10);
    expect(parseTaskStatNice('12 (x) R 1 12 12 0 -1 0 0 0 0 0 0 0 0 0 20 0 1'), 0);
    expect(parseTaskStatNice('broken'), isNull);
  });

  group('the system of this computer', () {
    final system = ThreadPriorityPlatform.system();

    test('the right layer for each system', () {
      expect(
        system,
        Platform.isWindows
            ? isA<WindowsThreadPriority>()
            : Platform.isLinux
            ? isA<LinuxThreadPriority>()
            : isA<UnchangedThreadPriority>(),
      );
    });

    test('lists the threads of this process, the calling one among them', () {
      final threads = system.threads()!;
      expect(threads, isNotEmpty);
      expect(threads.keys, contains(system.currentThreadId()));
    }, skip: Platform.isMacOS ? 'macOS does not list them' : null);

    test('Windows lowers the calling thread for the body and puts it back', () {
      final id = system.currentThreadId()!;
      final before = system.priorityOf(id);
      final during = ComputePriority(system).whileLowered(() => system.priorityOf(id));
      expect(during, windowsBelowNormal);
      expect(system.priorityOf(id), before);
    }, skip: Platform.isWindows ? null : 'Windows only');

    test('Linux names the calling thread for a while, and gives its name back', () {
      final comm = File('/proc/thread-self/comm');
      final before = comm.readAsStringSync().trim();
      final restore = system.nameCurrentThread(sessionThreadName)!;
      expect(comm.readAsStringSync().trim(), sessionThreadName);
      restore();
      expect(comm.readAsStringSync().trim(), before);
    }, skip: Platform.isLinux ? null : 'Linux only');

    test('Linux leaves the calling thread as it is', () {
      final id = system.currentThreadId()!;
      final before = system.priorityOf(id);
      final during = ComputePriority(system).whileLowered(() => system.priorityOf(id));
      expect((during, system.priorityOf(id)), (before, before));
    }, skip: Platform.isLinux ? null : 'Linux only');
  });
}
