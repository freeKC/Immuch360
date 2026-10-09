// The GPU memory counters of the measurement harness (gpu_memory_support.dart): how the instances of the "GPU
// Process Memory" counters are added up, and on Windows that pdh.dll answers.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'gpu_memory_support.dart';

void main() {
  group('bytesByAdapter', () {
    test('keeps the instances of the process and adds them up per adapter', () {
      final values = {
        'pid_4242_luid_0x00000000_0x0000D3F1_phys_0': 300 << 20,
        'pid_4242_luid_0x00000000_0x0000d3f1_phys_1': 100 << 20,
        'pid_4242_luid_0x00000000_0x00011A2B_phys_0': 50 << 20,
        'pid_42_luid_0x00000000_0x0000D3F1_phys_0': 999 << 20,
        'pid_424242_luid_0x00000000_0x0000D3F1_phys_0': 999 << 20,
        '_Total': 1 << 30,
      };
      expect(bytesByAdapter(values, 4242), {'0x00000000_0x0000d3f1': 400 << 20, '0x00000000_0x00011a2b': 50 << 20});
      expect(bytesByAdapter(values, 7), isEmpty);
    });
  });

  group('gpuMemoryRecord', () {
    test('totals in MiB, and the adapters only when the process uses more than one', () {
      expect(gpuMemoryRecord(shared: {'a': 300 << 20}, dedicated: {}), {'sharedMB': 300, 'dedicatedMB': 0});
      expect(gpuMemoryRecord(shared: {'a': 300 << 20, 'b': (1 << 20) + 5}, dedicated: {'b': 2 << 30}), {
        'sharedMB': 301,
        'dedicatedMB': 2048,
        'adapters': {
          'a': {'sharedMB': 300, 'dedicatedMB': 0},
          'b': {'sharedMB': 1, 'dedicatedMB': 2048},
        },
      });
    });
  });

  test('reads the counters of this process on Windows, then again from the same query', () {
    final first = Stopwatch()..start();
    final sample = GpuProcessMemory.sample();
    first.stop();
    expect(sample, isNotNull);
    expect(sample!['error'], isNull, reason: '$sample');
    expect(sample['sharedMB'], isA<int>());
    expect(sample['dedicatedMB'], isA<int>());
    final again = Stopwatch()..start();
    final next = GpuProcessMemory.sample();
    again.stop();
    printOnFailure('first sample ${first.elapsedMilliseconds} ms, next ${again.elapsedMilliseconds} ms');
    expect(next!['error'], isNull, reason: '$next');
    // The harness samples between and during its phases: the open query must keep that cheap
    expect(again.elapsed, lessThan(const Duration(seconds: 2)));
    GpuProcessMemory.close();
  }, skip: Platform.isWindows ? false : 'pdh.dll is Windows only');

  test('is null off Windows', () {
    expect(GpuProcessMemory.sample(), isNull);
  }, skip: Platform.isWindows ? 'Windows reads the counters' : false);
}
