// Whether the computer runs on its battery (lot C6; design-final 2026-10-27, section 4.7, point 5): what
// GetSystemPowerStatus says on Windows, the supplies of /sys/class/power_supply on Linux (a laptop plugged in or not,
// a desktop, the battery of a mouse, a battery that says nothing), and the probe of this computer answering.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/power_probe.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('power_probe_test_'));
  tearDown(() => folder.deleteSync(recursive: true));

  void supply(String name, Map<String, String> files) {
    final entry = Directory(p.join(folder.path, name))..createSync();
    for (final MapEntry(key: file, value: text) in files.entries) {
      File(p.join(entry.path, file)).writeAsStringSync('$text\n');
    }
  }

  group('Windows', () {
    test('on battery, on the mains, unknown; a desktop has no system battery', () {
      expect(onBatteryFromPowerStatus(acLineStatus: 0, batteryFlag: 1), isTrue);
      expect(onBatteryFromPowerStatus(acLineStatus: 1, batteryFlag: 8), isFalse);
      expect(onBatteryFromPowerStatus(acLineStatus: 255, batteryFlag: 1), isNull);
      expect(onBatteryFromPowerStatus(acLineStatus: 255, batteryFlag: 128), isFalse);
    });
  });

  group('Linux', () {
    test('a laptop plugged in: the mains online', () {
      supply('AC', {'type': 'Mains', 'online': '1'});
      supply('BAT0', {'type': 'Battery', 'status': 'Charging'});
      expect(onBatteryFromPowerSupply(folder), isFalse);
    });

    test('a laptop on its battery: the mains offline, the battery discharging', () {
      supply('ADP1', {'type': 'Mains', 'online': '0'});
      supply('BAT0', {'type': 'Battery', 'status': 'Discharging'});
      expect(onBatteryFromPowerSupply(folder), isTrue);
    });

    test('plugged in through USB C', () {
      supply('ucsi-source-psy-USBC000:001', {'type': 'USB', 'online': '1'});
      supply('BAT1', {'type': 'Battery', 'status': 'Discharging'});
      expect(onBatteryFromPowerSupply(folder), isFalse);
    });

    test('a desktop with a wireless mouse: no battery of the system', () {
      supply('hidpp_battery_0', {'type': 'Battery', 'scope': 'Device', 'status': 'Discharging'});
      expect(onBatteryFromPowerSupply(folder), isFalse);
      folder.listSync().forEach((entry) => entry.deleteSync(recursive: true));
      expect(onBatteryFromPowerSupply(folder), isFalse);
    });

    test('a full battery without a mains supply listed is on the mains; one that says nothing is not known', () {
      supply('BAT0', {'type': 'Battery', 'status': 'Full'});
      expect(onBatteryFromPowerSupply(folder), isFalse);
      Directory(p.join(folder.path, 'BAT0')).deleteSync(recursive: true);
      supply('BAT0', {'type': 'Battery', 'status': 'Unknown'});
      expect(onBatteryFromPowerSupply(folder), isNull);
    });

    test('no such folder: not known', () {
      expect(onBatteryFromPowerSupply(Directory(p.join(folder.path, 'missing'))), isNull);
    });
  });

  test('the probe of this computer answers without failing', () {
    final answer = const SystemPowerProbe().onBattery();
    expect(answer, anyOf(isNull, isTrue, isFalse));
  });
}
