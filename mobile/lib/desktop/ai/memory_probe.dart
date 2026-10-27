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
//
// The queue runs two lanes, the processor and the graphics card (design-final 2026-10-27, section 4.5): a job starts
// beside the one under way on the other lane only when the memory a program can take now covers its own need
// ([jobMemoryNeedOf], per kind) and a reserve for the job under way ([secondLaneReserve]); otherwise it waits for that
// job to end.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

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

const _mib = 1024 * 1024;
const _gib = 1024 * _mib;

/// What the job of a 3D scene needs at its peak: MoGe-2 ViT-S at 2 500 tokens took 1.35 GB with the arena of ONNX
/// Runtime off, then LaMa 0.91 GB beside the 0.28 GB MoGe keeps, some 1.6 GB with the pictures of a 12 Mpx photo
/// (M2 on ai1, which proposed 2 GiB)
const sceneJobMemory = 2 * _gib;

/// What the job of a 360° panorama needs of the memory of the computer at its peak: stable-diffusion.cpp took up to
/// 6 GiB of private memory with the text encoder on the processor (M3 on the RTX 4060 Laptop), plus the pictures of the
/// upscale and of the photo pasted back
const panoramaJobMemory = 6 * _gib + 512 * _mib;

/// What the job of a 360° 3D panorama needs at its peak: the panorama decoded and its copy (8192 x 4096, 4 bytes a
/// pixel), the two eyes and the copy the encoder works on (4096 x 4096), the maps of the tangent views and the session
/// of the depth model
const stereoPanoramaJobMemory = 2 * 4 * 8192 * 4096 + 2 * 4 * 4096 * 4096 + 64 * _mib + depthSessionMemory + 64 * _mib;

/// What a job that makes a file of [kind] needs at its peak, told before it runs, to decide whether it may run beside
/// a job of the other lane: a 3D photo of 24 Mpx with its session to open for the 3D photo, whose own job then checks
/// the size of its photo (jobMemoryNeed)
int jobMemoryNeedOf(ImmersiveKind kind) => switch (kind) {
  ImmersiveKind.stereoPhoto => jobMemoryNeed(
    sourceWidth: 6000,
    sourceHeight: 4000,
    eyeWidth: 6000,
    eyeHeight: 4000,
    sessionOpen: false,
  ),
  ImmersiveKind.volumetricScene => sceneJobMemory,
  ImmersiveKind.panorama360 => panoramaJobMemory,
  ImmersiveKind.stereoPanorama360 => stereoPanoramaJobMemory,
};

/// What is kept free for the job under way on the other lane when a second one starts: M3 saw the free memory of
/// Windows go down to 871 MiB while stable-diffusion.cpp ran, and proposed that the lane of the processor waits under
/// 3 GiB free, the need of a scene and this reserve
const secondLaneReserve = _gib;

/// Whether a job that needs [need] bytes may start beside a job of the other lane, the memory being [facts]: always
/// when the system does not say what is available (macOS), as the gate
bool fitsBeside(int need, MemoryFacts facts) {
  final available = facts.available;
  return available == null || available >= need + secondLaneReserve;
}
