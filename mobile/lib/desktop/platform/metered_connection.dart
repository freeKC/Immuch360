// Whether the connection of this computer is metered now (issue 21: the AI components never update by themselves on
// one), as each system tells it:
// - Windows: the cost of the internet connection profile (Windows.Networking.Connectivity, the one Windows Update
//   reads), through the Windows PowerShell that ships with Windows; Fixed or Variable, roaming or over the data limit
//   is metered.
// - Linux: the Metered property of NetworkManager on the system bus (busctl, else dbus-send); yes or a guess of yes is
//   metered. Without NetworkManager the system does not tell.
// - macOS: the path of the Network framework (an iPhone hotspot is expensive, Low Data Mode is constrained), asked
//   from the runner (macos/Runner/MainFlutterWindow.swift, channel immuch360/network).
// Null when the system does not tell, which the update takes as not metered. Nothing leaves the computer.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('MeteredConnection');

/// Runs a program and gives its output, null when it cannot run or fails; replaced in tests
typedef MeteredProgramRunner = Future<String?> Function(String program, List<String> arguments);

/// The script that prints the cost of the internet connection profile: "Unrestricted False False", or "none"
const windowsConnectionCostScript =
    r"$ErrorActionPreference='Stop';"
    r'[void][Windows.Networking.Connectivity.NetworkInformation,'
    r'Windows.Networking.Connectivity,ContentType=WindowsRuntime];'
    r'$p=[Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile();'
    r"if($p -eq $null){'none'}else{$c=$p.GetConnectionCost();"
    r"'{0} {1} {2}' -f $c.NetworkCostType,$c.Roaming,$c.OverDataLimit}";

/// Whether the output of [windowsConnectionCostScript] says metered; null when it does not tell
bool? windowsCostIsMetered(String output) {
  final words = output.trim().split(RegExp(r'\s+'));
  if (words.length < 3) {
    return null;
  }
  if (words[1] == 'True' || words[2] == 'True') {
    return true;
  }
  return switch (words[0]) {
    'Fixed' || 'Variable' => true,
    'Unrestricted' => false,
    _ => null,
  };
}

/// Whether the Metered property of NetworkManager, as busctl ("u 4") or dbus-send ("variant uint32 4") prints it,
/// says metered: 1 (yes) and 3 (guessed yes) are, 2 (no) and 4 (guessed no) are not; null for 0 (unknown) or another
/// output
bool? networkManagerIsMetered(String output) {
  final value = RegExp(r'(\d+)\s*$').firstMatch(output.trim())?.group(1);
  return switch (value) {
    '1' || '3' => true,
    '2' || '4' => false,
    _ => null,
  };
}

Future<String?> _runProgram(String program, List<String> arguments) async {
  try {
    final result = await Process.run(program, arguments).timeout(const Duration(seconds: 15));
    if (result.exitCode != 0) {
      return null;
    }
    return '${result.stdout}';
  } on Object catch (error) {
    _log.fine('$program could not tell whether the connection is metered: $error');
    return null;
  }
}

const _macChannel = MethodChannel('immuch360/network');

Future<bool?> _macMetered() async {
  try {
    return await _macChannel.invokeMethod<bool>('isMetered');
  } on Object catch (error) {
    _log.fine('the runner did not tell whether the connection is metered: $error');
    return null;
  }
}

/// Whether the connection of this computer is metered now; see the top of this file
Future<bool?> desktopMeteredConnection({
  MeteredProgramRunner run = _runProgram,
  String? operatingSystem,
  Future<bool?> Function()? mac,
}) async {
  switch (operatingSystem ?? Platform.operatingSystem) {
    case 'windows':
      final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final powershell = p.windows.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
      final output = await run(powershell, ['-NoProfile', '-NonInteractive', '-Command', windowsConnectionCostScript]);
      return output == null ? null : windowsCostIsMetered(output);
    case 'linux':
      const property = ['org.freedesktop.NetworkManager', '/org/freedesktop/NetworkManager'];
      final output =
          await run('busctl', ['--system', 'get-property', ...property, 'org.freedesktop.NetworkManager', 'Metered']) ??
          await run('dbus-send', [
            '--system',
            '--print-reply',
            '--dest=${property[0]}',
            property[1],
            'org.freedesktop.DBus.Properties.Get',
            'string:org.freedesktop.NetworkManager',
            'string:Metered',
          ]);
      return output == null ? null : networkManagerIsMetered(output);
    case 'macos':
      return (mac ?? _macMetered)();
    default:
      return null;
  }
}
