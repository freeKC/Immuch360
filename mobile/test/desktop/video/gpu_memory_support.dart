// The GPU memory of this process on Windows, for the measurement harness (integration_test/
// desktop_video_measure_test.dart): the "GPU Process Memory" counters of the performance data, the figures Task Manager
// shows as dedicated and shared GPU memory.
//
// Why: ProcessInfo.currentRss is the working set, which leaves out what the graphics driver holds for the process,
// the decoder surfaces and the textures above all. On an integrated GPU (the Intel UHD of the owner's laptop) those
// sit in shared system memory, the same 16 GB the app, Windows and WSL live in, so the 8K memory risk of plan 2.7 is
// only measured with these counters next to the working set.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// An instance of the counters: `pid_<process>_luid_<adapter LUID high>_<low>_phys_<physical adapter>`
final _instance = RegExp(r'^pid_(\d+)_luid_(0x[0-9A-Fa-f]+_0x[0-9A-Fa-f]+)_phys_\d+$');

/// The bytes of the instances of [pid] in [values] (instance name to bytes), added up per adapter LUID
Map<String, int> bytesByAdapter(Map<String, int> values, int pid) {
  final adapters = <String, int>{};
  for (final MapEntry(key: name, :value) in values.entries) {
    final match = _instance.firstMatch(name);
    if (match == null || int.parse(match.group(1)!) != pid) {
      continue;
    }
    final luid = match.group(2)!.toLowerCase();
    adapters[luid] = (adapters[luid] ?? 0) + value;
  }
  return adapters;
}

/// One sample in MiB: the totals, then per adapter (LUID) when the process uses more than one
Map<String, Object?> gpuMemoryRecord({required Map<String, int> shared, required Map<String, int> dedicated}) {
  int mib(int bytes) => bytes ~/ (1 << 20);
  int total(Map<String, int> bytes) => bytes.values.fold(0, (sum, value) => sum + value);
  final adapters = {...shared.keys, ...dedicated.keys}.toList()..sort();
  return {
    'sharedMB': mib(total(shared)),
    'dedicatedMB': mib(total(dedicated)),
    if (adapters.length > 1)
      'adapters': {
        for (final luid in adapters)
          luid: {'sharedMB': mib(shared[luid] ?? 0), 'dedicatedMB': mib(dedicated[luid] ?? 0)},
      },
  };
}

typedef _OpenQueryNative = Uint32 Function(Pointer<Utf16> source, IntPtr userData, Pointer<IntPtr> query);
typedef _OpenQuery = int Function(Pointer<Utf16> source, int userData, Pointer<IntPtr> query);
typedef _AddCounterNative =
    Uint32 Function(IntPtr query, Pointer<Utf16> path, IntPtr userData, Pointer<IntPtr> counter);
typedef _AddCounter = int Function(int query, Pointer<Utf16> path, int userData, Pointer<IntPtr> counter);
typedef _HandleNative = Uint32 Function(IntPtr handle);
typedef _Handle = int Function(int handle);
typedef _CounterArrayNative =
    Uint32 Function(IntPtr counter, Uint32 format, Pointer<Uint32> size, Pointer<Uint32> count, Pointer<Uint8> items);
typedef _CounterArray =
    int Function(int counter, int format, Pointer<Uint32> size, Pointer<Uint32> count, Pointer<Uint8> items);

/// Reads the counters through pdh.dll. English counter names (PdhAddEnglishCounterW): the owner's Windows is in
/// French, where the localised names differ. The query stays open between samples: the first one loads the counter
/// providers and takes seconds, the next ones only collect.
abstract final class GpuProcessMemory {
  static const _counters = ['Shared Usage', 'Dedicated Usage'];
  static const _formatLarge = 0x00000400;
  static const _moreData = 0x800007D2;

  // PDH_FMT_COUNTERVALUE_ITEM_W on 64 bit Windows: the instance name, then CStatus and the 8 byte value
  static const _itemSize = 24;
  static const _statusOffset = 8;
  static const _valueOffset = 16;

  static _Pdh? _pdh;
  static int? _query;
  static List<int>? _handles;

