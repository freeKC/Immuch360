// Whether the computer runs on its battery, for the 360° panoramas (design-final 2026-10-27, section 4.7, point 5): a
// generation keeps the graphics card busy for several minutes, so the dialog asks before one starts on battery ("On
// battery: a panorama keeps the graphics card busy for several minutes"). Read from the system without a plugin, as
// memory_probe.dart does:
//  - Windows: GetSystemPowerStatus of kernel32, ACLineStatus (0 on battery, 1 on the mains, 255 unknown) and
//    BatteryFlag (128: no system battery, a desktop);
//  - Linux: /sys/class/power_supply, a mains supply (Mains, USB) online meaning plugged in, a battery of the system
//    (not the battery of a mouse, scope Device) discharging meaning on battery;
//  - macOS: not read, the panoramas waiting for a lot of their own there.
// Unknown is null: nothing is asked then.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Reads whether the computer runs on its battery; a fake stands for it in the tests
abstract interface class PowerProbe {
  /// True on battery, false on the mains or without a battery, null when the system does not tell
  bool? onBattery();
}

/// The probe of the operating system
class SystemPowerProbe implements PowerProbe {
  const SystemPowerProbe();

  @override
  bool? onBattery() {
    try {
      if (Platform.isWindows) {
        return _windows();
      }
      if (Platform.isLinux) {
        return onBatteryFromPowerSupply(Directory('/sys/class/power_supply'));
      }
    } on Object {
      // A missing symbol or folder: not known
    }
    return null;
  }
}

/// The probe of the app; replaced in tests
final aiPowerProbeProvider = Provider<PowerProbe>((ref) => const SystemPowerProbe());

/// Whether a computer runs on its battery after what GetSystemPowerStatus says
bool? onBatteryFromPowerStatus({required int acLineStatus, required int batteryFlag}) {
  if (batteryFlag == 128) {
    return false;
  }
  return switch (acLineStatus) {
    0 => true,
    1 => false,
    _ => null,
  };
}

/// Whether a computer runs on its battery after the supplies of [folder] (/sys/class/power_supply): false with a
/// mains supply online or without any battery of the system, true with one discharging, false when its batteries say
/// they charge or are full, null when they say nothing
bool? onBatteryFromPowerSupply(Directory folder) {
  if (!folder.existsSync()) {
    return null;
  }
  String? read(Directory supply, String name) {
    final file = File('${supply.path}/$name');
    try {
      return file.existsSync() ? file.readAsStringSync().trim() : null;
    } on FileSystemException {
      return null;
    }
  }

  var batteries = 0;
  final statuses = <String>{};
  for (final entry in folder.listSync()) {
    final supply = Directory(entry.path);
    final type = read(supply, 'type');
    if ((type == 'Mains' || type == 'USB') && read(supply, 'online') == '1') {
      return false;
    }
    if (type == 'Battery' && read(supply, 'scope') != 'Device') {
      batteries++;
      final status = read(supply, 'status');
      if (status != null && status != 'Unknown') {
        statuses.add(status);
      }
    }
  }
  if (batteries == 0) {
    return false;
  }
  if (statuses.contains('Discharging')) {
    return true;
  }
  return statuses.isEmpty ? null : false;
}

// SYSTEM_POWER_STATUS: ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag, then two DWORD
const _powerStatusLength = 12;

typedef _GetSystemPowerStatusNative = Int32 Function(Pointer<Uint8>);
typedef _GetSystemPowerStatus = int Function(Pointer<Uint8>);

bool? _windows() {
  final call = DynamicLibrary.open(
    'kernel32.dll',
  ).lookupFunction<_GetSystemPowerStatusNative, _GetSystemPowerStatus>('GetSystemPowerStatus');
  return using((arena) {
    final status = arena<Uint8>(_powerStatusLength);
    if (call(status) == 0) {
      return null;
    }
    return onBatteryFromPowerStatus(acLineStatus: status[0], batteryFlag: status[1]);
  });
}
