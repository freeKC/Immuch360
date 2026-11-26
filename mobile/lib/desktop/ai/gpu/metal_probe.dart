// The graphics of a Mac for the AI features (lot L35 of the desktop parity plan, release 53): macOS has no Vulkan, so
// the probe of the cards (gpu_probe.dart) answers notSupported there, and the levels of "Enhance (AI)" that run on the
// graphics (Sharpen and Rebuild details, through the Metal build of stable-diffusion.cpp) ask Metal itself.
//
// Read in the app's process through the Objective-C runtime, no plugin and no child process (creating the default Metal
// device allocates nothing on it): MTLCreateSystemDefaultDevice of Metal.framework, then of that device
//  - name: "Apple M2 Pro" on a Mac, "Apple Paravirtual device" on the virtual Macs of GitHub's runners;
//  - recommendedMaxWorkingSetSize: what Metal advises one process to keep in use on the GPU, about two thirds to three
//    quarters of the memory on Apple silicon, where the GPU shares the memory of the computer (unified memory);
//  - hasUnifiedMemory;
//  - supportsFamily: MTLGPUFamilyApple7 (1007), the family of the M1 and every later Apple chip, which
//    stable-diffusion.cpp asks for its int8 matrix products on Metal (docs/guides/int8_convrot.md at 0d71f963: "Metal
//    supports INT8 tensorwise and convrot on Apple silicon (Apple GPU family 7 or newer)"), the format of the weights of
//    SeedVR2 that Rebuild details runs.
// Anything that fails (another system, a missing symbol, no device) gives null: the levels of the graphics then say the
// graphics of this Mac cannot be used.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// MTLGPUFamilyApple7 of MTLDevice.h
const metalGpuFamilyApple7 = 1007;

/// What Metal says of the GPU of a Mac (see the top of this file)
class MetalFacts {
  const MetalFacts({required this.name, required this.workingSet, required this.unifiedMemory, required this.apple7});

  final String name;

  /// recommendedMaxWorkingSetSize, in bytes
  final int workingSet;
  final bool unifiedMemory;

  /// Whether the GPU is of MTLGPUFamilyApple7 or later
  final bool apple7;

  Map<String, Object> toJson() => {
    'name': name,
    'recommendedMaxWorkingSetSize': workingSet,
    'hasUnifiedMemory': unifiedMemory,
    'apple7': apple7,
  };

  @override
  String toString() => 'MetalFacts($name, working set $workingSet, unified $unifiedMemory, Apple7 $apple7)';
}

/// Reads the GPU of this Mac; a fake stands for it in the tests
abstract interface class MetalProbe {
  MetalFacts? read();
}

typedef _CreateDevice = Pointer<Void> Function();
typedef _SelectorNative = Pointer<Void> Function(Pointer<Utf8>);
typedef _MessageU64Native = Uint64 Function(Pointer<Void>, Pointer<Void>);
typedef _MessageU64 = int Function(Pointer<Void>, Pointer<Void>);
typedef _MessageBoolNative = Uint8 Function(Pointer<Void>, Pointer<Void>);
typedef _MessageBool = int Function(Pointer<Void>, Pointer<Void>);
typedef _MessageBoolArgNative = Uint8 Function(Pointer<Void>, Pointer<Void>, Int64);
typedef _MessageBoolArg = int Function(Pointer<Void>, Pointer<Void>, int);
typedef _MessagePointerNative = Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _MessageVoidNative = Void Function(Pointer<Void>, Pointer<Void>);
typedef _MessageVoid = void Function(Pointer<Void>, Pointer<Void>);
typedef _MessageSelectorNative = Uint8 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _MessageSelector = int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);

/// The probe of Metal on this Mac (see the top of this file)
class SystemMetalProbe implements MetalProbe {
  const SystemMetalProbe();

  @override
  MetalFacts? read() {
    if (!Platform.isMacOS) {
      return null;
    }
    try {
      return _read();
    } on Object {
      return null;
    }
  }

  MetalFacts? _read() {
    final metal = DynamicLibrary.open('/System/Library/Frameworks/Metal.framework/Metal');
    final objc = DynamicLibrary.open('/usr/lib/libobjc.A.dylib');
    final create = metal.lookupFunction<_CreateDevice, _CreateDevice>('MTLCreateSystemDefaultDevice');
    final selector = objc.lookupFunction<_SelectorNative, _SelectorNative>('sel_registerName');
    // objc_msgSend called with the exact prototype of each method, as arm64 requires
    final sendU64 = objc.lookupFunction<_MessageU64Native, _MessageU64>('objc_msgSend');
    final sendBool = objc.lookupFunction<_MessageBoolNative, _MessageBool>('objc_msgSend');
    final sendBoolArg = objc.lookupFunction<_MessageBoolArgNative, _MessageBoolArg>('objc_msgSend');
    final sendPointer = objc.lookupFunction<_MessagePointerNative, _MessagePointerNative>('objc_msgSend');
    final sendVoid = objc.lookupFunction<_MessageVoidNative, _MessageVoid>('objc_msgSend');
    final responds = objc.lookupFunction<_MessageSelectorNative, _MessageSelector>('objc_msgSend');
    Pointer<Void> sel(String name) => using((arena) => selector(name.toNativeUtf8(allocator: arena)));

    final device = create();
    if (device == nullptr) {
      return null;
    }
    try {
      final nameObject = sendPointer(device, sel('name'));
      final utf8 = nameObject == nullptr ? nullptr : sendPointer(nameObject, sel('UTF8String')).cast<Utf8>();
      final family = sel('supportsFamily:');
      return MetalFacts(
        name: utf8 == nullptr ? '' : utf8.toDartString(),
        workingSet: sendU64(device, sel('recommendedMaxWorkingSetSize')),
        unifiedMemory: sendBool(device, sel('hasUnifiedMemory')) != 0,
        apple7:
            responds(device, sel('respondsToSelector:'), family) != 0 &&
            sendBoolArg(device, family, metalGpuFamilyApple7) != 0,
      );
    } finally {
      // MTLCreateSystemDefaultDevice returns a device the caller owns
      sendVoid(device, sel('release'));
    }
  }
}
