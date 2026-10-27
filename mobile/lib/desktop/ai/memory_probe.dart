// The memory of this computer, for the AI features (design-final 2026-10-26, sections 2.6 and 2.9): the physical
// memory the hardware gate asks for before it offers the button, and the memory a program can take now, which a job
// checks against what its photo needs before it decodes it. A photo of 24 Mpx takes some 800 MB at the peak of its job,
// one of 48 Mpx twice that: a job that cannot have it would make the system swap and the app unusable (spec 5.3), so
// it ends with "not enough memory" instead.
//
// Read from the system without a plugin, as native_sha1.dart and library_scanner.dart do:
//  - Windows: GlobalMemoryStatusEx of kernel32 (ullTotalPhys, and ullAvailPhys, which counts the standby list);
//  - Linux: /proc/meminfo (MemTotal, and MemAvailable, the kernel's own estimate, page cache included);
//  - macOS: sysctl hw.memsize for the physical memory. macOS keeps most of its memory busy with caches and compresses
//    the rest, and gives no simple "available" figure: none is read there, and a job is not checked against it.
// A probe that fails gives nothing rather than a guess: the gate and the jobs then do not refuse on memory.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// What the memory of a computer is, in bytes
class MemoryFacts {
  const MemoryFacts({this.physical, this.available});

  /// The physical memory, as the system counts it; null when it could not be read
  final int? physical;

  /// What a program can take now without the system swapping; null where the system does not say it simply (macOS)
  final int? available;

  @override
  String toString() => 'MemoryFacts(physical: $physical, available: $available)';
}

/// Reads the memory of this computer; a fake stands for it in the tests. Plain objects, sent to the worker isolate of
/// the jobs with the rest of its tools.
abstract interface class MemoryProbe {
  MemoryFacts read();
}

/// The probe of the operating system
class SystemMemoryProbe implements MemoryProbe {
  const SystemMemoryProbe();

  @override
  MemoryFacts read() {
    try {
      if (Platform.isWindows) {
        return _windows();
      }
      if (Platform.isLinux) {
        return parseProcMeminfo(File('/proc/meminfo').readAsStringSync());
      }
      if (Platform.isMacOS) {
        return MemoryFacts(physical: _macosMemsize());
      }
    } on Object {
      // A missing symbol or file: nothing known
    }
    return const MemoryFacts();
  }
}

/// The facts of [text], the content of /proc/meminfo (proc(5)): MemTotal and MemAvailable, in kB there. A kernel older
/// than 3.14 has no MemAvailable: nothing is guessed from the other lines.
MemoryFacts parseProcMeminfo(String text) {
  int? field(String name) {
    final match = RegExp('^$name:\\s+(\\d+)\\s*kB', multiLine: true).firstMatch(text);
    return match == null ? null : int.parse(match.group(1)!) * 1024;
  }

  return MemoryFacts(physical: field('MemTotal'), available: field('MemAvailable'));
}

// MEMORYSTATUSEX: dwLength, dwMemoryLoad, then seven DWORDLONG from ullTotalPhys on
const _memoryStatusLength = 64;
const _totalPhysOffset = 8;
const _availPhysOffset = 16;

typedef _GlobalMemoryStatusExNative = Int32 Function(Pointer<Uint8>);
typedef _GlobalMemoryStatusEx = int Function(Pointer<Uint8>);

MemoryFacts _windows() {
  final call = DynamicLibrary.open(
    'kernel32.dll',
  ).lookupFunction<_GlobalMemoryStatusExNative, _GlobalMemoryStatusEx>('GlobalMemoryStatusEx');
  return using((arena) {
    final status = arena<Uint8>(_memoryStatusLength);
    final data = status.cast<Uint32>();
    data.value = _memoryStatusLength;
    if (call(status) == 0) {
      return const MemoryFacts();
    }
    return MemoryFacts(
      physical: (status + _totalPhysOffset).cast<Uint64>().value,
      available: (status + _availPhysOffset).cast<Uint64>().value,
    );
  });
}

typedef _SysctlByNameNative = Int32 Function(Pointer<Utf8>, Pointer<Void>, Pointer<Size>, Pointer<Void>, Size);
typedef _SysctlByName = int Function(Pointer<Utf8>, Pointer<Void>, Pointer<Size>, Pointer<Void>, int);

int? _macosMemsize() {
  final call = DynamicLibrary.process().lookupFunction<_SysctlByNameNative, _SysctlByName>('sysctlbyname');
  return using((arena) {
    final value = arena<Uint64>();
    final length = arena<Size>()..value = sizeOf<Uint64>();
    if (call('hw.memsize'.toNativeUtf8(allocator: arena), value.cast(), length, nullptr, 0) != 0) {
      return null;
    }
    return value.value;
  });
}

/// The least physical memory the AI features run with: a computer sold with 4 GB. Such a computer reports 3.6 to 3.9
/// GiB once the firmware and the graphics took their share, hence 3.5 GiB and not 4.
const aiMinimumPhysicalMemory = 3584 * 1024 * 1024;

/// The memory the model session holds while it is open (ONNX Runtime and Depth Anything V2 Small, measured at about
/// 300 MB), counted for a job that has to open it
const depthSessionMemory = 350 * 1024 * 1024;

/// What the job of an original of [sourceWidth] x [sourceHeight] pixels, made into an eye of [eyeWidth] x [eyeHeight],
/// needs at its peak, in bytes: the decoded original and its turned or reduced copy (4 bytes a pixel each), the pair
/// (two eyes, 4 bytes a pixel), the copy of the pair the encoder works on and the JPEG it writes, the input and the
/// map of the model, plus the session when it is not open yet and a margin for the rest of the job.
int jobMemoryNeed({
  required int sourceWidth,
  required int sourceHeight,
  required int eyeWidth,
  required int eyeHeight,
  bool sessionOpen = true,
}) {
  final source = sourceWidth * sourceHeight;
  final eye = eyeWidth * eyeHeight;
  return 2 * 4 * source + // decoded, then turned or reduced
      2 * 4 * eye + // the pair
      2 * 4 * eye + // the copy the encoder works on
      2 * eye + // the JPEG, generously
      16 * 1024 * 1024 + // the input and the map of the model
      (sessionOpen ? 0 : depthSessionMemory) +
      64 * 1024 * 1024;
}
