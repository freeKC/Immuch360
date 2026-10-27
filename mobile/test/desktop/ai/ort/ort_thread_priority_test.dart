// The threads of a real ONNX Runtime session at a low priority (lot A4b, design-final 2026-10-26, section 2.6, point
// 6): opened as the worker opens it, the threads born with the session are lowered (nice 10 on Linux,
// THREAD_PRIORITY_BELOW_NORMAL on Windows) and the threads that were there before are left as they were. A file of its
// own, so that the session is the only one of its process. Needs IMMUCH360_ORT_LIB (ort_for_tests.dart).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/engine/thread_priority.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_depth_backend.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';

import 'ort_for_tests.dart';

void main() {
  final ort = ortForTests();

  test('the threads born with the session lowered, the others left as they were', () {
    final system = ThreadPriorityPlatform.system();
    final priority = ComputePriority(system);
    const intraOp = 3;
    final backend = OrtDepthBackend(
      libraryPath: ort.library!,
      modelPath: tinyDepthModelPath(),
      settings: const OrtSessionSettings(intraOpThreads: intraOp),
    );
    addTearDown(backend.close);
    // The library first, as the worker loads it, so that the threads its loading starts are there before
    OrtRuntime.load(ort.library!);
    final before = system.threads()!;
    final priorities = {for (final id in before.keys) id: system.priorityOf(id)};

    final lowered = openWithLowThreads(backend, priority);

    expect(backend.isOpen, isTrue);
    // On Linux the session's threads carry the name the opening thread lent them; Windows gives no names
    final after = system.threads()!;
    final born = {
      for (final MapEntry(key: id, value: name) in after.entries)
        if (!before.containsKey(id) && (!Platform.isLinux || name == sessionThreadName)) id,
    };
    // Intra-op 3: the calling thread and two of the session's own; 1.31.0 starts one more at the first session. Windows
    // may start threads of its own meanwhile, which it does not name
    expect(born.length, Platform.isLinux ? inInclusiveRange(intraOp - 1, intraOp) : greaterThanOrEqualTo(intraOp - 1));
    expect(lowered, born.length);
    for (final id in born) {
      expect(system.priorityOf(id), Platform.isWindows ? windowsBelowNormal : linuxComputeNice, reason: 'thread $id');
    }
    for (final MapEntry(key: id, value: was) in priorities.entries) {
      final now = system.priorityOf(id);
      if (now != null) {
        expect(now, was, reason: 'thread $id was there before the session');
      }
    }

    // Open already: nothing more
    expect(openWithLowThreads(backend, priority), 0);
    // Closed, then opened again by the next job: its new threads lowered too
    backend.close();
    final again = openWithLowThreads(backend, priority);
    expect(again, Platform.isLinux ? intraOp - 1 : greaterThanOrEqualTo(intraOp - 1));
  }, skip: ort.skip ?? (Platform.isMacOS ? 'macOS leaves the threads as they are in phase 1' : null));
}
