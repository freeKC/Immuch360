// Whether the connection is metered (issue 21): what Windows, NetworkManager and the macOS runner answer, read the
// way the automatic update of the AI components needs; the programs are replaced, nothing runs.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/platform/metered_connection.dart';

void main() {
  test('Windows: Fixed or Variable, roaming or over the data limit is metered; Unrestricted is not', () {
    expect(windowsCostIsMetered('Unrestricted False False\r\n'), isFalse);
    expect(windowsCostIsMetered('Fixed False False'), isTrue);
    expect(windowsCostIsMetered('Variable False False'), isTrue);
    expect(windowsCostIsMetered('Unrestricted True False'), isTrue);
    expect(windowsCostIsMetered('Unrestricted False True'), isTrue);
    expect(windowsCostIsMetered('Unknown False False'), isNull);
    expect(windowsCostIsMetered('none'), isNull);
    expect(windowsCostIsMetered(''), isNull);
  });

  test('NetworkManager: yes and guessed yes are metered, no and guessed no are not, unknown tells nothing', () {
    expect(networkManagerIsMetered('u 1\n'), isTrue);
    expect(networkManagerIsMetered('u 3'), isTrue);
    expect(networkManagerIsMetered('u 2'), isFalse);
    expect(networkManagerIsMetered('u 4'), isFalse);
    expect(networkManagerIsMetered('u 0'), isNull);
    expect(networkManagerIsMetered('method return time=1 sender=:1.4\n   variant       uint32 4\n'), isFalse);
    expect(networkManagerIsMetered('Failed to get property'), isNull);
  });

  test('Windows asks the PowerShell of the system for the cost of the connection profile', () async {
    final calls = <List<String>>[];
    final metered = await desktopMeteredConnection(
      operatingSystem: 'windows',
      run: (program, arguments) async {
        calls.add([program, ...arguments]);
        return 'Fixed False False\r\n';
      },
    );

    expect(metered, isTrue);
    expect(calls.single.first, endsWith(r'System32\WindowsPowerShell\v1.0\powershell.exe'));
    expect(calls.single, containsAll(['-NoProfile', '-NonInteractive', '-Command', windowsConnectionCostScript]));
  });

  test('Linux asks busctl, then dbus-send when busctl is not there; neither tells nothing', () async {
    final asked = <String>[];
    Future<bool?> on(Map<String, String?> answers) => desktopMeteredConnection(
      operatingSystem: 'linux',
      run: (program, arguments) async {
        asked.add(program);
        return answers[program];
      },
    );

    expect(await on({'busctl': 'u 2'}), isFalse);
    expect(asked, ['busctl']);
    asked.clear();
    expect(await on({'dbus-send': '   variant       uint32 1'}), isTrue);
    expect(asked, ['busctl', 'dbus-send']);
    expect(await on({}), isNull);
  });

  test('macOS asks the runner; another system tells nothing', () async {
    expect(await desktopMeteredConnection(operatingSystem: 'macos', mac: () async => true), isTrue);
    expect(await desktopMeteredConnection(operatingSystem: 'fuchsia'), isNull);
  });
}