  /// The GPU memory of [pid] (this process by default), as [gpuMemoryRecord] gives it; null off Windows, and a map
  /// holding "error" when the counters cannot be read
  static Map<String, Object?>? sample([int? pid]) {
    if (!Platform.isWindows) {
      return null;
    }
    try {
      final values = _read();
      final process = pid ?? _currentPid();
      return gpuMemoryRecord(
        shared: bytesByAdapter(values['Shared Usage']!, process),
        dedicated: bytesByAdapter(values['Dedicated Usage']!, process),
      );
    } catch (error) {
      close();
      return {'error': '$error'};
    }
  }

  /// Closes the query; the next sample opens it again
  static void close() {
    final query = _query;
    _query = null;
    _handles = null;
    if (query != null) {
      _pdh?.closeQuery(query);
    }
  }

  static int _currentPid() =>
      DynamicLibrary.open('kernel32.dll').lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId')();

  static void _check(int status, String call) {
    if (status != 0) {
      throw StateError('$call: PDH status 0x${status.toRadixString(16)}');
    }
  }

  /// Opens the query and adds the counters, once
  static (int, List<int>) _open(_Pdh pdh) {
    if (_query != null) {
      return (_query!, _handles!);
    }
    final query = calloc<IntPtr>();
    try {
      _check(pdh.openQuery(nullptr, 0, query), 'PdhOpenQueryW');
      final handles = <int>[];
      for (final name in _counters) {
        final path = '\\GPU Process Memory(*)\\$name'.toNativeUtf16();
        final handle = calloc<IntPtr>();
        try {
          final status = pdh.addCounter(query.value, path, 0, handle);
          if (status != 0) {
            pdh.closeQuery(query.value);
            _check(status, 'PdhAddEnglishCounterW $name');
          }
          handles.add(handle.value);
        } finally {
          calloc.free(path);
          calloc.free(handle);
        }
      }
      _query = query.value;
      _handles = handles;
      return (query.value, handles);
    } finally {
      calloc.free(query);
    }
  }

  /// Every instance of each counter now: counter name, then instance name to bytes
  static Map<String, Map<String, int>> _read() {
    final pdh = _pdh ??= _Pdh(DynamicLibrary.open('pdh.dll'));
    final (query, handles) = _open(pdh);
    _check(pdh.collect(query), 'PdhCollectQueryData');
    final values = <String, Map<String, int>>{};
    final size = calloc<Uint32>();
    final count = calloc<Uint32>();
    try {
      for (final (index, name) in _counters.indexed) {
        size.value = 0;
        count.value = 0;
        final status = pdh.counterArray(handles[index], _formatLarge, size, count, nullptr);
        if (status != _moreData) {
          _check(status, 'PdhGetFormattedCounterArrayW');
        }
        final items = calloc<Uint8>(size.value == 0 ? 1 : size.value);
        try {
          _check(pdh.counterArray(handles[index], _formatLarge, size, count, items), 'PdhGetFormattedCounterArrayW');
          final instances = values[name] = <String, int>{};
          for (var i = 0; i < count.value; i++) {
            final item = items + i * _itemSize;
            // PDH_CSTATUS_VALID_DATA and PDH_CSTATUS_NEW_DATA; an instance that went away meanwhile is skipped
            if ((item + _statusOffset).cast<Uint32>().value > 1) {
              continue;
            }
            final instance = item.cast<Pointer<Utf16>>().value.toDartString();
            instances[instance] = (item + _valueOffset).cast<Int64>().value;
          }
        } finally {
          calloc.free(items);
        }
      }
      return values;
    } finally {
      calloc.free(size);
      calloc.free(count);
    }
  }
}

/// The functions of pdh.dll the counters need
class _Pdh {
  _Pdh(DynamicLibrary pdh)
    : openQuery = pdh.lookupFunction<_OpenQueryNative, _OpenQuery>('PdhOpenQueryW'),
      addCounter = pdh.lookupFunction<_AddCounterNative, _AddCounter>('PdhAddEnglishCounterW'),
      collect = pdh.lookupFunction<_HandleNative, _Handle>('PdhCollectQueryData'),
      closeQuery = pdh.lookupFunction<_HandleNative, _Handle>('PdhCloseQuery'),
      counterArray = pdh.lookupFunction<_CounterArrayNative, _CounterArray>('PdhGetFormattedCounterArrayW');

  final _OpenQuery openQuery;
  final _AddCounter addCounter;
  final _Handle collect;
  final _Handle closeQuery;
  final _CounterArray counterArray;
}
